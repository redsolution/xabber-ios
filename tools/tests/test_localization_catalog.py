import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_catalog as catalog


def translated(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def base_catalog(strings):
    support = {
        "extractionState": "manual",
        "localizations": {
            locale: translated("Support") for locale in catalog.LOCALES
        },
    }
    return {
        "sourceLanguage": "en",
        "strings": {"support": support, **strings},
        "version": "1.0",
    }


class JSONLoadingTests(unittest.TestCase):
    def test_load_catalog_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(
                '{"sourceLanguage":"en","strings":{"same":{},"same":{}},"version":"1.0"}',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(catalog.CatalogError, "Duplicate JSON key.*same"):
                catalog.load_catalog(path)


class FormatSignatureTests(unittest.TestCase):
    def test_signature_preserves_position_type_width_and_precision(self):
        signature = catalog.parse_format_signature("%2$-08.2f / %1$lld / %% / %3$@")

        self.assertEqual(
            signature,
            [
                {
                    "argument": 1,
                    "conversion": "lld",
                    "flags": "",
                    "precision": None,
                    "width": None,
                },
                {
                    "argument": 2,
                    "conversion": "f",
                    "flags": "-0",
                    "precision": "2",
                    "width": "8",
                },
                {
                    "argument": 3,
                    "conversion": "@",
                    "flags": "",
                    "precision": None,
                    "width": None,
                },
            ],
        )

    def test_signature_rejects_mixed_positional_and_sequential_arguments(self):
        with self.assertRaisesRegex(catalog.CatalogError, "mixes positional"):
            catalog.parse_format_signature("%1$@ %d")

    def test_escaped_percent_does_not_consume_an_argument(self):
        self.assertEqual(catalog.parse_format_signature("Progress: 100%%"), [])

    def test_dynamic_width_and_precision_consume_integer_arguments(self):
        signature = catalog.parse_format_signature("%*.*f")

        self.assertEqual(catalog.format_argument_count(signature), 3)
        self.assertEqual(
            [(item["argument"], item["conversion"], item.get("role")) for item in signature],
            [(1, "d", "width"), (2, "d", "precision"), (3, "f", None)],
        )

    def test_positional_dynamic_width_and_precision_preserve_positions(self):
        signature = catalog.parse_format_signature("%3$*1$.*2$f")

        self.assertEqual(
            [(item["argument"], item["conversion"], item.get("role")) for item in signature],
            [(1, "d", "width"), (2, "d", "precision"), (3, "f", None)],
        )

    def test_unescaped_or_malformed_percent_is_rejected(self):
        with self.assertRaisesRegex(catalog.CatalogError, "Unsupported percent sequence"):
            catalog.parse_format_signature("Progress: 100%")

    def test_same_positional_argument_rejects_incompatible_value_types(self):
        with self.assertRaisesRegex(
            catalog.CatalogError,
            "argument 1.*incompatible",
        ):
            catalog.parse_format_signature("%1$d %1$@")

    def test_same_positional_argument_accepts_compatible_integer_renderings(self):
        signature = catalog.parse_format_signature("%1$d %1$x")

        self.assertEqual(catalog.format_argument_count(signature), 1)


class CatalogValidationTests(unittest.TestCase):
    def test_brand_values_use_positional_placeholders_with_locale_parity(self):
        document = base_catalog(
            {
                "branded": {
                    "extractionState": "manual",
                    "localizations": {
                        locale: translated(
                            "Welcome to %1$@ at %2$@"
                        )
                        for locale in catalog.LOCALES
                    },
                }
            }
        )

        report = catalog.validate_catalog(document)

        self.assertGreater(report["keys"], 0)

    def test_brand_positional_placeholder_parity_is_enforced(self):
        document = base_catalog(
            {
                "branded": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": translated(
                            "Welcome to %1$@ at %2$@"
                        ),
                        "ru": translated("Добро пожаловать в %1$@"),
                    },
                }
            }
        )

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "Placeholder signature mismatch.*branded.*ru",
        ):
            catalog.validate_catalog(document)

    def test_named_brand_template_tokens_are_rejected(self):
        values = (
            "Welcome to {{app_name}}",
            "Connect to {{domain}}",
            "Welcome to {{ app_name }}",
        )

        for index, value in enumerate(values):
            with self.subTest(value=value):
                document = base_catalog(
                    {
                        f"invalid_template_{index}": {
                            "extractionState": "manual",
                            "localizations": {"en": translated(value)},
                        }
                    }
                )

                with self.assertRaisesRegex(
                    catalog.CatalogError,
                    "Named localization tokens are not supported",
                ):
                    catalog.validate_catalog(document)

    def test_literal_product_brands_are_rejected_case_insensitively(self):
        for brand in (
            "Xabber",
            "xAbBeR",
            "Clandestino",
            "CLANDESTINO",
            "إكسابير",
            "شبير",
        ):
            with self.subTest(brand=brand):
                document = base_catalog(
                    {
                        "literal_brand": {
                            "extractionState": "manual",
                            "localizations": {
                                "en": translated(f"Welcome to {brand}")
                            },
                        }
                    }
                )

                with self.assertRaisesRegex(
                    catalog.CatalogError,
                    "Literal product brand.*literal_brand.*en",
                ):
                    catalog.validate_catalog(document)

    def test_exact_external_translation_project_url_is_allowed(self):
        document = base_catalog(
            {
                "settings__section_interface_language__text_description___link": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": translated("https://crowdin.com/project/xabber")
                    },
                }
            }
        )

        report = catalog.validate_catalog(document)

        self.assertGreater(report["keys"], 0)

    def test_external_translation_project_exception_is_exact(self):
        document = base_catalog(
            {
                "settings__section_interface_language__text_description___link": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": translated("Open Xabber at https://crowdin.com/project/xabber")
                    },
                }
            }
        )

        with self.assertRaisesRegex(catalog.CatalogError, "Literal product brand"):
            catalog.validate_catalog(document)

    def test_literal_product_hosts_are_rejected_case_insensitively(self):
        hosts = (
            "https://xabber.com/help",
            "user@Xabber.chat",
            "XABBER.ORG",
            "https://WWW.XABBER.COM/policy",
            "Visit Xabber.com.",
            "https://api.xabber.com/status",
        )

        for host in hosts:
            with self.subTest(host=host):
                document = base_catalog(
                    {
                        "literal_host": {
                            "extractionState": "manual",
                            "localizations": {"en": translated(host)},
                        }
                    }
                )

                with self.assertRaisesRegex(
                    catalog.CatalogError,
                    "Literal product host.*literal_host.*en",
                ):
                    catalog.validate_catalog(document)

    def test_literal_product_brand_is_rejected_inside_plural_variation(self):
        document = base_catalog(
            {
                "literal_plural_brand": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": translated("One client"),
                                    "other": translated("Xabber clients"),
                                }
                            }
                        }
                    },
                }
            }
        )

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "Literal product brand.*literal_plural_brand.*en",
        ):
            catalog.validate_catalog(document)

    def test_brand_policy_checks_values_but_not_keys_or_comments(self):
        document = base_catalog(
            {
                "xabber.com/Xabber/Clandestino": {
                    "comment": "Xabber at xabber.com",
                    "extractionState": "manual",
                    "localizations": {"en": translated("Neutral copy")},
                }
            }
        )

        report = catalog.validate_catalog(document)

        self.assertGreater(report["keys"], 0)

    def test_french_flux_and_non_product_hosts_are_allowed(self):
        document = base_catalog(
            {
                "ordinary_words": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": translated(
                            "Stream docs at https://example.com and "
                            "http://otr.cypherpunks.ca/ via "
                            "https://notxabber.com"
                        ),
                        "fr": translated(
                            "Erreur de flux sur https://example.com"
                        ),
                    },
                }
            }
        )

        report = catalog.validate_catalog(document)

        self.assertGreater(report["keys"], 0)

    def test_manifest_schema_version_rejects_json_boolean(self):
        document = base_catalog({})
        manifest = {
            "schemaVersion": True,
            "activeKeys": [],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "schemaVersion must be 1",
        ):
            catalog.validate_catalog(document, manifest=manifest)

    def test_manifest_requires_nonempty_english_for_domain_reserved_key(self):
        document = base_catalog({})
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [],
            "domainReservedKeys": [{
                "key": "typed_reserved",
                "apis": ["text"],
                "formatSignatures": [[]],
            }],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "reserved English.*typed_reserved",
        ):
            catalog.validate_catalog(document, manifest=manifest)

    def test_domain_reserved_signature_must_match_english(self):
        document = base_catalog(
            {
                "typed_reserved": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Reserved %@")},
                }
            }
        )
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [],
            "domainReservedKeys": [{
                "key": "typed_reserved",
                "apis": ["format"],
                "formatSignatures": [
                    catalog.parse_format_signature("Reserved %d")
                ],
            }],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "Reserved English/manifest signature mismatch.*typed_reserved",
        ):
            catalog.validate_catalog(document, manifest=manifest)

    def test_domain_reserved_key_requires_at_least_one_manifest_signature(self):
        document = base_catalog(
            {
                "typed_reserved": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Reserved")},
                }
            }
        )
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [],
            "domainReservedKeys": [
                {
                    "key": "typed_reserved",
                    "apis": ["text"],
                    "formatSignatures": [],
                }
            ],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "invalid format signatures",
        ):
            catalog.validate_catalog(document, manifest=manifest)

    def test_manifest_requires_nonempty_english_for_every_active_key(self):
        document = base_catalog({})
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [
                {
                    "key": "missing",
                    "formatSignature": [],
                    "callsites": [],
                }
            ],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "active English.*missing"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_manifest_requires_every_supported_locale_for_active_key(self):
        localizations = {
            locale: translated("Translated") for locale in catalog.LOCALES
        }
        del localizations["fr"]
        document = base_catalog(
            {
                "active": {
                    "extractionState": "manual",
                    "localizations": localizations,
                }
            }
        )
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [
                {
                    "key": "active",
                    "apis": ["text"],
                    "formatSignature": [],
                    "callsites": [],
                }
            ],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "Missing active translation.*active.*fr",
        ):
            catalog.validate_catalog(
                document,
                manifest=manifest,
                require_complete_translations=True,
            )

    def test_manifest_requires_every_supported_locale_for_reserved_key(self):
        localizations = {
            locale: translated("Translated") for locale in catalog.LOCALES
        }
        del localizations["ar"]
        document = base_catalog(
            {
                "reserved": {
                    "extractionState": "manual",
                    "localizations": localizations,
                }
            }
        )
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [],
            "domainReservedKeys": [
                {
                    "key": "reserved",
                    "apis": ["text"],
                    "formatSignatures": [[]],
                }
            ],
        }

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "Missing reserved translation.*reserved.*ar",
        ):
            catalog.validate_catalog(
                document,
                manifest=manifest,
                require_complete_translations=True,
            )

    def test_manifest_signature_must_match_english(self):
        document = base_catalog(
            {
                "greeting": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Hello %@")},
                }
            }
        )
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [
                {
                    "key": "greeting",
                    "formatSignature": catalog.parse_format_signature("Hello %d"),
                    "callsites": [],
                }
            ],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "manifest signature"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_plural_count_is_implicit_and_may_be_unused_by_the_variant(self):
        substitution = {
            "stringUnit": {"state": "translated", "value": "%#@items@"},
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("Several items"),
                        }
                    },
                }
            },
        }
        document = base_catalog(
            {
                "count": {
                    "extractionState": "manual",
                    "localizations": {"en": substitution},
                }
            }
        )
        signature = catalog.localization_signatures(substitution)[0]
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [
                {
                    "key": "count",
                    "formatSignature": signature,
                    "callsites": [
                        {
                            "api": "plural",
                            "argumentCount": 0,
                            "path": "Screen.swift",
                            "line": 1,
                        }
                    ],
                }
            ],
        }

        report = catalog.validate_catalog(document, manifest=manifest)

        self.assertGreater(report["keys"], 0)

    def test_typed_callsite_signature_must_match_english(self):
        document = base_catalog(
            {
                "value": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Value %d")},
                }
            }
        )
        expected = catalog.parse_format_signature("Value %d")
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "value",
                "formatSignature": expected,
                "callsites": [{
                    "api": "format",
                    "argumentCount": 1,
                    "fallback": "Value %@",
                    "formatSignature": catalog.parse_format_signature("Value %@"),
                    "typeSafety": "typed",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "callsite signature"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_callsite_with_unknown_argument_count_is_rejected(self):
        document = base_catalog(
            {
                "value": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Value %@")},
                }
            }
        )
        expected = catalog.parse_format_signature("Value %@")
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "value",
                "formatSignature": expected,
                "callsites": [{
                    "api": "format",
                    "argumentCount": None,
                    "fallback": "Value %@",
                    "formatSignature": expected,
                    "typeSafety": "typed",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "unknown argument count"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_legacy_callsite_only_enforces_argument_count(self):
        document = base_catalog(
            {
                "value": {
                    "extractionState": "manual",
                    "localizations": {"en": translated("Value %d")},
                }
            }
        )
        expected = catalog.parse_format_signature("Value %d")
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "value",
                "formatSignature": expected,
                "callsites": [{
                    "api": "legacy",
                    "argumentCount": 1,
                    "fallback": "Value %@",
                    "formatSignature": catalog.parse_format_signature("Value %@"),
                    "typeSafety": "typeUnchecked",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        report = catalog.validate_catalog(document, manifest=manifest)

        self.assertGreater(report["keys"], 0)

    def test_plural_requires_other_category(self):
        document = base_catalog(
            {
                "count": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {"one": translated("%lld item")}
                            }
                        }
                    },
                }
            }
        )

        with self.assertRaisesRegex(catalog.CatalogError, "missing plural category 'other'"):
            catalog.validate_catalog(document)

    def test_plural_rejects_category_not_used_by_locale(self):
        document = base_catalog(
            {
                "count": {
                    "extractionState": "manual",
                    "localizations": {
                        "zh-Hans": {
                            "variations": {
                                "plural": {
                                    "one": translated("一个"),
                                    "other": translated("%lld 个"),
                                }
                            }
                        }
                    },
                }
            }
        )

        with self.assertRaisesRegex(catalog.CatalogError, "unsupported plural categories"):
            catalog.validate_catalog(document)

    def test_substitution_plural_tracks_implicit_count_without_visible_placeholder(self):
        substitution = {
            "stringUnit": {"state": "translated", "value": "%#@items@"},
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("Several items"),
                        }
                    },
                }
            },
        }
        document = base_catalog(
            {
                "count": {
                    "extractionState": "manual",
                    "localizations": {"en": substitution},
                }
            }
        )

        report = catalog.validate_catalog(document)

        self.assertGreater(report["keys"], 0)
        self.assertEqual(
            catalog.localization_signatures(substitution),
            [[
                {
                    "argument": 1,
                    "conversion": "lld",
                    "flags": "",
                    "precision": None,
                    "width": None,
                }
            ]],
        )

    def test_substitution_visible_count_replaces_implicit_selector_placeholder(self):
        localization = {
            "stringUnit": {"state": "translated", "value": "%#@items@"},
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("%lld items"),
                        }
                    },
                }
            },
        }
        expected = [{
            "argument": 1,
            "conversion": "lld",
            "flags": "",
            "precision": None,
            "width": None,
        }]
        document = base_catalog({
            "items": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })

        self.assertEqual(catalog.localization_signatures(localization), [expected])
        self.assertGreater(catalog.validate_catalog(document)["keys"], 0)

    def test_each_visible_count_replaces_its_own_selector_in_compound_outer(self):
        localization = {
            "stringUnit": {
                "state": "translated",
                "value": "%#@items@ in %#@folders@ by %@",
            },
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("%lld items"),
                        }
                    },
                },
                "folders": {
                    "formatSpecifier": "d",
                    "variations": {
                        "plural": {
                            "one": translated("One folder"),
                            "other": translated("%d folders"),
                        }
                    },
                },
            },
        }
        expected = [
            {
                "argument": 1,
                "conversion": "lld",
                "flags": "",
                "precision": None,
                "width": None,
            },
            {
                "argument": 2,
                "conversion": "d",
                "flags": "",
                "precision": None,
                "width": None,
            },
            {
                "argument": 3,
                "conversion": "@",
                "flags": "",
                "precision": None,
                "width": None,
            },
        ]
        document = base_catalog({
            "compound_items": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })

        self.assertEqual(
            catalog._substitution_argument_map(localization),
            {"folders": 2, "items": 1},
        )
        self.assertEqual(catalog.localization_signatures(localization), [expected])
        self.assertGreater(catalog.validate_catalog(document)["keys"], 0)

    def test_compound_substitution_assigns_arguments_left_to_right(self):
        localization = {
            "stringUnit": {
                "state": "translated",
                "value": "%#@count@ by %@",
            },
            "substitutions": {
                "count": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("Several items"),
                        }
                    },
                }
            },
        }

        document = base_catalog({
            "compound": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })

        self.assertEqual(
            catalog.localization_signatures(localization),
            [[
                {
                    "argument": 1,
                    "conversion": "lld",
                    "flags": "",
                    "precision": None,
                    "width": None,
                },
                {
                    "argument": 2,
                    "conversion": "@",
                    "flags": "",
                    "precision": None,
                    "width": None,
                },
            ]],
        )
        self.assertGreater(catalog.validate_catalog(document)["keys"], 0)

    def test_multiple_substitutions_preserve_every_category_combination(self):
        localization = {
            "stringUnit": {
                "state": "translated",
                "value": "%#@files@ in %#@folders@",
            },
            "substitutions": {
                "files": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One file"),
                            "other": translated("Several files"),
                        }
                    },
                },
                "folders": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One folder"),
                            "other": translated("Several folders"),
                        }
                    },
                },
            },
        }

        signature_map = catalog.localization_signature_map(localization)
        document = base_catalog({
            "multiple": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })

        self.assertIsNotNone(signature_map)
        self.assertEqual(len(signature_map), 4)
        self.assertTrue(
            all(
                [item["argument"] for item in signature] == [1, 2]
                for signature in signature_map.values()
            )
        )
        self.assertGreater(catalog.validate_catalog(document)["keys"], 0)

    def test_cross_locale_sequential_substitution_reorder_is_rejected(self):
        def localization(value):
            return {
                "stringUnit": {"state": "translated", "value": value},
                "substitutions": {
                    name: {
                        "formatSpecifier": "lld",
                        "variations": {
                            "plural": {
                                "one": translated(f"One {name}"),
                                "other": translated(f"Several {name}"),
                            }
                        },
                    }
                    for name in ("files", "folders")
                },
            }

        document = base_catalog({
            "counts": {
                "extractionState": "manual",
                "localizations": {
                    "en": localization("%#@files@ in %#@folders@"),
                    "ru": localization("%#@folders@ contains %#@files@"),
                },
            }
        })

        with self.assertRaisesRegex(
            catalog.CatalogError,
            "substitution argument mapping",
        ):
            catalog.validate_catalog(document)

    def test_cross_locale_positional_substitution_reorder_is_allowed(self):
        def localization(value):
            return {
                "stringUnit": {"state": "translated", "value": value},
                "substitutions": {
                    name: {
                        "formatSpecifier": "lld",
                        "variations": {
                            "plural": {
                                "one": translated(f"One {name}"),
                                "other": translated(f"Several {name}"),
                            }
                        },
                    }
                    for name in ("files", "folders")
                },
            }

        document = base_catalog({
            "counts": {
                "extractionState": "manual",
                "localizations": {
                    "en": localization("%#@files@ in %#@folders@"),
                    "ru": localization(
                        "%2$#@folders@ contains %1$#@files@"
                    ),
                },
            }
        })

        self.assertGreater(catalog.validate_catalog(document)["keys"], 0)

    def test_substitution_markers_and_definitions_are_validated_fail_closed(self):
        cases = {
            "missing definition": {
                "stringUnit": {"state": "translated", "value": "%#@count@"},
                "substitutions": {},
            },
            "unused definition": {
                "stringUnit": {"state": "translated", "value": "Items"},
                "substitutions": {
                    "count": {
                        "formatSpecifier": "lld",
                        "variations": {
                            "plural": {
                                "one": translated("One item"),
                                "other": translated("Several items"),
                            }
                        },
                    }
                },
            },
            "duplicate marker": {
                "stringUnit": {
                    "state": "translated",
                    "value": "%#@count@ and %#@count@",
                },
                "substitutions": {
                    "count": {
                        "formatSpecifier": "lld",
                        "variations": {
                            "plural": {
                                "one": translated("One item"),
                                "other": translated("Several items"),
                            }
                        },
                    }
                },
            },
            "invalid format specifier": {
                "stringUnit": {"state": "translated", "value": "%#@count@"},
                "substitutions": {
                    "count": {
                        "formatSpecifier": "lld %@",
                        "variations": {
                            "plural": {
                                "one": translated("One item"),
                                "other": translated("Several items"),
                            }
                        },
                    }
                },
            },
        }

        for label, localization in cases.items():
            with self.subTest(label=label):
                with self.assertRaises(catalog.CatalogError):
                    catalog.localization_signature_map(localization)
                document = base_catalog({
                    f"broken_{label.replace(' ', '_')}": {
                        "extractionState": "manual",
                        "localizations": {"ru": localization},
                    }
                })
                with self.assertRaises(catalog.CatalogError):
                    catalog.validate_catalog(document)

    def test_plural_callsite_rejects_extra_arguments(self):
        substitution = {
            "stringUnit": {"state": "translated", "value": "%#@items@"},
            "substitutions": {
                "items": {
                    "formatSpecifier": "lld",
                    "variations": {
                        "plural": {
                            "one": translated("One item"),
                            "other": translated("Several items"),
                        }
                    },
                }
            },
        }
        document = base_catalog({
            "count": {
                "extractionState": "manual",
                "localizations": {"en": substitution},
            }
        })
        expected = catalog.localization_signatures(substitution)[0]
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "count",
                "apis": ["plural"],
                "formatSignature": expected,
                "callsites": [{
                    "api": "plural",
                    "argumentCount": 1,
                    "fallback": "Several items",
                    "formatSignature": [],
                    "typeSafety": "typed",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "argument count mismatch"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_plural_fallback_cannot_change_the_count_integer_type(self):
        localization = {
            "variations": {
                "plural": {
                    "one": translated("%lld item"),
                    "other": translated("%lld items"),
                }
            }
        }
        document = base_catalog({
            "count": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })
        expected = catalog.localization_signatures(localization)[0]
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "count",
                "apis": ["plural"],
                "formatSignature": expected,
                "callsites": [{
                    "api": "plural",
                    "argumentCount": 0,
                    "fallback": "%d items",
                    "formatSignature": catalog.parse_format_signature("%d items"),
                    "typeSafety": "typed",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "callsite signature"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_active_plural_api_requires_native_plural_structure(self):
        document = base_catalog({
            "count": {
                "extractionState": "manual",
                "localizations": {"en": translated("%lld items")},
            }
        })
        expected = catalog.parse_format_signature("%lld items")
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "count",
                "apis": ["plural"],
                "formatSignature": expected,
                "callsites": [],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "native plural"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_active_plural_count_must_use_an_integer_conversion(self):
        localization = {
            "variations": {
                "plural": {
                    "one": translated("%@ item"),
                    "other": translated("%@ items"),
                }
            }
        }
        document = base_catalog({
            "count": {
                "extractionState": "manual",
                "localizations": {"en": localization},
            }
        })
        expected = catalog.localization_signatures(localization)[0]
        manifest = {
            "schemaVersion": 1,
            "activeKeys": [{
                "key": "count",
                "apis": ["plural"],
                "formatSignature": expected,
                "callsites": [{
                    "api": "plural",
                    "argumentCount": 0,
                    "fallback": "%@ items",
                    "formatSignature": expected,
                    "typeSafety": "typed",
                    "path": "Screen.swift",
                    "line": 1,
                }],
            }],
        }

        with self.assertRaisesRegex(catalog.CatalogError, "integer count"):
            catalog.validate_catalog(document, manifest=manifest)

    def test_english_plural_categories_must_share_a_signature(self):
        document = base_catalog({
            "count": {
                "extractionState": "manual",
                "localizations": {
                    "en": {
                        "variations": {
                            "plural": {
                                "one": translated("%@ item"),
                                "other": translated("%lld items"),
                            }
                        }
                    }
                },
            }
        })

        with self.assertRaisesRegex(catalog.CatalogError, "Placeholder signature mismatch"):
            catalog.validate_catalog(document)


if __name__ == "__main__":
    unittest.main()
