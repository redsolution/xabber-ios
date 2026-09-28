#!/usr/bin/env python3
"""Audit material target-locale expansion for active localization strings."""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

import localization_catalog
import localization_completion


class LengthAuditError(RuntimeError):
    pass


_FORMAT_PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|q|z|t|j)?(?:@|[diuoxXfFeEgGaAcCsSp%])"
)
_SUBSTITUTION_PLACEHOLDER = re.compile(r"%#@[A-Za-z0-9_]+@")
_HTML_TAG = re.compile(r"<[^>]*>")
_MARKDOWN_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_PLURAL_CATEGORIES = frozenset({"zero", "one", "two", "few", "many", "other"})


def visible_text(value: str) -> str:
    """Return copy whose length approximates what the UI must lay out."""

    value = _MARKDOWN_LINK.sub(r"\1", value)
    value = _HTML_TAG.sub("", value)
    value = _SUBSTITUTION_PLACEHOLDER.sub("", value)
    value = _FORMAT_PLACEHOLDER.sub("", value)
    value = " ".join(value.replace("\\n", " ").split())
    return "".join(
        character
        for character in value
        if unicodedata.category(character) not in {"Cf", "Mn", "Me"}
    )


def display_width(value: str) -> int:
    """Return deterministic terminal-style columns for visible text."""

    return sum(
        2 if unicodedata.east_asian_width(character) in {"F", "W"} else 1
        for character in value
    )


def _string_units(value: Any, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], str]:
    units: dict[tuple[str, ...], str] = {}
    if not isinstance(value, dict):
        return units
    string_unit = value.get("stringUnit")
    if isinstance(string_unit, dict) and isinstance(string_unit.get("value"), str):
        units[path] = string_unit["value"]
    for key, child in value.items():
        if key != "stringUnit":
            units.update(_string_units(child, path + (key,)))
    return units


def _english_branch(
    english: dict[tuple[str, ...], str],
    target_path: tuple[str, ...],
) -> str | None:
    exact = english.get(target_path)
    if exact is not None:
        return exact
    for index, component in enumerate(target_path):
        if component not in _PLURAL_CATEGORIES:
            continue
        fallback_path = target_path[:index] + ("other",) + target_path[index + 1 :]
        fallback = english.get(fallback_path)
        if fallback is not None:
            return fallback
    if len(english) == 1:
        return next(iter(english.values()))
    return None


def _threshold(config: dict[str, Any], english_length: int) -> dict[str, Any]:
    thresholds = config.get("thresholds")
    if not isinstance(thresholds, list) or not thresholds:
        raise LengthAuditError("thresholds must be a non-empty array")
    for index, threshold in enumerate(thresholds):
        if not isinstance(threshold, dict):
            raise LengthAuditError(f"threshold {index} must be an object")
        maximum = threshold.get("maxEnglishLength")
        if maximum is None or english_length <= maximum:
            ratio = threshold.get("minimumRatio")
            extra = threshold.get("minimumExtra")
            if not isinstance(ratio, (int, float)) or ratio <= 1:
                raise LengthAuditError(f"threshold {index} has invalid minimumRatio")
            if not isinstance(extra, int) or extra < 1:
                raise LengthAuditError(f"threshold {index} has invalid minimumExtra")
            return threshold
    raise LengthAuditError("thresholds must end with an unbounded entry")


def _branch_name(path: tuple[str, ...]) -> str:
    return "/".join(path) if path else "stringUnit"


def _candidate_identity(candidate: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        candidate["key"],
        candidate["locale"],
        candidate["branch"],
        candidate["translation"],
    )


def _configured_exceptions(config: dict[str, Any]) -> dict[tuple[str, str, str, str], str]:
    configured = config.get("reviewedExceptions", [])
    if not isinstance(configured, list):
        raise LengthAuditError("reviewedExceptions must be an array")
    exceptions: dict[tuple[str, str, str, str], str] = {}
    for index, entry in enumerate(configured):
        if not isinstance(entry, dict):
            raise LengthAuditError(f"reviewed exception {index} must be an object")
        expected = {"key", "locale", "branch", "translation", "reason"}
        if set(entry) != expected:
            raise LengthAuditError(
                f"reviewed exception {index} must contain exactly {sorted(expected)}"
            )
        if not all(isinstance(entry[field], str) and entry[field].strip() for field in expected):
            raise LengthAuditError(f"reviewed exception {index} has a blank field")
        identity = (entry["key"], entry["locale"], entry["branch"], entry["translation"])
        if identity in exceptions:
            raise LengthAuditError(f"duplicate reviewed exception {identity!r}")
        exceptions[identity] = entry["reason"]
    return exceptions


def build_report(
    catalog: dict[str, Any],
    manifest: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any]:
    locales = config.get("locales")
    if not isinstance(locales, list) or not locales:
        raise LengthAuditError("locales must be a non-empty array")
    if len(set(locales)) != len(locales):
        raise LengthAuditError("locales must not contain duplicates")
    unsupported = [locale for locale in locales if locale not in localization_completion.TARGET_LOCALES]
    if unsupported:
        raise LengthAuditError(f"unsupported locales: {unsupported}")

    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise LengthAuditError("catalog strings must be an object")

    candidates: list[dict[str, Any]] = []
    for key in localization_completion.active_key_ids(manifest):
        entry = strings.get(key)
        if not isinstance(entry, dict):
            continue
        localizations = entry.get("localizations", {})
        english = _string_units(localizations.get("en"))
        if not english:
            continue
        for locale in locales:
            target = _string_units(localizations.get(locale))
            for target_path, translation in sorted(target.items()):
                source = _english_branch(english, target_path)
                if source is None:
                    continue
                visible_english = visible_text(source)
                visible_translation = visible_text(translation)
                english_length = display_width(visible_english)
                translation_length = display_width(visible_translation)
                if english_length < 2 or not visible_translation:
                    continue
                threshold = _threshold(config, english_length)
                ratio = translation_length / english_length
                extra = translation_length - english_length
                if ratio < threshold["minimumRatio"] or extra < threshold["minimumExtra"]:
                    continue
                candidates.append({
                    "branch": _branch_name(target_path),
                    "english": source,
                    "englishLength": english_length,
                    "extraCharacters": extra,
                    "key": key,
                    "locale": locale,
                    "ratio": round(ratio, 2),
                    "translation": translation,
                    "translationLength": translation_length,
                })

    candidates.sort(
        key=lambda item: (
            item["locale"],
            -item["ratio"],
            -item["extraCharacters"],
            item["key"],
            item["branch"],
        )
    )
    configured_exceptions = _configured_exceptions(config)
    matched: set[tuple[str, str, str, str]] = set()
    reviewed: list[dict[str, Any]] = []
    unreviewed: list[dict[str, Any]] = []
    for candidate in candidates:
        identity = _candidate_identity(candidate)
        reason = configured_exceptions.get(identity)
        if reason is None:
            unreviewed.append(candidate)
            continue
        matched.add(identity)
        reviewed.append({**candidate, "reason": reason})

    stale = sorted(set(configured_exceptions) - matched)
    if stale:
        raise LengthAuditError(f"stale reviewed exception: {stale[0]!r}")

    def counts(items: list[dict[str, Any]]) -> dict[str, int]:
        return {
            locale: sum(item["locale"] == locale for item in items)
            for locale in locales
        }

    return {
        "candidateCount": len(candidates),
        "candidatesByLocale": counts(candidates),
        "locales": locales,
        "manifestOwnedKeys": len(localization_completion.active_key_ids(manifest)),
        "reviewedExceptionCount": len(reviewed),
        "reviewedExceptions": reviewed,
        "unreviewedCandidateCount": len(unreviewed),
        "unreviewedCandidates": unreviewed,
        "unreviewedCandidatesByLocale": counts(unreviewed),
    }


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise LengthAuditError(f"could not read {path}: {error}") from error
    if not isinstance(value, dict):
        raise LengthAuditError(f"{path} must contain a JSON object")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("report", "check"))
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("xabber/translations/Localizable.xcstrings"),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("docs/localization/active-keys.json"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("tools/localization_length_config.json"),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = build_report(
            localization_catalog.load_catalog(args.catalog),
            _load_json(args.manifest),
            _load_json(args.config),
        )
        if args.command == "check" and report["unreviewedCandidates"]:
            first = report["unreviewedCandidates"][0]
            raise LengthAuditError(
                "unreviewed material translation expansion: "
                f"{first['key']}/{first['locale']} {first['branch']} "
                f"({first['englishLength']} -> {first['translationLength']})"
            )
    except (LengthAuditError, localization_catalog.CatalogError) as error:
        print(f"localization length audit failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
