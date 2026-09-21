import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_branding as branding


class InfoPlistBrandingTests(unittest.TestCase):
    def _write_plist(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def _read_plist(self, path: Path) -> object:
        result = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def _write_config(self, root: Path, app_name: str = "Acme Chat") -> Path:
        path = root / "common_config.plist"
        self._write_plist(
            path,
            {"app_name": app_name, "domain": "chat.example.test"},
        )
        return path

    def _write_catalog(self, root: Path) -> Path:
        path = root / "InfoPlist.xcstrings"
        path.write_text(
            json.dumps(
                {
                    "sourceLanguage": "en",
                    "strings": {
                        "NSCameraUsageDescription": {
                            "extractionState": "manual",
                            "localizations": {
                                locale: {
                                    "stringUnit": {
                                        "state": "translated",
                                        "value": value,
                                    }
                                }
                                for locale, value in {
                                    "en": "__APP_NAME__ uses the camera.",
                                    "ru": "__APP_NAME__ использует камеру.",
                                }.items()
                            },
                        }
                    },
                    "version": "1.0",
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        return path

    def test_materialize_writes_localized_strings_from_configured_app_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "Resources"

            branding.materialize_info_plist_strings(
                catalog_path=self._write_catalog(root),
                config_path=self._write_config(root),
                output_root=output,
                expected_locales=("en", "ru"),
            )

            for locale, expected in {
                "en": "Acme Chat uses the camera.",
                "ru": "Acme Chat использует камеру.",
            }.items():
                values = self._read_plist(
                    output / f"{locale}.lproj/InfoPlist.strings"
                )
                self.assertEqual(values["NSCameraUsageDescription"], expected)
                self.assertNotIn("__APP_NAME__", values["NSCameraUsageDescription"])

    def test_materialize_writes_configured_info_plist_from_template(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "Info.plist"
            configured = root / "Derived/ConfiguredInfo.plist"
            self._write_plist(
                template,
                {
                    "CFBundleDisplayName": "Legacy Brand",
                    "CFBundleName": "Legacy Brand",
                    "NSCameraUsageDescription": "Legacy Brand uses the camera.",
                },
            )

            branding.materialize_info_plist_strings(
                catalog_path=self._write_catalog(root),
                config_path=self._write_config(root),
                output_root=root / "Resources",
                info_plist_template=template,
                info_plist_output=configured,
                expected_locales=("en", "ru"),
            )

            values = self._read_plist(configured)
            self.assertEqual(values["CFBundleDisplayName"], "Acme Chat")
            self.assertEqual(values["CFBundleName"], "Acme Chat")
            self.assertEqual(
                values["NSCameraUsageDescription"],
                "Acme Chat uses the camera.",
            )
            self.assertEqual(
                self._read_plist(template)["CFBundleDisplayName"],
                "Legacy Brand",
            )

    def test_materialize_requires_template_and_output_together(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "Info.plist"
            self._write_plist(template, {"CFBundleName": "__APP_NAME__"})

            with self.assertRaisesRegex(branding.BrandingError, "provided together"):
                branding.materialize_info_plist_strings(
                    catalog_path=self._write_catalog(root),
                    config_path=self._write_config(root),
                    output_root=root / "Resources",
                    info_plist_template=template,
                    expected_locales=("en", "ru"),
                )

    def test_materialize_rejects_blank_app_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(branding.BrandingError, "non-empty app_name"):
                branding.materialize_info_plist_strings(
                    catalog_path=self._write_catalog(root),
                    config_path=self._write_config(root, app_name="  "),
                    output_root=root / "Resources",
                    expected_locales=("en", "ru"),
                )

    def test_materialize_rejects_missing_or_unexpected_locales(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(branding.BrandingError, "locales must be exactly"):
                branding.materialize_info_plist_strings(
                    catalog_path=self._write_catalog(root),
                    config_path=self._write_config(root),
                    output_root=root / "Resources",
                    expected_locales=("en", "ru", "fr"),
                )

    def test_materialize_requires_app_name_token_in_every_value(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog_path = self._write_catalog(root)
            document = json.loads(catalog_path.read_text(encoding="utf-8"))
            document["strings"]["NSCameraUsageDescription"]["localizations"]["ru"][
                "stringUnit"
            ]["value"] = "Приложение использует камеру."
            catalog_path.write_text(
                json.dumps(document, ensure_ascii=False),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(branding.BrandingError, "must contain exactly one"):
                branding.materialize_info_plist_strings(
                    catalog_path=catalog_path,
                    config_path=self._write_config(root),
                    output_root=root / "Resources",
                    expected_locales=("en", "ru"),
                )


if __name__ == "__main__":
    unittest.main()
