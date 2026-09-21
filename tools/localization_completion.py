#!/usr/bin/env python3
"""Complete and export translations for manifest-owned localization keys."""

from __future__ import annotations

import argparse
import copy
import csv
import io
import json
import sys
from pathlib import Path
from typing import Any

import localization_catalog


LOCALES = localization_catalog.LOCALES
TARGET_LOCALES = tuple(locale for locale in LOCALES if locale != "en")


class CompletionError(RuntimeError):
    pass


def active_key_ids(manifest: dict[str, Any]) -> list[str]:
    keys: list[str] = []
    for field in ("activeKeys", "domainReservedKeys"):
        entries = manifest.get(field, [])
        if not isinstance(entries, list):
            raise CompletionError(f"Manifest {field} must be an array")
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("key"), str):
                raise CompletionError(f"Manifest {field} has an invalid key entry")
            keys.append(entry["key"])
    duplicates = sorted(key for key in set(keys) if keys.count(key) > 1)
    if duplicates:
        raise CompletionError(f"Manifest repeats active keys: {duplicates}")
    return sorted(keys)


def _string_unit_values(value: Any) -> list[str]:
    values: list[str] = []
    if isinstance(value, dict):
        string_unit = value.get("stringUnit")
        if isinstance(string_unit, dict) and isinstance(string_unit.get("value"), str):
            values.append(string_unit["value"])
        for key, child in value.items():
            if key != "stringUnit":
                values.extend(_string_unit_values(child))
    elif isinstance(value, list):
        for child in value:
            values.extend(_string_unit_values(child))
    return values


def localization_has_value(localization: Any) -> bool:
    values = _string_unit_values(localization)
    return bool(values) and all(value.strip() for value in values)


def _translated(value: str = "") -> dict[str, Any]:
    return {"stringUnit": {"state": "translated", "value": value}}


def _target_categories(locale: str) -> list[str]:
    preferred = ("zero", "one", "two", "few", "many", "other")
    supported = localization_catalog.PLURAL_CATEGORIES[locale]
    return [category for category in preferred if category in supported]


def _blank_translation(source: dict[str, Any], locale: str) -> dict[str, Any]:
    if "substitutions" in source:
        result = {
            "stringUnit": _translated()["stringUnit"],
            "substitutions": {},
        }
        for name, substitution in sorted(source["substitutions"].items()):
            result["substitutions"][name] = {
                "formatSpecifier": substitution["formatSpecifier"],
                "variations": {
                    "plural": {
                        category: _translated()
                        for category in _target_categories(locale)
                    }
                },
            }
        return result
    if "variations" in source:
        return {
            "variations": {
                "plural": {
                    category: _translated()
                    for category in _target_categories(locale)
                }
            }
        }
    if "stringUnit" in source:
        return _translated()
    raise CompletionError("English localization has no supported string structure")


def missing_keys(
    catalog: dict[str, Any], manifest: dict[str, Any], locale: str
) -> list[str]:
    if locale not in LOCALES:
        raise CompletionError(f"Unsupported locale {locale!r}")
    strings = catalog.get("strings", {})
    missing: list[str] = []
    for key in active_key_ids(manifest):
        entry = strings.get(key)
        if not isinstance(entry, dict):
            raise CompletionError(f"Active key {key!r} is absent from the catalog")
        localization = entry.get("localizations", {}).get(locale)
        if not localization_has_value(localization):
            missing.append(key)
    return missing


def build_packet(
    catalog: dict[str, Any], manifest: dict[str, Any], locale: str
) -> dict[str, Any]:
    if locale not in TARGET_LOCALES:
        raise CompletionError(f"Translation packets require one of {TARGET_LOCALES}")
    translations: dict[str, Any] = {}
    for key in missing_keys(catalog, manifest, locale):
        entry = catalog["strings"][key]
        english = entry.get("localizations", {}).get("en")
        if not localization_has_value(english):
            raise CompletionError(f"Active key {key!r} has no canonical English")
        packet_entry: dict[str, Any] = {
            "source": copy.deepcopy(english),
            "translation": _blank_translation(english, locale),
        }
        comment = entry.get("comment")
        if isinstance(comment, str) and comment.strip():
            packet_entry["comment"] = comment
        translations[key] = packet_entry
    return {
        "locale": locale,
        "sourceLanguage": "en",
        "translations": translations,
        "version": 1,
    }


def apply_packet(
    catalog: dict[str, Any], manifest: dict[str, Any], packet: dict[str, Any]
) -> dict[str, Any]:
    locale = packet.get("locale")
    if locale not in TARGET_LOCALES:
        raise CompletionError(f"Packet has unsupported locale {locale!r}")
    if packet.get("sourceLanguage") != "en" or packet.get("version") != 1:
        raise CompletionError("Packet source language or version is invalid")
    translations = packet.get("translations")
    if not isinstance(translations, dict):
        raise CompletionError("Packet translations must be an object")
    expected = set(missing_keys(catalog, manifest, locale))
    actual = set(translations)
    if actual != expected:
        raise CompletionError(
            f"Packet key mismatch for {locale}; "
            f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
        )

    result = copy.deepcopy(catalog)
    for key in sorted(translations):
        packet_entry = translations[key]
        if not isinstance(packet_entry, dict):
            raise CompletionError(f"Packet entry {key!r} must be an object")
        source = result["strings"][key]["localizations"]["en"]
        if packet_entry.get("source") != source:
            raise CompletionError(f"Packet source drift for {key!r}")
        translation = packet_entry.get("translation")
        if not localization_has_value(translation):
            raise CompletionError(f"Packet has blank translated value for {key!r}")
        result["strings"][key]["localizations"][locale] = copy.deepcopy(
            translation
        )
    return result


def _cell_value(localization: Any) -> str:
    if not localization_has_value(localization):
        return ""
    if "substitutions" in localization:
        substitutions = {}
        for name, substitution in sorted(localization["substitutions"].items()):
            variations = substitution["variations"]["plural"]
            substitutions[name] = {
                "formatSpecifier": substitution["formatSpecifier"],
                "plural": {
                    category: variation["stringUnit"]["value"]
                    for category, variation in sorted(variations.items())
                },
            }
        value = {
            "template": localization["stringUnit"]["value"],
            "substitutions": substitutions,
        }
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if "variations" in localization:
        variations = localization["variations"]["plural"]
        value = {
            category: variation["stringUnit"]["value"]
            for category, variation in sorted(variations.items())
        }
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return localization["stringUnit"]["value"]


def translation_table_rows(
    catalog: dict[str, Any], manifest: dict[str, Any]
) -> list[list[str]]:
    rows = [["id", *LOCALES]]
    for key in active_key_ids(manifest):
        localizations = catalog["strings"][key].get("localizations", {})
        row = [key]
        for locale in LOCALES:
            localization = localizations.get(locale)
            if not localization_has_value(localization):
                raise CompletionError(f"Missing table value for {key!r}/{locale}")
            row.append(_cell_value(localization))
        rows.append(row)
    return rows


def translation_csv_text(rows: list[list[str]]) -> str:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerows(rows)
    return stream.getvalue()


def _load(path: Path) -> dict[str, Any]:
    return localization_catalog.load_catalog(path)


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _report(catalog: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    manifest_owned = active_key_ids(manifest)
    missing = {
        locale: missing_keys(catalog, manifest, locale) for locale in LOCALES
    }
    return {
        "activeKeys": len(manifest.get("activeKeys", [])),
        "domainReservedKeys": len(manifest.get("domainReservedKeys", [])),
        "manifestOwnedKeys": len(manifest_owned),
        "missing": {locale: len(keys) for locale, keys in missing.items()},
        "missingTotal": sum(len(keys) for keys in missing.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "packet",
            "apply",
            "check",
            "report",
            "table-json",
            "csv",
            "check-csv",
        ),
    )
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--locale", choices=TARGET_LOCALES)
    parser.add_argument("--packet", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    try:
        catalog = _load(arguments.catalog)
        manifest = _load(arguments.manifest)
        if arguments.command == "packet":
            if arguments.locale is None or arguments.output is None:
                parser.error("packet requires --locale and --output")
            _write_json(
                arguments.output,
                build_packet(catalog, manifest, arguments.locale),
            )
        elif arguments.command == "apply":
            if arguments.packet is None or arguments.output is None:
                parser.error("apply requires --packet and --output")
            merged = apply_packet(catalog, manifest, _load(arguments.packet))
            localization_catalog.validate_catalog(merged)
            _write_json(arguments.output, merged)
        elif arguments.command in ("table-json", "csv", "check-csv"):
            if arguments.output is None:
                parser.error(f"{arguments.command} requires --output")
            localization_catalog.validate_catalog(
                catalog,
                manifest=manifest,
                require_complete_translations=True,
            )
            rows = translation_table_rows(catalog, manifest)
            if arguments.command == "table-json":
                _write_json(arguments.output, rows)
            else:
                expected = translation_csv_text(rows)
                if arguments.command == "csv":
                    arguments.output.parent.mkdir(parents=True, exist_ok=True)
                    arguments.output.write_text(expected, encoding="utf-8")
                else:
                    try:
                        actual = arguments.output.read_text(encoding="utf-8")
                    except OSError as error:
                        raise CompletionError(
                            f"Could not read CSV {arguments.output}: {error}"
                        ) from error
                    if actual != expected:
                        raise CompletionError(
                            f"Translation CSV is stale: {arguments.output}"
                        )
        else:
            report = _report(catalog, manifest)
            if arguments.command == "check":
                localization_catalog.validate_catalog(
                    catalog,
                    manifest=manifest,
                    require_complete_translations=True,
                )
                if report["missingTotal"]:
                    raise CompletionError(f"Missing active translations: {report['missing']}")
            print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    except (CompletionError, localization_catalog.CatalogError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
