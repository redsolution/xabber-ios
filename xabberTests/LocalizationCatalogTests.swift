import XCTest
@testable import xabber

final class LocalizationCatalogTests: XCTestCase {
    private let supportedLocales = Set(SupportedLanguage.allCases.map(\.rawValue))

    func testCompiledAppAndExtensionContainOnlySupportedLocalizations() throws {
        let extensionBundle = try pushExtensionBundle()

        XCTAssertEqual(
            topLevelLocalizationDirectories(in: .main),
            supportedLocales.union(["Base"])
        )
        XCTAssertEqual(
            topLevelLocalizationDirectories(in: extensionBundle),
            supportedLocales
        )
    }

    func testCompiledLocalizationResourcesAreIdenticalInAppAndExtension() throws {
        let extensionBundle = try pushExtensionBundle()

        for locale in supportedLocales.sorted() {
            let appResources = localizedResourceNames(locale: locale, bundle: .main)
            let extensionResources = localizedResourceNames(
                locale: locale,
                bundle: extensionBundle
            )
            XCTAssertTrue(
                appResources.contains("Localizable.strings"),
                "Missing compiled strings for \(locale)"
            )
            XCTAssertEqual(
                appResources,
                extensionResources,
                "Compiled resource set differs for \(locale)"
            )

            for resource in appResources.sorted() {
                let appData = try XCTUnwrap(localizedResourceData(
                    resource,
                    locale: locale,
                    bundle: .main
                ))
                let extensionData = try XCTUnwrap(localizedResourceData(
                    resource,
                    locale: locale,
                    bundle: extensionBundle
                ))
                XCTAssertEqual(
                    appData,
                    extensionData,
                    "Compiled resource differs for \(locale)/\(resource)"
                )
            }
        }
    }

    func testSimpleTranslationPlaceholderSignaturesMatchEnglish() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)
        let explicitEnglishKeys = try catalogStrings().compactMap { key, value -> String? in
            guard let localizations = value["localizations"] as? [String: Any],
                  localizations[SupportedLanguage.english.rawValue] != nil else {
                return nil
            }
            return key
        }

        for locale in supportedLocales.subtracting([SupportedLanguage.english.rawValue]) {
            let localized = try strings(locale: locale)
            for key in explicitEnglishKeys {
                guard let englishValue = english[key] else { continue }
                guard let localizedValue = localized[key] else { continue }
                XCTAssertEqual(
                    placeholderSignature(localizedValue),
                    placeholderSignature(englishValue),
                    "Placeholder mismatch for \(locale)/\(key)"
                )
            }
        }
    }

    func testResolvedCatalogConflictsUseCanonicalValues() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)

        XCTAssertNil(english["chat"])
        XCTAssertEqual(english["feedback"], "Feedback")
        XCTAssertEqual(
            english["public_group_invitation"],
            "You are invited to join this public group"
        )
        XCTAssertEqual(
            english["incognito_group_invitation"],
            "You are invited to join this incognito group"
        )
        XCTAssertEqual(english["settings_language_system"], "System")
        XCTAssertNotNil(english["settings__dialog_change_language__header"])
    }

    func testCanonicalEnglishContainsStageTwoConflictResolutions() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)

        XCTAssertEqual(
            english["settings_account__label_active_sessions"],
            "Active sessions"
        )
        XCTAssertEqual(
            english["settings_account__label_active_devices"],
            "Active devices"
        )
        XCTAssertEqual(
            english["signin_server_capabilities_retryable_subtitle"],
            "Server capabilities will be checked again automatically."
        )
        XCTAssertEqual(
            english["signin_server_capabilities_partial_failure_subtitle"],
            "Some server capabilities could not be verified right now. You can continue safely; the app will retry automatically."
        )
        XCTAssertEqual(english["push_invitation_sender_unknown"], "Someone")
        XCTAssertEqual(english["push_sender_unknown"], "Somebody")
        XCTAssertNil(english["somebody"])
    }

    func testActiveKeyManifestHasCompleteEnglishAndNoUnresolvedLookups() throws {
        let manifest = try localizationManifest()
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)

        let summary = try XCTUnwrap(manifest["summary"] as? [String: Any])
        XCTAssertEqual(summary["activeWithoutEnglish"] as? Int, 0)
        XCTAssertEqual(summary["unresolvedDynamicCalls"] as? Int, 0)
        XCTAssertEqual(summary["directLookups"] as? Int, 0)
        XCTAssertEqual(summary["dynamicDomains"] as? Int, 7)
        XCTAssertTrue(try XCTUnwrap(
            manifest["unresolvedDynamicCalls"] as? [[String: Any]]
        ).isEmpty)
        XCTAssertTrue(try XCTUnwrap(
            manifest["directLookups"] as? [[String: Any]]
        ).isEmpty)

        let catalog = try catalogStrings()
        let activeKeys = try XCTUnwrap(
            manifest["activeKeys"] as? [[String: Any]]
        )
        XCTAssertFalse(activeKeys.isEmpty)
        for active in activeKeys {
            let key = try XCTUnwrap(active["key"] as? String)
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations[SupportedLanguage.english.rawValue],
                key
            )
            XCTAssertTrue(
                containsNonemptyLocalizedValue(english),
                "Active key has no nonempty English value: \(key)"
            )
        }
    }

    func testHardcodedUserInterfaceAuditHasNoUnclassifiedCandidates() throws {
        let manifest = try localizationManifest()
        let candidates = try XCTUnwrap(
            manifest["hardcodedCandidates"] as? [[String: Any]]
        )
        let summary = try XCTUnwrap(manifest["summary"] as? [String: Any])

        XCTAssertTrue(candidates.isEmpty, "Unclassified UI text remains: \(candidates.prefix(5))")
        XCTAssertEqual(summary["hardcodedCandidates"] as? Int, 0)
    }

    func testMigratedHardcodedUIKeysContainEverySupportedTranslation() throws {
        let catalog = try catalogStrings()

        for key in try hardcodedUIMigrationKeys() {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                XCTAssertTrue(
                    containsNonemptyLocalizedValue(localizations[locale] as Any),
                    "Missing translated value for \(locale)/\(key)"
                )
            }
        }
    }

    func testSemanticHardcodedUIFollowupsContainEverySupportedTranslation() throws {
        let catalog = try catalogStrings()
        let keys = [
            "chat__body__forward_content_unavailable",
            "chat__error_message__unable_to_send_file",
            "common__action__close",
            "common__label__unknown_user",
            "device_info__text__last_authenticated_format",
            "device_info__text__trusted_manually",
            "notification__body__new_activity",
            "premium__entitlement__next_renewal",
            "push_sender_unknown",
        ]

        for key in keys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                XCTAssertTrue(
                    containsNonemptyLocalizedValue(localizations[locale] as Any),
                    "Missing \(locale) translation for \(key)"
                )
            }
        }

        let english = try strings(locale: SupportedLanguage.english.rawValue)
        XCTAssertEqual(
            english["premium__entitlement__scheduled_change_format"],
            "Scheduled change: %1$@ on %2$@"
        )
    }

    func testPrivacyUsageDescriptionsContainEverySupportedTranslation() throws {
        let catalog = try infoPlistCatalogStrings()
        let expectedKeys: Set<String> = [
            "NFCReaderUsageDescription",
            "NSCameraUsageDescription",
            "NSFaceIDUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
            "NSPhotoLibraryUsageDescription"
        ]

        XCTAssertEqual(Set(catalog.keys), expectedKeys)
        for key in expectedKeys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                XCTAssertTrue(
                    containsNonemptyLocalizedValue(localizations[locale] as Any),
                    "Missing privacy translation for \(locale)/\(key)"
                )
            }
        }
    }

    func testPrivacyUsageDescriptionsUseBuildTimeConfiguredAppNameToken() throws {
        let catalog = try infoPlistCatalogStrings()

        for (key, entry) in catalog {
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            for locale in supportedLocales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "\(key)/\(locale)"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key)/\(locale)"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key)/\(locale)"
                )
                XCTAssertEqual(
                    value.components(separatedBy: "__APP_NAME__").count - 1,
                    1,
                    "\(key)/\(locale)"
                )
                XCTAssertFalse(value.localizedCaseInsensitiveContains("Xabber"))
                XCTAssertFalse(value.localizedCaseInsensitiveContains("Clandestino"))
            }
        }

        let infoPlist = try sourceText("xabber/Info.plist.example")
        XCTAssertTrue(infoPlist.contains("<string>__APP_NAME__</string>"))
        XCTAssertFalse(infoPlist.contains("<string>Xabber</string>"))
    }

    func testCompiledInfoPlistBrandingUsesCommonConfigAppName() throws {
        let appName = CommonConfigManager.shared.config.app_name
        XCTAssertFalse(appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            appName
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            appName
        )

        let expectedKeys = Set(try infoPlistCatalogStrings().keys)
        for locale in supportedLocales {
            let data = try XCTUnwrap(
                localizedResourceData(
                    "InfoPlist.strings",
                    locale: locale,
                    bundle: .main
                ),
                locale
            )
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            let values = try XCTUnwrap(propertyList as? [String: String], locale)
            XCTAssertEqual(Set(values.keys), expectedKeys, locale)
            for (key, value) in values {
                XCTAssertTrue(value.contains(appName), "\(locale)/\(key)")
                XCTAssertFalse(value.contains("__APP_NAME__"), "\(locale)/\(key)")
            }
        }
    }

    func testActiveBrandAndDomainLocalizationCallsitesUseCommonConfigArguments() throws {
        let manifest = try localizationManifest()
        let activeEntries = try XCTUnwrap(
            manifest["activeKeys"] as? [[String: Any]]
        )
        let requiredKeys: Set<String> = [
            "about_extension_protocols",
            "about_xabber",
            "account_settings_terminate_description",
            "chat_xabber_call_hint",
            "device_detail__screen__encryption_key_verified_by_certificate_issued_by_clandestino_for",
            "dialog_jingle_message__message_sign_up",
            "intro_saved_messages_link",
            "notifications_settings__in_app__footer",
            "premium__about__open_source_and_subscription_support",
            "premium__brand__title",
            "premium_subscribtion__presentation_call__about_xabber_premium",
            "registration_title_account_created",
            "registration_title_choose_username",
            "server_doesnt_support_pinned_chats",
            "settings__menu_item__xabber_account",
            "signin_ask_to_register",
            "signin_file_upload_error",
            "signin_message_archive_error",
            "signin_no_message_archive",
            "signin_not_all_features",
            "signin_pubsub_error",
            "signin_push_notifications_error",
            "signin_quick_synchronization_error",
            "signin_tokens_error",
            "simple__alert_message__enter_your_password_to_permanently_delete_value_from_clandestino_this_action_can",
            "xabber_developers",
            "xabber_translators",
        ]
        let entriesByKey = Dictionary(
            uniqueKeysWithValues: activeEntries.compactMap { entry -> (String, [String: Any])? in
                guard let key = entry["key"] as? String else { return nil }
                return (key, entry)
            }
        )

        XCTAssertTrue(requiredKeys.isSubset(of: Set(entriesByKey.keys)))
        for key in requiredKeys {
            let entry = try XCTUnwrap(entriesByKey[key], key)
            let apis = try XCTUnwrap(entry["apis"] as? [String], key)
            XCTAssertEqual(Set(apis), ["format"], key)
            let callsites = try XCTUnwrap(entry["callsites"] as? [[String: Any]], key)
            XCTAssertFalse(callsites.isEmpty, key)
            for callsite in callsites {
                XCTAssertGreaterThan(callsite["argumentCount"] as? Int ?? 0, 0, key)
                let fallback = callsite["fallback"] as? String ?? ""
                XCTAssertFalse(fallback.localizedCaseInsensitiveContains("Xabber"), key)
                XCTAssertFalse(fallback.localizedCaseInsensitiveContains("Clandestino"), key)
                XCTAssertFalse(fallback.localizedCaseInsensitiveContains("xabber.com"), key)
                XCTAssertFalse(fallback.localizedCaseInsensitiveContains("xabber.chat"), key)
                XCTAssertFalse(fallback.localizedCaseInsensitiveContains("xabber.org"), key)
            }
        }

        let sourcePaths = Set(requiredKeys.flatMap { key -> [String] in
            guard let callsites = entriesByKey[key]?["callsites"] as? [[String: Any]] else {
                return []
            }
            return callsites.compactMap { $0["path"] as? String }
        })
        let combinedSource = try sourcePaths.sorted().map(sourceText).joined(separator: "\n")
        XCTAssertTrue(combinedSource.contains("CommonConfigManager.shared.config.app_name"))
        XCTAssertTrue(combinedSource.contains("CommonConfigManager.shared.config.domain"))
    }

    func testVisibleBrandingOutsideCatalogUsesCommonConfig() throws {
        let expectations: [String: String] = [
            "xabber-push-extension/NotificationService.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/xmpp/voip/VoIPManager/VoIPManager.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/controllers/chats/image_gallery/PhotoGallery.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/controllers/chats/info_screens/qr_code/QRCodeViewController.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/controllers/chats/info_screens/account_info/devices_list/device_info/DeviceDetailViewController.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/controllers/chats/info_screens/contact_info/encryption/trusted_devies/ContactDeviceDetailViewController.swift": "CommonConfigManager.shared.config.app_name",
            "xabber/application/AppRootCoordinator.swift": "CommonConfigManager.shared.config.app_name",
        ]

        for (path, requiredText) in expectations {
            XCTAssertTrue(try sourceText(path).contains(requiredText), path)
        }

        let domainBackedFallbacks = [
            "xabber/application/AppRootCoordinator.swift",
            "xabber/xmpp/abuse/XMPPAbuseManager.swift",
        ]
        for path in domainBackedFallbacks {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("CommonConfigManager.shared.config.domain"), path)
            XCTAssertFalse(source.contains("abuse@xabber.com"), path)
            XCTAssertFalse(source.contains("support@xabber.com"), path)
        }

        let premiumSource = try sourceText(
            "xabber/controllers/settings/premium/PremiumSubscribtionViewController.swift"
        )
        XCTAssertTrue(premiumSource.contains("CommonConfigManager.shared.config.domain"))
        XCTAssertFalse(premiumSource.contains("jid.contains(\"xabber.com\")"))
    }

    func testInterfaceBuilderTabTitlesUseReviewedTranslations() throws {
        let expected: [String: [String: String]] = [
            "ar": [
                "5Td-4f-rk4.title": "الدردشات",
                "DWB-EN-Ghs.title": "المكالمات",
                "F61-hp-mAL.title": "الإعدادات",
                "WPS-gd-j8K.title": "الإعدادات",
                "YqP-KI-1X9.title": "جهات الاتصال",
                "hAP-ZD-dLP.title": "استكشاف",
                "uRa-JJ-lEf.title": "جهات الاتصال",
                "v1J-YX-V7X.title": "استكشاف",
                "v9l-7H-qYr.title": "الدردشات"
            ],
            "es": [
                "5Td-4f-rk4.title": "Chats",
                "DWB-EN-Ghs.title": "Llamadas",
                "F61-hp-mAL.title": "Ajustes",
                "WPS-gd-j8K.title": "Ajustes",
                "YqP-KI-1X9.title": "Contactos",
                "hAP-ZD-dLP.title": "Descubrir",
                "uRa-JJ-lEf.title": "Contactos",
                "v1J-YX-V7X.title": "Descubrir",
                "v9l-7H-qYr.title": "Chats"
            ],
            "fr": [
                "5Td-4f-rk4.title": "Discussions",
                "DWB-EN-Ghs.title": "Appels",
                "F61-hp-mAL.title": "Réglages",
                "WPS-gd-j8K.title": "Réglages",
                "YqP-KI-1X9.title": "Contacts",
                "hAP-ZD-dLP.title": "Découvrir",
                "uRa-JJ-lEf.title": "Contacts",
                "v1J-YX-V7X.title": "Découvrir",
                "v9l-7H-qYr.title": "Discussions"
            ],
            "ru": [
                "5Td-4f-rk4.title": "Чаты",
                "DWB-EN-Ghs.title": "Звонки",
                "F61-hp-mAL.title": "Настройки",
                "WPS-gd-j8K.title": "Настройки",
                "YqP-KI-1X9.title": "Контакты",
                "hAP-ZD-dLP.title": "Обзор",
                "uRa-JJ-lEf.title": "Контакты",
                "v1J-YX-V7X.title": "Обзор",
                "v9l-7H-qYr.title": "Чаты"
            ],
            "zh-Hans": [
                "5Td-4f-rk4.title": "聊天",
                "DWB-EN-Ghs.title": "通话",
                "F61-hp-mAL.title": "设置",
                "WPS-gd-j8K.title": "设置",
                "YqP-KI-1X9.title": "联系人",
                "hAP-ZD-dLP.title": "发现",
                "uRa-JJ-lEf.title": "联系人",
                "v1J-YX-V7X.title": "发现",
                "v9l-7H-qYr.title": "聊天"
            ]
        ]

        for (locale, values) in expected {
            XCTAssertEqual(
                try interfaceBuilderStrings(locale: locale, file: "Main.strings"),
                values,
                locale
            )
            XCTAssertEqual(
                try interfaceBuilderStrings(
                    locale: locale,
                    file: "LaunchScreen.strings"
                )["5Ov-Vz-Avm.text"],
                "1.0.0",
                locale
            )
        }
    }

    func testManifestCallsitesMatchCatalogPlaceholderContracts() throws {
        let manifest = try localizationManifest()
        let activeKeys = try XCTUnwrap(
            manifest["activeKeys"] as? [[String: Any]]
        )

        for active in activeKeys {
            let key = try XCTUnwrap(active["key"] as? String)
            let expected = try XCTUnwrap(
                active["formatSignature"] as? [[String: Any]],
                key
            )
            let expectedCount = expected.compactMap { $0["argument"] as? Int }.max() ?? 0
            let callsites = try XCTUnwrap(
                active["callsites"] as? [[String: Any]],
                key
            )
            for callsite in callsites {
                let api = try XCTUnwrap(callsite["api"] as? String, key)
                let argumentCount = try XCTUnwrap(
                    callsite["argumentCount"] as? Int,
                    "Unknown argument count for \(key)"
                )
                let providedCount = argumentCount + (api == "plural" ? 1 : 0)
                XCTAssertEqual(
                    providedCount,
                    expectedCount,
                    "Argument count mismatch for \(key)"
                )

                guard callsite["typeSafety"] as? String != "typeUnchecked",
                      callsite["fallback"] is String,
                      let actual = callsite["formatSignature"] as? [[String: Any]] else {
                    continue
                }
                let matches = signaturesEqual(actual, expected) || (
                    api == "plural" &&
                    signaturesEqual(actual, removingPluralCount(from: expected))
                )
                XCTAssertTrue(matches, "Placeholder signature mismatch for \(key)")
            }
        }
    }

    func testCorrectedFormattingKeysSubstituteRuntimeArguments() {
        let english = localizationService(language: .english)
        let domain = "xmpp.example.test"
        let group = "Friends"
        let contact = "Alex"

        let certificate = english.format(
            key: "account_identity_not_verified_proceed_anyway",
            fallback: "The identity of \"%@\" cannot be verified.",
            arguments: [domain]
        )
        let duplicateCircle = english.format(
            key: "account_circle_already_exists",
            fallback: "Circle \"%@\" already exists",
            arguments: [group]
        )
        let deleteContact = english.format(
            key: "contact_delete_confirm_short",
            fallback: "Do you really want to delete contact %@?",
            arguments: [contact]
        )

        XCTAssertTrue(certificate.contains(domain))
        XCTAssertTrue(duplicateCircle.contains(group))
        XCTAssertTrue(deleteContact.contains(contact))
        XCTAssertFalse(certificate.contains("%@"))
        XCTAssertFalse(duplicateCircle.contains("%@"))
        XCTAssertFalse(deleteContact.contains("%@"))
    }

    func testStageTwoNativePluralsReplaceActiveManualFamilies() throws {
        let catalog = try catalogStrings()
        let expectedPluralKeys = [
            "groupchat__toast__invitations_sent",
            "chat_list__attachment_preview__photos_count",
            "chat_list__attachment_preview__videos_count",
            "chat_list__attachment_preview__files_count",
            "chat_list__attachment_preview__voice_messages_count"
        ]

        for key in expectedPluralKeys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations[SupportedLanguage.english.rawValue] as? [String: Any],
                key
            )
            let variations: [String: Any]
            if let direct = english["variations"] as? [String: Any] {
                variations = direct
            } else {
                let substitutions = try XCTUnwrap(
                    english["substitutions"] as? [String: Any],
                    key
                )
                let substitution = try XCTUnwrap(
                    substitutions.values.first as? [String: Any],
                    key
                )
                variations = try XCTUnwrap(
                    substitution["variations"] as? [String: Any],
                    key
                )
            }
            let plural = try XCTUnwrap(
                variations["plural"] as? [String: Any],
                key
            )
            XCTAssertNotNil(plural["other"], key)
        }

        XCTAssertFalse(
            catalog.keys.contains { $0.hasPrefix("plurals.last_chat_attachment_preview__") }
        )
        XCTAssertFalse(
            catalog.keys.contains { $0.hasPrefix("plurals.groupchat__toast__invitations_sent.") }
        )
    }

    func testActivePlainTextConfirmationContainsNoLegacyHTML() throws {
        let english = try strings(locale: SupportedLanguage.english.rawValue)
        let value = try XCTUnwrap(english["contact_delete_confirm_short"])

        XCTAssertEqual(value, "Do you really want to delete contact %@?")
        XCTAssertFalse(value.contains("<b>"))
        XCTAssertFalse(value.contains("</b>"))
    }

    func testInvitationPluralSelectsGrammarWithoutDisplayingCount() {
        let english = localizationService(language: .english)
        let russian = localizationService(language: .russian)
        let french = localizationService(language: .french)

        XCTAssertEqual(
            english.plural(
                key: "groupchat__toast__invitations_sent",
                count: 1,
                fallback: "Invitation sent"
            ),
            "Invitation sent"
        )
        XCTAssertEqual(
            english.plural(
                key: "groupchat__toast__invitations_sent",
                count: 3,
                fallback: "Invitations sent"
            ),
            "Invitations sent"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 1,
                fallback: "Invitation sent"
            ),
            "Приглашение отправлено"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 21,
                fallback: "Invitations sent"
            ),
            "Приглашение отправлено"
        )
        XCTAssertEqual(
            russian.plural(
                key: "groupchat__toast__invitations_sent",
                count: 5,
                fallback: "Invitations sent"
            ),
            "Приглашения отправлены"
        )
        XCTAssertEqual(
            french.plural(
                key: "groupchat__toast__invitations_sent",
                count: 2,
                fallback: "Invitations sent"
            ),
            "Invitations sent"
        )
    }

    func testLastChatAttachmentPluralsUseEnglishRussianAndEnglishFallback() {
        let english = localizationService(language: .english)
        let russian = localizationService(language: .russian)
        let french = localizationService(language: .french)
        let cases = [
            ("chat_list__attachment_preview__photos_count", "2 Photos", "2 фото"),
            ("chat_list__attachment_preview__videos_count", "2 Videos", "2 видео"),
            ("chat_list__attachment_preview__files_count", "2 Files", "2 файла"),
            ("chat_list__attachment_preview__voice_messages_count", "2 Voice messages", "2 голосовых сообщения")
        ]

        for (key, englishValue, russianValue) in cases {
            XCTAssertEqual(
                english.plural(key: key, count: 2, fallback: englishValue),
                englishValue,
                key
            )
            XCTAssertEqual(
                russian.plural(key: key, count: 2, fallback: englishValue),
                russianValue,
                key
            )
            XCTAssertEqual(
                french.plural(key: key, count: 2, fallback: englishValue),
                englishValue,
                key
            )
        }
    }

    func testDateTimeDurationPluralsCoverEverySupportedLanguage() {
        let cases: [(SupportedLanguage, String, String, String)] = [
            (.english, "1 day", "2 hours", "5 minutes"),
            (.russian, "1 день", "2 часа", "5 минут"),
            (.french, "1 jour", "2 heures", "5 minutes"),
            (.spanish, "1 día", "2 horas", "5 minutos"),
            (.arabic, "1 يوم", "2 ساعتان", "5 دقائق"),
            (.simplifiedChinese, "1 天", "2 小时", "5 分钟")
        ]

        for (language, day, hours, minutes) in cases {
            let service = localizationService(language: language)
            XCTAssertEqual(
                service.plural(
                    key: "date_time_picker__duration__days_count",
                    count: 1,
                    fallback: "%lld day"
                ),
                day,
                language.rawValue
            )
            XCTAssertEqual(
                service.plural(
                    key: "date_time_picker__duration__hours_count",
                    count: 2,
                    fallback: "%lld hours"
                ),
                hours,
                language.rawValue
            )
            XCTAssertEqual(
                service.plural(
                    key: "date_time_picker__duration__minutes_count",
                    count: 5,
                    fallback: "%lld minutes"
                ),
                minutes,
                language.rawValue
            )
        }
    }

    func testPasscodeOptionValuesStayIndependentFromLocalizedTitles() {
        XCTAssertEqual(
            PasscodeSettingsOptionLocalization.autoLockSeconds,
            [0, 60, 120, 300, 600]
        )
        XCTAssertEqual(
            PasscodeSettingsOptionLocalization.attemptLimits,
            [0, 1, 2, 3, 4, 5]
        )
        XCTAssertEqual(
            PasscodeSettingsOptionLocalization.displayedAttemptOffsets,
            [0, 1, 2, 3, 4, 5, 10]
        )

        let russian = localizationService(language: .russian)
        XCTAssertEqual(
            PasscodeSettingsOptionLocalization.autoLockTitle(
                seconds: 0,
                localizer: russian
            ),
            "Никогда"
        )
        XCTAssertEqual(
            PasscodeSettingsOptionLocalization.attemptLimitTitle(
                attempts: 0,
                localizer: russian
            ),
            "Без ограничений"
        )
    }

    func testPasscodeAutoLockMinutePluralCoversEverySupportedLanguage() throws {
        let key = "settings__passcode__auto_lock_minutes_count"
        let catalog = try catalogStrings()
        let entry = try XCTUnwrap(catalog[key], key)
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any],
            key
        )
        XCTAssertEqual(Set(localizations.keys), supportedLocales)

        let cases: [(SupportedLanguage, String, String)] = [
            (.english, "1 minute", "2 minutes"),
            (.russian, "1 минута", "2 минуты"),
            (.french, "1 minute", "2 minutes"),
            (.spanish, "1 minuto", "2 minutos"),
            (.arabic, "1 دقيقة", "2 دقيقتان"),
            (.simplifiedChinese, "1 分钟", "2 分钟")
        ]

        for (language, oneMinute, twoMinutes) in cases {
            let service = localizationService(language: language)
            XCTAssertEqual(
                PasscodeSettingsOptionLocalization.autoLockTitle(
                    seconds: 60,
                    localizer: service
                ),
                oneMinute,
                language.rawValue
            )
            XCTAssertEqual(
                PasscodeSettingsOptionLocalization.autoLockTitle(
                    seconds: 120,
                    localizer: service
                ),
                twoMinutes,
                language.rawValue
            )
        }
    }

    func testPasscodeAttemptChoicesUseTheSelectedLocaleNumberFormatter() {
        for language in SupportedLanguage.allCases {
            let service = localizationService(language: language)
            let expected = service.formatters
                .numberFormatter()
                .string(from: NSNumber(value: 5)) ?? "5"

            XCTAssertEqual(
                PasscodeSettingsOptionLocalization.attemptLimitTitle(
                    attempts: 5,
                    localizer: service
                ),
                expected,
                language.rawValue
            )
            XCTAssertEqual(
                PasscodeSettingsOptionLocalization.displayedAttemptOffsetTitle(
                    offset: 5,
                    localizer: service
                ),
                "+ \(expected)",
                language.rawValue
            )
        }
    }

    func testMediaAttachmentFileSizeUsesLocalizationFormatterFactory() {
        let attachment = MessageMediaAttachmentStorageItem()
        attachment.kind = .file
        attachment.sizeBytes = 3_072

        let expected = L10n.formatters
            .byteCountFormatter(
                countStyle: .binary,
                allowedUnits: [.useKB, .useMB]
            )
            .string(fromByteCount: 3_072)

        XCTAssertEqual(attachment.subtitle(), expected)
    }

    func testPremiumBillingCadenceUsesNativePluralRulesInEverySupportedLanguage() throws {
        let expected: [(SupportedLanguage, String, String)] = [
            (.english, "yearly", "2 months"),
            (.russian, "ежегодно", "2 месяца"),
            (.french, "annuellement", "2 mois"),
            (.spanish, "anualmente", "2 meses"),
            (.arabic, "سنويًا", "2 شهران"),
            (.simplifiedChinese, "每年", "2 个月")
        ]

        for (language, yearly, twoMonths) in expected {
            let service = localizationService(language: language)
            XCTAssertEqual(
                PremiumPeriodLocalization.billingCadence(
                    totalMonths: 12,
                    localizer: service
                ),
                yearly,
                language.rawValue
            )
            XCTAssertEqual(
                PremiumPeriodLocalization.billingCadence(
                    totalMonths: 2,
                    localizer: service
                ),
                twoMonths,
                language.rawValue
            )

            let subtitle = PremiumPeriodLocalization.equivalentBilling(
                monthlyPriceText: "EUR 4.99",
                totalMonths: 2,
                localizer: service
            )
            XCTAssertTrue(subtitle.contains("EUR 4.99"), language.rawValue)
            XCTAssertTrue(subtitle.contains(twoMonths), language.rawValue)
            XCTAssertFalse(subtitle.contains("%1$@"), language.rawValue)
            XCTAssertFalse(subtitle.contains("%2$@"), language.rawValue)
        }

        let catalog = try catalogStrings()
        for key in [
            "premium__period__billing_cadence_months_count",
            "premium__period__billing_cadence_yearly"
        ] {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
        }
        let pluralEntry = try XCTUnwrap(
            catalog["premium__period__billing_cadence_months_count"]
        )
        let pluralLocalizations = try XCTUnwrap(
            pluralEntry["localizations"] as? [String: Any]
        )
        for locale in supportedLocales {
            XCTAssertNotNil(
                (pluralLocalizations[locale] as? [String: Any])?["variations"],
                locale
            )
        }
    }

    func testUnknownPushAttachmentFilenameHasEverySupportedTranslation() throws {
        let entry = try XCTUnwrap(
            try catalogStrings()["push__attachment__filename_unknown"]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )

        XCTAssertEqual(Set(localizations.keys), supportedLocales)
        for locale in supportedLocales {
            XCTAssertTrue(
                containsNonemptyLocalizedValue(
                    try XCTUnwrap(localizations[locale] as? [String: Any])
                ),
                locale
            )
        }
    }

    func testContactsFooterOnlineCategoryUsesOnlineCountAcrossSupportedLanguages() {
        let expected: [(SupportedLanguage, String)] = [
            (.english, "2 online\u{00a0}contacts"),
            (.russian, "2 контакта в сети"),
            (.french, "2 contacts en ligne"),
            (.spanish, "2 contactos en línea"),
            (.arabic, "2 جهتا اتصال متصلتان"),
            (.simplifiedChinese, "2 位联系人在线")
        ]

        for (language, value) in expected {
            withRuntimeLanguage(language) {
                XCTAssertEqual(
                    ContactsFooterLocalization.footer(
                        count: 1,
                        onlineCount: 2,
                        showOffline: true,
                        category: "online",
                        isGroup: false
                    ),
                    value,
                    language.rawValue
                )
            }
        }
    }

    func testContactsFooterEnglishPluralsPreserveExistingWording() {
        let cases: [(String?, Bool, Int, String)] = [
            ("all", false, 1, "1 contact"),
            ("all", false, 2, "2 contacts"),
            ("subscriptions", false, 1, "1 contact request"),
            ("subscriptions", false, 2, "2 contact requests"),
            ("requests", false, 1, "1 outgoing request"),
            ("requests", false, 2, "2 outgoing requests"),
            ("public", true, 1, "1 public group"),
            ("public", true, 2, "2 public groups"),
            ("incognito", true, 1, "1 incognito group"),
            ("incognito", true, 2, "2 incognito groups"),
            ("private", true, 1, "1 private chat"),
            ("private", true, 2, "2 private chats"),
            ("invitations", true, 1, "1 invitation"),
            ("invitations", true, 2, "2 invitations"),
            (nil, true, 1, "1 group"),
            (nil, true, 2, "2 groups"),
            (nil, false, 1, "1 contact"),
            (nil, false, 2, "2 contacts")
        ]

        withRuntimeLanguage(.english) {
            for (category, isGroup, count, value) in cases {
                XCTAssertEqual(
                    ContactsFooterLocalization.footer(
                        count: count,
                        onlineCount: 0,
                        showOffline: true,
                        category: category,
                        isGroup: isGroup
                    ),
                    value
                )
            }

            XCTAssertEqual(
                ContactsFooterLocalization.footer(
                    count: 2,
                    onlineCount: 1,
                    showOffline: true,
                    category: "custom",
                    isGroup: false
                ),
                "2 contacts 1 online"
            )
            XCTAssertEqual(
                ContactsFooterLocalization.footer(
                    count: 2,
                    onlineCount: 2,
                    showOffline: false,
                    category: nil,
                    isGroup: false
                ),
                "2 online"
            )
        }
    }

    func testContactsFooterCircleFilterUsesNativePluralPhrase() {
        withRuntimeLanguage(.english) {
            XCTAssertEqual(
                ContactsFooterLocalization.circleContext(groups: ["Friends"]),
                "in circle Friends"
            )
            XCTAssertEqual(
                ContactsFooterLocalization.circleContext(
                    groups: ["Family", "Friends"]
                ),
                "in circles Family, Friends"
            )
        }
    }

    func testContactsFooterPluralCatalogEntriesCoverEverySupportedLanguage() throws {
        let keys: Set<String> = [
            "contacts__footer__circle_filter",
            "contacts__footer__contact_requests_count",
            "contacts__footer__contacts_count",
            "contacts__footer__contacts_with_online_count",
            "contacts__footer__groups_count",
            "contacts__footer__incognito_groups_count",
            "contacts__footer__invitations_count",
            "contacts__footer__online_contacts_count",
            "contacts__footer__online_count",
            "contacts__footer__outgoing_requests_count",
            "contacts__footer__private_chats_count",
            "contacts__footer__public_groups_count"
        ]
        let catalog = try catalogStrings()

        for key in keys {
            let entry = try XCTUnwrap(catalog[key], key)
            XCTAssertFalse(
                try XCTUnwrap(entry["comment"] as? String, key).isEmpty,
                key
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "\(locale)/\(key)"
                )
                XCTAssertTrue(
                    localization["variations"] != nil ||
                        localization["substitutions"] != nil,
                    "Expected a native plural for \(locale)/\(key)"
                )
                XCTAssertTrue(
                    containsNonemptyLocalizedValue(localization),
                    "Missing translated plural value for \(locale)/\(key)"
                )
            }
        }
    }

    func testGroupchatInfoCountsUseNativePluralRules() {
        withRuntimeLanguage(.english) {
            XCTAssertEqual(GroupchatInfoCountLocalization.members(1), "1 member")
            XCTAssertEqual(GroupchatInfoCountLocalization.members(2), "2 members")
            XCTAssertEqual(
                GroupchatInfoCountLocalization.sectionTitle(members: 2, online: 1),
                "2 members, 1 online"
            )
        }

        withRuntimeLanguage(.russian) {
            XCTAssertEqual(GroupchatInfoCountLocalization.members(1), "1 участник")
            XCTAssertEqual(GroupchatInfoCountLocalization.members(2), "2 участника")
            XCTAssertEqual(GroupchatInfoCountLocalization.members(5), "5 участников")
        }

        withRuntimeLanguage(.arabic) {
            XCTAssertEqual(GroupchatInfoCountLocalization.members(2), "2 عضوان")
            XCTAssertEqual(GroupchatInfoCountLocalization.members(5), "5 أعضاء")
        }

        withRuntimeLanguage(.simplifiedChinese) {
            XCTAssertEqual(GroupchatInfoCountLocalization.members(2), "2 位成员")
        }
    }

    func testGroupchatInfoCountCatalogEntriesCoverEverySupportedLanguage() throws {
        let keys = [
            "groupchat_info__count__members",
            "groupchat_info__count__online",
            "groupchat_info__count__subtitle_format",
            "groupchat_info__count__summary_format"
        ]
        let catalog = try catalogStrings()

        for key in keys {
            let entry = try XCTUnwrap(catalog[key], key)
            XCTAssertFalse(
                try XCTUnwrap(entry["comment"] as? String, key).isEmpty,
                key
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
        }
    }

    func testCircleAccessibilityCountUsesNativePluralRules() throws {
        let cases: [(SupportedLanguage, Int, String)] = [
            (.english, 1, "Friends, 1 contact"),
            (.english, 2, "Friends, 2 contacts"),
            (.russian, 2, "Friends, 2 контакта"),
            (.russian, 5, "Friends, 5 контактов"),
            (.arabic, 2, "Friends، 2 جهتا اتصال"),
            (.simplifiedChinese, 2, "Friends，2 位联系人")
        ]

        for (language, count, expected) in cases {
            let service = localizationService(language: language)
            XCTAssertEqual(
                service.plural(
                    key: "settings__circles__accessibility_label",
                    count: count,
                    fallback: "%2$@, %1$lld contacts",
                    arguments: ["Friends"]
                ),
                expected,
                language.rawValue
            )
        }

        let entry = try XCTUnwrap(
            try catalogStrings()["settings__circles__accessibility_label"]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )
        XCTAssertEqual(Set(localizations.keys), supportedLocales)
    }

    func testActiveInterfaceCountersUseNativePluralsInEverySupportedLanguage() throws {
        let keys = [
            "cloud_storage_gallery__title__value_values_selected",
            "chat__text__value_selected",
            "passcode_or_biometric__text__value_attempts_left",
            "file_deletion_confirmation__text__view_files_to_delete_value"
        ]
        let catalog = try catalogStrings()

        for key in keys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "\(locale)/\(key)"
                )
                XCTAssertNotNil(
                    localization["variations"],
                    "Expected a native plural for \(locale)/\(key)"
                )
            }
        }
    }

    func testActiveInterfaceCountersRenderReviewedPluralCopy() {
        let cases: [(SupportedLanguage, String, Int, String, String)] = [
            (.english, "cloud_storage_gallery__title__value_values_selected", 1, "%lld item selected", "1 item selected"),
            (.english, "chat__text__value_selected", 2, "%lld messages selected", "2 messages selected"),
            (.russian, "passcode_or_biometric__text__value_attempts_left", 5, "%lld attempts left", "Осталось 5 попыток"),
            (.french, "file_deletion_confirmation__text__view_files_to_delete_value", 2, "View files to delete (%lld)", "Afficher les fichiers à supprimer (2)"),
            (.spanish, "cloud_storage_gallery__title__value_values_selected", 2, "%lld items selected", "2 elementos seleccionados"),
            (.arabic, "chat__text__value_selected", 2, "%lld messages selected", "تم تحديد رسالتين (2)"),
            (.simplifiedChinese, "passcode_or_biometric__text__value_attempts_left", 2, "%lld attempts left", "还剩 2 次尝试")
        ]

        for (language, key, count, fallback, expected) in cases {
            XCTAssertEqual(
                localizationService(language: language).plural(
                    key: key,
                    count: count,
                    fallback: fallback
                ),
                expected,
                "\(language.rawValue)/\(key)"
            )
        }
    }

    func testReviewedSimpleTranslationCorrectionsRemainStable() throws {
        let expected: [String: [String: String]] = [
            "ar": [
                "common__action__done": "تم",
                "contacts__list__groups": "المجموعات",
                "subscription_requests__action__add_contact": "إضافة جهة اتصال",
                "group_settings__membership__membership_updated": "تم تحديث إعداد العضوية",
                "privacy__title__incognito_mode": "وضع التخفي",
                "contact_device__verification__bundle_not_found": "لم يتم العثور على حزمة المفاتيح",
                "xmppauthentication_failure__user_message__device_was_revoked": "تم سحب صلاحية الجهاز.",
                "floating_bottom_bar_view__accessibility_value__off": "غير مفعّل",
                "floating_bottom_bar_view__accessibility_value__on": "مفعّل",
                "voice": "الرسائل الصوتية"
            ],
            "en": [
                "group_settings__membership__membership_updated": "Membership setting updated",
                "contact_device__verification__bundle_not_found": "Key bundle not found",
                "device_detail__screen__bundle_not_found": "Key bundle not found",
                "voice": "Voice messages"
            ],
            "es": [
                "common__action__done": "Listo",
                "contacts__list__groups": "Grupos",
                "change_password__result__success": "Éxito",
                "chat__selection__success": "Éxito",
                "premium__entitlement__scheduled_change_format": "Cambio programado a %1$@ para %2$@",
                "voice": "Mensajes de voz"
            ],
            "fr": [
                "common__action__done": "Terminé",
                "navigation__destination__chats": "Discussions",
                "navigation__destination__settings": "Réglages",
                "appearance__content__chats": "Discussions",
                "privacy__title__incognito_mode": "Mode incognito",
                "premium__entitlement__next_renewal": "prochain renouvellement",
                "premium__cta__upgrade_format": "Passer à l’offre supérieure %@",
                "premium__cta__downgrade_format": "Passer à l’offre inférieure %@",
                "voice": "Messages vocaux"
            ],
            "ru": [
                "common__action__done": "Готово",
                "chat__reply__reply_to": "Ответить пользователю %@",
                "group_member__menu__manage": "Управлять",
                "notifications__item__mentioned_you_format": "%@ упоминает вас",
                "premium__cta__upgrade_format": "Повысить тариф до %@",
                "premium__cta__downgrade_format": "Понизить тариф до %@",
                "floating_bottom_bar_view__accessibility_value__off": "Выключено",
                "floating_bottom_bar_view__accessibility_value__on": "Включено",
                "voice": "Голосовые сообщения"
            ],
            "zh-Hans": [
                "common__action__done": "完成",
                "contacts__list__groups": "群组",
                "contact_device__verification__bundle_not_found": "未找到密钥包",
                "floating_bottom_bar_view__accessibility_value__off": "已关闭",
                "floating_bottom_bar_view__accessibility_value__on": "已开启",
                "voice": "语音消息"
            ]
        ]

        for (locale, values) in expected {
            let localized = try strings(locale: locale)
            for (key, value) in values {
                XCTAssertEqual(localized[key], value, "\(locale)/\(key)")
            }
        }
    }

    func testScannerFollowupUITranslationsRemainStable() throws {
        let expected: [String: [String: String]] = [
            "ar": [
                "password_change__field__repeat_new_password_placeholder": "أعد إدخال كلمة المرور الجديدة",
                "device__accessibility__session": "جلسة الجهاز",
                "registration__error__internal_retry_later": "خطأ داخلي. حاول مرة أخرى لاحقًا.",
                "appearance__bubble_style__no_tail": "بلا ذيل",
                "appearance__theme__classic": "كلاسيكي",
                "appearance__wallpaper__aliens": "كائنات فضائية",
                "settings_account__qr_theme__accessibility_label_format": "%1$@، %2$@"
            ],
            "en": [
                "password_change__field__repeat_new_password_placeholder": "repeat new password",
                "device__accessibility__session": "Device session",
                "registration__error__internal_retry_later": "Internal error. Try again later.",
                "appearance__bubble_style__no_tail": "No tail",
                "appearance__theme__classic": "Classic",
                "appearance__wallpaper__aliens": "Aliens",
                "settings_account__qr_theme__accessibility_label_format": "%1$@, %2$@"
            ],
            "es": [
                "password_change__field__repeat_new_password_placeholder": "repite la nueva contraseña",
                "device__accessibility__session": "Sesión del dispositivo",
                "registration__error__internal_retry_later": "Error interno. Inténtalo de nuevo más tarde.",
                "appearance__bubble_style__no_tail": "Sin cola",
                "appearance__theme__classic": "Clásico",
                "appearance__wallpaper__aliens": "Alienígenas",
                "settings_account__qr_theme__accessibility_label_format": "%1$@, %2$@"
            ],
            "fr": [
                "password_change__field__repeat_new_password_placeholder": "répétez le nouveau mot de passe",
                "device__accessibility__session": "Session de l’appareil",
                "registration__error__internal_retry_later": "Erreur interne. Réessayez plus tard.",
                "appearance__bubble_style__no_tail": "Sans pointe",
                "appearance__theme__classic": "Classique",
                "appearance__wallpaper__aliens": "Extraterrestres",
                "settings_account__qr_theme__accessibility_label_format": "%1$@, %2$@"
            ],
            "ru": [
                "password_change__field__repeat_new_password_placeholder": "повторите новый пароль",
                "device__accessibility__session": "Сеанс устройства",
                "registration__error__internal_retry_later": "Внутренняя ошибка. Повторите попытку позже.",
                "appearance__bubble_style__no_tail": "Без хвостика",
                "appearance__theme__classic": "Классическая",
                "appearance__wallpaper__aliens": "Пришельцы",
                "settings_account__qr_theme__accessibility_label_format": "%1$@, %2$@"
            ],
            "zh-Hans": [
                "password_change__field__repeat_new_password_placeholder": "再次输入新密码",
                "device__accessibility__session": "设备会话",
                "registration__error__internal_retry_later": "内部错误。请稍后重试。",
                "appearance__bubble_style__no_tail": "无尾角",
                "appearance__theme__classic": "经典",
                "appearance__wallpaper__aliens": "外星人",
                "settings_account__qr_theme__accessibility_label_format": "%1$@，%2$@"
            ]
        ]

        for (locale, values) in expected {
            let localized = try strings(locale: locale)
            for (key, value) in values {
                XCTAssertEqual(localized[key], value, "\(locale)/\(key)")
            }
        }
    }

    func testManualScannerGapKeysContainEverySupportedTranslation() throws {
        let catalog = try catalogStrings()
        let keys = [
            "appearance__interface_style__system",
            "chat__self_destruct_timer__minutes_count",
            "chat__self_destruct_timer__off",
            "chat__self_destruct_timer__seconds_count",
            "chat_resource_web",
            "photo_gallery__page_count_format",
            "settings_account__qr_theme__accessibility_label_format"
        ]

        for key in keys {
            let entry = try XCTUnwrap(catalog[key], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for locale in supportedLocales {
                XCTAssertTrue(
                    containsNonemptyLocalizedValue(localizations[locale] as Any),
                    "Missing \(locale) translation for \(key)"
                )
            }
        }
    }

    func testSelfDestructTimerPickerUsesNativePluralRules() {
        let english = localizationService(language: .english)
        let russian = localizationService(language: .russian)

        XCTAssertEqual(
            english.plural(
                key: "chat__self_destruct_timer__seconds_count",
                count: 5,
                fallback: "%lld seconds"
            ),
            "5 seconds"
        )
        XCTAssertEqual(
            russian.plural(
                key: "chat__self_destruct_timer__seconds_count",
                count: 5,
                fallback: "%lld seconds"
            ),
            "5 секунд"
        )
        XCTAssertEqual(
            russian.plural(
                key: "chat__self_destruct_timer__minutes_count",
                count: 1,
                fallback: "%lld minutes"
            ),
            "1 минута"
        )
    }

    func testReviewedArabicPluralCategoriesRemainStable() {
        let arabic = localizationService(language: .arabic)
        let cases: [(String, Int, String, [CVarArg], String)] = [
            ("chat__system_message__self_destruct_timer_set_minutes", 0, "Self-destruct timer was set to %lld minutes", [], "تم ضبط مؤقت التدمير الذاتي على 0 دقائق"),
            ("chat__system_message__self_destruct_timer_set_seconds", 0, "Self-destruct timer was set to %lld seconds", [], "تم ضبط مؤقت التدمير الذاتي على 0 ثوانٍ"),
            ("date_time_picker__duration__days_count", 100, "%lld days", [], "100 يوم"),
            ("date_time_picker__duration__hours_count", 100, "%lld hours", [], "100 ساعة"),
            ("date_time_picker__duration__minutes_count", 100, "%lld minutes", [], "100 دقيقة"),
            ("settings__passcode__auto_lock_minutes_count", 100, "%lld minutes", [], "100 دقيقة"),
            ("contacts__footer__contacts_count", 0, "%lld contacts", [], "0 جهات اتصال"),
            ("contacts__footer__groups_count", 0, "%lld groups", [], "0 مجموعات"),
            ("contacts__footer__invitations_count", 0, "%lld invitations", [], "0 دعوات"),
            ("groupchat_info__count__members", 0, "%lld members", [], "0 أعضاء"),
            ("groupchat_info__count__online", 3, "%lld online", [], "3 متصلين"),
            ("groupchat_info__count__online", 0, "%lld online", [], "0 متصلين"),
            ("contacts__footer__online_count", 0, "%lld online", [], "0 متصلين"),
            ("contacts__footer__circle_filter", 2, "in circles %2$@", ["Family, Friends"], "في الدائرتين \u{2066}Family, Friends\u{2069}")
        ]

        for (key, count, fallback, arguments, expected) in cases {
            XCTAssertEqual(
                arabic.plural(
                    key: key,
                    count: count,
                    fallback: fallback,
                    arguments: arguments
                ),
                expected,
                key
            )
        }
    }

    private func withRuntimeLanguage<T>(
        _ language: SupportedLanguage,
        perform body: () throws -> T
    ) rethrows -> T {
        let previous = LocalizationRuntime.shared.context
        LocalizationRuntime.shared.replaceContext(
            localizationService(language: language).context
        )
        defer { LocalizationRuntime.shared.replaceContext(previous) }
        return try body()
    }

    private func pushExtensionBundle() throws -> Bundle {
        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )
        let url = try XCTUnwrap(
            urls.first {
                $0.pathExtension == "appex" &&
                    $0.lastPathComponent.contains("push-extension")
            }
        )
        return try XCTUnwrap(Bundle(url: url))
    }

    private func localizationService(language: SupportedLanguage) -> LocalizationService {
        let provider = LprojBundleProvider(resourceBundle: .main)
        let context = LanguageResolver.makeContext(
            selection: .fixed(language),
            preferredLanguages: [language.rawValue],
            baseLocale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bundleProvider: provider,
            revision: 1
        )
        return LocalizationService(context: context)
    }

    private func topLevelLocalizationDirectories(in bundle: Bundle) -> Set<String> {
        guard let resourceURL = bundle.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return []
        }
        return Set(
            urls
                .filter { $0.pathExtension == "lproj" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    private func localizedResourceData(
        _ resource: String,
        locale: String,
        bundle: Bundle
    ) throws -> Data? {
        guard let root = bundle.resourceURL else {
            return nil
        }
        let url = root
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent(resource)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func localizedResourceNames(
        locale: String,
        bundle: Bundle
    ) -> Set<String> {
        guard let root = bundle.resourceURL else { return [] }
        let localeURL = root.appendingPathComponent("\(locale).lproj", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: localeURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return Set(
            urls
                .map(\.lastPathComponent)
                .filter { $0 == "Localizable.strings" || $0 == "Localizable.stringsdict" }
        )
    }

    private func catalogStrings() throws -> [String: [String: Any]] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("xabber/translations/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(json as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func infoPlistCatalogStrings() throws -> [String: [String: Any]] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("xabber/translations/InfoPlist.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(json as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func interfaceBuilderStrings(
        locale: String,
        file: String
    ) throws -> [String: String] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("xabber/\(locale).lproj", isDirectory: true)
            .appendingPathComponent(file)
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: String])
    }

    private func hardcodedUIMigrationKeys() throws -> Set<String> {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repositoryRoot.appendingPathComponent(
            "tools/localization_migrations",
            isDirectory: true
        )
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        var result: Set<String> = []
        for url in urls {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data)
            let root = try XCTUnwrap(json as? [String: Any])
            let migrations = try XCTUnwrap(root["migrations"] as? [[String: Any]])
            for migration in migrations {
                result.insert(try XCTUnwrap(migration["key"] as? String))
            }
        }
        XCTAssertFalse(result.isEmpty)
        return result
    }

    private func localizationManifest() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot
            .appendingPathComponent("docs/localization/active-keys.json")
        let data = try Data(contentsOf: manifestURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func sourceText(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func containsNonemptyLocalizedValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary["value"] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return dictionary.values.contains(where: containsNonemptyLocalizedValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNonemptyLocalizedValue)
        }
        return false
    }

    private func signaturesEqual(
        _ lhs: [[String: Any]],
        _ rhs: [[String: Any]]
    ) -> Bool {
        NSArray(array: lhs).isEqual(to: rhs)
    }

    private func removingPluralCount(
        from signature: [[String: Any]]
    ) -> [[String: Any]] {
        signature.filter { item in
            guard item["argument"] as? Int == 1,
                  item["role"] == nil,
                  let conversion = item["conversion"] as? String else {
                return true
            }
            return !["d", "i", "u"].contains(String(conversion.suffix(1)))
        }
    }

    private func strings(locale: String) throws -> [String: String] {
        guard let root = Bundle.main.resourceURL else {
            return [:]
        }
        let url = root
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: String])
    }

    private func placeholderSignature(_ value: String) -> [String] {
        let pattern = #"%(?!%)(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?([@diuoxXfFeEgGaAcCsSp])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[range])
        }.sorted()
    }
}

enum LocalizationCatalogTestFixture {
    static func localizedKeys(for language: String) throws -> Set<String> {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("xabber/translations/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else {
            throw NSError(
                domain: "LocalizationCatalogTestFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Localizable.xcstrings"]
            )
        }
        return Set(strings.compactMap { key, entry in
            guard let localizations = entry["localizations"] as? [String: Any],
                  let localization = localizations[language],
                  containsNonemptyLocalizedValue(localization) else {
                return nil
            }
            return key
        })
    }

    private static func containsNonemptyLocalizedValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary["value"] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return dictionary.values.contains(where: containsNonemptyLocalizedValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNonemptyLocalizedValue)
        }
        return false
    }
}
