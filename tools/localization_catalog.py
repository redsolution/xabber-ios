#!/usr/bin/env python3
"""Migrate and validate Xabber's legacy Localizable.strings resources."""

from __future__ import annotations

import argparse
import itertools
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
    r"%(?P<position>[1-9]\d*\$)?(?P<flags>[-+ #0']*)"
    r"(?:(?P<width>\d+)|(?P<width_star>\*)(?P<width_position>[1-9]\d*\$)?)?"
    r"(?:\.(?:(?P<precision>\d+)|(?P<precision_star>\*)"
    r"(?P<precision_position>[1-9]\d*\$)?))?"
    r"(?P<length>hh|h|ll|l|q|z|t|j|L)?"
    r"(?P<conversion>[@diuoxXfFeEgGaAcCsSp])"
)
SUBSTITUTION_SPECIFIER_PATTERN = re.compile(
    r"%(?P<position>[1-9]\d*\$)?#@(?P<name>[A-Za-z_][A-Za-z0-9_]*)@"
)

PLURAL_CATEGORIES = {
    "en": {"one", "other"},
    "ru": {"one", "few", "many", "other"},
    "fr": {"one", "many", "other"},
    "es": {"one", "many", "other"},
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "zh-Hans": {"other"},
}


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
    catalog: dict[str, Any],
    resources: dict[str, dict[str, str]] | None = None,
    manifest: dict[str, Any] | None = None,
    require_complete_translations: bool = False,
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
                string_unit = localization["stringUnit"]
                units.append(string_unit)
                substitutions = localization.get("substitutions")
                outer_value = (
                    string_unit.get("value")
                    if isinstance(string_unit, dict)
                    else None
                )
                outer_tokens = (
                    _format_tokens(outer_value)
                    if isinstance(outer_value, str)
                    else []
                )
                if substitutions is not None:
                    _, substitutions, _, _ = _validated_substitution_components(
                        localization
                    )
                    for name, substitution in substitutions.items():
                        try:
                            format_specifier = substitution["formatSpecifier"]
                            variations = substitution["variations"]["plural"]
                        except (KeyError, TypeError) as error:
                            raise CatalogError(
                                f"{key!r}/{locale}/{name} has an invalid substitution"
                            ) from error
                        if not isinstance(format_specifier, str) or not format_specifier:
                            raise CatalogError(
                                f"{key!r}/{locale}/{name} has an invalid format specifier"
                            )
                        if not isinstance(variations, dict):
                            raise CatalogError(
                                f"{key!r}/{locale}/{name} has invalid plural variations"
                            )
                        _validate_plural_categories(key, locale, variations, suffix=name)
                        try:
                            units.extend(
                                variation["stringUnit"]
                                for variation in variations.values()
                            )
                        except (KeyError, TypeError) as error:
                            raise CatalogError(
                                f"{key!r}/{locale}/{name} has invalid plural string units"
                            ) from error
                elif any(kind == "substitution" for kind, _ in outer_tokens):
                    raise CatalogError(
                        f"{key!r}/{locale} has substitution markers without definitions"
                    )
            elif isinstance(localization, dict) and "variations" in localization:
                try:
                    variations = localization["variations"]["plural"]
                    if not isinstance(variations, dict):
                        raise TypeError
                    _validate_plural_categories(key, locale, variations)
                    units.extend(
                        variation["stringUnit"] for variation in variations.values()
                    )
                except CatalogError:
                    raise
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

        english_signature_map = localization_signature_map(localizations.get("en"))
        if english_signature_map is not None:
            english_substitution_arguments = (
                _substitution_argument_map(localizations["en"])
                if "substitutions" in localizations["en"]
                else None
            )
            for locale, localization in localizations.items():
                signature_map = localization_signature_map(localization)
                substitution_arguments = (
                    _substitution_argument_map(localization)
                    if isinstance(localization, dict)
                    and "substitutions" in localization
                    else None
                )
                if substitution_arguments != english_substitution_arguments:
                    raise CatalogError(
                        f"Placeholder substitution argument mapping mismatch for "
                        f"{key!r}: en={english_substitution_arguments}, "
                        f"{locale}={substitution_arguments}"
                    )
                if not _compatible_signature_maps(english_signature_map, signature_map):
                    raise CatalogError(
                        f"Placeholder signature mismatch for {key!r}: "
                        f"en={english_signature_map}, {locale}={signature_map}"
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

    if manifest is not None:
        validate_manifest_catalog_parity(
            strings,
            manifest,
            require_complete_translations=require_complete_translations,
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


def _format_tokens(
    value: str,
) -> list[tuple[str, re.Match[str]]]:
    tokens: list[tuple[str, re.Match[str]]] = []
    index = 0
    while index < len(value):
        if value[index] != "%":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1] == "%":
            index += 2
            continue
        substitution = SUBSTITUTION_SPECIFIER_PATTERN.match(value, index)
        if substitution is not None:
            tokens.append(("substitution", substitution))
            index = substitution.end()
            continue
        match = FORMAT_SPECIFIER_PATTERN.match(value, index)
        if match is None:
            raise CatalogError(
                f"Unsupported percent sequence at offset {index}: {value!r}"
            )
        tokens.append(("format", match))
        index = match.end()
    return tokens


def _format_match_signature(
    match: re.Match[str], next_sequential_argument: int
) -> tuple[list[dict[str, Any]], int]:
    signature: list[dict[str, Any]] = []
    width = "*" if match.group("width_star") else match.group("width")
    precision = "*" if match.group("precision_star") else match.group("precision")
    for role, star_group, position_group in (
        ("width", "width_star", "width_position"),
        ("precision", "precision_star", "precision_position"),
    ):
        if not match.group(star_group):
            continue
        position = match.group(position_group)
        argument = (
            int(position[:-1]) if position is not None else next_sequential_argument
        )
        if position is None:
            next_sequential_argument += 1
        signature.append(
            {
                "argument": argument,
                "conversion": "d",
                "flags": "",
                "precision": None,
                "role": role,
                "width": None,
            }
        )
    position = match.group("position")
    argument = int(position[:-1]) if position is not None else next_sequential_argument
    if position is None:
        next_sequential_argument += 1
    length = match.group("length") or ""
    signature.append(
        {
            "argument": argument,
            "conversion": f"{length}{match.group('conversion')}",
            "flags": match.group("flags") or "",
            "precision": precision,
            "width": width,
        }
    )
    return signature, next_sequential_argument


def _conversion_value_type(conversion: str) -> str:
    code = conversion[-1:]
    length = conversion[:-1]
    if code == "@":
        return "object"
    if code in {"d", "i", "u", "o", "x", "X"}:
        return f"integer:{length or 'default'}"
    if code in {"c", "C"}:
        is_wide = code == "C" or length == "l"
        return "integer:wide-character" if is_wide else "integer:default"
    if code in {"f", "F", "e", "E", "g", "G", "a", "A"}:
        return "floating:long-double" if length == "L" else "floating:double"
    if code in {"s", "S"}:
        is_wide = code == "S" or length == "l"
        return "string-pointer:wide" if is_wide else "string-pointer:narrow"
    if code == "p":
        return "pointer"
    return f"unsupported:{conversion}"


def _validate_argument_value_types(
    signature: list[dict[str, Any]], value: str
) -> None:
    types_by_argument: dict[int, set[str]] = {}
    for item in signature:
        argument = item.get("argument")
        conversion = item.get("conversion")
        if type(argument) is not int or not isinstance(conversion, str):
            raise CatalogError(f"Invalid placeholder signature for {value!r}")
        types_by_argument.setdefault(argument, set()).add(
            _conversion_value_type(conversion)
        )
    for argument, value_types in sorted(types_by_argument.items()):
        if len(value_types) > 1:
            raise CatalogError(
                f"Format argument {argument} has incompatible value types "
                f"{sorted(value_types)} in {value!r}"
            )


def _sorted_signature(
    signature: list[dict[str, Any]], value: str
) -> list[dict[str, Any]]:
    _validate_argument_value_types(signature, value)
    return sorted(
        signature,
        key=lambda item: (
            item["argument"],
            item["conversion"],
            item["flags"],
            item["width"] or "",
            item["precision"] or "",
            item.get("role") or "",
        ),
    )


def parse_format_signature(value: str) -> list[dict[str, Any]]:
    """Return an exact, argument-indexed printf signature for one string.

    Positional formats are normalized by argument index, so translators may reorder
    arguments without changing the contract. Flags, width, precision, length and
    conversion remain part of the signature. Literal ``%%`` does not consume an
    argument. Mixing positional and sequential arguments is rejected because its
    behavior is undefined across Foundation formatters.
    """

    matches = [
        match for kind, match in _format_tokens(value) if kind == "format"
    ]

    positional: list[bool] = []
    for match in matches:
        if match.group("width_star"):
            positional.append(match.group("width_position") is not None)
        if match.group("precision_star"):
            positional.append(match.group("precision_position") is not None)
        positional.append(match.group("position") is not None)
    if any(positional) and not all(positional):
        raise CatalogError(f"Format string mixes positional and sequential arguments: {value!r}")

    signature: list[dict[str, Any]] = []
    next_sequential_argument = 1
    for match in matches:
        items, next_sequential_argument = _format_match_signature(
            match, next_sequential_argument
        )
        signature.extend(items)
    return _sorted_signature(signature, value)


def format_argument_count(signature: list[dict[str, Any]]) -> int:
    return max((item["argument"] for item in signature), default=0)


def _validate_plural_categories(
    key: str,
    locale: str,
    variations: dict[str, Any],
    suffix: str | None = None,
) -> None:
    label = f"{key!r}/{locale}" + (f"/{suffix}" if suffix else "")
    categories = set(variations)
    if "other" not in categories:
        raise CatalogError(f"{label} is missing plural category 'other'")
    unsupported = categories - PLURAL_CATEGORIES[locale]
    if unsupported:
        raise CatalogError(
            f"{label} has unsupported plural categories {sorted(unsupported)}"
        )


def _substitution_contract(
    localization: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    outer, substitutions, tokens, markers = _validated_substitution_components(
        localization
    )
    positional: list[bool] = []
    for kind, match in tokens:
        if kind == "substitution":
            positional.append(match.group("position") is not None)
            continue
        if match.group("width_star"):
            positional.append(match.group("width_position") is not None)
        if match.group("precision_star"):
            positional.append(match.group("precision_position") is not None)
        positional.append(match.group("position") is not None)
    if any(positional) and not all(positional):
        raise CatalogError(
            f"Substitution string mixes positional and sequential arguments: {outer!r}"
        )

    result: list[dict[str, Any]] = []
    argument_by_name: dict[str, int] = {}
    next_sequential_argument = 1
    for kind, match in tokens:
        if kind == "format":
            items, next_sequential_argument = _format_match_signature(
                match, next_sequential_argument
            )
            result.extend(items)
            continue

        position = match.group("position")
        argument = (
            int(position[:-1]) if position is not None else next_sequential_argument
        )
        if position is None:
            next_sequential_argument += 1
        name = match.group("name")
        argument_by_name[name] = argument
        format_specifier = substitutions[name]["formatSpecifier"]
        parsed = parse_format_signature("%" + format_specifier)
        if (
            len(parsed) != 1
            or parsed[0].get("argument") != 1
            or parsed[0].get("role") is not None
        ):
            raise CatalogError(
                f"Invalid substitution format specifier {format_specifier!r}"
            )
        item = dict(parsed[0])
        item["argument"] = argument
        result.append(item)
    return _sorted_signature(result, outer), argument_by_name


def _substitution_signature(
    localization: dict[str, Any]
) -> list[dict[str, Any]]:
    return _substitution_contract(localization)[0]


def _substitution_argument_map(localization: dict[str, Any]) -> dict[str, int]:
    return _substitution_contract(localization)[1]


def _validated_substitution_components(
    localization: dict[str, Any],
) -> tuple[
    str,
    dict[str, Any],
    list[tuple[str, re.Match[str]]],
    list[re.Match[str]],
]:
    outer = localization.get("stringUnit", {}).get("value")
    if not isinstance(outer, str):
        raise CatalogError("Substitution localization has an invalid outer string unit")
    substitutions = localization.get("substitutions")
    if not isinstance(substitutions, dict) or not substitutions:
        raise CatalogError("Substitution localization has no definitions")
    tokens = _format_tokens(outer)
    markers = [match for kind, match in tokens if kind == "substitution"]
    marker_names = [marker.group("name") for marker in markers]
    if not marker_names:
        raise CatalogError("Substitution localization has definitions but no markers")
    duplicate_names = sorted(
        name for name, count in Counter(marker_names).items() if count > 1
    )
    if duplicate_names:
        raise CatalogError(
            f"Substitution localization has duplicate markers {duplicate_names}"
        )
    if set(marker_names) != set(substitutions):
        missing = sorted(set(marker_names) - set(substitutions))
        unused = sorted(set(substitutions) - set(marker_names))
        raise CatalogError(
            "Substitution markers and definitions do not match; "
            f"missing={missing}, unused={unused}"
        )
    for name in marker_names:
        substitution = substitutions[name]
        if not isinstance(substitution, dict):
            raise CatalogError(f"Substitution {name!r} is not an object")
        format_specifier = substitution.get("formatSpecifier")
        if not isinstance(format_specifier, str) or not format_specifier:
            raise CatalogError(
                f"Substitution {name!r} has an invalid format specifier"
            )
        parsed_format_specifier = parse_format_signature("%" + format_specifier)
        if (
            len(parsed_format_specifier) != 1
            or parsed_format_specifier[0].get("argument") != 1
            or parsed_format_specifier[0].get("role") is not None
        ):
            raise CatalogError(
                f"Substitution {name!r} has an invalid format specifier "
                f"{format_specifier!r}"
            )
        try:
            variations = substitution["variations"]["plural"]
        except (KeyError, TypeError) as error:
            raise CatalogError(
                f"Substitution {name!r} has invalid plural variations"
            ) from error
        if not isinstance(variations, dict) or not variations:
            raise CatalogError(
                f"Substitution {name!r} has invalid plural variations"
            )
        for category, variation in variations.items():
            if not isinstance(category, str) or not isinstance(variation, dict):
                raise CatalogError(
                    f"Substitution {name!r} has an invalid plural variation"
                )
            string_unit = variation.get("stringUnit")
            if not isinstance(string_unit, dict) or not isinstance(
                string_unit.get("value"), str
            ):
                raise CatalogError(
                    f"Substitution {name!r}/{category} has an invalid string unit"
                )
    return outer, substitutions, tokens, markers


def _substitution_selector_item(
    substitution: dict[str, Any], argument: int
) -> dict[str, Any]:
    parsed = parse_format_signature("%" + substitution["formatSpecifier"])
    item = dict(parsed[0])
    item["argument"] = argument
    return item


def _substitution_variation_signature(
    name: str,
    value: str,
    selector_item: dict[str, Any],
) -> tuple[list[dict[str, Any]], bool]:
    signature = parse_format_signature(value)
    format_matches = [
        match for kind, match in _format_tokens(value) if kind == "format"
    ]
    uses_positional_arguments = any(
        match.group("position") is not None for match in format_matches
    )
    local_selector_argument = (
        selector_item["argument"] if uses_positional_arguments else 1
    )
    selector_indexes = [
        index
        for index, item in enumerate(signature)
        if item.get("argument") == local_selector_argument
        and item.get("role") is None
    ]
    if not selector_indexes:
        return signature, False

    expected_conversion = selector_item["conversion"]
    for index in selector_indexes:
        actual_conversion = signature[index]["conversion"]
        if actual_conversion != expected_conversion:
            raise CatalogError(
                f"Visible selector for substitution {name!r} uses "
                f"{actual_conversion!r}; expected {expected_conversion!r}"
            )

    normalized = [dict(item) for item in signature]
    for index in selector_indexes:
        normalized[index]["argument"] = selector_item["argument"]
    return _sorted_signature(normalized, value), True


def localization_signature_map(
    localization: Any,
) -> dict[str, list[dict[str, Any]]] | None:
    if not isinstance(localization, dict):
        return None
    if "substitutions" in localization:
        base, argument_by_name = _substitution_contract(localization)
        _, substitutions, _, markers = _validated_substitution_components(localization)
        maps: dict[str, list[dict[str, Any]]] = {}
        variation_groups: list[
            tuple[
                str,
                dict[str, Any],
                list[tuple[str, list[dict[str, Any]], bool]],
            ]
        ] = []
        for marker in markers:
            name = marker.group("name")
            variations = substitutions[name]["variations"]["plural"]
            selector_item = _substitution_selector_item(
                substitutions[name], argument_by_name[name]
            )
            category_signatures = []
            for category, variation in sorted(variations.items()):
                value = variation["stringUnit"]["value"]
                signature, displays_selector = _substitution_variation_signature(
                    name, value, selector_item
                )
                category_signatures.append(
                    (category, signature, displays_selector)
                )
            variation_groups.append(
                (name, selector_item, category_signatures)
            )
        combinations = itertools.product(
            *(categories for _, _, categories in variation_groups)
        )
        names = [name for name, _, _ in variation_groups]
        selector_items = {
            name: selector_item for name, selector_item, _ in variation_groups
        }
        for combination in combinations:
            key = "substitution:" + "|".join(
                f"{name}={category}"
                for name, (category, _, _) in zip(names, combination)
            )
            combined = list(base)
            for name, (_, variation_signature, displays_selector) in zip(
                names, combination
            ):
                if displays_selector:
                    try:
                        combined.remove(selector_items[name])
                    except ValueError as error:
                        raise CatalogError(
                            f"Missing selector contract for substitution {name!r}"
                        ) from error
                combined.extend(variation_signature)
            maps[key] = _sorted_signature(combined, key)
        return maps
    if "stringUnit" in localization:
        value = localization["stringUnit"].get("value", "")
        if any(kind == "substitution" for kind, _ in _format_tokens(value)):
            raise CatalogError(
                "Substitution marker has no substitution definitions"
            )
        return {
            "string": parse_format_signature(value)
        }
    try:
        return {
            category: parse_format_signature(
                variation["stringUnit"].get("value", "")
            )
            for category, variation in localization["variations"]["plural"].items()
        }
    except (KeyError, TypeError, AttributeError):
        return None


def _is_count_conversion(conversion: str) -> bool:
    return conversion[-1:] in {"d", "i", "u"}


def _without_plural_count(
    signature: list[dict[str, Any]],
) -> list[dict[str, Any]] | None:
    count_items = [
        item
        for item in signature
        if item.get("argument") == 1
        and item.get("role") is None
        and _is_count_conversion(item.get("conversion", ""))
    ]
    if len(count_items) != 1:
        return None
    count_item = count_items[0]
    return [item for item in signature if item is not count_item]


def _plural_signatures_compatible(
    expected: list[dict[str, Any]],
    actual: list[dict[str, Any]],
) -> bool:
    if actual == expected:
        return True
    expected_without_count = _without_plural_count(expected)
    if expected_without_count is not None and actual == expected_without_count:
        return True
    actual_without_count = _without_plural_count(actual)
    return actual_without_count is not None and expected == actual_without_count


def _compatible_signature_maps(
    english: dict[str, list[dict[str, Any]]],
    translated: dict[str, list[dict[str, Any]]] | None,
) -> bool:
    if translated is None:
        return False
    if "string" in english or "string" in translated:
        return english == translated
    english_uses_substitutions = bool(english) and all(
        key.startswith("substitution:") for key in english
    )
    translated_uses_substitutions = bool(translated) and all(
        key.startswith("substitution:") for key in translated
    )
    if english_uses_substitutions or translated_uses_substitutions:
        if not english_uses_substitutions or not translated_uses_substitutions:
            return False
        english_baseline = next(iter(english.values()))
        return all(
            _plural_signatures_compatible(english_baseline, signature)
            for signature in english.values()
        ) and all(
            _plural_signatures_compatible(english_baseline, signature)
            for signature in translated.values()
        )
    english_other = english.get("other", [])
    if not all(
        _plural_signatures_compatible(english_other, signature)
        for signature in english.values()
    ):
        return False
    for category, signature in translated.items():
        expected = english.get(category, english_other)
        if not _plural_signatures_compatible(expected, signature):
            return False
    return True


def localization_signatures(localization: Any) -> list[list[dict[str, Any]]] | None:
    signature_map = localization_signature_map(localization)
    if signature_map is None:
        return None
    signatures_by_json = {
        json.dumps(signature, ensure_ascii=False, sort_keys=True): signature
        for signature in signature_map.values()
    }
    return [signatures_by_json[key] for key in sorted(signatures_by_json)]


def validate_manifest_catalog_parity(
    strings: dict[str, Any],
    manifest: dict[str, Any],
    require_complete_translations: bool = False,
) -> None:
    if (
        type(manifest.get("schemaVersion")) is not int
        or manifest["schemaVersion"] != 1
    ):
        raise CatalogError("Localization manifest schemaVersion must be 1")
    active_keys = manifest.get("activeKeys")
    if not isinstance(active_keys, list):
        raise CatalogError("Localization manifest activeKeys must be an array")
    domain_reserved_keys = manifest.get("domainReservedKeys", [])
    if not isinstance(domain_reserved_keys, list):
        raise CatalogError(
            "Localization manifest domainReservedKeys must be an array"
        )

    for reserved in domain_reserved_keys:
        if not isinstance(reserved, dict) or not isinstance(
            reserved.get("key"), str
        ):
            raise CatalogError(
                "Localization manifest has an invalid domain-reserved key entry"
            )
        key = reserved["key"]
        english = strings.get(key, {}).get("localizations", {}).get("en")
        signatures = localization_signatures(english)
        if not signatures:
            raise CatalogError(f"Missing reserved English localization for {key!r}")

        expected_signatures = reserved.get("formatSignatures")
        if (
            not isinstance(expected_signatures, list)
            or not expected_signatures
            or not all(isinstance(signature, list) for signature in expected_signatures)
        ):
            raise CatalogError(
                f"Domain-reserved key {key!r} has invalid format signatures"
            )
        incompatible_signatures = [
            signature
            for signature in expected_signatures
            if signature not in signatures
        ]
        if incompatible_signatures:
            raise CatalogError(
                f"Reserved English/manifest signature mismatch for {key!r}: "
                f"manifest={expected_signatures}, catalog={signatures}"
            )
        if require_complete_translations:
            localizations = strings.get(key, {}).get("localizations", {})
            for locale in LOCALES:
                if not localization_signatures(localizations.get(locale)):
                    raise CatalogError(
                        f"Missing reserved translation for {key!r}/{locale}"
                    )

    for active in active_keys:
        if not isinstance(active, dict) or not isinstance(active.get("key"), str):
            raise CatalogError("Localization manifest has an invalid active key entry")
        key = active["key"]
        english = strings.get(key, {}).get("localizations", {}).get("en")
        signatures = localization_signatures(english)
        if not signatures:
            raise CatalogError(f"Missing active English localization for {key!r}")

        if "plural" in active.get("apis", []):
            is_native_plural = isinstance(english, dict) and (
                "variations" in english or "substitutions" in english
            )
            if not is_native_plural:
                raise CatalogError(
                    f"Active plural key {key!r} must use a native plural structure"
                )

        expected = active.get("formatSignature", [])
        if expected not in signatures:
            raise CatalogError(
                f"English/manifest signature mismatch for {key!r}: "
                f"manifest={expected}, catalog={signatures}"
            )
        if "plural" in active.get("apis", []):
            first_argument = [
                item for item in expected if item.get("argument") == 1
            ]
            if (
                len(first_argument) != 1
                or first_argument[0].get("role") is not None
                or not _is_count_conversion(
                    first_argument[0].get("conversion", "")
                )
            ):
                raise CatalogError(
                    f"Active plural key {key!r} must use one integer count "
                    "conversion as argument 1"
                )

        if require_complete_translations:
            localizations = strings.get(key, {}).get("localizations", {})
            for locale in LOCALES:
                if not localization_signatures(localizations.get(locale)):
                    raise CatalogError(
                        f"Missing active translation for {key!r}/{locale}"
                    )

        expected_count = format_argument_count(expected)
        for callsite in active.get("callsites", []):
            argument_count = callsite.get("argumentCount")
            if argument_count is None:
                raise CatalogError(
                    f"Callsite has unknown argument count for {key!r} at "
                    f"{callsite.get('path')}:{callsite.get('line')}"
                )
            api = callsite.get("api")
            provided_count = argument_count + (1 if api == "plural" else 0)
            if provided_count != expected_count:
                raise CatalogError(
                    f"Callsite argument count mismatch for {key!r} at "
                    f"{callsite.get('path')}:{callsite.get('line')}: "
                    f"expected {expected_count}, got {provided_count}"
                )
            callsite_signature = callsite.get("formatSignature")
            if (
                callsite_signature is not None
                and callsite.get("fallback") is not None
                and callsite.get("typeSafety") != "typeUnchecked"
            ):
                signature_matches = callsite_signature == expected
                if api == "plural":
                    signature_matches = _plural_signatures_compatible(
                        expected, callsite_signature
                    )
                if not signature_matches:
                    raise CatalogError(
                        f"Typed callsite signature mismatch for {key!r} at "
                        f"{callsite.get('path')}:{callsite.get('line')}: "
                        f"catalog={expected}, callsite={callsite_signature}"
                    )


def load_catalog(path: Path) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise CatalogError(f"Duplicate JSON key {key!r} in {path}")
            result[key] = value
        return result

    try:
        parsed = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys
        )
    except CatalogError:
        raise
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
        "--manifest",
        type=Path,
        help="validate active-key English and callsite contracts against a schema-v1 manifest",
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
        manifest = load_catalog(arguments.manifest) if arguments.manifest else None
        report = validate_catalog(
            load_catalog(arguments.catalog),
            resources,
            manifest=manifest,
            require_complete_translations=manifest is not None,
        )
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
