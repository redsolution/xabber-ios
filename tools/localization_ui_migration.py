#!/usr/bin/env python3
"""Apply reviewed hard-coded UI localization mappings.

The scanner in ``localization_manifest`` owns the presentation-sink contract.
This module consumes its token offsets so audit and rewrite cannot silently
drift apart. Mapping files are intentionally explicit: every source string is
scoped by path and sink and every catalog entry carries all shipped locales.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

import localization_manifest as manifest
from localization_catalog import (
    CatalogError,
    LOCALES,
    format_argument_count,
    load_catalog,
    parse_format_signature,
)


class MigrationError(RuntimeError):
    pass


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _canonical_fallback(entry: dict[str, Any]) -> str:
    return entry.get("fallback", entry["value"])


def validate_migrations(entries: list[dict[str, Any]]) -> None:
    required = {"path", "sink", "value", "key", "comment", "translations"}
    allowed = required | {"fallback", "api"}
    seen_triples: dict[tuple[str, str, str], str] = {}
    by_key: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for index, entry in enumerate(entries):
        context = f"migration {index}"
        if not isinstance(entry, dict):
            raise MigrationError(f"{context} must be an object")
        missing = sorted(required - set(entry))
        unknown = sorted(set(entry) - allowed)
        if missing or unknown:
            raise MigrationError(
                f"{context} fields do not match schema: "
                f"missing {missing}, unknown {unknown}"
            )
        for field in ("path", "sink", "value", "key", "comment"):
            if not _nonempty_string(entry[field]):
                raise MigrationError(f"{context} {field} must be non-empty")
        if Path(entry["path"]).is_absolute() or ".." in Path(entry["path"]).parts:
            raise MigrationError(f"{context} path must be repository-relative")
        if "fallback" in entry and not _nonempty_string(entry["fallback"]):
            raise MigrationError(f"{context} fallback must be non-empty")
        if entry.get("api", "auto") not in {"auto", "text", "format"}:
            raise MigrationError(f"{context} api must be text, format, or auto")

        localized = entry["translations"]
        if not isinstance(localized, dict) or set(localized) != set(LOCALES) or any(
            not _nonempty_string(localized.get(locale)) for locale in LOCALES
        ):
            raise MigrationError(
                f"{context} translations must contain exactly six non-empty locales"
            )
        fallback = _canonical_fallback(entry)
        if localized["en"] != fallback:
            raise MigrationError(
                f"{context} English translation must equal its canonical fallback"
            )

        identity = (entry["path"], entry["sink"], entry["value"])
        previous = seen_triples.get(identity)
        if previous is not None and previous != entry["key"]:
            raise MigrationError(
                f"{context} conflicts with another key for {identity!r}"
            )
        seen_triples[identity] = entry["key"]
        by_key[entry["key"]].append(entry)

    for key, key_entries in sorted(by_key.items()):
        fallbacks = {_canonical_fallback(entry) for entry in key_entries}
        translations = {
            tuple(entry["translations"][locale] for locale in LOCALES)
            for entry in key_entries
        }
        if len(fallbacks) != 1 or len(translations) != 1:
            raise MigrationError(
                f"Localization key {key!r} has conflicting canonical values"
            )


def load_mapping_files(paths: Iterable[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    migrations: list[dict[str, Any]] = []
    exclusions: list[dict[str, Any]] = []
    for path in paths:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise MigrationError(f"Could not read mapping {path}: {error}") from error
        if not isinstance(document, dict) or set(document) != {"migrations", "exclusions"}:
            raise MigrationError(
                f"Mapping {path} must contain exactly migrations and exclusions"
            )
        if not isinstance(document["migrations"], list) or not isinstance(
            document["exclusions"], list
        ):
            raise MigrationError(f"Mapping {path} arrays are invalid")
        migrations.extend(document["migrations"])
        exclusions.extend(document["exclusions"])
    validate_migrations(migrations)
    return migrations, exclusions


def _interpolation_expressions(literal: str) -> list[str]:
    descriptor = manifest._string_start(literal, 0)
    if descriptor is None or manifest._string_end(literal, 0) != len(literal):
        raise MigrationError(f"Invalid Swift string literal: {literal!r}")
    hashes, multiline = descriptor
    opening_length = hashes + (3 if multiline else 1)
    closing_length = (3 if multiline else 1) + hashes
    content = literal[opening_length:-closing_length]
    escape = "\\" + ("#" * hashes)
    interpolation = escape + "("
    expressions: list[str] = []
    cursor = 0
    while cursor < len(content):
        if not content.startswith(interpolation, cursor):
            cursor += 1
            continue
        opening = cursor + len(escape)
        end = manifest._interpolation_end(content, opening)
        expression = content[opening + 1 : end - 1].strip()
        if not expression:
            raise MigrationError(f"Empty interpolation in {literal!r}")
        expressions.append(expression)
        cursor = end
    return expressions


def _swift_literal(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _replacement(entry: dict[str, Any], literal: str) -> str:
    key = _swift_literal(entry["key"])
    fallback_value = _canonical_fallback(entry)
    fallback = _swift_literal(fallback_value)
    expressions = _interpolation_expressions(literal)
    api = entry.get("api", "auto")
    if api == "auto":
        api = "format" if expressions else "text"
    if api == "text":
        if expressions:
            raise MigrationError(
                f"Text migration {entry['key']!r} contains interpolation"
            )
        return f"L10n.text({key}, fallback: {fallback})"
    if not expressions:
        raise MigrationError(
            f"Format migration {entry['key']!r} contains no interpolation"
        )
    try:
        expected_count = format_argument_count(parse_format_signature(fallback_value))
    except CatalogError as error:
        raise MigrationError(
            f"Invalid format fallback for {entry['key']!r}: {error}"
        ) from error
    if expected_count != len(expressions):
        raise MigrationError(
            f"Format migration {entry['key']!r} has {len(expressions)} "
            f"interpolations but {expected_count} format arguments"
        )
    arguments = ", ".join(
        f"String(describing: {expression})" for expression in expressions
    )
    return (
        f"L10n.format({key}, fallback: {fallback}, "
        f"arguments: [{arguments}])"
    )


def rewrite_swift_source(
    source: str,
    path: str,
    entries: list[dict[str, Any]],
) -> tuple[str, set[int]]:
    """Rewrite reviewed candidates and return local mapping indices matched."""

    exact: dict[tuple[str, str], list[int]] = defaultdict(list)
    by_value: dict[str, list[int]] = defaultdict(list)
    for index, entry in enumerate(entries):
        if entry["path"] != path:
            continue
        exact[(entry["sink"], entry["value"])].append(index)
        by_value[entry["value"]].append(index)

    source_without_comments = manifest.mask_swift_comments(source)
    candidates = manifest._hardcoded_candidate_tokens(
        source,
        source_without_comments,
        path,
    )
    replacements: list[tuple[int, int, str]] = []
    matched: set[int] = set()
    for candidate in candidates:
        indices = exact.get((candidate["sink"], candidate["value"]), [])
        if not indices:
            indices = by_value.get(candidate["value"], [])
            keys = {entries[index]["key"] for index in indices}
            if len(keys) > 1:
                raise MigrationError(
                    f"Candidate {path}:{candidate['line']} {candidate['value']!r} "
                    "has an ambiguous path/value migration"
                )
        if not indices:
            continue
        keys = {entries[index]["key"] for index in indices}
        if len(keys) != 1:
            raise MigrationError(
                f"Candidate {path}:{candidate['line']} maps to multiple keys"
            )
        entry = entries[indices[0]]
        replacements.append(
            (
                candidate["start"],
                candidate["end"],
                _replacement(entry, candidate["literal"]),
            )
        )
        matched.update(indices)

    rewritten = source
    for start, end, replacement in sorted(replacements, reverse=True):
        rewritten = rewritten[:start] + replacement + rewritten[end:]
    return rewritten, matched


def _string_unit(value: str) -> dict[str, Any]:
    return {"stringUnit": {"state": "translated", "value": value}}


def _existing_value(localization: Any) -> str | None:
    if not isinstance(localization, dict):
        return None
    unit = localization.get("stringUnit")
    if not isinstance(unit, dict):
        return None
    value = unit.get("value")
    return value if _nonempty_string(value) else None


def merge_catalog(
    document: dict[str, Any],
    entries: list[dict[str, Any]],
) -> dict[str, Any]:
    validate_migrations(entries)
    if document.get("sourceLanguage") != "en" or document.get("version") != "1.0":
        raise MigrationError("Catalog must use English source language and version 1.0")
    strings = document.get("strings")
    if not isinstance(strings, dict):
        raise MigrationError("Catalog strings must be an object")

    merged = copy.deepcopy(document)
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        grouped[entry["key"]].append(entry)

    for key in sorted(grouped):
        key_entries = grouped[key]
        translations = key_entries[0]["translations"]
        comments = sorted({entry["comment"].strip() for entry in key_entries})
        catalog_entry = merged["strings"].setdefault(
            key,
            {"extractionState": "manual", "localizations": {}},
        )
        if not isinstance(catalog_entry, dict):
            raise MigrationError(f"Catalog entry {key!r} is invalid")
        catalog_entry["extractionState"] = "manual"
        if not _nonempty_string(catalog_entry.get("comment")):
            catalog_entry["comment"] = " ".join(comments)
        localizations = catalog_entry.setdefault("localizations", {})
        if not isinstance(localizations, dict):
            raise MigrationError(f"Catalog localizations for {key!r} are invalid")

        existing_english = _existing_value(localizations.get("en"))
        if existing_english is not None and existing_english != translations["en"]:
            raise MigrationError(
                f"Catalog English for {key!r} conflicts with migration fallback"
            )
        for locale in LOCALES:
            if _existing_value(localizations.get(locale)) is None:
                localizations[locale] = _string_unit(translations[locale])
    return merged


def render_catalog(document: dict[str, Any]) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def apply_migrations(
    root: Path,
    catalog_path: Path,
    entries: list[dict[str, Any]],
    *,
    write: bool,
) -> dict[str, Any]:
    validate_migrations(entries)
    by_path: dict[str, list[tuple[int, dict[str, Any]]]] = defaultdict(list)
    for index, entry in enumerate(entries):
        by_path[entry["path"]].append((index, entry))

    rewritten_sources: dict[Path, str] = {}
    matched_global: set[int] = set()
    for relative_path in sorted(by_path):
        source_path = root / relative_path
        if not source_path.is_file():
            raise MigrationError(f"Migration source is missing: {relative_path}")
        indexed_entries = by_path[relative_path]
        local_entries = [entry for _, entry in indexed_entries]
        source = source_path.read_text(encoding="utf-8")
        rewritten, local_matches = rewrite_swift_source(
            source,
            relative_path,
            local_entries,
        )
        for local_index in local_matches:
            matched_global.add(indexed_entries[local_index][0])
        rewritten_sources[source_path] = rewritten

    unmatched = [
        f"{entry['path']} {entry['sink']} {entry['value']!r}"
        for index, entry in enumerate(entries)
        if index not in matched_global
    ]
    if unmatched:
        preview = "; ".join(unmatched[:5])
        raise MigrationError(
            f"{len(unmatched)} migration entries matched no source candidate: {preview}"
        )

    try:
        catalog = load_catalog(catalog_path)
    except CatalogError as error:
        raise MigrationError(str(error)) from error
    merged_catalog = merge_catalog(catalog, entries)
    if write:
        for path, rewritten in rewritten_sources.items():
            path.write_text(rewritten, encoding="utf-8")
        catalog_path.write_text(render_catalog(merged_catalog), encoding="utf-8")
    return {
        "catalogKeys": len({entry["key"] for entry in entries}),
        "files": len(rewritten_sources),
        "migrations": len(entries),
    }


def check_applied_migrations(
    root: Path,
    catalog_path: Path,
    entries: list[dict[str, Any]],
) -> dict[str, Any]:
    """Verify that reviewed migrations remain applied to source and catalog."""

    validate_migrations(entries)
    by_path: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        by_path[entry["path"]].append(entry)

    for relative_path in sorted(by_path):
        source_path = root / relative_path
        if not source_path.is_file():
            raise MigrationError(f"Migration source is missing: {relative_path}")
        source = manifest.mask_swift_comments(
            source_path.read_text(encoding="utf-8")
        )
        for entry in by_path[relative_path]:
            encoded_key = re.escape(_swift_literal(entry["key"]))
            facade_lookup = re.compile(
                rf"\bL10n\s*\.\s*"
                rf"(?:text|format|plural|attributedMarkdown)\s*\(\s*"
                rf"(?:key\s*:\s*)?{encoded_key}"
            )
            instance_lookup = re.compile(
                rf"\b(?:self\s*\.\s*)?[a-z_][A-Za-z0-9_]*\s*\.\s*"
                rf"(?:text|format|plural|attributedMarkdown)\s*\(\s*"
                rf"key\s*:\s*{encoded_key}"
            )
            if (
                facade_lookup.search(source) is None
                and instance_lookup.search(source) is None
            ):
                raise MigrationError(
                    f"Localization lookup is missing from {relative_path}: "
                    f"{entry['key']!r}"
                )

    try:
        catalog = load_catalog(catalog_path)
    except CatalogError as error:
        raise MigrationError(str(error)) from error
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise MigrationError("Catalog strings must be an object")

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        grouped[entry["key"]].append(entry)
    for key, key_entries in sorted(grouped.items()):
        catalog_entry = strings.get(key)
        if not isinstance(catalog_entry, dict):
            raise MigrationError(f"Catalog entry is missing: {key!r}")
        localizations = catalog_entry.get("localizations")
        if not isinstance(localizations, dict):
            raise MigrationError(f"Catalog localizations are missing: {key!r}")
        missing_locales = [
            locale
            for locale in LOCALES
            if _existing_value(localizations.get(locale)) is None
        ]
        if missing_locales:
            raise MigrationError(
                f"Catalog entry {key!r} has empty locales: "
                f"{', '.join(missing_locales)}"
            )
        expected_english = _canonical_fallback(key_entries[0])
        actual_english = _existing_value(localizations.get("en"))
        if actual_english != expected_english:
            raise MigrationError(
                f"Catalog English for {key!r} is {actual_english!r}; "
                f"expected {expected_english!r}"
            )

    return {
        "catalogKeys": len(grouped),
        "files": len(by_path),
        "migrations": len(entries),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply"))
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("xabber/translations/Localizable.xcstrings"),
    )
    parser.add_argument("mapping", nargs="+", type=Path)
    arguments = parser.parse_args(argv)
    try:
        migrations, _ = load_mapping_files(arguments.mapping)
        root = arguments.root.resolve()
        catalog = arguments.catalog
        if not catalog.is_absolute():
            catalog = root / catalog
        if arguments.command == "apply":
            result = apply_migrations(root, catalog, migrations, write=True)
        else:
            result = check_applied_migrations(root, catalog, migrations)
    except (MigrationError, CatalogError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    verb = "Applied" if arguments.command == "apply" else "Validated"
    print(
        f"{verb} {result['migrations']} migrations across "
        f"{result['files']} files and {result['catalogKeys']} catalog keys."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
