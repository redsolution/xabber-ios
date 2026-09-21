import json
import subprocess
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

    def test_hardcoded_candidate_tokens_share_the_public_detection_contract(self):
        source = 'label.text = "Visible title"\n'
        source_without_comments = manifest.mask_swift_comments(source)

        tokens = manifest._hardcoded_candidate_tokens(
            source,
            source_without_comments,
            "xabber/Screen.swift",
        )
        public = manifest.scan_swift_source(
            source,
            "xabber/Screen.swift",
            {},
        )["hardcodedCandidates"]

        self.assertEqual(len(tokens), 1)
        self.assertEqual(
            set(tokens[0]),
            {"end", "line", "literal", "path", "sink", "start", "value"},
        )
        self.assertEqual(
            source[tokens[0]["start"] : tokens[0]["end"]],
            tokens[0]["literal"],
        )
        self.assertEqual(
            [
                {
                    key: token[key]
                    for key in ("line", "path", "sink", "value")
                }
                for token in tokens
            ],
            public,
        )

    def test_hardcoded_ui_audit_ignores_all_localization_call_arguments(self):
        source = r'''
        label.text = "Fallback".localizeString(
            id: "localized_key",
            arguments: []
        )
        label.text = L10n.text("text_key", fallback: "Text fallback")
        label.text = L10n.format(
            "format_key",
            fallback: "%@ selected",
            arguments: ["argument literal"]
        )
        label.text = L10n.plural(
            "plural_key",
            count: 2,
            fallback: "%d items",
            arguments: ["argument literal"]
        )
        label.attributedText = L10n.attributedMarkdown(
            "markdown_key",
            fallback: "**Important**",
            arguments: ["argument literal"]
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(result["hardcodedCandidates"], [])

    def test_scanner_registers_explicit_localizing_instance_calls(self):
        source = r'''
        final class Screen {
            private let service: any Localizing

            init(service: any Localizing) {
                self.service = service
            }

            func render(name: String, count: Int, localizer: Localizing) {
                label.text = localizer.text(
                    key: "instance_text",
                    fallback: "Unlimited"
                )
                countLabel.text = localizer.plural(
                    key: "instance_plural",
                    count: count,
                    fallback: "%lld minutes"
                )
                greetingLabel.text = service.format(
                    key: "instance_format",
                    fallback: "Hello %@",
                    arguments: [name]
                )
                detailLabel.attributedText = service.attributedMarkdown(
                    key: "instance_markdown",
                    fallback: "**Important**",
                    arguments: []
                )
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})
        calls = {call["key"]: call for call in result["calls"]}

        self.assertEqual(
            {key: call["api"] for key, call in calls.items()},
            {
                "instance_format": "format",
                "instance_markdown": "attributedMarkdown",
                "instance_plural": "plural",
                "instance_text": "text",
            },
        )
        self.assertEqual(calls["instance_format"]["argumentCount"], 1)
        self.assertEqual(calls["instance_markdown"]["argumentCount"], 0)
        self.assertTrue(calls["instance_plural"]["pluralCountArgument"])
        self.assertEqual(result["hardcodedCandidates"], [])

    def test_scanner_does_not_treat_untyped_text_receiver_as_localizer(self):
        source = r'''
        func render(presenter: Presenter) {
            label.text = presenter.text(
                key: "not_a_localization_key",
                fallback: "Visible fallback"
            )
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(result["calls"], [])
        self.assertEqual(
            {candidate["value"] for candidate in result["hardcodedCandidates"]},
            {"Visible fallback", "not_a_localization_key"},
        )

    def test_hardcoded_ui_audit_ignores_locale_neutral_dynamic_only_strings(self):
        source = r'''
        label.text = "\(count)"
        content.body = "\(sender)\n\(body)"
        section.subtitle = "\(unread) \(mentions)"
        counter.text = "0"
        summary.text = "\(count) selected"
        footer.text = "\(online) of \(total) online"
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("text", "%@ of %@ online"),
                ("text", "%@ selected"),
            },
        )

    def test_hardcoded_ui_audit_detects_interpolated_and_conditional_sinks(self):
        source = r'''
        content.body = "New \(action)"
        label.text = "\(count) selected"
        button.accessibilityLabel = isGroup
            ? "Online groups filter"
            : "Online contacts filter"
        cell.accessibilityValue = selected ? "Selected" : "Not selected"
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("accessibilityLabel", "Online contacts filter"),
                ("accessibilityLabel", "Online groups filter"),
                ("accessibilityValue", "Not selected"),
                ("accessibilityValue", "Selected"),
                ("body", "New %@"),
                ("text", "%@ selected"),
            },
        )

    def test_hardcoded_ui_audit_detects_extended_uikit_and_voiceover_sinks(self):
        source = r'''
        configuration.secondaryText = "Verification is pending"
        navigationItem.prompt = "Choose an account"
        let action = UIAction(
            title: "Contacts",
            discoverabilityTitle: "Show all contacts"
        ) { _ in }
        let empty = EmptyState(
            buttonTitle: "Try again",
            footerLabel: "Check your connection"
        )
        let customAction = UIAccessibilityCustomAction(
            name: "Go to message",
            target: self,
            selector: #selector(openMessage)
        )
        let segmented = UISegmentedControl(items: ["Chats", "Contacts"])
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})
        actual = {
            (candidate["sink"], candidate["value"])
            for candidate in result["hardcodedCandidates"]
        }

        self.assertTrue(
            {
                ("buttonTitle", "Try again"),
                ("discoverabilityTitle", "Show all contacts"),
                ("footerLabel", "Check your connection"),
                ("prompt", "Choose an account"),
                ("secondaryText", "Verification is pending"),
                ("uiAccessibilityCustomAction", "Go to message"),
                ("uiSegmentedControlItem", "Chats"),
                ("uiSegmentedControlItem", "Contacts"),
            }
            <= actual
        )

    def test_hardcoded_ui_audit_detects_custom_presenters_and_ui_producers(self):
        source = r'''
        func render() {
            showError("Incorrect passcode. Try again.")
            presentChatAttachmentError("Unable to open attachment picker.")
            buildSectionHeader("SUBSCRIPTION PERIOD")
            makeSystemMessage(jid: jid, body: "Verification succeeded")

            let secondaryText: String?
            secondaryText = "Verification failed."
            let controlAccessibilityLabel = "Play voice message"
            let titleText = "Incoming Device Verification Request"
        }

        func tableView(
            _ tableView: UITableView,
            titleForHeaderInSection section: Int
        ) -> String? {
            return "Selected files"
        }

        enum SaveError: LocalizedError {
            var errorDescription: String? {
                return "Could not upload the wallpaper."
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})
        actual = {
            (candidate["sink"], candidate["value"])
            for candidate in result["hardcodedCandidates"]
        }

        self.assertTrue(
            {
                ("body", "Verification succeeded"),
                ("controlAccessibilityLabel", "Play voice message"),
                ("localizedErrorDescription", "Could not upload the wallpaper."),
                ("presentationCall", "Incorrect passcode. Try again."),
                ("presentationCall", "SUBSCRIPTION PERIOD"),
                ("presentationCall", "Unable to open attachment picker."),
                ("secondaryText", "Verification failed."),
                ("tableSectionTitle", "Selected files"),
                ("titleText", "Incoming Device Verification Request"),
            }
            <= actual
        )

    def test_hardcoded_ui_audit_detects_indirect_uikit_and_status_producers(self):
        source = r'''
        final class Screen: UIViewController {
            enum Section {
                var title: String? {
                    switch self {
                    case .sounds: return "Notification Sounds"
                    }
                }

                var footer: String? {
                    return "Configure notification sounds."
                }
            }

            func configure() {
                title = "Notifications"
                let message = "Search results have changed."
                let reason = "Unlock application with biometrics"
                context.localizedCancelTitle = "Use only passcode"
                context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Confirm your identity"
                ) { _, _ in }
                let items = ["Never", "10 min"]
                statusMessage.accept("Offline")
                statusMessage.accept(serverText ?? "Unknown status")
                changeNewUserState(for: jid, to: .failure("Server not found"))
                return state("Unavailable")
            }

            static func titleText(for name: String) -> String {
                return "Information from \(name)"
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})
        actual = {
            (candidate["sink"], candidate["value"])
            for candidate in result["hardcodedCandidates"]
        }

        self.assertTrue(
            {
                ("footer", "Configure notification sounds."),
                ("localizedCancelTitle", "Use only passcode"),
                ("localizedReason", "Confirm your identity"),
                ("message", "Search results have changed."),
                ("presentationCall", "Unavailable"),
                ("reason", "Unlock application with biometrics"),
                ("statusMessage", "Offline"),
                ("statusMessage", "Unknown status"),
                ("title", "Notifications"),
                ("title", "Notification Sounds"),
                ("titleText", "Information from %@"),
                ("uiActionItem", "10 min"),
                ("uiActionItem", "Never"),
                ("userVisibleFailure", "Server not found"),
            }
            <= actual
        )

    def test_hardcoded_ui_audit_detects_bare_accessibility_and_cancel_sinks(self):
        source = r'''
        final class Footer: UIView {
            func configure() {
                accessibilityLabel = "Loading more files"
                accessibilityHint = "Double-tap to retry"
                accessibilityValue = "Loading"
                presenter.present(
                    title: "Delete files",
                    cancel: "Cancel"
                )
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Footer.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("accessibilityHint", "Double-tap to retry"),
                ("accessibilityLabel", "Loading more files"),
                ("accessibilityValue", "Loading"),
                ("cancel", "Cancel"),
                ("title", "Delete files"),
            },
        )

    def test_hardcoded_ui_audit_detects_nested_button_and_accessibility_copy(self):
        source = r'''
        button.setTitle(isEnabled ? "Enabled" : "Disabled", for: .normal)
        button.setTitle(
            String(format: "Delete %@", filename),
            for: .normal
        )
        UIAccessibility.post(
            notification: .announcement,
            argument: "Changes saved"
        )
        navigationItem.backButtonTitle = "Account"
        backButtonTitle = "Settings"
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("accessibilityAnnouncement", "Changes saved"),
                ("backButtonTitle", "Account"),
                ("backButtonTitle", "Settings"),
                ("setTitle", "Delete %@"),
                ("setTitle", "Disabled"),
                ("setTitle", "Enabled"),
            },
        )

    def test_hardcoded_ui_audit_detects_conditional_and_action_arguments(self):
        source = r'''
        let row = Datasource(
            subtitle: target.contains("@") ? "XMPP ID" : "Domain"
        )
        let state = SubscriptionState(
            warningMessage: "Showing cached products.",
            errorMessage: "Subscriptions are unavailable."
        )
        presenter.present(
            primaryActionTitle: "Continue",
            secondaryActionTitle: "Not now",
            destructiveActionTitle: "Delete"
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("destructiveActionTitle", "Delete"),
                ("errorMessage", "Subscriptions are unavailable."),
                ("primaryActionTitle", "Continue"),
                ("secondaryActionTitle", "Not now"),
                ("subtitle", "Domain"),
                ("subtitle", "XMPP ID"),
                ("warningMessage", "Showing cached products."),
            },
        )

    def test_hardcoded_ui_audit_detects_semantic_string_producers(self):
        source = r'''
        final class Screen {
            private static let genericAuthenticationFailureMessage =
                "Authentication failed"

            func render() {
                var descriptionText = "Secure connection details"
                let stepsText = "Confirm the verification code"
                let aboutText = "About Premium"
                let durationText = "Queued · 01:00"
                inviteErrorMessage = "You cannot invite this contact"
                currentPlayingSubtitle = "Voice message"
            }

            func emptyStateTitle() -> String {
                return "No contacts found"
            }

            func buildPeriodSubtitle() -> String {
                return "Billed yearly"
            }

            var secondaryDescription: String {
                return "This action deletes the account."
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("buildPeriodSubtitle", "Billed yearly"),
                ("aboutText", "About Premium"),
                ("currentPlayingSubtitle", "Voice message"),
                ("descriptionText", "Secure connection details"),
                ("durationText", "Queued · 01:00"),
                ("emptyStateTitle", "No contacts found"),
                (
                    "genericAuthenticationFailureMessage",
                    "Authentication failed",
                ),
                ("inviteErrorMessage", "You cannot invite this contact"),
                ("secondaryDescription", "This action deletes the account."),
                ("stepsText", "Confirm the verification code"),
            },
        )

    def test_hardcoded_ui_audit_detects_display_names_and_row_values(self):
        source = r'''
        enum AppearanceStyle {
            var displayName: String {
                switch self {
                case .system: return "System"
                case .light: return "Light"
                }
            }
        }

        private func value(for row: Row) -> String? {
            switch row {
            case .wallpaper: return "None"
            case .gradient: return "Custom Gradient"
            case .cloud: return "Photo"
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Appearance.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("displayName", "Light"),
                ("displayName", "System"),
                ("rowValue", "Custom Gradient"),
                ("rowValue", "None"),
                ("rowValue", "Photo"),
            },
        )

    def test_hardcoded_ui_audit_detects_semantic_tuple_and_datasource_fields(self):
        source = r'''
        private static let features: [(
            icon: String,
            color: UIColor,
            title: String,
            desc: String
        )] = [
            (
                "archivebox.fill",
                .systemBlue,
                "Message Archive",
                "Complete message history stored securely."
            )
        ]

        let section = Datasource(
            .session,
            name: "Secure Your Conversation",
            value: "Several devices need verification.",
            key: "verification_section"
        )
        let action = Datasource(
            .button,
            name: "Revoke trust",
            value: "revoke_trust",
            key: "revoke_trust"
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("datasourceName", "Revoke trust"),
                ("datasourceName", "Secure Your Conversation"),
                ("datasourceValue", "Several devices need verification."),
                ("description", "Complete message history stored securely."),
                ("title", "Message Archive"),
            },
        )

    def test_hardcoded_ui_audit_detects_named_string_collections(self):
        source = r'''
        final class ChangePasswordScreen {
            let sections: [String] = [
                "Old password",
                "New password"
            ]
            let placeholders: [String] = [
                "old password",
                "new password",
                "repeat new password"
            ]
        }

        let protocolValues = ["chat", "group"]
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("placeholder", "new password"),
                ("placeholder", "old password"),
                ("placeholder", "repeat new password"),
                ("sectionTitle", "New password"),
                ("sectionTitle", "Old password"),
            },
        )

    def test_hardcoded_ui_audit_detects_visible_named_arguments(self):
        source = r'''
        cell.configure(senderName: "Audio message")
        let file = Datasource(fileName: "File")
        let sender = Sender(displayName: "Me")
        coordinator.failed(error: "Audio file is unavailable")
        asset.setup(filename: "Default document")
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("displayName", "Me"),
                ("error", "Audio file is unavailable"),
                ("fileName", "File"),
                ("filename", "Default document"),
                ("senderName", "Audio message"),
            },
        )

    def test_hardcoded_ui_audit_detects_bounded_custom_cell_configure_copy(self):
        source = r'''
        cell.configure(
            "name@example.com or example.com",
            value: enteredTarget,
            key: "target"
        )
        cell.configure("Add new circle", value: nil, key: "new_group")
        cell.configure(with: "No circles", color: .systemGray)
        cell.configure(
            key: "enabled",
            for: "Share device info",
            active: false
        )

        // These strings are identifiers or model values rather than copy.
        cell.configure("resource", value: "desktop")
        object.configure(with: "xmpp-token", mode: .wire)
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("cellText", "No circles"),
                ("placeholder", "Add new circle"),
                ("placeholder", "name@example.com or example.com"),
                ("title", "Share device info"),
            },
        )

    def test_hardcoded_ui_audit_detects_accessibility_label_builders(self):
        source = r'''
        private func updateAccessibilityLabel(isOnline: Bool, current: Bool) {
            var parts: [String] = ["Device session"]
            parts.append(isOnline ? "Online" : "Offline")
            if current {
                parts.append("This device")
            }
            accessibilityIdentifier = "device.row.current"
            accessibilityLabel = parts.joined(separator: ", ")
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Cell.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("accessibilityLabel", "Device session"),
                ("accessibilityLabel", "Offline"),
                ("accessibilityLabel", "Online"),
                ("accessibilityLabel", "This device"),
            },
        )

    def test_hardcoded_ui_audit_ignores_indented_legacy_localization_receiver(self):
        source = '''
        let row = Datasource(
            filename: item.name ?? "File"
                                            .localizeString(
                                                id: "chat_message_file",
                                                arguments: []
                                            )
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(result["hardcodedCandidates"], [])

    def test_hardcoded_ui_audit_finds_long_table_delegate_return(self):
        padding = "\n".join(
            f"        if section == {index} {{ _ = section }}"
            for index in range(120)
        )
        source = f'''
        func tableView(
            _ tableView: UITableView,
            titleForFooterInSection section: Int
        ) -> String? {{
        {padding}
            return "Contact presence details"
        }}
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            ],
            [("tableSectionTitle", "Contact presence details")],
        )

    def test_hardcoded_ui_audit_finds_conditional_semantic_return(self):
        source = r'''
        private static func durationTitle(_ values: [String]) -> String {
            return values.isEmpty ? "Forever" : values.joined(separator: " ")
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            ],
            [("durationTitle", "Forever")],
        )

    def test_hardcoded_ui_audit_detects_visible_nickname_producer_copy(self):
        source = r'''
        final var groupchatDisplayedNickname: String? {
            if let nick = groupchatAuthorNickname {
                return outgoing ? "You:" : nick
            }
            return nil
        }

        // A badge can expose a persisted role through capitalization, but the
        // scanner must not mistake the protocol comparison token for UI copy.
        final var groupchatAuthorBadge: String? {
            if role?.lowercased() == "member" {
                return badge
            }
            return badge ?? role?.capitalized
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Message.swift", {})

        self.assertEqual(
            [
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            ],
            [("groupchatDisplayedNickname", "You:")],
        )

    def test_hardcoded_ui_audit_ignores_debug_description_properties(self):
        source = r'''
        struct Trace: CustomStringConvertible {
            var description: String {
                return "offset=%@"
            }
        }

        final class Model: NSObject {
            override var description: String {
                return "Model debug description"
            }
        }

        enum SettingsItem {
            func description() -> String {
                return "Visible settings row"
            }
        }
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            ],
            [("description", "Visible settings row")],
        )

    def test_hardcoded_ui_audit_covers_repository_uikit_literal_shapes(self):
        source = r'''
        acknowledgementLabel.text = "I agree to the terms"
        declineMessageLabel.text = "You must accept the agreement"
        titleLabel.text = "Hi! Connect to your existing account"
        connectButton.title = isReady ? "Let's rock!" : "Proceed anyway"
        self.tabBar.items?[0].title = "Chats"
        messageLabel.text = "Point the camera at a QR code"
        let feedback = ChatAttachmentStatusFeedback(
            message: account.isConnecting
                ? "Cloud Storage is still connecting."
                : "Cloud Storage is unavailable."
        )
        senderNameButton.setTitle(
            "Sent by \(sender)",
            for: .normal
        )
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            {
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            },
            {
                ("message", "Cloud Storage is still connecting."),
                ("message", "Cloud Storage is unavailable."),
                ("setTitle", "Sent by %@"),
                ("text", "Hi! Connect to your existing account"),
                ("text", "I agree to the terms"),
                ("text", "Point the camera at a QR code"),
                ("text", "You must accept the agreement"),
                ("title", "Chats"),
                ("title", "Let's rock!"),
                ("title", "Proceed anyway"),
            },
        )

    def test_hardcoded_assignment_does_not_capture_following_method_calls(self):
        source = r'''
        accessibilityLabel = "Preview"
        button.setImage(UIImage(systemName: "chevron.backward"), for: .normal)

        let body = content?.element(forName: "body")?.stringValue
        message.element(forName: "message")?.addBody(body ?? "Failed to decrypt")
        '''

        result = manifest.scan_swift_source(source, "xabber/Screen.swift", {})

        self.assertEqual(
            [
                (candidate["sink"], candidate["value"])
                for candidate in result["hardcodedCandidates"]
            ],
            [("accessibilityLabel", "Preview")],
        )

    def test_localized_static_let_initializers_are_rejected_as_frozen_language(self):
        source = r'''
        private static let fixtures: [String] = [
            L10n.text("preview", fallback: "Preview")
        ]
        static let direct = L10n.text("direct", fallback: "Direct")
        static var computed: [String] { [L10n.text("live", fallback: "Live")] }
        static let stableIdentifier = "settings.language.en"
        '''

        self.assertEqual(
            manifest._frozen_localization_declarations(source),
            [
                {"line": 2, "name": "fixtures"},
                {"line": 5, "name": "direct"},
            ],
        )

    def test_migrated_repository_attributed_strings_are_not_hardcoded_candidates(self):
        repository_root = TOOLS_ROOT.parent
        fixtures = {
            "xabber/controllers/credentials/CredentialsExpiredViewController.swift": {
                "keys": {"credentials_expired__content__password"},
                "values": {"Password"},
            },
            "xabber/controllers/notifications/NotificationsListViewController.swift": {
                "keys": {
                    "notifications__category__security",
                    "notifications__category__security_description",
                },
                "values": {
                    "Notifications about new logins, device changes, and activity on your account.",
                    "Security",
                },
            },
            "xabber/controllers/split/BaseRootViewController.swift": {
                "keys": {"navigation__destination__chats"},
                "values": {"Chats"},
            },
            "xabber/controllers/chats/chat/messages_kit/Views/Cells/old/SystemMessageCell.swift": {
                "keys": {"chat_message_incoming", "chat_message_missed_call"},
                "values": {"Incoming call", "Missed call"},
            },
        }

        for relative_path, expected in fixtures.items():
            source = (repository_root / relative_path).read_text(encoding="utf-8")
            result = manifest.scan_swift_source(source, relative_path, {})
            hardcoded_values = {
                candidate["value"] for candidate in result["hardcodedCandidates"]
            }
            localization_keys = {call["key"] for call in result["calls"]}
            with self.subTest(path=relative_path):
                self.assertTrue(expected["values"].isdisjoint(hardcoded_values))
                self.assertTrue(expected["keys"] <= localization_keys)

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
            "nonTargetSources": [],
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
                "nonTargetSources": 0,
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

    def _write_project(
        self,
        root: Path,
        *,
        app_sources: tuple[str, ...] = (),
        push_sources: tuple[str, ...] = (),
    ) -> None:
        project = root / "xabber.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True, exist_ok=True)
        paths = sorted(set(app_sources) | set(push_sources))
        references = {
            path: f"{index + 1:024X}"
            for index, path in enumerate(paths)
        }
        app_builds = {
            path: f"{index + 1001:024X}"
            for index, path in enumerate(app_sources)
        }
        push_builds = {
            path: f"{index + 2001:024X}"
            for index, path in enumerate(push_sources)
        }

        def build_section(builds: dict[str, str]) -> str:
            return "\n".join(
                f"\t\t{build_id} /* {Path(path).name} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {references[path]} "
                f"/* {Path(path).name} */; }};"
                for path, build_id in builds.items()
            )

        def phase_files(builds: dict[str, str]) -> str:
            return "\n".join(
                f"\t\t\t\t{build_id} /* {Path(path).name} in Sources */,"
                for path, build_id in builds.items()
            )

        file_references = "\n".join(
            f"\t\t{reference} /* {Path(path).name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f'path = "{path}"; sourceTree = SOURCE_ROOT; }};'
            for path, reference in references.items()
        )
        project.write_text(
            f'''// !$*UTF8*$!
{{
objects = {{
/* Begin PBXBuildFile section */
{build_section(app_builds)}
{build_section(push_builds)}
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
{file_references}
/* End PBXFileReference section */
/* Begin PBXNativeTarget section */
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* xabber */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (CCCCCCCCCCCCCCCCCCCCCCCC /* Sources */,);
\t\t\tname = xabber;
\t\t}};
\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* xabber-push-extension */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (DDDDDDDDDDDDDDDDDDDDDDDD /* Sources */,);
\t\t\tname = "xabber-push-extension";
\t\t}};
/* End PBXNativeTarget section */
/* Begin PBXSourcesBuildPhase section */
\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tfiles = (
{phase_files(app_builds)}
\t\t\t);
\t\t}};
\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tfiles = (
{phase_files(push_builds)}
\t\t\t);
\t\t}};
/* End PBXSourcesBuildPhase section */
}};
}}
''',
            encoding="utf-8",
        )

    def _write_plist(self, path: Path, document) -> None:
        def escape(value: str) -> str:
            return (
                value.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
            )

        def encode(value) -> str:
            if isinstance(value, dict):
                children = "".join(
                    f"<key>{escape(key)}</key>{encode(child)}"
                    for key, child in sorted(value.items())
                )
                return f"<dict>{children}</dict>"
            if isinstance(value, list):
                return "<array>" + "".join(map(encode, value)) + "</array>"
            if isinstance(value, str):
                return f"<string>{escape(value)}</string>"
            raise TypeError(f"Unsupported plist fixture value: {value!r}")

        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
            f'<plist version="1.0">{encode(document)}</plist>',
            encoding="utf-8",
        )

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
            info_template = root / "xabber/Info.plist.example"
            info_document = {
                "InternalSetting": "Not visible",
                "NSCameraUsageDescription": "Use the camera",
            }
            self._write_plist(info_template, info_document)
            self._write_plist(root / "xabber/Info.plist", info_document)
            config = {
                "sourceRoots": ["xabber", "xabber-push-extension"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "excludedPaths": ["xabber/Ignored.swift"],
                "infoPlistTemplates": ["xabber/Info.plist.example"],
                "manifest": "docs/localization/active-keys.json",
            }

            first = manifest.build_manifest(root, config)
            second = manifest.build_manifest(root, config)

            self.assertEqual(manifest.render_manifest(first), manifest.render_manifest(second))
            self.assertEqual(first["schemaVersion"], 1)
            self.assertEqual(first["summary"]["activeKeys"], 1)
            self.assertEqual(first["interfaceBuilder"][0]["value"], "Welcome")
            self.assertEqual(first["infoPlist"][0]["key"], "NSCameraUsageDescription")
            self.assertEqual(
                first["infoPlist"][0]["path"],
                "xabber/Info.plist.example",
            )
            classifications = {
                item["key"]: item["classification"] for item in first["catalogOnly"]
            }
            self.assertEqual(classifications["catalog_only"], "reviewCandidate")
            self.assertEqual(
                classifications["plurals.old.item_0"], "retainedLegacyPlural"
            )

    def test_info_plist_inventory_uses_exact_templates_and_visible_keys_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            usage_descriptions = {
                "NFCReaderUsageDescription": "Use NFC",
                "NSCameraUsageDescription": "Use Camera",
                "NSFaceIDUsageDescription": "Use Face ID",
                "NSLocalNetworkUsageDescription": "Use Local Network",
                "NSLocationWhenInUseUsageDescription": "Use Location",
                "NSMicrophoneUsageDescription": "Use Microphone",
                "NSPhotoLibraryAddUsageDescription": "Add Photos",
                "NSPhotoLibraryUsageDescription": "Use Photos",
            }
            template = root / "xabber/Info.plist.example"
            self._write_plist(
                template,
                {
                    "CFBundleDisplayName": "Xabber",
                    "CFBundleName": "Xabber",
                    "InternalSetting": "Not visible",
                    **usage_descriptions,
                },
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "infoPlistTemplates": ["xabber/Info.plist.example"],
            }

            document = manifest.build_manifest(root, config)

            self.assertEqual(document["summary"]["infoPlistStrings"], 10)
            self.assertEqual(
                {entry["key"] for entry in document["infoPlist"]},
                {
                    "CFBundleDisplayName",
                    "CFBundleName",
                    *usage_descriptions,
                },
            )
            self.assertEqual(
                {entry["path"] for entry in document["infoPlist"]},
                {"xabber/Info.plist.example"},
            )

    def test_info_plist_template_config_and_document_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "infoPlistTemplates": "xabber/Info.plist.example",
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "infoPlistTemplates must be an array",
            ):
                manifest.build_manifest(root, config)

            config["infoPlistTemplates"] = ["xabber/*.plist.example"]
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "exact repository-relative path",
            ):
                manifest.build_manifest(root, config)

            config["infoPlistTemplates"] = ["xabber/Missing.plist.example"]
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "existing file",
            ):
                manifest.build_manifest(root, config)

            template = root / "xabber/Info.plist.example"
            self._write_plist(template, ["not", "a", "dictionary"])
            config["infoPlistTemplates"] = ["xabber/Info.plist.example"]
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "top-level dictionary",
            ):
                manifest.build_manifest(root, config)

            template.write_text("not a plist", encoding="utf-8")
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "could not be parsed",
            ):
                manifest.build_manifest(root, config)

    def test_info_plist_template_must_be_git_tracked_in_a_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            template = root / "xabber/Info.plist.example"
            self._write_plist(
                template,
                {"NSCameraUsageDescription": "Use the camera"},
            )
            subprocess.run(
                ["git", "init", "--quiet", str(root)],
                check=True,
                capture_output=True,
                text=True,
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "infoPlistTemplates": ["xabber/Info.plist.example"],
            }

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "git-tracked template",
            ):
                manifest.build_manifest(root, config)

            subprocess.run(
                ["git", "-C", str(root), "add", "xabber/Info.plist.example"],
                check=True,
                capture_output=True,
                text=True,
            )
            document = manifest.build_manifest(root, config)
            self.assertEqual(document["summary"]["infoPlistStrings"], 1)

    def test_info_plist_assembled_copy_must_match_template_visible_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            template = root / "xabber/Info.plist.example"
            assembled = root / "xabber/Info.plist"
            template_document = {
                "CFBundleDisplayName": "Xabber",
                "InternalSetting": "template-only internal value",
                "NSCameraUsageDescription": "Use the camera",
            }
            self._write_plist(template, template_document)
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "infoPlistTemplates": ["xabber/Info.plist.example"],
            }

            self._write_plist(
                assembled,
                {"CFBundleDisplayName": "Xabber"},
            )
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "missing visible key NSCameraUsageDescription",
            ):
                manifest.build_manifest(root, config)

            self._write_plist(
                assembled,
                {
                    "CFBundleDisplayName": "Xabber",
                    "NSCameraUsageDescription": "Different camera copy",
                },
            )
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "does not match template",
            ):
                manifest.build_manifest(root, config)

            self._write_plist(
                assembled,
                {
                    "CFBundleDisplayName": "Xabber",
                    "InternalSetting": "different internal value is allowed",
                    "NSCameraUsageDescription": "Use the camera",
                },
            )
            document = manifest.build_manifest(root, config)
            self.assertEqual(
                [entry["path"] for entry in document["infoPlist"]],
                ["xabber/Info.plist.example", "xabber/Info.plist.example"],
            )

    def test_hardcoded_ui_exclusions_are_exact_reasoned_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Diagnostic fixture"\n', encoding="utf-8")
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "hardcodedUIExclusions": [{
                    "line": 1,
                    "path": "xabber/Screen.swift",
                    "reason": (
                        "This label belongs to a non-production diagnostic fixture."
                    ),
                    "sink": "text",
                    "value": "Diagnostic fixture",
                }],
            }

            document = manifest.build_manifest(root, config)
            self.assertEqual(document["hardcodedCandidates"], [])

            config["hardcodedUIExclusions"][0]["value"] = "Stale value"
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "hardcoded UI exclusion",
            ):
                manifest.build_manifest(root, config)

    def test_hardcoded_ui_exclusion_files_are_reasoned_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Diagnostic fixture"\n', encoding="utf-8")
            mapping = root / "tools/localization_migrations/diagnostics.json"
            mapping.parent.mkdir(parents=True, exist_ok=True)
            mapping.write_text(
                json.dumps({
                    "exclusions": [{
                        "path": "xabber/Screen.swift",
                        "reason": "The text belongs to a diagnostic-only fixture.",
                        "sink": "text",
                        "value": "Diagnostic fixture",
                    }],
                    "migrations": [],
                }),
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "hardcodedUIExclusionFiles": [
                    "tools/localization_migrations/diagnostics.json"
                ],
            }

            document = manifest.build_manifest(root, config)
            self.assertEqual(document["hardcodedCandidates"], [])

            mapping.write_text(
                json.dumps({
                    "exclusions": [{
                        "path": "xabber/Screen.swift",
                        "reason": "The text belongs to a diagnostic-only fixture.",
                        "sink": "text",
                        "value": "Stale fixture",
                    }],
                    "migrations": [],
                }),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "Stale hardcoded UI exclusion",
            ):
                manifest.build_manifest(root, config)

    def test_hardcoded_ui_exclusion_files_reject_invalid_paths_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Diagnostic fixture"\n', encoding="utf-8")
            first = root / "tools/localization_migrations/first.json"
            second = root / "tools/localization_migrations/second.json"
            first.parent.mkdir(parents=True, exist_ok=True)
            exclusion = {
                "path": "xabber/Screen.swift",
                "reason": "The text belongs to a diagnostic-only fixture.",
                "sink": "text",
                "value": "Diagnostic fixture",
            }
            first.write_text(
                json.dumps({"exclusions": [exclusion], "migrations": []}),
                encoding="utf-8",
            )
            second.write_text(
                json.dumps({"exclusions": [exclusion], "migrations": []}),
                encoding="utf-8",
            )
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            invalid_values = (
                "tools/localization_migrations/*.json",
                "tools/localization_migrations/missing.json",
            )
            for value in invalid_values:
                with self.subTest(value=value):
                    config["hardcodedUIExclusionFiles"] = [value]
                    with self.assertRaisesRegex(
                        manifest.ManifestError,
                        "hardcoded UI exclusion file",
                    ):
                        manifest.build_manifest(root, config)

            config["hardcodedUIExclusionFiles"] = [
                "tools/localization_migrations/first.json",
                "tools/localization_migrations/first.json",
            ]
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "Duplicate hardcoded UI exclusion file",
            ):
                manifest.build_manifest(root, config)

            config["hardcodedUIExclusionFiles"] = [
                "tools/localization_migrations/first.json",
                "tools/localization_migrations/second.json",
            ]
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "Duplicate hardcoded UI exclusion",
            ):
                manifest.build_manifest(root, config)

            source.write_text(
                'label.text = "Diagnostic fixture"\n'
                'other.text = "Diagnostic fixture"\n',
                encoding="utf-8",
            )
            config["hardcodedUIExclusionFiles"] = [
                "tools/localization_migrations/first.json"
            ]
            document = manifest.build_manifest(root, config)
            self.assertEqual(document["hardcodedCandidates"], [])

    def test_hardcoded_ui_exclusion_files_validate_entry_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Diagnostic fixture"\n', encoding="utf-8")
            mapping = root / "tools/localization_migrations/diagnostics.json"
            mapping.parent.mkdir(parents=True, exist_ok=True)
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "hardcodedUIExclusionFiles": [
                    "tools/localization_migrations/diagnostics.json"
                ],
            }

            invalid_documents = (
                {"migrations": []},
                {"exclusions": ["not an object"], "migrations": []},
                {
                    "exclusions": [{
                        "path": "xabber/Screen.swift",
                        "reason": "",
                        "sink": "text",
                        "value": "Diagnostic fixture",
                    }],
                    "migrations": [],
                },
                {
                    "exclusions": [{
                        "extra": "unsupported",
                        "path": "xabber/Screen.swift",
                        "reason": "Diagnostic fixture only.",
                        "sink": "text",
                        "value": "Diagnostic fixture",
                    }],
                    "migrations": [],
                },
            )
            for document in invalid_documents:
                with self.subTest(document=document):
                    mapping.write_text(json.dumps(document), encoding="utf-8")
                    with self.assertRaisesRegex(
                        manifest.ManifestError,
                        "hardcoded UI exclusion file",
                    ):
                        manifest.build_manifest(root, config)

    def test_hardcoded_ui_excluded_paths_are_exact_existing_and_non_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/DebugFixture.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Diagnostic fixture"\n', encoding="utf-8")
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "hardcodedUIExcludedPaths": [{
                    "path": "xabber/DebugFixture.swift",
                    "reason": "The entire source is a debug-only presentation fixture.",
                }],
            }

            document = manifest.build_manifest(root, config)
            self.assertEqual(document["hardcodedCandidates"], [])

            config["hardcodedUIExcludedPaths"][0]["path"] = "xabber/*.swift"
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "hardcoded UI excluded path",
            ):
                manifest.build_manifest(root, config)

            config["hardcodedUIExcludedPaths"][0]["path"] = (
                "xabber/DebugFixture.swift"
            )
            source.write_text("let value = 1\n", encoding="utf-8")
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "excluded path has no candidates",
            ):
                manifest.build_manifest(root, config)

            config["hardcodedUIExcludedPaths"][0]["path"] = "xabber/Missing.swift"
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "hardcoded UI excluded path",
            ):
                manifest.build_manifest(root, config)

    def test_non_target_source_is_audited_but_cannot_add_active_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            active = root / "xabber/Screen.swift"
            ignored = root / "xabber/LegacyScreen.swift"
            active.parent.mkdir(parents=True, exist_ok=True)
            active.write_text(
                'label.text = L10n.text("hello", fallback: "Hello")\n',
                encoding="utf-8",
            )
            ignored.write_text(
                'label.text = "Legacy visible copy"\n'
                'label.text = L10n.text("legacy_only", fallback: "Legacy")\n',
                encoding="utf-8",
            )
            self._write_project(root)
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "nonTargetSources": [{
                    "path": "xabber/LegacyScreen.swift",
                    "reason": "Legacy source is not compiled by an application target.",
                }],
            }

            document = manifest.build_manifest(root, config)

            self.assertEqual(
                [entry["key"] for entry in document["activeKeys"]],
                ["hello"],
            )
            self.assertEqual(
                {
                    (candidate["path"], candidate["value"])
                    for candidate in document["hardcodedCandidates"]
                },
                {("xabber/LegacyScreen.swift", "Legacy visible copy")},
            )
            self.assertEqual(document["nonTargetSources"], config["nonTargetSources"])
            self.assertEqual(document["summary"]["nonTargetSources"], 1)

    def test_non_target_sources_are_exact_reasoned_existing_swift_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/LegacyScreen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Legacy"\n', encoding="utf-8")
            self._write_project(root)
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
            }

            invalid_entries = (
                "xabber/LegacyScreen.swift",
                {"path": "xabber/*.swift", "reason": "Wildcard"},
                {"path": "xabber/Missing.swift", "reason": "Missing"},
                {"path": "xabber/LegacyScreen.swift", "reason": ""},
            )
            for entry in invalid_entries:
                with self.subTest(entry=entry):
                    config["nonTargetSources"] = [entry]
                    with self.assertRaisesRegex(
                        manifest.ManifestError,
                        "non-target source",
                    ):
                        manifest.build_manifest(root, config)

    def test_non_target_source_fails_when_added_to_app_or_push_target(self):
        for target in ("app", "push"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._write_catalog(root)
                relative = "xabber/LegacyScreen.swift"
                source = root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text('label.text = "Legacy"\n', encoding="utf-8")
                self._write_project(
                    root,
                    app_sources=(relative,) if target == "app" else (),
                    push_sources=(relative,) if target == "push" else (),
                )
                config = {
                    "sourceRoots": ["xabber"],
                    "catalog": "xabber/translations/Localizable.xcstrings",
                    "nonTargetSources": [{
                        "path": relative,
                        "reason": "Legacy source is not compiled.",
                    }],
                }

                with self.assertRaisesRegex(
                    manifest.ManifestError,
                    "non-target source.*target membership",
                ):
                    manifest.build_manifest(root, config)

    def test_non_target_membership_uses_exact_paths_not_basenames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            legacy = root / "xabber/legacy/Screen.swift"
            active = root / "xabber/active/Screen.swift"
            legacy.parent.mkdir(parents=True, exist_ok=True)
            active.parent.mkdir(parents=True, exist_ok=True)
            legacy.write_text('label.text = "Legacy"\n', encoding="utf-8")
            active.write_text("let value = 1\n", encoding="utf-8")
            self._write_project(root, app_sources=("xabber/active/Screen.swift",))
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "nonTargetSources": [{
                    "path": "xabber/legacy/Screen.swift",
                    "reason": "A different same-named source is compiled.",
                }],
            }

            document = manifest.build_manifest(root, config)

            self.assertEqual(document["summary"]["nonTargetSources"], 1)

    def test_zero_unclassified_hardcoded_ui_gate_is_configurable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber/Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('label.text = "Visible title"\n', encoding="utf-8")
            config = {
                "sourceRoots": ["xabber"],
                "catalog": "xabber/translations/Localizable.xcstrings",
                "requireZeroUnclassifiedHardcodedUI": False,
            }

            document = manifest.build_manifest(root, config)
            self.assertEqual(document["summary"]["hardcodedCandidates"], 1)

            config["requireZeroUnclassifiedHardcodedUI"] = True
            with self.assertRaisesRegex(
                manifest.ManifestError,
                "unclassified hard-coded UI",
            ):
                manifest.build_manifest(root, config)

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

    def test_manifest_rejects_process_lifetime_localized_constants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_catalog(root)
            source = root / "xabber" / "Screen.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                'static let title = L10n.text("title", fallback: "Title")\n',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                manifest.ManifestError,
                "Localized static let freezes the process language",
            ):
                manifest.build_manifest(
                    root,
                    {
                        "catalog": "xabber/translations/Localizable.xcstrings",
                        "sourceRoots": ["xabber"],
                    },
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

    def test_repository_config_declares_known_non_target_swift_sources(self):
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

        configured = {
            entry["path"] for entry in config.get("nonTargetSources", [])
        }
        self.assertTrue(expected <= configured)
        self.assertNotIn("excludedPaths", config)
        audit_config = dict(config)
        audit_config["hardcodedUIExclusionFiles"] = []
        audit_config["hardcodedUIExclusions"] = []
        audit_config["requireZeroUnclassifiedHardcodedUI"] = False
        document = manifest.build_manifest(repository_root, audit_config)
        inventoried_paths = {
            candidate["path"] for candidate in document["hardcodedCandidates"]
        }
        # Non-target files remain visible to the UI-copy audit while their
        # localization calls cannot pollute the active key registry.
        self.assertIn(
            "xabber/xmpp/omemo/OmemoManagerTest.swift",
            inventoried_paths,
        )
        self.assertEqual(document["summary"]["nonTargetSources"], 8)

    def test_repository_config_loads_every_reviewed_ui_mapping_deterministically(self):
        repository_root = TOOLS_ROOT.parent
        config = manifest.load_config(
            repository_root / "tools/localization_manifest_config.json"
        )
        expected = sorted(
            path.relative_to(repository_root).as_posix()
            for path in (
                repository_root / "tools/localization_migrations"
            ).glob("*.json")
        )

        self.assertTrue(expected)
        self.assertEqual(config.get("hardcodedUIExclusionFiles"), expected)


if __name__ == "__main__":
    unittest.main()
