#!/usr/bin/env python3
"""Migrate and validate Xabber's legacy Localizable.strings resources."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


LOCALES = ("en", "ru", "fr", "es", "ar", "zh-Hans")
OMITTED_KEYS = {"chat"}
ADDITIONAL_STRINGS = {
    "settings_language_system": {"en": "System"},
}
DERIVED_PLURALS = {
    "chat_search_message_count": {
        "legacyBase": "plurals.chat_search_messages",
        "categories": {
            "en": {"one": 0, "other": 1},
            "ru": {"one": 0, "few": 1, "many": 2, "other": 3},
        },
    },
}
EXPECTED_DUPLICATES = {
    "en": {
        "chat": 2,
        "feedback": 2,
        "incognito_group_invitation": 2,
        "public_group_invitation": 2,
    }
}
EXPECTED_ACTIVE_VALUES = {
    "feedback": "Feedback",
    "incognito_group_invitation": "You are invited to join this incognito group",
    "public_group_invitation": "You are invited to join this public group",
}
PLACEHOLDER_CORRECTIONS = {
    ("fr", "no_permission_storage"): "Permission d’accéder au stockage refusée",
    ("fr", "plurals.account_connected_devices.item_0"): "1 appareil connecté",
    ("fr", "plurals.account_connected_devices.item_1"): "%d appareils connectés",
    ("ar", "plurals.blocked_contacts_number.item_0"): "%d جهة اتصال محظورة",
    ("ar", "plurals.blocked_contacts_number.item_1"): "%d جهات اتصال محظورة",
    (
        "ru",
        "plurals.chat_screen__bottom_panel__selected_messages__text.item_0",
    ): "Выбрано 1 сообщение",
}
ASSIGNMENT_PATTERN = re.compile(r'^\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*=', re.MULTILINE)
FORMAT_SPECIFIER_PATTERN = re.compile(
    r"%(?!%)(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"
)


class CatalogError(RuntimeError):
    pass


def read_strings(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise CatalogError(f"Could not parse {path}: {result.stderr.strip()}")
    parsed = json.loads(result.stdout)
    if not isinstance(parsed, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in parsed.items()
    ):
        raise CatalogError(f"{path} is not a string-to-string property list")
    return parsed


def duplicate_keys(path: Path) -> dict[str, int]:
    assignments = ASSIGNMENT_PATTERN.findall(path.read_text(encoding="utf-8"))
    counts = Counter(assignments)
    return {key: count for key, count in counts.items() if count > 1}


def read_legacy_resources(legacy_root: Path) -> dict[str, dict[str, str]]:
    resources: dict[str, dict[str, str]] = {}
    for locale in LOCALES:
        source = legacy_root / f"{locale}.lproj" / "Localizable.strings"
        if not source.is_file():
            raise CatalogError(f"Missing legacy resource: {source}")
        actual_duplicates = duplicate_keys(source)
        expected_duplicates = EXPECTED_DUPLICATES.get(locale, {})
        if actual_duplicates != expected_duplicates:
            raise CatalogError(
                f"Unexpected duplicate keys in {source}: "
                f"expected {expected_duplicates}, got {actual_duplicates}"
            )
        resources[locale] = read_strings(source)

    english = resources["en"]
    for key, expected_value in EXPECTED_ACTIVE_VALUES.items():
        if english.get(key) != expected_value:
            raise CatalogError(
                f"Unexpected active English value for {key!r}: {english.get(key)!r}"
            )
    return resources


def make_catalog(resources: dict[str, dict[str, str]]) -> dict[str, Any]:
    keys = sorted(set().union(*(localized.keys() for localized in resources.values())))
    strings: dict[str, Any] = {}
    for key in keys:
        if key in OMITTED_KEYS:
            continue
        localizations: dict[str, Any] = {}
        for locale in LOCALES:
            value = resources[locale].get(key)
            if value is None or not value.strip():
                continue
            value = PLACEHOLDER_CORRECTIONS.get((locale, key), value)
            localizations[locale] = {
                "stringUnit": {
                    "state": "translated",
                    "value": value,
                }
            }
        strings[key] = {
            "extractionState": "manual",
            "localizations": localizations,
        }

    for key, translations in ADDITIONAL_STRINGS.items():
        strings[key] = {
            "extractionState": "manual",
            "localizations": {
                locale: {
                    "stringUnit": {
                        "state": "translated",
                        "value": value,
                    }
                }
                for locale, value in translations.items()
            },
        }

    for key, configuration in DERIVED_PLURALS.items():
        localizations = {}
        for locale, categories in configuration["categories"].items():
            plural_variations = {}
            for category, index in categories.items():
                legacy_key = f'{configuration["legacyBase"]}.item_{index}'
                try:
                    value = resources[locale][legacy_key]
                except KeyError as error:
                    raise CatalogError(
                        f"Missing source for derived plural {key}/{locale}/{category}: "
                        f"{legacy_key}"
                    ) from error
                value = (
                    value.replace("%1$@", "%lld")
                    .replace("%@", "%lld")
                    .replace("%1$d", "%lld")
                    .replace("%d", "%lld")
                )
                plural_variations[category] = {
                    "stringUnit": {
                        "state": "translated",
                        "value": value,
                    }
                }
            localizations[locale] = {
                "variations": {
                    "plural": plural_variations,
                }
            }
        strings[key] = {
            "extractionState": "manual",
            "localizations": localizations,
        }
    return {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }


def write_catalog(catalog: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    output.write_text(rendered, encoding="utf-8")


def validate_catalog(
    catalog: dict[str, Any], resources: dict[str, dict[str, str]] | None = None
) -> dict[str, Any]:
    if catalog.get("sourceLanguage") != "en":
        raise CatalogError("Catalog sourceLanguage must be en")
    if catalog.get("version") != "1.0":
        raise CatalogError("Catalog version must be 1.0")
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise CatalogError("Catalog strings must be an object")
    if OMITTED_KEYS & strings.keys():
        raise CatalogError(f"Omitted keys are present: {sorted(OMITTED_KEYS & strings.keys())}")

    catalog_locales: set[str] = set()
    translations_by_locale = Counter()
    for key, entry in strings.items():
        if not isinstance(key, str) or not isinstance(entry, dict):
            raise CatalogError("Every catalog entry must be an object keyed by a string")
        if entry.get("extractionState") != "manual":
            raise CatalogError(f"{key!r} is not protected as a manual entry")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            raise CatalogError(f"{key!r} has invalid localizations")
        catalog_locales.update(localizations)
        for locale, localization in localizations.items():
            if locale not in LOCALES:
                raise CatalogError(f"{key!r} has unsupported locale {locale!r}")
            units = []
            if isinstance(localization, dict) and "stringUnit" in localization:
                units.append(localization["stringUnit"])
            elif isinstance(localization, dict) and "variations" in localization:
                try:
                    variations = localization["variations"]["plural"]
                    units.extend(
                        variation["stringUnit"] for variation in variations.values()
                    )
                except (KeyError, TypeError, AttributeError) as error:
                    raise CatalogError(
                        f"{key!r}/{locale} has invalid plural variations"
                    ) from error
            else:
                raise CatalogError(f"{key!r}/{locale} has no string unit or variation")
            for string_unit in units:
                try:
                    state = string_unit["state"]
                    value = string_unit["value"]
                except (KeyError, TypeError) as error:
                    raise CatalogError(f"{key!r}/{locale} is not a string unit") from error
                if state != "translated" or not isinstance(value, str) or not value.strip():
                    raise CatalogError(f"{key!r}/{locale} has an invalid translated value")
            translations_by_locale[locale] += 1

        english_signatures = localization_signatures(localizations.get("en"))
        if english_signatures is not None:
            for locale, localization in localizations.items():
                signatures = localization_signatures(localization)
                if signatures != english_signatures:
                    raise CatalogError(
                        f"Placeholder signature mismatch for {key!r}: "
                        f"en={english_signatures}, {locale}={signatures}"
                    )

    if catalog_locales != set(LOCALES):
        raise CatalogError(
            f"Catalog locales must be exactly {LOCALES}; got {sorted(catalog_locales)}"
        )

    locale_only_keys = {
        key
        for key, entry in strings.items()
        if "en" not in entry.get("localizations", {})
    }
    if resources is not None:
        expected_keys = set().union(*(localized.keys() for localized in resources.values()))
        expected_keys -= OMITTED_KEYS
        expected_keys.update(ADDITIONAL_STRINGS)
        expected_keys.update(DERIVED_PLURALS)
        if set(strings) != expected_keys:
            missing = sorted(expected_keys - set(strings))
            extra = sorted(set(strings) - expected_keys)
            raise CatalogError(f"Catalog key mismatch; missing={missing}, extra={extra}")

        for locale in LOCALES:
            for key, value in resources[locale].items():
                if key in OMITTED_KEYS or not value.strip():
                    continue
                expected = PLACEHOLDER_CORRECTIONS.get((locale, key), value)
                actual = (
                    strings.get(key, {})
                    .get("localizations", {})
                    .get(locale, {})
                    .get("stringUnit", {})
                    .get("value")
                )
                if actual != expected:
                    raise CatalogError(
                        f"Translation changed for {locale}/{key}: {expected!r} -> {actual!r}"
                    )
        expected_derived = make_catalog(resources)["strings"]
        for key in DERIVED_PLURALS:
            if strings[key] != expected_derived[key]:
                raise CatalogError(f"Derived plural {key!r} does not match its legacy forms")

        for key in ADDITIONAL_STRINGS:
            if strings[key] != expected_derived[key]:
                raise CatalogError(f"Additional string {key!r} has an unexpected value")

        locale_only_keys = (
            set().union(*(localized.keys() for localized in resources.values()))
            - set(resources["en"])
        )

    return {
        "keys": len(strings),
        "locales": list(LOCALES),
        "translations": {
            locale: translations_by_locale[locale] for locale in LOCALES
        },
        "localeOnlyKeys": len(locale_only_keys),
        "derivedPluralKeys": sorted(DERIVED_PLURALS),
    }


def localization_signatures(localization: Any) -> list[list[str]] | None:
    if not isinstance(localization, dict):
        return None
    values: list[str]
    if "stringUnit" in localization:
        values = [localization["stringUnit"].get("value", "")]
    else:
        try:
            values = [
                variation["stringUnit"].get("value", "")
                for variation in localization["variations"]["plural"].values()
            ]
        except (KeyError, TypeError, AttributeError):
            return None
    signatures = {
        tuple(sorted(FORMAT_SPECIFIER_PATTERN.findall(value)))
        for value in values
    }
    return [list(signature) for signature in sorted(signatures)]


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CatalogError(f"Could not read catalog {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise CatalogError(f"Catalog {path} must have a JSON object at its root")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    parser.add_argument(
        "--legacy-root",
        type=Path,
        help="validate against and optionally migrate the six legacy .lproj directories",
    )
    parser.add_argument(
        "--migrate",
        action="store_true",
        help="generate the catalog before validating it (requires --legacy-root)",
    )
    arguments = parser.parse_args()

    try:
        resources = (
            read_legacy_resources(arguments.legacy_root)
            if arguments.legacy_root is not None
            else None
        )
        if arguments.migrate:
            if resources is None:
                parser.error("--migrate requires --legacy-root")
            write_catalog(make_catalog(resources), arguments.catalog)
        report = validate_catalog(load_catalog(arguments.catalog), resources)
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
