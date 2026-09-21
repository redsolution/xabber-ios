import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_completion as completion


def translated(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class ActiveTranslationCompletionTests(unittest.TestCase):
    def setUp(self):
        self.catalog = {
            "sourceLanguage": "en",
            "strings": {
                "alpha": {
                    "comment": "A simple label.",
                    "extractionState": "manual",
                    "localizations": {
                        "en": translated("Alpha"),
                        "ru": translated("Альфа"),
                    },
                },
                "count": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": translated("%lld item"),
                                    "other": translated("%lld items"),
                                }
                            }
                        }
                    },
                },
                "reserved": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Reserved")},
                },
            },
            "version": "1.0",
        }
        self.manifest = {
            "schemaVersion": 1,
            "activeKeys": [
                {"key": "count"},
                {"key": "alpha"},
            ],
            "domainReservedKeys": [{"key": "reserved"}],
        }

    def test_active_key_ids_include_domain_reserved_keys_and_are_sorted(self):
        self.assertEqual(
            completion.active_key_ids(self.manifest),
            ["alpha", "count", "reserved"],
        )

    def test_packet_contains_only_missing_keys_and_target_plural_categories(self):
        packet = completion.build_packet(self.catalog, self.manifest, "ru")

        self.assertEqual(sorted(packet["translations"]), ["count", "reserved"])
        self.assertEqual(
            set(
                packet["translations"]["count"]["translation"]
                ["variations"]["plural"]
            ),
            {"one", "few", "many", "other"},
        )
        self.assertEqual(
            packet["translations"]["count"]["source"]
            ["variations"]["plural"]["other"]["stringUnit"]["value"],
            "%lld items",
        )
        self.assertEqual(
            packet["translations"]["reserved"]["translation"]
            ["stringUnit"]["value"],
            "",
        )

    def test_substitution_packet_requires_translation_of_outer_template(self):
        source = {
            "stringUnit": {
                "state": "translated",
                "value": "You have %#@items@",
            },
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("%lld item"),
                            "other": translated("%lld items"),
                        }
                    },
                }
            },
        }

        translation = completion._blank_translation(source, "fr")

        self.assertEqual(translation["stringUnit"]["value"], "")
        self.assertEqual(
            set(translation["substitutions"]["items"]["variations"]["plural"]),
            {"one", "many", "other"},
        )

    def test_apply_packet_rejects_blank_values_and_preserves_existing_translations(self):
        packet = completion.build_packet(self.catalog, self.manifest, "ru")
        packet["translations"]["reserved"]["translation"]["stringUnit"][
            "value"
        ] = "Зарезервировано"

        with self.assertRaisesRegex(completion.CompletionError, "blank.*count"):
            completion.apply_packet(self.catalog, self.manifest, packet)

        for category, value in {
            "one": "%lld элемент",
            "few": "%lld элемента",
            "many": "%lld элементов",
            "other": "%lld элемента",
        }.items():
            packet["translations"]["count"]["translation"]["variations"][
                "plural"
            ][category]["stringUnit"]["value"] = value

        result = completion.apply_packet(self.catalog, self.manifest, packet)

        self.assertEqual(
            result["strings"]["alpha"]["localizations"]["ru"],
            translated("Альфа"),
        )
        self.assertEqual(
            result["strings"]["reserved"]["localizations"]["ru"],
            translated("Зарезервировано"),
        )

    def test_table_rows_are_deterministic_and_encode_plural_cells_as_json(self):
        complete = copy.deepcopy(self.catalog)
        for key in completion.active_key_ids(self.manifest):
            entry = complete["strings"][key]
            english = entry["localizations"]["en"]
            for locale in completion.LOCALES:
                entry["localizations"].setdefault(locale, copy.deepcopy(english))

        rows = completion.translation_table_rows(complete, self.manifest)

        self.assertEqual(
            rows[0], ["id", "en", "ru", "fr", "es", "ar", "zh-Hans"]
        )
        self.assertEqual([row[0] for row in rows[1:]], ["alpha", "count", "reserved"])
        plural_cell = rows[2][1]
        self.assertEqual(
            json.loads(plural_cell),
            {"one": "%lld item", "other": "%lld items"},
        )

    def test_packet_round_trip_is_deterministic(self):
        first = completion.build_packet(self.catalog, self.manifest, "fr")
        second = completion.build_packet(self.catalog, self.manifest, "fr")

        self.assertEqual(
            json.dumps(first, ensure_ascii=False, sort_keys=True),
            json.dumps(second, ensure_ascii=False, sort_keys=True),
        )

    def test_report_distinguishes_active_and_domain_reserved_keys(self):
        report = completion._report(self.catalog, self.manifest)

        self.assertEqual(report["activeKeys"], 2)
        self.assertEqual(report["domainReservedKeys"], 1)
        self.assertEqual(report["manifestOwnedKeys"], 3)

    def test_csv_is_utf8_rfc4180_and_preserves_commas_quotes_and_newlines(self):
        rows = [
            ["id", "en"],
            ["plain", "Alpha"],
            ["complex", 'One, "two"\nthree'],
        ]

        rendered = completion.translation_csv_text(rows)

        self.assertEqual(
            rendered,
            'id,en\nplain,Alpha\ncomplex,"One, ""two""\nthree"\n',
        )


class RepositoryTranslationCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repository_root = TOOLS_ROOT.parent
        cls.catalog = completion.localization_catalog.load_catalog(
            cls.repository_root / "xabber/translations/Localizable.xcstrings"
        )
        cls.manifest = completion.localization_catalog.load_catalog(
            cls.repository_root / "docs/localization/active-keys.json"
        )

    def test_every_manifest_owned_key_has_all_six_locales(self):
        missing = {
            locale: completion.missing_keys(self.catalog, self.manifest, locale)
            for locale in completion.LOCALES
        }

        self.assertEqual(missing, {locale: [] for locale in completion.LOCALES})

    def test_checked_in_csv_matches_catalog_and_manifest(self):
        expected = completion.translation_csv_text(
            completion.translation_table_rows(self.catalog, self.manifest)
        )
        actual = (
            self.repository_root / "docs/localization/active-translations.csv"
        ).read_text(encoding="utf-8")

        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
