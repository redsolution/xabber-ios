import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_manifest as manifest
import localization_catalog as catalog_tool


class SwiftScannerTests(unittest.TestCase):
    def test_scanner_ignores_line_and_nested_block_comments(self):
        source = r'''
        // "Ignored".localizeString(id: "ignored_line", arguments: [])
        /* outer
           "Ignored".localizeString(id: "ignored_outer", arguments: [])
           /* "Ignored".localizeString(id: "ignored_nested", arguments: []) */
        */
        let value = "Visible".localizeString(id: "visible", arguments: [])
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual([call["key"] for call in result["calls"]], ["visible"])

    def test_scanner_reads_raw_multiline_and_interpolated_literals(self):
        source = r'''
        func render(count: Int, name: String) {
            let raw = #"Raw fallback"#.localizeString(
                id: #"raw_key"#,
                arguments: []
            )
            let multiline = """
                First line
                Second line
                """.localizeString(id: "multiline_key", arguments: [])
            let formatted = L10n.format(
                "formatted_key",
                fallback: "%2$@ has %1$lld items",
                arguments: [count, name]
            )
            let interpolated = "Hello \(name)".localizeString(
                id: "hello_name",
                arguments: [name]
            )
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})
        calls = {call["key"]: call for call in result["calls"]}

        self.assertEqual(calls["raw_key"]["fallback"], "Raw fallback")
        self.assertEqual(calls["multiline_key"]["fallback"], "First line\nSecond line")
        self.assertEqual(calls["formatted_key"]["argumentCount"], 2)
        self.assertEqual(
            [item["conversion"] for item in calls["formatted_key"]["formatSignature"]],
            ["lld", "@"],
        )
        self.assertEqual(calls["hello_name"]["fallback"], "Hello %@")

    def test_scanner_reports_unresolved_and_direct_lookups(self):
        source = r'''
        let first = L10n.text(dynamicKey, fallback: fallback)
        let second = NSLocalizedString("forbidden", comment: "")
        let third = bundle.localizedString(forKey: "also_forbidden", value: nil, table: nil)
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(len(result["unresolved"]), 1)
        self.assertEqual(
            [lookup["api"] for lookup in result["directLookups"]],
            ["NSLocalizedString", "Bundle.localizedString"],
        )

    def test_scanner_reports_modern_foundation_localization_lookups(self):
        source = r'''
        let first = String(localized: "forbidden")
        let second = Swift.String(localized: "also_forbidden")
        let third = LocalizedStringResource("resource_forbidden")
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [lookup["api"] for lookup in result["directLookups"]],
            [
                "String(localized:)",
                "String(localized:)",
                "LocalizedStringResource",
            ],
        )

    def test_scanner_reports_direct_legacy_format_outside_adapter(self):
        source = (
            'let value = L10n.legacyFormat("key", fallback: "Value", arguments: [])\n'
        )

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [lookup["api"] for lookup in result["directLookups"]],
            ["L10n.legacyFormat"],
        )

    def test_scanner_allows_legacy_format_only_in_configured_adapter(self):
        source = 'return L10n.legacyFormat(id, fallback: self, arguments: arguments)\n'
        config = {
            "allowedLegacyFormatPaths": [
                "xabber/utils/String/StringExtensions.swift"
            ]
        }

        adapter = manifest.scan_swift_source(
            source,
            "xabber/utils/String/StringExtensions.swift",
            config,
        )
        other_file = manifest.scan_swift_source(
            source,
            "xabber/OtherAdapter.swift",
            config,
        )

        self.assertEqual(adapter["directLookups"], [])
        self.assertEqual(
            [lookup["api"] for lookup in other_file["directLookups"]],
            ["L10n.legacyFormat"],
        )

    def test_bounded_domain_expands_dynamic_callsite(self):
        source = 'return L10n.text(key, fallback: fallback)\n'
        config = {
            "boundedDynamicDomains": [
                {
                    "name": "push",
                    "path": "xabber/Push.swift",
                    "keys": [
                        {"key": "push_title", "fallback": "New message"},
                        {"key": "push_body", "fallback": "%@ sent a message"},
                    ],
                }
            ]
        }

        result = manifest.scan_swift_source(source, "xabber/Push.swift", config)

        self.assertEqual(result["unresolved"], [])
        self.assertEqual(
            [(call["key"], call["origin"]) for call in result["calls"]],
            [("push_body", "generatedPattern"), ("push_title", "generatedPattern")],
        )

    def test_bounded_domain_filters_expanded_keys_by_matching_api(self):
        source = '''
        let title = L10n.text(key, fallback: fallback)
        let body = L10n.format(key, fallback: fallback, arguments: arguments)
        '''
        config = {
            "boundedDynamicDomains": [
                {
                    "name": "push",
                    "path": "xabber/Push.swift",
                    "patterns": [
                        {"api": "text", "keyExpression": "key"},
                        {"api": "format", "keyExpression": "key"},
                    ],
                    "keys": [
                        {
                            "api": "text",
                            "argumentCount": 0,
                            "fallback": "New message",
                            "key": "push_title",
                        },
                        {
                            "api": "format",
                            "argumentCount": 1,
                            "fallback": "%@ sent a message",
                            "key": "push_body",
                        },
                    ],
                }
            ]
        }

        result = manifest.scan_swift_source(source, "xabber/Push.swift", config)

        self.assertEqual(result["unresolved"], [])
        self.assertEqual(
            [(call["key"], call["api"]) for call in result["calls"]],
            [("push_body", "format"), ("push_title", "text")],
        )

    def test_hardcoded_ui_audit_keeps_accessibility_text_but_not_identifier(self):
        source = r'''
        titleLabel.text = "Visible title"
        let alert = UIAlertController(title: "Alert title", message: "Alert message")
        view.makeToast("Toast message")
        button.accessibilityLabel = "Readable button"
        button.accessibilityHint = "Performs an action"
        button.accessibilityValue = "Enabled"
        button.accessibilityIdentifier = "settings.language.en"
        logger.info("Diagnostic only")
        titleLabel.text = L10n.text("title", fallback: "Localized")
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [candidate["sink"] for candidate in result["hardcodedCandidates"]],
            [
                "accessibilityHint",
                "accessibilityLabel",
                "accessibilityValue",
                "makeToast",
                "message",
                "text",
                "title",
            ],
        )
        self.assertNotIn(
            "settings.language.en",
            [candidate["value"] for candidate in result["hardcodedCandidates"]],
        )

    def test_hardcoded_ui_audit_includes_attributed_string_sinks(self):
        source = r'''
        label.attributedText = NSAttributedString(string: "Visible attributed title")
        let mutableValue = NSMutableAttributedString(
            string: "Visible mutable attributed title"
        )
        let value = AttributedString(
            "Visible Swift attributed title",
            attributes: AttributeContainer()
        )
        label.attributedText = NSAttributedString(
            string: L10n.text("localized", fallback: "Localized")
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [candidate["value"] for candidate in result["hardcodedCandidates"]],
            [
                "Visible Swift attributed title",
                "Visible attributed title",
                "Visible mutable attributed title",
            ],
        )
        self.assertEqual(
            {candidate["sink"] for candidate in result["hardcodedCandidates"]},
            {"attributedString"},
        )

    def test_repository_attributed_ui_strings_are_present_in_audit(self):
        repository_root = TOOLS_ROOT.parent
        fixtures = {
            "xabber/controllers/credentials/CredentialsExpiredViewController.swift": {
                "Password"
            },
            "xabber/controllers/notifications/NotificationsListViewController.swift": {
                "Notifications about new logins, device changes, and activity on your account.",
                "Security",
            },
            "xabber/controllers/split/BaseRootViewController.swift": {"Chats"},
            "xabber/controllers/ake/AuthenticationCodeInputViewController.swift": {
                "1.\tEnsure the other device is displaying the verification code.\n\n2.\tEnter the verification code displayed on the other device to complete the encryption key exchange:",
                "1.\tCarefully verify the address and identity of this contact.\n\n2.\tEnter the verification code provided by your contact to confirm the secure connection:",
            },
            "xabber/controllers/chats/chat/messages_kit/Views/Cells/old/SystemMessageCell.swift": {
                "Incoming call",
                "Missed call",
            },
        }

        for relative_path, expected in fixtures.items():
            source = (repository_root / relative_path).read_text(encoding="utf-8")
            result = manifest.scan_swift_source(source, relative_path, {})
            attributed_values = {
                candidate["value"]
                for candidate in result["hardcodedCandidates"]
                if candidate["sink"] == "attributedString"
            }
            with self.subTest(path=relative_path):
                self.assertTrue(expected <= attributed_values)

    def test_push_localization_facade_is_a_first_class_literal_api(self):
        source = r'''
        let title = PushNotificationLocalization.string(
            "push_title",
            fallback: "New message"
        )
        let body = PushNotificationLocalization.string(
            "push_body",
            fallback: "%@ sent a message",
            sender
        )
        '''

        result = manifest.scan_swift_source(
            source, "xabber-push-extension/NotificationService.swift", {}
        )
        calls = {call["key"]: call for call in result["calls"]}

        self.assertEqual(calls["push_title"]["api"], "text")
        self.assertEqual(calls["push_title"]["argumentCount"], 0)
        self.assertEqual(calls["push_body"]["api"], "format")
        self.assertEqual(calls["push_body"]["argumentCount"], 1)
        self.assertEqual(calls["push_body"]["surfaces"], ["push"])


class ManifestBuildTests(unittest.TestCase):
    def _minimal_manifest_document(self) -> dict:
        return {
            "activeKeys": [],
            "catalog": "xabber/translations/Localizable.xcstrings",
            "catalogOnly": [],
            "computedFallbacks": [],
            "directLookups": [],
            "domainReservedKeys": [],
            "dynamicDomains": [],
            "excludedPaths": [],
            "fallbackConflictQuarantine": [],
            "hardcodedCandidates": [],
            "infoPlist": [],
            "interfaceBuilder": [],
            "legacyMarkupQuarantine": [],
            "schemaVersion": manifest.SCHEMA_VERSION,
            "sourceLanguage": "en",
            "summary": {
                "activeKeys": 0,
                "activeWithoutEnglish": 0,
                "catalogKeys": 0,
                "catalogOnlyKeys": 0,
                "computedFallbacks": 0,
                "directLookups": 0,
                "domainReservedKeys": 0,
                "dynamicDomains": 0,
                "excludedPaths": 0,
                "fallbackConflicts": 0,
                "hardcodedCandidates": 0,
                "infoPlistStrings": 0,
                "interfaceBuilderStrings": 0,
                "unresolvedDynamicCalls": 0,
            },
            "unresolvedDynamicCalls": [],
        }

    def _minimal_active_manifest_document(self) -> dict:
        document = self._minimal_manifest_document()
        document["activeKeys"] = [
            {
                "apis": ["text"],
                "callsites": [
                    {
                        "api": "text",
                        "argumentCount": 0,
                        "fallback": "Hello",
                        "formatSignature": [],
                        "line": 1,
                        "origin": "sourceLiteral",
                        "path": "xabber/Screen.swift",
                        "surfaces": ["app"],
                        "symbol": None,
                        "typeSafety": "typed",
                    }
                ],
                "english": {"fallbackStatus": "consistent", "value": "Hello"},
                "fallbacks": ["Hello"],
                "formatSignature": [],
                "key": "hello",
                "origins": ["sourceLiteral"],
                "surfaces": ["app"],
            }
        ]
        document["summary"]["activeKeys"] = 1
        document["summary"]["catalogKeys"] = 1
        return document

    def _write_catalog(self, root: Path) -> None:
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "hello": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "stringUnit": {"state": "translated", "value": "Hello"}
                        }
                    },
                },
                "catalog_only": {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "stringUnit": {"state": "translated", "value": "Old"}
                        }
                    },
                },
                "plurals.old.item_0": {
                    "extractionState": "manual",
                    "localizations": {
                        "ru": {
                            "stringUnit": {"state": "translated", "value": "Старое"}
                        }
                    },
                },
            },
            "version": "1.0",
        }
        target = root / "xabber/translations/Localizable.xcstrings"
        target.parent.mkdir(parents=True)
        target.write_text(json.dumps(catalog), encoding="utf-8")

    def test_build_manifest_is_deterministic_and_inventories_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            (root / "xabber-push-extension").mkdir()
            source.write_text(
                'label.text = "Hello".localizeString(id: "hello", arguments: [])\n',
                encoding="utf-8",
            )
            (root / "xabber/Ignored.swift").write_text(
                'label.text = "Ignored".localizeString(id: "ignored", arguments: [])\n',
                encoding="utf-8",
            )
            storyboard = root / "xabber/Base.lproj/Main.storyboard"
            storyboard.parent.mkdir(parents=True)
            storyboard.write_text(
                '<?xml version="1.0"?><document><label id="abc" text="Welcome"/></document>',
                encoding="utf-8",
            )
            info = root / "xabber/Info.plist"
            info.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                '<plist version="1.0"><dict>'
                '<key>NSCameraUsageDescription</key><string>Use the camera</string>'
                '<key>InternalSetting</key><string>Not visible</string>'
                '</dict></plist>',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber", "xabber-push-extension"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "excludedPaths": ["xabber/Ignored.swift"],
                "manifest": "docs/localization/active-keys.json",
            }

            first = manifest.build_manifest(root, config)
            second = manifest.build_manifest(root, config)

            self.assertEqual(manifest.render_manifest(first), manifest.render_manifest(second))
            self.assertEqual(first["schemaVersion"], 1)
            self.assertEqual(first["summary"]["activeKeys"], 1)
            self.assertEqual(first["interfaceBuilder"][0]["value"], "Welcome")
            self.assertEqual(first["infoPlist"][0]["key"], "NSCameraUsageDescription")
            classifications = {
                item["key"]: item["classification"] for item in first["catalogOnly"]
            }
            self.assertEqual(classifications["catalog_only"], "reviewCandidate")
            self.assertEqual(
                classifications["plurals.old.item_0"], "retainedLegacyPlural"
            )

    def test_manifest_records_dynamic_patterns_and_expanded_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Dynamic.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "return L10n.text(key, fallback: fallback)\n",
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "boundedDynamicDomains": [{
                    "api": "text",
                    "keyExpression": "key",
                    "keys": [{
                        "argumentCount": 0,
                        "fallback": "Hello",
                        "key": "hello",
                    }],
                    "name": "dynamicGreeting",
                    "path": "xabber/Dynamic.swift",
                }],
            }

            document = manifest.build_manifest(root, config)

            self.assertEqual(document["summary"]["dynamicDomains"], 1)
            self.assertEqual(
                document["dynamicDomains"],
                [{
                    "expandedKeys": [{"apis": ["text"], "key": "hello"}],
                    "kind": "bounded",
                    "name": "dynamicGreeting",
                    "paths": ["xabber/Dynamic.swift"],
                    "patterns": [{"api": "text", "keyExpression": "key"}],
                }],
            )

    def test_configured_dynamic_domain_without_a_matching_call_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Dynamic.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("let value = 1\n", encoding="utf-8")
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "boundedDynamicDomains": [{
                    "api": "text",
                    "keyExpression": "key",
                    "keys": [{
                        "argumentCount": 0,
                        "fallback": "Hello",
                        "key": "hello",
                    }],
                    "name": "dynamicGreeting",
                    "path": "xabber/Dynamic.swift",
                }],
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "matched no localization calls",
            ):
                manifest.build_manifest(root, config)

    def test_each_bounded_dynamic_pattern_must_match_a_callsite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Dynamic.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                "return L10n.text(key, fallback: fallback)\n",
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "boundedDynamicDomains": [{
                    "keys": [{
                        "api": "text",
                        "argumentCount": 0,
                        "fallback": "Hello",
                        "key": "hello",
                    }],
                    "name": "dynamicGreeting",
                    "path": "xabber/Dynamic.swift",
                    "patterns": [
                        {"api": "text", "keyExpression": "key"},
                        {"api": "format", "keyExpression": "key"},
                    ],
                }],
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "pattern 1 matched no localization calls",
            ):
                manifest.build_manifest(root, config)

    def test_new_html_markup_requires_explicit_quarantine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            catalog_path = root / "xabber/translations/Localizable.xcstrings"
            catalog_document = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog_document["strings"]["catalog_only"]["localizations"]["en"] = {
                "stringUnit": {"state": "translated", "value": "<b>Old</b>"}
            }
            catalog_path.write_text(json.dumps(catalog_document), encoding="utf-8")
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            with self.assertRaisesRegex(manifest.ManifestError, "legacy markup quarantine"):
                manifest.build_manifest(root, config)

            config["legacyMarkupKeys"] = ["catalog_only"]
            document = manifest.build_manifest(root, config)

            self.assertEqual(
                document["legacyMarkupQuarantine"],
                [{"key": "catalog_only", "status": "catalogOnly"}],
            )

    def test_validate_manifest_rejects_unresolved_dynamic_calls(self):
        document = self._minimal_manifest_document()
        document["unresolvedDynamicCalls"] = [
            {
                "api": "text",
                "expression": "key",
                "line": 3,
                "path": "xabber/Screen.swift",
                "symbol": None,
            }
        ]
        document["summary"]["unresolvedDynamicCalls"] = 1

        with self.assertRaisesRegex(manifest.ManifestError, "unresolved dynamic"):
            manifest.validate_manifest(document)

    def test_validate_manifest_rejects_direct_localization_lookups(self):
        document = self._minimal_manifest_document()
        document["directLookups"] = [
            {
                "api": "LocalizedStringResource",
                "line": 3,
                "path": "xabber/Screen.swift",
                "symbol": None,
            }
        ]
        document["summary"]["directLookups"] = 1

        with self.assertRaisesRegex(manifest.ManifestError, "direct localization"):
            manifest.validate_manifest(document)

    def test_validate_manifest_requires_current_schema(self):
        document = self._minimal_manifest_document()
        del document["schemaVersion"]

        with self.assertRaisesRegex(manifest.ManifestError, "schemaVersion"):
            manifest.validate_manifest(document)

    def test_validate_manifest_rejects_malformed_active_entry(self):
        document = self._minimal_manifest_document()
        document["activeKeys"] = [{"broken": True}]
        document["summary"]["activeKeys"] = 1

        with self.assertRaisesRegex(manifest.ManifestError, "activeKeys\\[0\\]"):
            manifest.validate_manifest(document)

    def test_validate_manifest_rejects_summary_mismatch(self):
        document = self._minimal_manifest_document()
        document["summary"]["hardcodedCandidates"] = 1

        with self.assertRaisesRegex(
            manifest.ManifestError,
            "summary hardcodedCandidates",
        ):
            manifest.validate_manifest(document)

    def test_validate_manifest_rejects_json_booleans_for_integer_fields(self):
        mutations = {
            "schemaVersion": lambda document: document.__setitem__(
                "schemaVersion", True
            ),
            "summary": lambda document: document["summary"].__setitem__(
                "catalogKeys", True
            ),
            "argumentCount": lambda document: document["activeKeys"][0][
                "callsites"
            ][0].__setitem__("argumentCount", True),
            "line": lambda document: document["activeKeys"][0]["callsites"][
                0
            ].__setitem__("line", True),
            "format argument": lambda document: (
                document["activeKeys"][0].__setitem__(
                    "formatSignature",
                    [
                        {
                            "argument": True,
                            "conversion": "@",
                            "flags": "",
                            "precision": None,
                            "width": None,
                        }
                    ],
                ),
                document["activeKeys"][0]["callsites"][0].__setitem__(
                    "formatSignature",
                    [
                        {
                            "argument": True,
                            "conversion": "@",
                            "flags": "",
                            "precision": None,
                            "width": None,
                        }
                    ],
                ),
            ),
        }

        for field, mutate in mutations.items():
            with self.subTest(field=field):
                document = self._minimal_active_manifest_document()
                mutate(document)
                with self.assertRaises(manifest.ManifestError):
                    manifest.validate_manifest(document)

    def test_validate_manifest_requires_true_plural_count_marker_only_for_plural(self):
        plural_document = self._minimal_active_manifest_document()
        active = plural_document["activeKeys"][0]
        active["apis"] = ["plural"]
        active["callsites"][0]["api"] = "plural"
        active["callsites"][0]["pluralCountArgument"] = False

        with self.assertRaisesRegex(
            manifest.ManifestError,
            "pluralCountArgument",
        ):
            manifest.validate_manifest(plural_document)

        text_document = self._minimal_active_manifest_document()
        text_document["activeKeys"][0]["callsites"][0][
            "pluralCountArgument"
        ] = True

        with self.assertRaisesRegex(
            manifest.ManifestError,
            "pluralCountArgument",
        ):
            manifest.validate_manifest(text_document)

    def test_validate_manifest_requires_reserved_format_signatures(self):
        document = self._minimal_manifest_document()
        document["catalogOnly"] = [
            {
                "classification": "reviewCandidate",
                "key": "reserved",
            }
        ]
        document["domainReservedKeys"] = [
            {
                "apis": ["text"],
                "domains": ["typed"],
                "fallbacks": ["Reserved"],
                "formatSignatures": [],
                "key": "reserved",
                "surfaces": ["app"],
            }
        ]
        document["summary"]["catalogKeys"] = 1
        document["summary"]["catalogOnlyKeys"] = 1
        document["summary"]["domainReservedKeys"] = 1

        with self.assertRaisesRegex(
            manifest.ManifestError,
            "formatSignatures must not be empty",
        ):
            manifest.validate_manifest(document)

    def test_validate_manifest_rejects_overlapping_active_and_reserved_keys(self):
        document = self._minimal_manifest_document()
        document["activeKeys"] = [{
            "apis": ["text"],
            "callsites": [{
                "api": "text",
                "argumentCount": 0,
                "fallback": "Hello",
                "formatSignature": [],
                "line": 1,
                "origin": "sourceLiteral",
                "path": "xabber/Screen.swift",
                "surfaces": ["app"],
                "symbol": None,
                "typeSafety": "typed",
            }],
            "english": {"fallbackStatus": "consistent", "value": "Hello"},
            "fallbacks": ["Hello"],
            "formatSignature": [],
            "key": "hello",
            "origins": ["sourceLiteral"],
            "surfaces": ["app"],
        }]
        document["domainReservedKeys"] = [{
            "apis": ["text"],
            "domains": ["typed"],
            "fallbacks": ["Hello"],
            "formatSignatures": [[]],
            "key": "hello",
            "surfaces": ["app"],
        }]
        document["summary"]["activeKeys"] = 1
        document["summary"]["domainReservedKeys"] = 1

        with self.assertRaisesRegex(manifest.ManifestError, "active/reserved"):
            manifest.validate_manifest(document)

    def test_build_manifest_rejects_missing_source_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            config = {
                "sourceRoots": ["xabber", "missing-extension"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            with self.assertRaisesRegex(manifest.ManifestError, "source root"):
                manifest.build_manifest(root, config)

    def test_fallback_conflicts_require_exact_reasoned_quarantine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.write_text(
                '''
                let title = L10n.text("hello", fallback: "Hello")
                let alternate = L10n.text("hello", fallback: "Hi")
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            with self.assertRaisesRegex(
                manifest.ManifestError, "fallback conflict quarantine"
            ):
                manifest.build_manifest(root, config)

            config["fallbackConflictAllowlist"] = {
                "hello": "Two existing UI contexts intentionally retain distinct fallbacks."
            }
            document = manifest.build_manifest(root, config)
            hello = next(item for item in document["activeKeys"] if item["key"] == "hello")

            self.assertEqual(hello["english"]["fallbackStatus"], "conflictingFallbacks")
            self.assertEqual(
                document["fallbackConflictQuarantine"],
                [{
                    "key": "hello",
                    "reason": "Two existing UI contexts intentionally retain distinct fallbacks.",
                }],
            )

            config["fallbackConflictAllowlist"]["stale"] = "No longer conflicting."
            with self.assertRaisesRegex(
                manifest.ManifestError, "fallback conflict quarantine"
            ):
                manifest.build_manifest(root, config)

    def test_computed_fallbacks_require_exact_reasoned_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.write_text(
                '''
                let fallback = Bool.random() ? "Hello" : "Hi"
                let title = fallback.localizeString(id: "hello", arguments: [])
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            with self.assertRaisesRegex(
                manifest.ManifestError, "computed fallback configuration"
            ):
                manifest.build_manifest(root, config)

            config["computedFallbacks"] = {
                "hello": {
                    "expression": "fallback",
                    "reason": "The callsite selects one of two development strings at runtime.",
                }
            }
            document = manifest.build_manifest(root, config)
            hello = next(item for item in document["activeKeys"] if item["key"] == "hello")

            self.assertEqual(hello["english"]["fallbackStatus"], "computedFallback")
            self.assertEqual(
                document["computedFallbacks"],
                [{
                    "expression": "fallback",
                    "key": "hello",
                    "reason": "The callsite selects one of two development strings at runtime.",
                }],
            )

            config["computedFallbacks"]["stale"] = {
                "expression": "stale",
                "reason": "No matching computed callsite remains.",
            }
            with self.assertRaisesRegex(
                manifest.ManifestError, "computed fallback configuration"
            ):
                manifest.build_manifest(root, config)

    def test_load_config_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text('{"catalog":"first","catalog":"second"}', encoding="utf-8")

            with self.assertRaisesRegex(manifest.ManifestError, "Duplicate JSON key"):
                manifest.load_config(path)

    def test_typed_domain_infers_argument_count_from_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                '''
                enum TypedKey: String {
                    case greeting = "typed_greeting"

                    var developmentFallback: String {
                        switch self {
                        case .greeting: return "%@ has %lld items"
                        }
                    }
                }
                ''',
                encoding="utf-8",
            )
            domain = {
                "api": "format",
                "casePolicy": "allCasesRequired",
                "enum": "TypedKey",
                "fallbackProperty": "developmentFallback",
                "name": "typed",
                "source": "xabber/Typed.swift",
            }

            calls = manifest._typed_domain_calls(root, domain, {})

            self.assertEqual(calls[0]["argumentCount"], 2)

    def test_typed_domain_can_classify_text_and_format_by_argument_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                '''
                enum TypedKey: String {
                    case title = "typed_title"
                    case greeting = "typed_greeting"

                    var developmentFallback: String {
                        switch self {
                        case .title: return "Title"
                        case .greeting: return "Hello, %@"
                        }
                    }
                }
                ''',
                encoding="utf-8",
            )
            domain = {
                "api": "text",
                "formatWhenArgumentsPresent": True,
                "casePolicy": "allCasesRequired",
                "enum": "TypedKey",
                "fallbackProperty": "developmentFallback",
                "name": "typed",
                "source": "xabber/Typed.swift",
            }

            calls = manifest._typed_domain_calls(root, domain, {})
            apis = {call["key"]: call["api"] for call in calls}

            self.assertEqual(apis["typed_title"], "text")
            self.assertEqual(apis["typed_greeting"], "format")

    def test_all_cases_required_rejects_unparsed_cases_and_missing_fallbacks(self):
        fixtures = {
            "multiple declarations": '''
                enum TypedKey: String {
                    case first = "typed_first", second = "typed_second"

                    var developmentFallback: String {
                        switch self {
                        case .first: return "First"
                        case .second: return "Second"
                        }
                    }
                }
            ''',
            "implicit raw value": '''
                enum TypedKey: String {
                    case first

                    var developmentFallback: String {
                        switch self {
                        case .first: return "First"
                        }
                    }
                }
            ''',
            "missing fallback": '''
                enum TypedKey: String {
                    case first = "typed_first"
                    case second = "typed_second"

                    var developmentFallback: String {
                        switch self {
                        case .first: return "First"
                        case .second: return computedFallback
                        }
                    }
                }
            ''',
        }
        domain = {
            "api": "text",
            "casePolicy": "allCasesRequired",
            "enum": "TypedKey",
            "fallbackProperty": "developmentFallback",
            "name": "typed",
            "source": "xabber/Typed.swift",
        }

        for fixture, contents in fixtures.items():
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "xabber/Typed.swift"
                source.parent.mkdir(parents=True)
                source.write_text(contents, encoding="utf-8")

                with self.assertRaisesRegex(
                    manifest.ManifestError,
                    "Typed localization enum|fallback",
                ):
                    manifest._typed_domain_calls(root, domain, {})

    def test_typed_manifest_separates_observed_active_and_domain_reserved_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            catalog_path = root / "xabber/translations/Localizable.xcstrings"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            for key, value in {
                "typed_used": "Used",
                "typed_dynamic_first": "Dynamic first",
                "typed_dynamic_second": "Dynamic second",
                "typed_reserved": "Reserved",
            }.items():
                catalog["strings"][key] = {
                    "extractionState": "manual",
                    "localizations": {
                        "en": {
                            "stringUnit": {"state": "translated", "value": value}
                        }
                    },
                }
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            source = root / "xabber/Typed.swift"
            source.write_text(
                '''
                enum TypedKey: String {
                    case used = "typed_used"
                    case dynamicFirst = "typed_dynamic_first"
                    case dynamicSecond = "typed_dynamic_second"
                    case reserved = "typed_reserved"

                    var developmentFallback: String {
                        switch self {
                        case .used: return "Used"
                        case .dynamicFirst: return "Dynamic first"
                        case .dynamicSecond: return "Dynamic second"
                        case .reserved: return "Reserved"
                        }
                    }
                }

                func render(dynamicKey: TypedKey) {
                    _ = TypedLocalization.text(.used)
                    _ = TypedLocalization.text(dynamicKey)
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "typedDomains": [{
                    "api": "text",
                    "casePolicy": "conservative",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "TypedLocalization.text",
                        "dynamicCases": ["dynamicFirst", "dynamicSecond"],
                        "paths": ["xabber/*.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            document = manifest.build_manifest(root, config)

            self.assertEqual(
                [entry["key"] for entry in document["activeKeys"]],
                ["typed_dynamic_first", "typed_dynamic_second", "typed_used"],
            )
            self.assertEqual(
                [entry["key"] for entry in document["domainReservedKeys"]],
                ["typed_reserved"],
            )
            self.assertEqual(document["summary"]["domainReservedKeys"], 1)
            typed_domain = document["dynamicDomains"][0]
            self.assertEqual(
                [entry["key"] for entry in typed_domain["declaredKeys"]],
                [
                    "typed_dynamic_first",
                    "typed_dynamic_second",
                    "typed_reserved",
                    "typed_used",
                ],
            )

    def test_typed_dynamic_call_requires_an_explicit_bounded_case_list(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Typed.swift"
            source.write_text(
                '''
                enum TypedKey: String {
                    case first = "typed_first"

                    var developmentFallback: String {
                        switch self {
                        case .first: return "First"
                        }
                    }
                }

                func render(dynamicKey: TypedKey) {
                    _ = TypedLocalization.text(dynamicKey)
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "typedDomains": [{
                    "api": "text",
                    "casePolicy": "conservative",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "TypedLocalization.text",
                        "paths": ["xabber/*.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "unbounded typed localization call",
            ):
                manifest.build_manifest(root, config)

    def test_typed_facade_declaration_must_match_even_with_declared_domain_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                '''
                enum TypedKey: String {
                    case greeting = "hello"

                    var developmentFallback: String {
                        switch self {
                        case .greeting: return "Hello"
                        }
                    }
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "declaredKeys": [{
                    "anchor": "case greeting",
                    "domain": "typed",
                    "fallback": "Hello",
                    "key": "hello",
                    "path": "xabber/Typed.swift",
                }],
                "typedDomains": [{
                    "api": "text",
                    "casePolicy": "conservative",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "TypedLocalization.text",
                        "paths": ["xabber/Missing.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "facade 0 matched no localization calls",
            ):
                manifest.build_manifest(root, config)

    def test_typed_facade_literal_callsite_records_actual_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            catalog_path = root / "xabber/translations/Localizable.xcstrings"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog["strings"]["typed_greeting"] = {
                "extractionState": "manual",
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "translated",
                            "value": "%@ has %lld items",
                        }
                    }
                },
            }
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                '''
                enum TypedKey: String {
                    case greeting = "typed_greeting"

                    var developmentFallback: String {
                        switch self {
                        case .greeting: return "%@ has %lld items"
                        }
                    }
                }

                func render(name: String, count: Int) {
                    _ = TypedLocalization.text(
                        .greeting,
                        arguments: [name, count]
                    )
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "typedDomains": [{
                    "api": "format",
                    "casePolicy": "allCasesRequired",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "TypedLocalization.text",
                        "paths": ["xabber/*.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            document = manifest.build_manifest(root, config)
            greeting = next(
                item for item in document["activeKeys"]
                if item["key"] == "typed_greeting"
            )
            actual = next(
                call for call in greeting["callsites"]
                if call["origin"] == "typedCallsite"
            )

            self.assertEqual(actual["argumentCount"], 2)
            self.assertEqual(actual["formatSignature"], greeting["formatSignature"])
            self.assertEqual(actual["typeSafety"], "typed")

    def test_typed_facade_literal_callsite_wrong_arity_fails_catalog_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            catalog_path = root / "xabber/translations/Localizable.xcstrings"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog["strings"]["typed_greeting"] = {
                "extractionState": "manual",
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "translated",
                            "value": "%@ has %lld items",
                        }
                    }
                },
            }
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                '''
                enum TypedKey: String {
                    case greeting = "typed_greeting"

                    var developmentFallback: String {
                        switch self {
                        case .greeting: return "%@ has %lld items"
                        }
                    }
                }

                func render(name: String) {
                    _ = text(.greeting, arguments: [name])
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "typedDomains": [{
                    "api": "format",
                    "casePolicy": "allCasesRequired",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "text",
                        "paths": ["xabber/Typed.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            document = manifest.build_manifest(root, config)
            strings = catalog_tool.load_catalog(catalog_path)["strings"]

            with self.assertRaisesRegex(
                catalog_tool.CatalogError,
                "Callsite argument count mismatch",
            ):
                catalog_tool.validate_manifest_catalog_parity(strings, document)

    def test_typed_facade_scans_multiline_parenthesized_and_interpolated_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            catalog_path = root / "xabber/translations/Localizable.xcstrings"
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            catalog["strings"]["typed_greeting"] = {
                "extractionState": "manual",
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "translated",
                            "value": "%@ has %lld items",
                        }
                    }
                },
            }
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            source = root / "xabber/Typed.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                r'''
                enum TypedKey: String {
                    case greeting = "typed_greeting"

                    var developmentFallback: String {
                        switch self {
                        case .greeting: return "%@ has %lld items"
                        }
                    }
                }

                func render(name: String, count: Int) {
                    _ = TypedLocalization
                        .text(
                            (.greeting),
                            arguments: [Result<String, Int>.success(name), count,]
                        )
                    _ = "\(TypedLocalization.text(.greeting, arguments: [name, count]))"
                }
                ''',
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "typedDomains": [{
                    "api": "format",
                    "casePolicy": "allCasesRequired",
                    "enum": "TypedKey",
                    "facadeCalls": [{
                        "callee": "TypedLocalization.text",
                        "paths": ["xabber/*.swift"],
                    }],
                    "fallbackProperty": "developmentFallback",
                    "name": "typed",
                    "source": "xabber/Typed.swift",
                }],
            }

            document = manifest.build_manifest(root, config)
            greeting = next(
                item for item in document["activeKeys"]
                if item["key"] == "typed_greeting"
            )
            actual = [
                call for call in greeting["callsites"]
                if call["origin"] == "typedCallsite"
            ]

            self.assertEqual(len(actual), 2)
            self.assertEqual([call["argumentCount"] for call in actual], [2, 2])

    def test_repository_config_declares_seven_dynamic_domains(self):
        repository_root = TOOLS_ROOT.parent
        config = manifest.load_config(
            repository_root / "tools/localization_manifest_config.json"
        )
        names = {
            domain["name"]
            for group in ("boundedDynamicDomains", "typedDomains")
            for domain in config.get(group, [])
        }

        self.assertEqual(len(names), 7)

    def test_repository_config_excludes_known_non_target_swift_sources(self):
        repository_root = TOOLS_ROOT.parent
        config = manifest.load_config(
            repository_root / "tools/localization_manifest_config.json"
        )
        expected = {
            "xabber/controllers/ake/AuthenticationCodeInputViewController.swift",
            "xabber/controllers/alerts/DeleteAccountPresenter.swift",
            "xabber/controllers/chats/groupchats/join/GroupchatJoinViewController.swift",
            "xabber/controllers/chats/info_screens/footerInfoView/CloudDeleteInfoScreenView.swift",
        }

        self.assertTrue(expected <= set(config.get("excludedPaths", [])))
        document = manifest.build_manifest(repository_root, config)
        inventoried_paths = {
            candidate["path"] for candidate in document["hardcodedCandidates"]
        }
        self.assertTrue(expected.isdisjoint(inventoried_paths))


if __name__ == "__main__":
    unittest.main()
