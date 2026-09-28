import sys
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_length_audit as length_audit


def translated(value):
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationLengthAuditTests(unittest.TestCase):
    def setUp(self):
        self.catalog = {
            "sourceLanguage": "en",
            "strings": {
                "action": {
                    "localizations": {
                        "en": translated("Mute"),
                        "ru": translated("Выключить уведомления"),
                    }
                },
                "format": {
                    "localizations": {
                        "en": translated("Reply to %1$@"),
                        "ru": translated("Ответить пользователю %1$@"),
                    }
                },
                "plural": {
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": translated("%lld item"),
                                    "other": translated("%lld items"),
                                }
                            }
                        },
                        "ru": {
                            "variations": {
                                "plural": {
                                    "one": translated("%lld очень длинный элемент"),
                                    "few": translated("%lld очень длинных элемента"),
                                    "many": translated("%lld очень длинных элементов"),
                                    "other": translated("%lld очень длинного элемента"),
                                }
                            }
                        },
                    }
                },
            },
        }
        self.manifest = {
            "activeKeys": [
                {"key": "format"},
                {"key": "action"},
                {"key": "plural"},
            ],
            "domainReservedKeys": [],
        }
        self.config = {
            "locales": ["ru"],
            "thresholds": [
                {"maxEnglishLength": 6, "minimumRatio": 2.5, "minimumExtra": 8},
                {"maxEnglishLength": 20, "minimumRatio": 2.0, "minimumExtra": 10},
                {"minimumRatio": 1.75, "minimumExtra": 20},
            ],
            "reviewedExceptions": [],
        }

    def test_flags_material_expansion_and_reports_stable_metrics(self):
        report = length_audit.build_report(
            self.catalog,
            self.manifest,
            self.config,
        )

        action = next(
            item for item in report["unreviewedCandidates"]
            if item["key"] == "action"
        )
        self.assertEqual(action["englishLength"], 4)
        self.assertEqual(action["translationLength"], 21)
        self.assertEqual(action["extraCharacters"], 17)
        self.assertEqual(action["ratio"], 5.25)

    def test_printf_placeholders_do_not_count_toward_visible_length(self):
        report = length_audit.build_report(
            self.catalog,
            self.manifest,
            self.config,
        )

        formatted = next(
            item for item in report["unreviewedCandidates"]
            if item["key"] == "format"
        )
        self.assertEqual(formatted["english"], "Reply to %1$@")
        self.assertEqual(formatted["englishLength"], len("Reply to"))
        self.assertEqual(formatted["translationLength"], len("Ответить пользователю"))

    def test_cjk_and_fullwidth_characters_use_display_columns(self):
        self.assertEqual(length_audit.display_width("Bio"), 3)
        self.assertEqual(length_audit.display_width("个人简介"), 8)
        self.assertEqual(length_audit.display_width("简介"), 4)
        self.assertEqual(length_audit.display_width("Ａ"), 2)

    def test_target_only_plural_categories_compare_with_english_other(self):
        report = length_audit.build_report(
            self.catalog,
            self.manifest,
            self.config,
        )

        few = next(
            item for item in report["unreviewedCandidates"]
            if item["key"] == "plural" and item["branch"].endswith("/few")
        )
        self.assertEqual(few["english"], "%lld items")
        self.assertEqual(few["translation"], "%lld очень длинных элемента")

    def test_reviewed_exception_is_exact_and_stale_entries_fail(self):
        first = length_audit.build_report(
            self.catalog,
            self.manifest,
            self.config,
        )["unreviewedCandidates"][0]
        config = dict(self.config)
        config["reviewedExceptions"] = [{
            "key": first["key"],
            "locale": first["locale"],
            "branch": first["branch"],
            "translation": first["translation"],
            "reason": "Natural target-language expansion is required.",
        }]

        report = length_audit.build_report(self.catalog, self.manifest, config)
        self.assertEqual(len(report["reviewedExceptions"]), 1)
        self.assertNotIn(first, report["unreviewedCandidates"])

        config["reviewedExceptions"][0]["translation"] = "stale"
        with self.assertRaisesRegex(length_audit.LengthAuditError, "stale"):
            length_audit.build_report(self.catalog, self.manifest, config)

    def test_report_is_deterministic(self):
        first = length_audit.build_report(self.catalog, self.manifest, self.config)
        second = length_audit.build_report(self.catalog, self.manifest, self.config)

        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
