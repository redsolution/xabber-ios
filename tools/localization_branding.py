#!/usr/bin/env python3
"""Materialize system-owned localized branding from common_config.plist.

Runtime localization uses typed ``L10n.format`` arguments. Privacy usage
descriptions and bundle names are resolved by iOS before application code can
run, so this build helper applies the same CommonConfig ``app_name`` value to
a derived Info.plist and emits localized InfoPlist.strings files.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

import localization_catalog


APP_NAME_TOKEN = "__APP_NAME__"


class BrandingError(RuntimeError):
    pass


def _read_plist(path: Path) -> Any:
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise BrandingError(f"Could not parse property list {path}: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise BrandingError(f"Could not decode property list {path}: {error}") from error


def _write_binary_plist(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(value, ensure_ascii=False, sort_keys=True)
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "binary1", "-o", str(path), "--", "-"],
        input=rendered,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise BrandingError(f"Could not write property list {path}: {result.stderr.strip()}")


def _configured_app_name(config_path: Path) -> str:
    config = _read_plist(config_path)
    if not isinstance(config, dict):
        raise BrandingError(f"Common config {config_path} must be a dictionary")
    app_name = config.get("app_name")
    if not isinstance(app_name, str) or not app_name.strip():
        raise BrandingError(f"Common config {config_path} must contain a non-empty app_name")
    return app_name


def _replace_app_name_token(value: Any, app_name: str) -> tuple[Any, int]:
    if isinstance(value, str):
        count = value.count(APP_NAME_TOKEN)
        return value.replace(APP_NAME_TOKEN, app_name), count
    if isinstance(value, list):
        result: list[Any] = []
        count = 0
        for item in value:
            replaced, replacements = _replace_app_name_token(item, app_name)
            result.append(replaced)
            count += replacements
        return result, count
    if isinstance(value, dict):
        result: dict[Any, Any] = {}
        count = 0
        for key, item in value.items():
            replaced, replacements = _replace_app_name_token(item, app_name)
            result[key] = replaced
            count += replacements
        return result, count
    return value, 0


def _localized_info_plist_values(
    catalog_path: Path,
    app_name: str,
    expected_locales: Iterable[str],
) -> dict[str, dict[str, str]]:
    catalog = localization_catalog.load_catalog(catalog_path)
    strings = catalog.get("strings")
    if catalog.get("sourceLanguage") != "en" or not isinstance(strings, dict):
        raise BrandingError(f"Invalid InfoPlist string catalog {catalog_path}")

    expected = tuple(expected_locales)
    expected_set = set(expected)
    result: dict[str, dict[str, str]] = {locale: {} for locale in expected}
    discovered_locales: set[str] = set()
    for key, entry in sorted(strings.items()):
        if not isinstance(key, str) or not isinstance(entry, dict):
            raise BrandingError(f"Invalid InfoPlist catalog entry {key!r}")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            raise BrandingError(f"InfoPlist catalog entry {key!r} has no localizations")
        discovered_locales.update(localizations)
        for locale in expected:
            localization = localizations.get(locale)
            if not isinstance(localization, dict):
                continue
            string_unit = localization.get("stringUnit")
            value = string_unit.get("value") if isinstance(string_unit, dict) else None
            if not isinstance(value, str) or not value.strip():
                raise BrandingError(f"InfoPlist value {key!r}/{locale} is empty or invalid")
            if value.count(APP_NAME_TOKEN) != 1:
                raise BrandingError(
                    f"InfoPlist value {key!r}/{locale} must contain exactly one "
                    f"{APP_NAME_TOKEN} token"
                )
            result[locale][key] = value.replace(APP_NAME_TOKEN, app_name)

    if discovered_locales != expected_set:
        raise BrandingError(
            "InfoPlist catalog locales must be exactly "
            f"{sorted(expected_set)}; got {sorted(discovered_locales)}"
        )
    for locale, values in result.items():
        if set(values) != set(strings):
            missing = sorted(set(strings) - set(values))
            raise BrandingError(f"InfoPlist catalog is missing {locale} values: {missing}")
    return result


def materialize_info_plist_strings(
    *,
    catalog_path: Path,
    config_path: Path,
    output_root: Path,
    info_plist_template: Path | None = None,
    info_plist_output: Path | None = None,
    expected_locales: Iterable[str] = localization_catalog.LOCALES,
) -> None:
    if (info_plist_template is None) != (info_plist_output is None):
        raise BrandingError(
            "Info.plist template and output must be provided together"
        )

    app_name = _configured_app_name(config_path)
    localized = _localized_info_plist_values(
        catalog_path,
        app_name,
        expected_locales,
    )
    for locale, values in sorted(localized.items()):
        _write_binary_plist(
            output_root / f"{locale}.lproj" / "InfoPlist.strings",
            values,
        )

    if info_plist_template is not None and info_plist_output is not None:
        document = _read_plist(info_plist_template)
        if not isinstance(document, dict):
            raise BrandingError(
                f"Info.plist template {info_plist_template} must be a dictionary"
            )
        replaced, _ = _replace_app_name_token(document, app_name)
        replaced["CFBundleDisplayName"] = app_name
        replaced["CFBundleName"] = app_name
        english = localized.get("en")
        if english is None:
            raise BrandingError("InfoPlist catalog must contain English values")
        replaced.update(english)
        if APP_NAME_TOKEN in json.dumps(replaced, ensure_ascii=False):
            raise BrandingError(
                f"Configured Info.plist still contains {APP_NAME_TOKEN}"
            )
        _write_binary_plist(info_plist_output, replaced)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--info-plist-template", type=Path)
    parser.add_argument("--info-plist-output", type=Path)
    arguments = parser.parse_args()

    try:
        materialize_info_plist_strings(
            catalog_path=arguments.catalog,
            config_path=arguments.config,
            output_root=arguments.output_root,
            info_plist_template=arguments.info_plist_template,
            info_plist_output=arguments.info_plist_output,
        )
    except (BrandingError, localization_catalog.CatalogError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
