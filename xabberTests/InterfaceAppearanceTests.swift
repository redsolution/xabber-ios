//
//  InterfaceAppearanceTests.swift
//  xabberTests
//
//  Created by Codex on 04.09.2026.
//

import XCTest
import UIKit
@testable import xabber

final class InterfaceAppearanceTests: XCTestCase {
    private struct AppearanceEntitlementStub: AppearanceEntitlementProviding {
        let hasActiveAppearanceEntitlement: Bool
        let areSubscriptionsEnabled: Bool
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InterfaceAppearanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstProfileUsesSystemModeAndConfiguredAccent() {
        let store = AppearanceSettingsStore(
            defaults: defaults,
            defaultAccentHex: "#7B42F6"
        )

        let document = store.load()

        XCTAssertEqual(document.version, AppearanceSettingsDocument.currentVersion)
        XCTAssertEqual(document.profile.interfaceStyle, .system)
        XCTAssertEqual(document.profile.accentOverride, AppearanceColor(hex: "#7B42F6"))
        XCTAssertTrue(document.customThemes.isEmpty)
    }

    func testInvalidConfiguredAccentFallsBackToSystemBlue() {
        let store = AppearanceSettingsStore(
            defaults: defaults,
            defaultAccentHex: "definitely-not-a-color"
        )

        XCTAssertEqual(store.load().profile.accentOverride, .systemBlue)
    }

    func testLegacySettingsAreMigratedAndClamped() {
        defaults.set("Hearts", forKey: "chat_chooseBackground")
        defaults.set("greenBlue", forKey: "chat_chooseBackgroundColor")
        defaults.set("Curvy", forKey: "message_corner_style")
        defaults.set("48", forKey: "message_corner_radius")
        defaults.set("Top", forKey: "avatar_chat_vertical_position")
        defaults.set("pentagon", forKey: "avatar_masks_current_avatar_mask_")

        let profile = AppearanceSettingsStore(
            defaults: defaults,
            defaultAccentHex: "#0088CC"
        ).load().profile

        XCTAssertEqual(profile.wallpaper, .builtIn(name: "Hearts"))
        XCTAssertEqual(profile.themeID, "builtin.greenBlue")
        XCTAssertEqual(profile.bubbleStyle, .curvy)
        XCTAssertEqual(profile.bubbleRadius, 16)
        XCTAssertEqual(profile.avatarPosition, .top)
        XCTAssertEqual(profile.avatarMask, .pentagon)
    }

    func testCorruptedPayloadFallsBackWithoutCrashing() {
        defaults.set(Data("{broken".utf8), forKey: AppearanceSettingsStore.storageKey)

        let profile = AppearanceSettingsStore(
            defaults: defaults,
            defaultAccentHex: "#0099FF"
        ).load().profile

        XCTAssertEqual(profile.interfaceStyle, .system)
        XCTAssertEqual(profile.bubbleRadius, 16)
        XCTAssertEqual(profile.textSize, .system)
    }

    func testDecodedPayloadDropsCustomThemeWhoseNameCollidesWithBuiltInCatalog() throws {
        let builtIn = AppearanceThemeCatalog.builtInThemes[0]
        var colliding = builtIn
        colliding.id = "custom.collision"
        colliding.isBuiltIn = false
        colliding.name = builtIn.name.folding(options: .diacriticInsensitive, locale: .current).uppercased()
        let document = AppearanceSettingsDocument(
            profile: .default(accent: .systemBlue),
            customThemes: [colliding]
        )
        defaults.set(try JSONEncoder().encode(document), forKey: AppearanceSettingsStore.storageKey)

        let loaded = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF").load()

        XCTAssertTrue(loaded.customThemes.isEmpty)
    }

    func testCommitPersistsOneDocumentAndMirrorsLegacyKeys() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        var document = store.load()
        document.profile.bubbleStyle = .smooth
        document.profile.bubbleRadius = 7
        document.profile.avatarPosition = .top
        document.profile.avatarMask = .roundedSquare
        document.profile.wallpaper = .builtIn(name: "Cats")

        let changes = try store.commit(document)

        XCTAssertTrue(changes.contains(.layout))
        XCTAssertTrue(changes.contains(.paint))
        XCTAssertNotNil(defaults.data(forKey: AppearanceSettingsStore.storageKey))
        XCTAssertEqual(defaults.string(forKey: "message_corner_style"), "Smooth")
        XCTAssertEqual(defaults.string(forKey: "message_corner_radius"), "7")
        XCTAssertEqual(defaults.string(forKey: "avatar_chat_vertical_position"), "Top")
        XCTAssertEqual(defaults.string(forKey: "avatar_masks_current_avatar_mask_"), "rounded_square")
        XCTAssertEqual(defaults.string(forKey: "chat_chooseBackground"), "Cats")
    }

    func testThemeCRUDRejectsCaseAndDiacriticDuplicates() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let first = try store.createCustomTheme(named: "Crème", basedOn: AppearanceThemeCatalog.builtInThemes[0])

        XCTAssertThrowsError(
            try store.createCustomTheme(named: " creme ", basedOn: AppearanceThemeCatalog.builtInThemes[1])
        ) { error in
            XCTAssertEqual(error as? AppearanceStoreError, .duplicateThemeName)
        }

        let renamed = try store.renameCustomTheme(id: first.id, to: "Evening")
        XCTAssertEqual(renamed.name, "Evening")
        try store.deleteCustomTheme(id: first.id)
        XCTAssertTrue(store.load().customThemes.isEmpty)
    }

    @MainActor
    func testCoordinatorCreatesCustomThemeInItsConfiguredStore() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let source = AppearanceThemeCatalog.theme(
            id: coordinator.document.profile.themeID,
            customThemes: coordinator.document.customThemes
        )

        let created = try coordinator.createCustomTheme(named: "My Theme", basedOn: source)

        XCTAssertEqual(created.name, "My Theme")
        XCTAssertEqual(coordinator.document.customThemes, [created])
        XCTAssertEqual(store.load().customThemes, [created])
    }

    func testEditingActiveCustomThemeIsReportedAsPaintChange() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let custom = try store.createCustomTheme(
            named: "Nightfall",
            basedOn: AppearanceThemeCatalog.builtInThemes[0]
        )
        var document = store.load()
        document.profile.apply(theme: custom)
        _ = try store.commit(document)

        var edited = store.load()
        let index = try XCTUnwrap(edited.customThemes.firstIndex(where: { $0.id == custom.id }))
        edited.customThemes[index].lightPalette.accent = AppearanceColor(hex: "#FF5500")!

        let changes = try store.commit(edited)

        XCTAssertTrue(changes.contains(.paint))
        XCTAssertFalse(changes.contains(.layout))
    }

    func testApplyingThemePreservesIndependentLayoutSettingsAndReplacesAccentOverride() {
        var profile = AppearanceProfile.default(accent: AppearanceColor(hex: "#FF00FF")!)
        profile.textSize = .points20
        profile.bubbleStyle = .wedge
        profile.bubbleRadius = 3
        profile.avatarMask = .octagon
        profile.avatarPosition = .top
        let theme = AppearanceThemeCatalog.builtInThemes[2]

        profile.apply(theme: theme)

        XCTAssertEqual(profile.themeID, theme.id)
        XCTAssertEqual(profile.wallpaper, theme.wallpaper)
        XCTAssertNil(profile.accentOverride)
        XCTAssertEqual(profile.textSize, .points20)
        XCTAssertEqual(profile.bubbleStyle, .wedge)
        XCTAssertEqual(profile.bubbleRadius, 3)
        XCTAssertEqual(profile.avatarMask, .octagon)
        XCTAssertEqual(profile.avatarPosition, .top)
    }

    func testApplyingThemeCanPreserveWallpaperForLockedWhiteLabel() {
        var profile = AppearanceProfile.default(accent: .systemBlue)
        profile.wallpaper = .builtIn(name: "Hearts")

        profile.apply(theme: AppearanceThemeCatalog.builtInThemes[3], preserveWallpaper: true)

        XCTAssertEqual(profile.themeID, AppearanceThemeCatalog.builtInThemes[3].id)
        XCTAssertEqual(profile.wallpaper, .builtIn(name: "Hearts"))
        XCTAssertNil(profile.accentOverride)
    }

    func testResolverUsesWhiteOutgoingMessagesAndThemeColorForIncomingMessages() {
        let theme = AppearanceThemeCatalog.builtInThemes[0]
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.themeID = theme.id
        document.profile.accentOverride = nil

        let light = AppearanceResolver.resolve(document: document, traitStyle: .light)
        let dark = AppearanceResolver.resolve(document: document, traitStyle: .dark)

        XCTAssertEqual(light.palette.incomingBubble, theme.lightPalette.outgoingBubble)
        XCTAssertEqual(light.palette.incomingText, theme.lightPalette.outgoingText)
        XCTAssertEqual(light.palette.outgoingBubble, .white)
        XCTAssertEqual(light.palette.outgoingText, .black)
        XCTAssertEqual(dark.palette.incomingBubble, theme.darkPalette.outgoingBubble)
        XCTAssertEqual(dark.palette.incomingText, theme.darkPalette.outgoingText)
        XCTAssertEqual(dark.palette.outgoingBubble, .white)
        XCTAssertEqual(dark.palette.outgoingText, .black)
        XCTAssertEqual(light.accent, theme.lightPalette.accent)
        XCTAssertEqual(dark.accent, theme.darkPalette.accent)
    }

    func testLayoutSignatureChangesForEveryGeometrySetting() {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let base = AppearanceResolver.resolve(document: document, traitStyle: .light).layoutSignature

        let mutations: [(inout AppearanceProfile) -> Void] = [
            { $0.textSize = .points21 },
            { $0.bubbleStyle = .curvy },
            { $0.bubbleRadius = 0 },
            { $0.avatarMask = .star },
            { $0.avatarPosition = .top }
        ]

        for mutate in mutations {
            var changed = document
            mutate(&changed.profile)
            XCTAssertNotEqual(
                AppearanceResolver.resolve(document: changed, traitStyle: .light).layoutSignature,
                base
            )
        }
    }

    func testDraftDoesNotMutateOriginalUntilCommit() {
        let original = AppearanceProfile.default(accent: .systemBlue)
        var draft = AppearanceDraft(profile: original)

        draft.profile.bubbleRadius = 4

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(original.bubbleRadius, 16)
        XCTAssertEqual(draft.changeSet, [.layout])
        draft.reset()
        XCTAssertFalse(draft.isDirty)
    }

    @MainActor
    func testDraftEditorUsesNavigationControllerBackAndDiscardsUnsavedChanges() {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let controller = AppearanceDraftViewController(document: document, title: "Editor")
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.navigationItem.hidesBackButton)
        XCTAssertNil(controller.navigationItem.leftBarButtonItem)

        controller.draft.profile.bubbleRadius = 3
        XCTAssertTrue(controller.draft.isDirty)

        let popped = navigationController.popViewController(animated: false)

        XCTAssertTrue(popped === controller)
        XCTAssertEqual(controller.draft.profile, document.profile)
        XCTAssertFalse(controller.draft.isDirty)
    }

    @MainActor
    func testInterfaceLayoutEditorRoutePushesOntoExistingNavigationStack() throws {
        let controller = InterfaceSettingsViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 2, section: 1))

        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.topViewController is AppearanceDraftViewController)
        XCTAssertNil(navigationController.topViewController?.navigationItem.leftBarButtonItem)
    }

    @MainActor
    func testTextSizeUsesManualSliderAndSystemCellWithoutCommittingRootDraft() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        var appliedDocument = coordinator.document
        appliedDocument.profile.textSize = .points17
        try coordinator.commit(appliedDocument)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        XCTAssertNil(controller.navigationItem.leftBarButtonItem)
        XCTAssertNil(controller.navigationItem.rightBarButtonItem)
        XCTAssertFalse(controller.navigationItem.hidesBackButton)
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 2, section: 1))

        let editor = try XCTUnwrap(navigationController.topViewController as? AppearanceDraftViewController)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        let slider = try XCTUnwrap(
            descendant(in: editor.view, accessibilityIdentifier: "interface.textSize.slider") as? UISlider
        )
        let textSizeTable = try XCTUnwrap(
            descendant(in: editor.view, accessibilityIdentifier: "interface.textSize.table") as? UITableView
        )
        let preview = try XCTUnwrap(
            descendant(in: editor.view, accessibilityIdentifier: "interface.preview") as? AppearancePreviewView
        )
        let incomingMessage = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.incoming"
            ) as? TextMessageCell
        )
        let outgoingMessage = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.outgoing"
            ) as? TextMessageCell
        )

        XCTAssertNil(editor.navigationItem.leftBarButtonItem)
        XCTAssertNil(editor.navigationItem.rightBarButtonItem)
        XCTAssertEqual(slider.minimumValue, 0)
        XCTAssertEqual(slider.maximumValue, 7)
        XCTAssertEqual(slider.value, 3)
        XCTAssertEqual(textSizeTable.numberOfSections, 1)
        XCTAssertEqual(textSizeTable.numberOfRows(inSection: 0), 2)
        XCTAssertEqual(
            textSizeTable.dataSource?.tableView?(textSizeTable, titleForHeaderInSection: 0),
            "Text size: 17"
        )
        let systemFontCell = try XCTUnwrap(textSizeTable.cellForRow(at: IndexPath(row: 1, section: 0)))
        XCTAssertEqual(systemFontCell.accessibilityIdentifier, "interface.textSize.useSystem")
        XCTAssertEqual(systemFontCell.textLabel?.text, "Set System font size")
        XCTAssertEqual(systemFontCell.accessoryType, .none)
        XCTAssertEqual(try XCTUnwrap(slider.tintColor).cgColor.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(incomingMessage.messageLabel.text).split(separator: " ").count, 9)
        XCTAssertEqual(try XCTUnwrap(outgoingMessage.messageLabel.text).split(separator: " ").count, 9)
        let previewHeightAt17 = preview.bounds.height
        let incomingFrame = incomingMessage.convert(incomingMessage.bounds, to: preview)
        let outgoingFrameAt17 = outgoingMessage.convert(outgoingMessage.bounds, to: preview)
        XCTAssertEqual(
            outgoingFrameAt17.minY - incomingFrame.maxY,
            UICollectionViewFlowLayout().minimumLineSpacing,
            accuracy: 0.5
        )

        textSizeTable.delegate?.tableView?(textSizeTable, didSelectRowAt: IndexPath(row: 1, section: 0))
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        XCTAssertEqual(editor.draft.profile.textSize, .system)
        XCTAssertEqual(slider.value, 3)
        XCTAssertEqual(try XCTUnwrap(slider.tintColor).cgColor.alpha, 0.5, accuracy: 0.01)
        XCTAssertEqual(coordinator.document.profile.textSize, .points17)
        XCTAssertEqual(
            textSizeTable.dataSource?.tableView?(textSizeTable, titleForHeaderInSection: 0),
            "Text size: system"
        )
        let selectedSystemFontCell = try XCTUnwrap(
            textSizeTable.cellForRow(at: IndexPath(row: 1, section: 0))
        )
        XCTAssertEqual(selectedSystemFontCell.textLabel?.text, "Set System font size")
        XCTAssertEqual(selectedSystemFontCell.accessoryType, .none)
        XCTAssertEqual(
            controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
            "interface.settings.cancel"
        )
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "interface.settings.save"
        )
        XCTAssertTrue(controller.navigationItem.hidesBackButton)

        slider.setValue(6, animated: false)
        slider.sendActions(for: .valueChanged)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        XCTAssertEqual(editor.draft.profile.textSize, .points20)
        XCTAssertEqual(try XCTUnwrap(slider.tintColor).cgColor.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(coordinator.document.profile.textSize, .points17)
        XCTAssertEqual(
            textSizeTable.dataSource?.tableView?(textSizeTable, titleForHeaderInSection: 0),
            "Text size: 20"
        )
        let sliderAfterManualChange = try XCTUnwrap(
            descendant(in: editor.view, accessibilityIdentifier: "interface.textSize.slider") as? UISlider
        )
        XCTAssertTrue(slider === sliderAfterManualChange)
        XCTAssertEqual(preview.bounds.height, previewHeightAt17, accuracy: 0.5)

        slider.setValue(7, animated: false)
        slider.sendActions(for: .valueChanged)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        XCTAssertEqual(editor.draft.profile.textSize, .points21)
        XCTAssertEqual(preview.bounds.height, previewHeightAt17, accuracy: 0.5)
        let incomingFrameAt21 = incomingMessage.convert(incomingMessage.bounds, to: preview)
        let outgoingFrame = outgoingMessage.convert(outgoingMessage.bounds, to: preview)
        XCTAssertGreaterThanOrEqual(incomingFrameAt21.minY, 16 - 0.5)
        XCTAssertLessThanOrEqual(outgoingFrame.maxY, preview.bounds.maxY - 16 + 0.5)
    }

    @MainActor
    func testInterfaceSettingsSupportsNibInitializerForLegacyRoutes() throws {
        let controller = InterfaceSettingsViewController(nibName: nil, bundle: nil)

        controller.loadViewIfNeeded()

        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        XCTAssertEqual(tableView.accessibilityIdentifier, "interface.settings.table")
    }

    @MainActor
    func testInterfaceSettingsCombinesColorThemeAndChatAppearanceRows() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        XCTAssertEqual(controller.numberOfSections(in: tableView), 3)
        XCTAssertEqual(controller.tableView(tableView, titleForHeaderInSection: 1), "Customisation")
        XCTAssertEqual(controller.tableView(tableView, numberOfRowsInSection: 1), 5)
        let titles = try (0..<5).map { row in
            let cell = controller.tableView(tableView, cellForRowAt: IndexPath(row: row, section: 1))
            let configuration = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
            return try XCTUnwrap(configuration.text)
        }

        XCTAssertEqual(titles, ["Chat Wallpaper", "Message Bubbles", "Text Size", "Application Color", "Avatars"])
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.settings.chatThemes"))
    }

    @MainActor
    func testOverviewThemeRailEndsWithCreateThemeControl() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let createControl = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.theme.create") as? UIControl
        )
        let themeRail = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.theme.rail") as? UIStackView
        )

        createControl.sendActions(for: .touchUpInside)

        XCTAssertEqual(createControl.accessibilityLabel, "Create New Theme")
        XCTAssertTrue(themeRail.arrangedSubviews.last === createControl)
        XCTAssertTrue(controller.presentedViewController is UIAlertController)
    }

    @MainActor
    func testInterfaceSettingsShowsOnlyInlineSystemLightDarkAppearanceChoices() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        let cell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )

        XCTAssertEqual(Set(AppearanceInterfaceStyle.allCases), [.system, .light, .dark])
        XCTAssertEqual(controller.tableView(tableView, titleForHeaderInSection: 2), "Appearance")
        XCTAssertEqual(cell.accessibilityIdentifier, "interface.settings.appearance")
        XCTAssertEqual(cell.selectionStyle, .none)
        XCTAssertEqual(cell.accessoryType, .none)
        XCTAssertNotNil(descendant(in: cell, accessibilityIdentifier: "interface.mode.system") as? UIControl)
        XCTAssertNotNil(descendant(in: cell, accessibilityIdentifier: "interface.mode.light") as? UIControl)
        XCTAssertNotNil(descendant(in: cell, accessibilityIdentifier: "interface.mode.dark") as? UIControl)
        XCTAssertNil(descendant(in: cell, accessibilityIdentifier: "interface.mode.automatic"))
        XCTAssertNil(descendant(in: cell, accessibilityIdentifier: "interface.settings.mode"))
    }

    @MainActor
    func testInterfaceAvatarRowShowsOnlySelectedMaskWithoutLegacyGroupPosition() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        var document = coordinator.document
        document.profile.avatarMask = .roundedSquare
        document.profile.avatarPosition = .top
        _ = try coordinator.commit(document)

        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        let cell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 4, section: 1)
        )
        let configuration = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)

        XCTAssertEqual(configuration.secondaryText, AppearanceAvatarMask.roundedSquare.displayName)
        XCTAssertNotEqual(configuration.secondaryText, "Rounded square, Top")
    }

    @MainActor
    func testAppearanceModePreviewShowsOnlyRoundedMessagePictograms() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let cell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )
        let preview = try XCTUnwrap(
            descendant(in: cell, accessibilityIdentifier: "interface.mode.preview.system")
        )
        let messagePictograms = try (0..<2).map { index in
            try XCTUnwrap(
                descendant(
                    in: preview,
                    accessibilityIdentifier: "interface.mode.preview.system.message.\(index)"
                )
            )
        }

        XCTAssertFalse(labels(in: preview).contains { $0.text == "09:41" })
        XCTAssertTrue(messagePictograms.allSatisfy { !($0 is UILabel) })
        XCTAssertTrue(messagePictograms.allSatisfy { $0.layer.cornerRadius == 8 })
    }

    @MainActor
    func testInlineAppearanceChoiceCommitsAndAppliesImmediately() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let previousWindowAppearances = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map { ($0, $0.overrideUserInterfaceStyle, $0.tintColor) }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        let host = UIViewController()
        let navigationController = NonAnimatingNavigationController(rootViewController: host)
        navigationController.pushViewController(controller, animated: false)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindowAppearances.forEach { window, style, tintColor in
                window.overrideUserInterfaceStyle = style
                window.tintColor = tintColor
            }
            previousKeyWindow?.makeKey()
        }
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let originalProfile = coordinator.document.profile
        let theme = try XCTUnwrap(
            AppearanceThemeCatalog.builtInThemes.first(
                where: { $0.id != originalProfile.themeID }
            )
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let themeControl = try XCTUnwrap(
            descendant(
                in: overviewCell,
                accessibilityIdentifier: "interface.theme.mini.\(theme.id)"
            ) as? UIControl
        )
        themeControl.sendActions(for: .touchUpInside)

        XCTAssertEqual(coordinator.document.profile, originalProfile)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem?.isEnabled ?? false)

        let cell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )
        let dark = try XCTUnwrap(
            descendant(in: cell, accessibilityIdentifier: "interface.mode.dark") as? UIControl
        )

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
        dark.sendActions(for: .touchUpInside)

        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.topViewController === controller)
        XCTAssertEqual(coordinator.document.profile.interfaceStyle, .dark)
        XCTAssertEqual(store.load().profile.interfaceStyle, .dark)
        XCTAssertEqual(coordinator.document.profile.themeID, originalProfile.themeID)
        XCTAssertEqual(store.load().profile.themeID, originalProfile.themeID)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem?.isEnabled ?? false)

        let refreshedCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )
        let selectedDark = try XCTUnwrap(
            descendant(in: refreshedCell, accessibilityIdentifier: "interface.mode.dark") as? UIControl
        )
        XCTAssertEqual(selectedDark.accessibilityValue, "Selected")
        XCTAssertTrue(selectedDark.accessibilityTraits.contains(.selected))

        controller.cancelTapped()

        XCTAssertEqual(navigationController.viewControllers.count, 1)
        XCTAssertTrue(navigationController.topViewController === host)
        XCTAssertEqual(coordinator.document.profile.interfaceStyle, .dark)
        XCTAssertEqual(store.load().profile.interfaceStyle, .dark)
        XCTAssertEqual(coordinator.document.profile.themeID, originalProfile.themeID)
        XCTAssertEqual(store.load().profile.themeID, originalProfile.themeID)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
    }

    @MainActor
    func testOverviewThemeTapStaysInRootDraftUntilCheckmark() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let original = coordinator.document.profile
        let theme = try XCTUnwrap(
            AppearanceThemeCatalog.builtInThemes.first(where: { $0.id != original.themeID })
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let themeControl = try XCTUnwrap(
            descendant(
                in: overviewCell,
                accessibilityIdentifier: "interface.theme.mini.\(theme.id)"
            ) as? UIControl
        )

        themeControl.removeFromSuperview()
        themeControl.translatesAutoresizingMaskIntoConstraints = true
        themeControl.frame = CGRect(x: 0, y: 0, width: 86, height: 105)
        themeControl.setNeedsLayout()
        themeControl.layoutIfNeeded()
        let hitView = themeControl.hitTest(CGPoint(x: 20, y: 20), with: nil)

        XCTAssertTrue(
            hitView === themeControl,
            "Expected theme control, got \(String(describing: hitView)); " +
            "bounds=\(themeControl.bounds), enabled=\(themeControl.isEnabled), " +
            "interactive=\(themeControl.isUserInteractionEnabled), alpha=\(themeControl.alpha)"
        )
        (hitView as? UIControl)?.sendActions(for: .touchUpInside)

        XCTAssertEqual(navigationController.viewControllers.count, 1)
        XCTAssertTrue(navigationController.topViewController === controller)
        XCTAssertEqual(coordinator.document.profile, original)
        XCTAssertEqual(store.load().profile, original)

        let refreshedCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let selectedControl = try XCTUnwrap(
            descendant(
                in: refreshedCell,
                accessibilityIdentifier: "interface.theme.mini.\(theme.id)"
            ) as? UIControl
        )
        XCTAssertEqual(selectedControl.accessibilityValue, "Selected")
        XCTAssertTrue(selectedControl.accessibilityTraits.contains(.selected))

        controller.saveTapped()

        XCTAssertEqual(coordinator.document.profile.themeID, theme.id)
        XCTAssertNil(coordinator.document.profile.accentOverride)
        XCTAssertEqual(store.load().profile.themeID, theme.id)
    }

    @MainActor
    func testOverviewThemeMiniatureRendersItsWallpaper() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let document = coordinator.document
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let rose = try XCTUnwrap(
            AppearanceThemeCatalog.builtInThemes.first(where: { $0.name == "Rose" })
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let themeControl = try XCTUnwrap(
            descendant(
                in: overviewCell,
                accessibilityIdentifier: "interface.theme.mini.\(rose.id)"
            )
        )
        let wallpaper = try XCTUnwrap(
            descendant(
                in: themeControl,
                accessibilityIdentifier: "interface.theme.wallpaper.\(rose.id)"
            ) as? ChatBackgroundBackdropView
        )

        XCTAssertEqual(wallpaper.representedWallpaper, rose.wallpaper)
        XCTAssertTrue(wallpaper.hasVisibleWallpaperImage)
        XCTAssertNotEqual(document.profile.themeID, rose.id)
    }

    @MainActor
    func testOverviewThemeMiniatureUsesPlainRoundedMessagePictograms() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.overrideUserInterfaceStyle = .light
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let rose = try XCTUnwrap(
            AppearanceThemeCatalog.builtInThemes.first(where: { $0.name == "Rose" })
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let themeControl = try XCTUnwrap(
            descendant(
                in: overviewCell,
                accessibilityIdentifier: "interface.theme.mini.\(rose.id)"
            )
        )
        let incoming = try XCTUnwrap(
            descendant(
                in: themeControl,
                accessibilityIdentifier: "interface.theme.bubble.incoming.\(rose.id)"
            )
        )
        let outgoing = try XCTUnwrap(
            descendant(
                in: themeControl,
                accessibilityIdentifier: "interface.theme.bubble.outgoing.\(rose.id)"
            )
        )
        var roseDocument = AppearanceSettingsDocument(
            profile: .default(accent: .systemBlue)
        )
        roseDocument.profile.apply(theme: rose)
        let palette = AppearanceResolver.resolve(
            document: roseDocument,
            traitStyle: .light
        ).palette

        XCTAssertFalse(incoming is ModernMessageContainerView)
        XCTAssertFalse(outgoing is ModernMessageContainerView)
        XCTAssertNil(incoming.layer.mask)
        XCTAssertNil(outgoing.layer.mask)
        XCTAssertEqual(incoming.layer.cornerRadius, 9)
        XCTAssertEqual(outgoing.layer.cornerRadius, 9)
        XCTAssertEqual(incoming.backgroundColor, palette.incomingBubble.uiColor)
        XCTAssertEqual(outgoing.backgroundColor, palette.outgoingBubble.uiColor)
    }

    @MainActor
    func testAppearancePreviewUsesProductionChatCellsAndBubbleGeometry() throws {
        var profile = AppearanceProfile.default(accent: .systemBlue)
        profile.bubbleStyle = .smooth
        profile.bubbleRadius = 9
        let document = AppearanceSettingsDocument(profile: profile)
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 210))

        preview.configure(
            document: document,
            traits: UITraitCollection(userInterfaceStyle: .light),
            animated: false
        )
        preview.setNeedsLayout()
        preview.layoutIfNeeded()

        let incoming = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.incoming"
            ) as? TextMessageCell
        )
        let outgoing = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.outgoing"
            ) as? TextMessageCell
        )
        let expectedRadius = CommonConfigManager.shared.messageStyleConfig
            .messageBubbles.smooth.message.bubble.getRadiusFor(index: "9")
        let snapshot = AppearanceResolver.resolve(document: document, traitStyle: .light)

        XCTAssertEqual(incoming.messageContainerView.tail, "smooth")
        XCTAssertEqual(outgoing.messageContainerView.tail, "smooth")
        XCTAssertEqual(incoming.messageContainerView.radius1, expectedRadius.leftUpper)
        XCTAssertEqual(incoming.messageContainerView.radius2, expectedRadius.rightUpper)
        XCTAssertEqual(incoming.messageContainerView.radius3, expectedRadius.rightBottom)
        XCTAssertEqual(incoming.messageContainerView.radius4, expectedRadius.leftBottom)
        XCTAssertEqual(
            incoming.messageContainerView.bubble.backgroundColor,
            snapshot.palette.incomingBubble.uiColor
        )
        XCTAssertEqual(
            outgoing.messageContainerView.bubble.backgroundColor,
            snapshot.palette.outgoingBubble.uiColor
        )
    }

    @MainActor
    func testOverviewPreviewMessageTypographyMatchesSelectedTextSize() throws {
        var profile = AppearanceProfile.default(accent: .systemBlue)
        profile.textSize = .points21
        let document = AppearanceSettingsDocument(profile: profile)
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        preview.presentation = .interfaceOverview
        preview.configure(
            document: document,
            traits: .init(userInterfaceStyle: .light),
            animated: false
        )
        preview.setNeedsLayout()
        preview.layoutIfNeeded()

        let message = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.overview.0"
            ) as? TextMessageCell
        )
        let renderedFont = try XCTUnwrap(
            message.messageLabel.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )
        let expectedFont = AppearanceTypography.font(
            textStyle: .body,
            appearanceSize: .points21
        )

        XCTAssertEqual(renderedFont.fontName, expectedFont.fontName)
        XCTAssertEqual(renderedFont.pointSize, expectedFont.pointSize, accuracy: 0.01)
    }

    @MainActor
    func testRootInterfacePreviewTouchesCellEdgesAndLeavesThemeRailOnGroupedBackground() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let controller = InterfaceSettingsViewController(
            appearanceCoordinator: AppearanceCoordinator(store: store)
        )
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        overviewCell.frame = CGRect(x: 0, y: 0, width: 390, height: 429)
        overviewCell.setNeedsLayout()
        overviewCell.layoutIfNeeded()
        let preview = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.preview") as? AppearancePreviewView
        )
        let themeRail = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.theme.rail") as? UIStackView
        )
        let themeRailContainer = try XCTUnwrap(themeRail.superview as? UIScrollView)

        XCTAssertNil(themeRailContainer.backgroundColor)
        XCTAssertEqual(preview.frame.minX, overviewCell.contentView.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(preview.frame.maxX, overviewCell.contentView.bounds.maxX, accuracy: 0.01)
        XCTAssertEqual(preview.frame.minY, overviewCell.contentView.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(preview.frame.height, 300, accuracy: 0.01)
        XCTAssertEqual(themeRailContainer.frame.minY, preview.frame.maxY + 12, accuracy: 0.01)
        XCTAssertEqual(
            themeRailContainer.frame.maxY,
            overviewCell.contentView.bounds.maxY - 12,
            accuracy: 0.01
        )
        XCTAssertEqual(preview.layer.cornerRadius, 0, accuracy: 0.01)
        XCTAssertEqual(preview.layer.maskedCorners, [])
    }

    @MainActor
    func testRootInterfacePreviewUsesChatViewMessageInsets() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let controller = InterfaceSettingsViewController(
            appearanceCoordinator: AppearanceCoordinator(store: store)
        )
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        overviewCell.frame = CGRect(x: 0, y: 0, width: 390, height: 429)
        overviewCell.setNeedsLayout()
        overviewCell.layoutIfNeeded()

        let preview = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.preview") as? AppearancePreviewView
        )
        let incomingAvatar = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.messageAvatar.overview.0"
            ) as? UIImageView
        )
        let incoming = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.overview.0"
            ) as? TextMessageCell
        )
        let outgoing = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.overview.1"
            ) as? TextMessageCell
        )
        let thirdIncoming = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.overview.2"
            ) as? TextMessageCell
        )

        let incomingContainerFrame = incoming.messageContainerView.convert(
            incoming.messageContainerView.bounds,
            to: preview
        )
        let outgoingContainerFrame = outgoing.messageContainerView.convert(
            outgoing.messageContainerView.bounds,
            to: preview
        )
        let thirdIncomingContainerFrame = thirdIncoming.messageContainerView.convert(
            thirdIncoming.messageContainerView.bounds,
            to: preview
        )
        let incomingAvatarFrame = incomingAvatar.convert(incomingAvatar.bounds, to: preview)

        XCTAssertEqual(incoming.messageLabel.text, "How’s your morning going? I hope the weather is good today.")
        XCTAssertEqual(outgoing.messageLabel.text, "Really good — Tokyo is beautiful. I found a quiet café near the park. 😎")
        XCTAssertEqual(incomingAvatarFrame.minX, preview.bounds.minX + 4, accuracy: 0.01)
        XCTAssertEqual(incomingAvatarFrame.width, 32, accuracy: 0.01)
        XCTAssertEqual(incomingContainerFrame.minX, incomingAvatarFrame.maxX, accuracy: 0.01)
        XCTAssertEqual(outgoingContainerFrame.maxX, preview.bounds.maxX - 4, accuracy: 0.01)
        XCTAssertEqual(
            outgoingContainerFrame.minY - incomingContainerFrame.maxY,
            8,
            accuracy: 0.01
        )
        XCTAssertEqual(
            thirdIncomingContainerFrame.minY - outgoingContainerFrame.maxY,
            8,
            accuracy: 0.01
        )
        XCTAssertLessThanOrEqual(thirdIncomingContainerFrame.maxY, preview.bounds.maxY - 4)
    }

    @MainActor
    func testRootInterfacePreviewShowsChatChromePhotoAvatarsAndThreeMessages() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let preview = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.preview") as? AppearancePreviewView
        )
        let navigation = try XCTUnwrap(
            descendant(in: preview, accessibilityIdentifier: "interface.preview.navigation")
        )
        let title = try XCTUnwrap(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.title") as? UILabel
        )
        let navigationAvatar = try XCTUnwrap(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.avatar") as? UIImageView
        )
        let firstIncomingAvatar = try XCTUnwrap(
            descendant(in: preview, accessibilityIdentifier: "interface.preview.messageAvatar.overview.0") as? UIImageView
        )
        let secondIncomingAvatar = try XCTUnwrap(
            descendant(in: preview, accessibilityIdentifier: "interface.preview.messageAvatar.overview.2") as? UIImageView
        )

        XCTAssertEqual(title.text, "Alicia Torreaux")
        XCTAssertNotNil(navigationAvatar.image)
        let firstIncomingAvatarData = try XCTUnwrap(firstIncomingAvatar.image?.pngData())
        let secondIncomingAvatarData = try XCTUnwrap(secondIncomingAvatar.image?.pngData())
        XCTAssertEqual(
            firstIncomingAvatarData,
            secondIncomingAvatarData,
            "Incoming root-preview messages must use one contact avatar"
        )
        for index in 0..<3 {
            XCTAssertNotNil(
                descendant(
                    in: preview,
                    accessibilityIdentifier: "interface.themePreview.chat.message.overview.\(index)"
                ) as? TextMessageCell
            )
        }
    }

    @MainActor
    func testInterfacePreviewContentPhotosFollowSelectedMaskWhileNavigationAvatarRemainsCircular() throws {
        var octagonDocument = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        octagonDocument.profile.avatarMask = .octagon

        let overview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        overview.presentation = .interfaceOverview
        overview.configure(
            document: octagonDocument,
            traits: .init(userInterfaceStyle: .light),
            animated: false
        )
        overview.setNeedsLayout()
        overview.layoutIfNeeded()

        for identifier in [
            "interface.preview.messageAvatar.overview.0",
            "interface.preview.messageAvatar.overview.2"
        ] {
            let avatar = try XCTUnwrap(
                descendant(in: overview, accessibilityIdentifier: identifier) as? UIImageView
            )
            XCTAssertEqual(
                avatar.mask?.accessibilityIdentifier,
                "interface.preview.avatarMask.octagon",
                "\(identifier) must use the selected avatar mask"
            )
        }
        let navigationAvatar = try XCTUnwrap(
            descendant(
                in: overview,
                accessibilityIdentifier: "interface.preview.navigation.avatar"
            ) as? UIImageView
        )
        XCTAssertEqual(navigationAvatar.mask?.accessibilityIdentifier, "interface.preview.avatarMask.circle")
        XCTAssertNotNil(
            descendant(
                in: overview,
                accessibilityIdentifier: "interface.preview.navigation.avatarSlot"
            )
        )
        XCTAssertNil(
            descendant(
                in: overview,
                accessibilityIdentifier: "interface.preview.navigation.avatarRing"
            )
        )

        let chatList = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        chatList.showsChatList = true
        chatList.configure(
            document: octagonDocument,
            traits: .init(userInterfaceStyle: .light),
            animated: false
        )
        chatList.setNeedsLayout()
        chatList.layoutIfNeeded()
        for index in 0..<4 {
            let avatar = try XCTUnwrap(
                descendant(
                    in: chatList,
                    accessibilityIdentifier: "interface.preview.chatListAvatar.\(index)"
                ) as? UIImageView
            )
            XCTAssertEqual(avatar.mask?.accessibilityIdentifier, "interface.preview.avatarMask.octagon")
        }

        var squareDocument = octagonDocument
        squareDocument.profile.avatarMask = .square
        overview.configure(
            document: squareDocument,
            traits: .init(userInterfaceStyle: .light),
            animated: false
        )
        chatList.configure(
            document: squareDocument,
            traits: .init(userInterfaceStyle: .light),
            animated: false
        )
        overview.setNeedsLayout()
        overview.layoutIfNeeded()
        chatList.setNeedsLayout()
        chatList.layoutIfNeeded()

        let squareNavigationAvatar = try XCTUnwrap(
            descendant(
                in: overview,
                accessibilityIdentifier: "interface.preview.navigation.avatar"
            ) as? UIImageView
        )
        let squareChatListAvatar = try XCTUnwrap(
            descendant(
                in: chatList,
                accessibilityIdentifier: "interface.preview.chatListAvatar.0"
            ) as? UIImageView
        )
        XCTAssertNil(squareChatListAvatar.mask)
        XCTAssertEqual(squareNavigationAvatar.mask?.accessibilityIdentifier, "interface.preview.avatarMask.circle")
        XCTAssertEqual(squareChatListAvatar.layer.cornerRadius, 0, accuracy: 0.5)
    }

    @MainActor
    func testRootInterfacePreviewNavigationUsesGlassBackAndPlainChatAvatar() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let overviewCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let preview = try XCTUnwrap(
            descendant(in: overviewCell, accessibilityIdentifier: "interface.preview") as? AppearancePreviewView
        )
        let navigation = try XCTUnwrap(
            descendant(in: preview, accessibilityIdentifier: "interface.preview.navigation")
        )
        let backGlass = try XCTUnwrap(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.backGlass") as? UIVisualEffectView
        )
        let online = try XCTUnwrap(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.online") as? UILabel
        )
        let avatarSlot = try XCTUnwrap(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.avatarSlot")
        )

        XCTAssertEqual(navigation.backgroundColor, .clear)
        XCTAssertNotNil(backGlass.effect)
        XCTAssertEqual(online.text, "Online")
        XCTAssertFalse(avatarSlot is UIVisualEffectView)
        XCTAssertNil(
            descendant(in: navigation, accessibilityIdentifier: "interface.preview.navigation.avatarRing")
        )
    }

    @MainActor
    func testApplicationColorSwatchShowsSelectedStateAndUpdatesTintPreview() throws {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let controller = AppearanceAccentViewController(document: document)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let initiallySelectedSwatch = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.accent.swatch.0"
            ) as? UIControl
        )
        let swatch = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.accent.swatch.4"
            ) as? UIControl
        )

        XCTAssertEqual(initiallySelectedSwatch.accessibilityValue, "Selected")
        XCTAssertTrue(initiallySelectedSwatch.accessibilityTraits.contains(.selected))
        swatch.sendActions(for: .touchUpInside)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let preview = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.tint.preview"
            )
        )
        let navigationAction = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.tint.preview.navigationAction"
            ) as? UIButton
        )
        let modeControl = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.tint.preview.mode"
            ) as? UISegmentedControl
        )
        let tintSwitch = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.tint.preview.switch"
            ) as? UISwitch
        )
        let slider = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.tint.preview.slider"
            ) as? UISlider
        )
        let progress = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.tint.preview.progress"
            ) as? UIProgressView
        )
        let selectedColor = try XCTUnwrap(AppearanceColor(hex: "#D94B54"))

        XCTAssertEqual(swatch.accessibilityValue, "Selected")
        XCTAssertTrue(swatch.accessibilityTraits.contains(.selected))
        XCTAssertEqual(navigationAction.tintColor, selectedColor.uiColor)
        XCTAssertEqual(modeControl.tintColor, selectedColor.uiColor)
        XCTAssertEqual(tintSwitch.onTintColor, selectedColor.uiColor)
        XCTAssertEqual(slider.minimumTrackTintColor, selectedColor.uiColor)
        XCTAssertEqual(progress.progressTintColor, selectedColor.uiColor)
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.preview.message.outgoing"))
        XCTAssertNotNil(descendant(in: controller.view, accessibilityIdentifier: "interface.accent.custom"))
    }

    @MainActor
    func testCustomApplicationColorQuickColorsStayCircular() throws {
        let controller = AppearanceCustomAccentColorViewController(initialColor: UIColor.systemBlue)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let quickColor = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.accent.custom.quickColor.6"
            ) as? UIControl
        )

        XCTAssertEqual(quickColor.bounds.width, 30, accuracy: 0.01)
        XCTAssertEqual(quickColor.bounds.height, 30, accuracy: 0.01)
        XCTAssertEqual(quickColor.layer.cornerRadius, 15, accuracy: 0.01)
    }

    @MainActor
    func testCustomApplicationColorUsesColorGridWithLeftDismissAndRightSave() throws {
        let initial = AppearanceColor.systemBlue
        let controller = AppearanceCustomAccentColorViewController(initialColor: initial.uiColor)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let grid = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.accent.custom.grid"
            ) as? UICollectionView
        )
        var savedColor: AppearanceColor?
        controller.onSave = { savedColor = $0 }
        let preview = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.accent.custom.preview"
            )
        )
        let selected = try XCTUnwrap(AppearanceColor(hex: "#D94B54"))
        controller.select(color: selected)
        controller.saveSelectedColor()

        XCTAssertEqual(
            navigationController.topViewController?.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
            "interface.accent.custom.cancel"
        )
        XCTAssertEqual(
            navigationController.topViewController?.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "interface.accent.custom.save"
        )
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 120)
        XCTAssertEqual(preview.backgroundColor, selected.uiColor)
        let layout = try XCTUnwrap(grid.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.minimumInteritemSpacing, 0)
        XCTAssertEqual(layout.minimumLineSpacing, 0)
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.accent.custom.hue"))
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.accent.custom.eyedropper"))
        XCTAssertEqual(savedColor, selected)
    }

    @MainActor
    func testApplicationColorCustomSelectionPublishesToRootDraftWithStandardBack() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let originalAccent = coordinator.document.profile.accentOverride
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 3, section: 1))
        let accentEditor = try XCTUnwrap(
            navigationController.topViewController as? AppearanceAccentViewController
        )
        accentEditor.loadViewIfNeeded()
        let customButton = try XCTUnwrap(
            descendant(in: accentEditor.view, accessibilityIdentifier: "interface.accent.custom") as? UIButton
        )

        customButton.sendActions(for: .touchUpInside)

        let picker = try XCTUnwrap(
            navigationController.topViewController as? AppearanceCustomAccentColorViewController
        )
        picker.loadViewIfNeeded()
        XCTAssertNil(picker.navigationItem.leftBarButtonItem)
        XCTAssertNil(picker.navigationItem.rightBarButtonItem)

        let selected = try XCTUnwrap(AppearanceColor(hex: "#D94B54"))
        picker.select(color: selected)

        XCTAssertEqual(coordinator.document.profile.accentOverride, originalAccent)
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "interface.settings.save"
        )
        XCTAssertEqual(navigationController.viewControllers.count, 3)
    }

    @MainActor
    func testThemePreviewProvidesFullConversationAndProductionChatListPages() throws {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let theme = try XCTUnwrap(AppearanceThemeCatalog.builtInThemes.first)
        let controller = AppearanceThemePreviewViewController(document: document, theme: theme)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let pages = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themePreview.pages"
            ) as? UIScrollView
        )
        let pageControl = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themePreview.pageControl"
            ) as? UIPageControl
        )
        let applyButton = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themePreview.apply"
            ) as? UIButton
        )
        let applyGlass = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themePreview.applyGlass"
            ) as? UIVisualEffectView
        )
        let textMessageIDs = [
            "opening", "answer", "question", "confirmation", "reply", "voice", "quoted", "closing"
        ]
        let textCells = try textMessageIDs.map { identifier in
            try XCTUnwrap(
                descendant(
                    in: controller.view,
                    accessibilityIdentifier: "interface.themePreview.chat.message.\(identifier)"
                ) as? TextMessageCell
            )
        }
        let chatRows = try (0..<7).map { index in
            try XCTUnwrap(
                descendant(
                    in: controller.view,
                    accessibilityIdentifier: "interface.themePreview.chats.row.\(index)"
                ) as? ChatListTableViewCell
            )
        }
        let voiceCell = try XCTUnwrap(
            textCells.first {
                $0.accessibilityIdentifier == "interface.themePreview.chat.message.voice"
            }
        )
        let quotedCell = try XCTUnwrap(
            textCells.first {
                $0.accessibilityIdentifier == "interface.themePreview.chat.message.quoted"
            }
        )

        XCTAssertTrue(pages.isPagingEnabled)
        XCTAssertEqual(pageControl.numberOfPages, 2)
        let pagesFrame = pages.convert(pages.bounds, to: controller.view)
        let applyFrame = applyButton.convert(applyButton.bounds, to: controller.view)
        XCTAssertEqual(pagesFrame.minX, controller.view.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(pagesFrame.maxX, controller.view.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(pagesFrame.minY, controller.view.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(pagesFrame.maxY, controller.view.bounds.maxY, accuracy: 0.5)
        XCTAssertTrue(pagesFrame.intersects(applyFrame))
        XCTAssertEqual(applyGlass.frame, applyButton.frame)
        XCTAssertEqual(applyButton.tintColor, UIColor.label)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(applyGlass.effect is UIGlassEffect)
        } else {
            XCTAssertTrue(applyGlass.effect is UIBlurEffect)
        }
        XCTAssertEqual(textCells.count, 8)
        XCTAssertEqual(voiceCell.audiosView.views.count, 1)
        let voiceView = try XCTUnwrap(voiceCell.audiosView.views.first)
        voiceView.setNeedsLayout()
        voiceView.layoutIfNeeded()
        XCTAssertGreaterThan(voiceView.bounds.width, 0)
        XCTAssertGreaterThan(voiceView.waveform.frame.width, 0)
        XCTAssertGreaterThanOrEqual(
            voiceView.waveform.frame.minX,
            voiceView.iconButton.frame.maxX
        )
        XCTAssertLessThanOrEqual(
            voiceView.waveform.frame.maxX,
            voiceView.bounds.maxX + 0.5
        )
        XCTAssertLessThanOrEqual(
            voiceView.durationLabel.frame.maxX,
            voiceView.bounds.maxX + 0.5
        )
        XCTAssertEqual(quotedCell.forwardsContainer.inlineViews.count, 1)
        XCTAssertEqual(quotedCell.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(
            quotedCell.frame.height,
            quotedCell.superview?.bounds.height ?? 0,
            accuracy: 0.5
        )
        let forwardedView = try XCTUnwrap(quotedCell.forwardsContainer.inlineViews.first)
        XCTAssertTrue(forwardedView.timeMarker.isHidden)
        XCTAssertGreaterThan(forwardedView.authorLabel.frame.height, 0)
        XCTAssertGreaterThan(forwardedView.messageLabel.frame.height, 0)
        XCTAssertGreaterThanOrEqual(
            forwardedView.messageLabel.frame.minY,
            forwardedView.authorLabel.frame.maxY - 0.5
        )
        XCTAssertLessThanOrEqual(
            forwardedView.timeMarker.frame.maxX,
            forwardedView.containerView.bounds.maxX + 0.5
        )
        XCTAssertEqual(chatRows.count, 7)
        XCTAssertTrue(chatRows.allSatisfy(\.accountIndicator.isHidden))
        XCTAssertEqual(chatRows.first?.usernameLabel.text, "Alicia Torreaux")
        XCTAssertEqual(chatRows.last?.usernameLabel.text, "Jennie Alpha")
    }

    @MainActor
    func testThemeEditorUsesNavigationControllerBackButton() {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let controller = AppearanceThemeEditorViewController(
            document: document,
            theme: AppearanceThemeCatalog.builtInThemes[0]
        )
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.pushViewController(controller, animated: false)

        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.navigationItem.hidesBackButton)
        XCTAssertNil(controller.navigationItem.leftBarButtonItem)
    }

    @MainActor
    func testThemeEditorUsesApplicationColorGridForEveryAvailableColorStep() throws {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        var theme = AppearanceThemeCatalog.builtInThemes[0]
        let messageColor = try XCTUnwrap(AppearanceColor(hex: "#56A8D7"))
        theme.lightPalette.outgoingBubble = messageColor
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        for tabIndex in 0..<3 {
            let controller = AppearanceThemeEditorViewController(
                document: document,
                theme: theme
            )
            let navigationController = UINavigationController(rootViewController: UIViewController())
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = navigationController
            navigationController.loadViewIfNeeded()
            navigationController.view.frame = window.bounds
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            navigationController.pushViewController(controller, animated: false)
            controller.loadViewIfNeeded()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            XCTAssertNotNil(controller.view.window)
            let tabs = try XCTUnwrap(firstSubview(of: UISegmentedControl.self, in: controller.view))
            let changeButton = try XCTUnwrap(
                descendant(in: controller.view, accessibilityIdentifier: "interface.themeEditor.change") as? UIButton
            )

            guard tabIndex < tabs.numberOfSegments else { continue }
            tabs.selectedSegmentIndex = tabIndex
            tabs.sendActions(for: .valueChanged)
            changeButton.sendActions(for: .touchUpInside)

            let pickerNavigationController = try XCTUnwrap(
                controller.presentedViewController as? UINavigationController,
                "Theme-editor step \(tabIndex) must open the shared colour-picker sheet."
            )
            XCTAssertTrue(
                pickerNavigationController.topViewController is AppearanceCustomAccentColorViewController,
                "Theme-editor step \(tabIndex) must use the Application Color controller."
            )
            XCTAssertFalse(controller.presentedViewController is UIColorPickerViewController)
            if tabIndex == 2 {
                let selectedColorPreview = try XCTUnwrap(
                    descendant(
                        in: pickerNavigationController.topViewController!.view,
                        accessibilityIdentifier: "interface.accent.custom.preview"
                    ) as? UIView
                )
                XCTAssertEqual(selectedColorPreview.backgroundColor, messageColor.uiColor)
            }
            controller.dismiss(animated: false)
        }
    }

    @MainActor
    func testThemeEditorPreviewShowsAllEditableChatSurfacesAndWallpaperChoices() throws {
        var theme = AppearanceThemeCatalog.builtInThemes[0]
        theme.id = "custom.theme-editor-preview"
        theme.name = "Preview"
        theme.isBuiltIn = false
        theme.lightPalette.accent = try XCTUnwrap(AppearanceColor(hex: "#D94B54"))
        theme.lightPalette.replyAccent = theme.lightPalette.accent
        let counterpartyBubble = try XCTUnwrap(AppearanceColor(hex: "#6AB89D"))
        theme.lightPalette.outgoingBubble = counterpartyBubble
        var document = AppearanceSettingsDocument(
            profile: .default(accent: .systemBlue),
            customThemes: [theme]
        )
        document.profile.apply(theme: theme)

        let controller = AppearanceThemeEditorViewController(document: document, theme: theme)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let preview = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themeEditor.preview"
            )
        )
        let navigation = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themeEditor.preview.navigation"
            )
        )
        let online = try XCTUnwrap(
            descendant(
                in: navigation,
                accessibilityIdentifier: "interface.themeEditor.preview.navigation.online"
            ) as? UILabel
        )
        let wallpaper = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themeEditor.preview.background"
            ) as? ChatBackgroundBackdropView
        )
        let date = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themeEditor.preview.date"
            ) as? UILabel
        )
        let textCells = try (0..<3).map { index in
            try XCTUnwrap(
                descendant(
                    in: preview,
                    accessibilityIdentifier: "interface.themePreview.chat.message.editor.text.\(index)"
                ) as? TextMessageCell
            )
        }
        let voice = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.editor.voice"
            ) as? TextMessageCell
        )
        let wallpaperButton = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.themeEditor.wallpaper"
            ) as? UIButton
        )

        XCTAssertEqual(online.textColor, theme.lightPalette.accent.uiColor)
        XCTAssertTrue(wallpaper.hasVisibleWallpaperImage)
        XCTAssertEqual(wallpaper.representedWallpaper, theme.wallpaper)
        XCTAssertEqual(date.backgroundColor, UIColor.black.withAlphaComponent(0.2))
        XCTAssertNotEqual(date.backgroundColor, theme.lightPalette.accent.uiColor)
        XCTAssertNil(firstSubview(of: UIScrollView.self, in: preview))
        XCTAssertEqual(textCells.count, 3)
        XCTAssertEqual(
            textCells[0].messageContainerView.bubble.backgroundColor,
            counterpartyBubble.uiColor
        )
        let ownBubble = try XCTUnwrap(textCells[1].messageContainerView.bubble.backgroundColor)
        var ownRed: CGFloat = 0
        var ownGreen: CGFloat = 0
        var ownBlue: CGFloat = 0
        var ownAlpha: CGFloat = 0
        XCTAssertTrue(ownBubble.getRed(&ownRed, green: &ownGreen, blue: &ownBlue, alpha: &ownAlpha))
        XCTAssertEqual(ownRed, 1, accuracy: 0.001)
        XCTAssertEqual(ownGreen, 1, accuracy: 0.001)
        XCTAssertEqual(ownBlue, 1, accuracy: 0.001)
        XCTAssertEqual(ownAlpha, 1, accuracy: 0.001)
        XCTAssertEqual(voice.audiosView.views.count, 1)
        let voiceView = try XCTUnwrap(voice.audiosView.views.first)
        XCTAssertEqual(voiceView.iconButton.backgroundColor, theme.lightPalette.accent.uiColor)
        XCTAssertEqual(voiceView.waveform.gradientStartColor, theme.lightPalette.accent.uiColor)
        XCTAssertEqual(voiceView.waveform.gradientEndColor, theme.lightPalette.accent.uiColor)
        XCTAssertEqual(
            voiceView.waveform.barBackgroundFillColor,
            theme.lightPalette.accent.uiColor.withAlphaComponent(0.24)
        )
        XCTAssertEqual(
            voiceView.durationLabel.textColor,
            theme.lightPalette.accent.uiColor.withAlphaComponent(0.86)
        )
        XCTAssertNil(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.themePreview.chat.message.editor.image"
            )
        )
        XCTAssertEqual(wallpaperButton.configuration?.title, "Choose Wallpaper")

        let firstTextContainer = textCells[0].messageContainerView.convert(
            textCells[0].messageContainerView.bounds,
            to: preview
        )
        let secondTextContainer = textCells[1].messageContainerView.convert(
            textCells[1].messageContainerView.bounds,
            to: preview
        )
        XCTAssertEqual(firstTextContainer.minX, preview.bounds.minX + 4, accuracy: 0.5)
        XCTAssertEqual(secondTextContainer.maxX, preview.bounds.maxX - 4, accuracy: 0.5)
        XCTAssertEqual(
            secondTextContainer.minY - firstTextContainer.maxY,
            8,
            accuracy: 0.5
        )
        let voiceFrame = voice.convert(voice.bounds, to: preview)
        XCTAssertLessThanOrEqual(voiceFrame.maxY, preview.bounds.maxY - 8 + 0.5)

        var selectedWallpaper: AppearanceWallpaper?
        let wallpaperPicker = AppearanceThemeWallpaperPickerViewController(
            document: document,
            theme: theme
        ) { selectedWallpaper = $0 }
        wallpaperPicker.loadViewIfNeeded()
        wallpaperPicker.view.frame = controller.view.bounds
        wallpaperPicker.view.setNeedsLayout()
        wallpaperPicker.view.layoutIfNeeded()
        let grid = try XCTUnwrap(
            descendant(
                in: wallpaperPicker.view,
                accessibilityIdentifier: "interface.themeEditor.wallpaperPicker.grid"
            ) as? UICollectionView
        )
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 8)
        wallpaperPicker.collectionView(grid, didSelectItemAt: IndexPath(item: 1, section: 0))
        XCTAssertEqual(selectedWallpaper, .builtIn(name: "Honeycomb"))
    }

    func testPremiumPolicyMatchesExactFreeMatrix() {
        let free = AppearancePremiumPolicy(isEntitled: false, subscriptionsEnabled: true)
        let paid = AppearancePremiumPolicy(isEntitled: true, subscriptionsEnabled: true)

        XCTAssertEqual(Set(free.visibleBubbleStyles), Set(AppearanceBubbleStyle.allCases))
        XCTAssertEqual(
            AppearanceBubbleStyle.freeCases,
            [.noTail, .smooth, .bubble, .bubbles, .curvy]
        )
        XCTAssertEqual(
            AppearanceBubbleStyle.premiumCases,
            [.stripes, .transparent, .wedge]
        )
        XCTAssertTrue(free.canSelect(.noTail, currentlyApplied: .wedge))
        XCTAssertTrue(free.canSelect(.curvy, currentlyApplied: .noTail))
        XCTAssertTrue(free.canSelect(.stripes, currentlyApplied: .noTail))
        XCTAssertTrue(free.canSelect(.wedge, currentlyApplied: .noTail))
        XCTAssertTrue(free.canSelect(.wedge, currentlyApplied: .wedge))
        XCTAssertTrue(free.canSelect(.star, currentlyApplied: .circle))
        XCTAssertTrue(paid.canSelect(.star, currentlyApplied: .circle))
        XCTAssertTrue(paid.canSelect(.transparent, currentlyApplied: .noTail))
        XCTAssertTrue(free.requiresPurchaseToCommit(.stripes, currentlyApplied: .noTail))
        XCTAssertTrue(free.requiresPurchaseToCommit(.star, currentlyApplied: .circle))
        XCTAssertFalse(free.requiresPurchaseToCommit(.wedge, currentlyApplied: .wedge))
        XCTAssertFalse(free.requiresPurchaseToCommit(.octagon, currentlyApplied: .octagon))
        XCTAssertFalse(paid.requiresPurchaseToCommit(.transparent, currentlyApplied: .noTail))
    }

    func testDisabledSubscriptionsHidePremiumOptions() {
        let policy = AppearancePremiumPolicy(isEntitled: false, subscriptionsEnabled: false)

        XCTAssertEqual(Set(policy.visibleBubbleStyles), Set(AppearanceBubbleStyle.freeCases))
        XCTAssertEqual(Set(policy.visibleAvatarMasks), Set(AppearanceAvatarMask.freeCases))
    }

    @MainActor
    func testRootInterfaceDraftDefersPremiumChoicesUntilPurchaseAndCanBeCancelled() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let originalProfile = coordinator.document.profile
        var paywallPresentationCount = 0
        let controller = InterfaceSettingsViewController(
            appearanceCoordinator: coordinator,
            entitlementProvider: AppearanceEntitlementStub(
                hasActiveAppearanceEntitlement: false,
                areSubscriptionsEnabled: true
            ),
            paywallPresenter: { _ in
                paywallPresentationCount += 1
                return true
            }
        )
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 1, section: 1))
        let bubbleEditor = try XCTUnwrap(
            navigationController.topViewController as? AppearanceBubbleViewController
        )
        bubbleEditor.loadViewIfNeeded()
        bubbleEditor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        bubbleEditor.view.setNeedsLayout()
        bubbleEditor.view.layoutIfNeeded()
        let premiumBubble = try XCTUnwrap(
            descendant(
                in: bubbleEditor.view,
                accessibilityIdentifier: "interface.bubble.stripes"
            ) as? UIControl
        )
        XCTAssertEqual(premiumBubble.accessibilityValue, "Premium")
        premiumBubble.sendActions(for: .touchUpInside)
        XCTAssertNil(bubbleEditor.navigationItem.leftBarButtonItem)
        XCTAssertNil(bubbleEditor.navigationItem.rightBarButtonItem)
        XCTAssertEqual(
            controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier,
            "interface.settings.cancel"
        )
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "interface.settings.save"
        )
        navigationController.popViewController(animated: false)

        XCTAssertTrue(navigationController.topViewController === controller)
        XCTAssertEqual(coordinator.document.profile, originalProfile)

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 4, section: 1))
        let avatarEditor = try XCTUnwrap(
            navigationController.topViewController as? AppearanceAvatarViewController
        )
        avatarEditor.loadViewIfNeeded()
        avatarEditor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        avatarEditor.view.setNeedsLayout()
        avatarEditor.view.layoutIfNeeded()
        let premiumAvatar = try XCTUnwrap(
            descendant(
                in: avatarEditor.view,
                accessibilityIdentifier: "interface.avatar.star"
            ) as? UIControl
        )
        XCTAssertEqual(premiumAvatar.accessibilityValue, "Premium")
        premiumAvatar.sendActions(for: .touchUpInside)
        XCTAssertNil(avatarEditor.navigationItem.leftBarButtonItem)
        XCTAssertNil(avatarEditor.navigationItem.rightBarButtonItem)
        navigationController.popViewController(animated: false)

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.numberOfSections(in: tableView), 3)
        XCTAssertEqual(controller.tableView(tableView, titleForHeaderInSection: 2), "Appearance")
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.settings.premiumUpsell"))
        let subscribePremium = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.settings.subscribePremium"
            ) as? UIButton
        )
        XCTAssertEqual(subscribePremium.title(for: .normal), "Unlock premium style")
        XCTAssertEqual(subscribePremium.bounds.height, 50, accuracy: 0.01)
        XCTAssertEqual(subscribePremium.layer.cornerRadius, 25, accuracy: 0.01)
        XCTAssertTrue(subscribePremium.layer.sublayers?.contains(where: { $0 is CAGradientLayer }) ?? false)
        XCTAssertFalse(subscribePremium.clipsToBounds)
        XCTAssertEqual(subscribePremium.layer.shadowOpacity, 0.12, accuracy: 0.001)
        XCTAssertEqual(subscribePremium.layer.shadowRadius, 8, accuracy: 0.01)
        XCTAssertEqual(subscribePremium.layer.shadowOffset, CGSize(width: 0, height: 3))
        XCTAssertNotNil(subscribePremium.layer.shadowPath)
        XCTAssertTrue(subscribePremium.superview === controller.view)
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.settings.premiumBottomBar"))
        XCTAssertEqual(tableView.frame.maxY, controller.view.bounds.maxY, accuracy: 0.01)
        XCTAssertLessThan(subscribePremium.frame.minY, tableView.frame.maxY)
        XCTAssertGreaterThan(tableView.contentInset.bottom, 0)
        XCTAssertGreaterThan(tableView.verticalScrollIndicatorInsets.bottom, 0)
        subscribePremium.sendActions(for: .touchUpInside)
        XCTAssertEqual(paywallPresentationCount, 1)

        controller.saveTapped()

        XCTAssertEqual(paywallPresentationCount, 2)
        XCTAssertEqual(coordinator.document.profile, originalProfile)

        controller.cancelTapped()

        XCTAssertTrue(navigationController.topViewController === navigationController.viewControllers.first)
        XCTAssertEqual(coordinator.document.profile, originalProfile)
    }

    @MainActor
    func testRootInterfaceCheckmarkCommitsFreeDraft() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(
            appearanceCoordinator: coordinator,
            entitlementProvider: AppearanceEntitlementStub(
                hasActiveAppearanceEntitlement: false,
                areSubscriptionsEnabled: true
            )
        )
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 1, section: 1))
        let bubbleEditor = try XCTUnwrap(
            navigationController.topViewController as? AppearanceBubbleViewController
        )
        bubbleEditor.loadViewIfNeeded()
        let targetBubble: AppearanceBubbleStyle = coordinator.document.profile.bubbleStyle == .smooth
            ? .curvy
            : .smooth
        let freeBubble = try XCTUnwrap(
            descendant(
                in: bubbleEditor.view,
                accessibilityIdentifier: "interface.bubble.\(targetBubble.rawValue)"
            ) as? UIControl
        )
        freeBubble.sendActions(for: .touchUpInside)
        XCTAssertNil(bubbleEditor.navigationItem.rightBarButtonItem)
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier,
            "interface.settings.save"
        )
        navigationController.popViewController(animated: false)

        controller.saveTapped()

        XCTAssertEqual(coordinator.document.profile.bubbleStyle, targetBubble)
        XCTAssertTrue(navigationController.topViewController === navigationController.viewControllers.first)
    }

    @MainActor
    func testBubbleGalleryUsesFullChatMessageLayoutCanvasWithoutAvatarsAndKeepsPremiumStatusLockStableAcrossRadiusChanges() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .builtIn(name: "Honeycomb")
        document.profile.bubbleStyle = .smooth
        document.profile.avatarMask = .octagon
        document.profile.textSize = .points21
        let gallery = AppearanceBubbleStyleGalleryView(frame: CGRect(x: 0, y: 0, width: 360, height: 680))
        gallery.configure(
            document: document,
            traits: .init(userInterfaceStyle: .light),
            styles: AppearanceBubbleStyle.allCases,
            selectedStyle: .smooth,
            lockedStyles: [.stripes]
        )
        gallery.setNeedsLayout()
        gallery.layoutIfNeeded()

        let backdrop = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubbles.background"
            ) as? ChatBackgroundBackdropView
        )
        XCTAssertTrue(backdrop.hasVisibleWallpaperImage)
        let expectedSampleTexts: [AppearanceBubbleStyle: String] = [
            .noTail: "Can we meet after lunch today?",
            .smooth: "The train leaves in twenty minutes.",
            .bubble: "I'll send the photo when I get home.",
            .bubbles: "The coffee place opens at eight.",
            .curvy: "We can talk again tomorrow morning.",
            .stripes: "I saved the address in the notes.",
            .transparent: "Let me know when you arrive home.",
            .wedge: "That works for me, thanks for checking."
        ]

        for style in AppearanceBubbleStyle.allCases {
            XCTAssertNotNil(
                descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.\(style.rawValue)"
                )
            )
            XCTAssertNotNil(
                descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.message.\(style.rawValue)"
                )
            )
            let host = try XCTUnwrap(
                descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.message.\(style.rawValue)"
                )
            )
            let cell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: host))
            XCTAssertGreaterThan(
                cell.messageContainerView.frame.midX,
                cell.bounds.midX,
                "\(style.displayName) must remain an outgoing, right-aligned sample"
            )
            XCTAssertNil(
                descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.avatar.\(style.rawValue)"
                ),
                "\(style.displayName) must not add an avatar that ChatViewController does not show"
            )
            let messageText = try XCTUnwrap(cell.messageLabel.attributedText)
            let messageFont = try XCTUnwrap(
                messageText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            )
            XCTAssertEqual(messageText.string, try XCTUnwrap(expectedSampleTexts[style]))
            XCTAssertFalse(
                messageText.string.contains("\n"),
                "\(style.displayName) must naturally wrap rather than forcing a line break"
            )
            XCTAssertEqual(
                cell.bounds.width,
                gallery.bounds.width,
                accuracy: 0.5,
                "\(style.displayName) must be measured on the full ChatViewController-width canvas"
            )
            XCTAssertGreaterThanOrEqual(
                cell.messageLabel.bounds.height,
                ceil(messageFont.lineHeight * 2) - 1,
                "\(style.displayName) sample must naturally occupy two visual lines at 21 pt"
            )
            XCTAssertLessThanOrEqual(
                cell.messageLabel.bounds.height,
                ceil(messageFont.lineHeight * 2) + 1,
                "\(style.displayName) sample must not wrap beyond two visual lines at 21 pt"
            )
        }

        let messageFrames = try AppearanceBubbleStyle.allCases.map { style -> CGRect in
            let messageHost = try XCTUnwrap(
                descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.message.\(style.rawValue)"
                )
            )
            let cell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: messageHost))
            return cell.messageContainerView.convert(
                cell.messageContainerView.bounds,
                to: gallery
            )
        }
        let messageGaps = zip(messageFrames, messageFrames.dropFirst()).map { previous, next in
            next.minY - previous.maxY
        }
        for gap in messageGaps {
            XCTAssertEqual(gap, 8, accuracy: 0.5)
        }
        for frame in messageFrames {
            XCTAssertEqual(
                frame.maxX,
                gallery.bounds.maxX - 4,
                accuracy: 0.5,
                "Outgoing gallery messages must use ChatViewController's 4 pt trailing inset"
            )
        }

        let selectedIndicator = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.smooth.selection"
            )
        )
        XCTAssertEqual(selectedIndicator.accessibilityValue, "Selected")
        XCTAssertEqual(selectedIndicator.layer.cornerRadius, selectedIndicator.bounds.width / 2, accuracy: 0.5)
        var selectedStyleFromWholeRow: AppearanceBubbleStyle?
        gallery.onStyleSelected = { selectedStyleFromWholeRow = $0 }
        let smoothRow = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.smooth"
            ) as? UIControl
        )
        smoothRow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selectedStyleFromWholeRow, .smooth)
        let selectedCellHost = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.message.smooth"
            )
        )
        let selectedCell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: selectedCellHost))
        XCTAssertFalse(selectedCell.timeMarker.indicatorView.isHidden)
        let selectedIndicatorFrame = selectedIndicator.convert(selectedIndicator.bounds, to: gallery)
        let selectedContainerFrame = selectedCell.messageContainerView.convert(
            selectedCell.messageContainerView.bounds,
            to: gallery
        )
        XCTAssertEqual(
            selectedIndicatorFrame.midY,
            selectedContainerFrame.midY,
            accuracy: 0.5,
            "The left selection control must align to this message container, not the entire row"
        )
        XCTAssertEqual(
            descendant(
                    in: gallery,
                    accessibilityIdentifier: "interface.bubble.stripes"
                )?.accessibilityValue,
            "Premium"
        )
        let premiumHost = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.message.stripes"
            )
        )
        let premiumCell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: premiumHost))
        let premiumLock = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.lock.stripes"
            ) as? UIImageView
        )
        XCTAssertTrue(premiumCell.timeMarker.indicatorView.isHidden)
        XCTAssertEqual(premiumCell.timeMarker.textLabel.attributedText?.string, "Premium")
        let regularTimeFont = try XCTUnwrap(
            selectedCell.timeMarker.textLabel.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )
        let premiumTimeFont = try XCTUnwrap(
            premiumCell.timeMarker.textLabel.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )
        XCTAssertEqual(premiumTimeFont.fontName, regularTimeFont.fontName)
        XCTAssertEqual(premiumTimeFont.pointSize, regularTimeFont.pointSize)
        let premiumLockFrame = premiumLock.convert(premiumLock.bounds, to: premiumCell.timeMarker)
        XCTAssertEqual(premiumLockFrame, premiumCell.timeMarker.indicatorView.frame)
        XCTAssertEqual(premiumLock.tintColor, .systemPurple)

        let cellBeforeRadiusChange = selectedCell
        document.profile.bubbleRadius = 16
        gallery.updateRadius(document: document, traits: .init(userInterfaceStyle: .light))
        gallery.setNeedsLayout()
        gallery.layoutIfNeeded()
        let cellAfterRadiusChange = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: selectedCellHost))
        XCTAssertTrue(cellBeforeRadiusChange === cellAfterRadiusChange)
    }

    @MainActor
    func testBubbleGalleryDoesNotAddAFixedRowHeightToTheProductionMessageLayout() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.textSize = .points14
        let gallery = AppearanceBubbleStyleGalleryView(frame: CGRect(x: 0, y: 0, width: 360, height: 680))
        gallery.configure(
            document: document,
            traits: .init(userInterfaceStyle: .light),
            styles: AppearanceBubbleStyle.allCases,
            selectedStyle: .smooth,
            lockedStyles: []
        )
        gallery.setNeedsLayout()
        gallery.layoutIfNeeded()

        let host = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.message.\(AppearanceBubbleStyle.noTail.rawValue)"
            )
        )
        let cell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: host))

        XCTAssertLessThan(
            cell.bounds.height,
            64,
            "The compact production message establishes the regression fixture"
        )
        XCTAssertEqual(
            host.bounds.height,
            cell.bounds.height,
            accuracy: 0.5,
            "The gallery host must use the production cell's measured height without a fixed row minimum"
        )
    }

    @MainActor
    func testBubbleEditorDefersPremiumPaywallUntilSave() throws {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        var paywallPresentationCount = 0
        let controller = AppearanceBubbleViewController(
            document: document,
            entitlementProvider: AppearanceEntitlementStub(
                hasActiveAppearanceEntitlement: false,
                areSubscriptionsEnabled: true
            ),
            paywallPresenter: { _ in
                paywallPresentationCount += 1
                return true
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let premiumRow = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubble.stripes"
            ) as? UIControl
        )
        premiumRow.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.draft.profile.bubbleStyle, .stripes)
        XCTAssertEqual(paywallPresentationCount, 0)

        controller.setTapped()

        XCTAssertEqual(paywallPresentationCount, 1)
        XCTAssertEqual(controller.document.profile.bubbleStyle, document.profile.bubbleStyle)
        XCTAssertTrue(controller.draft.isDirty)
    }

    @MainActor
    func testAvatarEditorDefersPremiumPaywallUntilSave() throws {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        var paywallPresentationCount = 0
        let controller = AppearanceAvatarViewController(
            document: document,
            entitlementProvider: AppearanceEntitlementStub(
                hasActiveAppearanceEntitlement: false,
                areSubscriptionsEnabled: true
            ),
            paywallPresenter: { _ in
                paywallPresentationCount += 1
                return true
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let premiumRow = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.avatar.star"
            ) as? UIControl
        )
        XCTAssertEqual(premiumRow.accessibilityValue, "Premium")
        premiumRow.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.draft.profile.avatarMask, .star)
        XCTAssertEqual(paywallPresentationCount, 0)

        controller.setTapped()

        XCTAssertEqual(paywallPresentationCount, 1)
        XCTAssertEqual(controller.document.profile.avatarMask, document.profile.avatarMask)
        XCTAssertTrue(controller.draft.isDirty)
    }

    @MainActor
    func testBubbleEditorUsesInsetGroupedTableWithPaddedGalleryAndRadiusSections() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .builtIn(name: "Honeycomb")
        document.profile.textSize = .points21
        document.profile.bubbleRadius = 8
        let controller = AppearanceBubbleViewController(document: document)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let settleLayout = expectation(description: "bubble gallery self-sizing settles")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                settleLayout.fulfill()
            }
        }
        wait(for: [settleLayout], timeout: 1)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let tableView = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.table"
            ) as? UITableView
        )
        let galleryBackdrop = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.background"
            ) as? ChatBackgroundBackdropView
        )
        let gallery = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.gallery"
            ) as? AppearanceBubbleStyleGalleryView
        )
        let radiusSection = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.radiusSection"
            )
        )
        let firstBubble = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.noTail"
            ) as? UIControl
        )
        let lastBubble = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.wedge"
            ) as? UIControl
        )

        XCTAssertEqual(tableView.style, .insetGrouped)
        XCTAssertEqual(
            tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: 1),
            "Radius: 8"
        )
        XCTAssertTrue(galleryBackdrop.hasVisibleWallpaperImage)
        XCTAssertFalse(galleryBackdrop.isHidden)
        XCTAssertEqual(
            galleryBackdrop.convert(galleryBackdrop.bounds, to: controller.view),
            gallery.convert(gallery.bounds, to: controller.view)
        )
        let galleryFrame = gallery.convert(gallery.bounds, to: controller.view)
        let radiusSectionFrame = radiusSection.convert(radiusSection.bounds, to: controller.view)
        XCTAssertGreaterThan(galleryFrame.minX, controller.view.bounds.minX)
        XCTAssertLessThan(galleryFrame.maxX, controller.view.bounds.maxX)
        XCTAssertEqual(gallery.layer.cornerRadius, 0, accuracy: 0.01)
        let firstMessageCell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: firstBubble))
        let lastMessageCell = try XCTUnwrap(firstSubview(of: TextMessageCell.self, in: lastBubble))
        let firstMessageContainerFrame = firstMessageCell.messageContainerView.convert(
            firstMessageCell.messageContainerView.bounds,
            to: gallery
        )
        let lastMessageContainerFrame = lastMessageCell.messageContainerView.convert(
            lastMessageCell.messageContainerView.bounds,
            to: gallery
        )
        XCTAssertGreaterThanOrEqual(firstMessageContainerFrame.minY, 16)
        XCTAssertLessThanOrEqual(lastMessageContainerFrame.maxY, gallery.bounds.maxY - 16)
        XCTAssertGreaterThan(radiusSectionFrame.minX, controller.view.bounds.minX)
        XCTAssertLessThan(radiusSectionFrame.maxX, controller.view.bounds.maxX)
        XCTAssertGreaterThan(radiusSectionFrame.minY, galleryFrame.maxY)

        let radiusSlider = try XCTUnwrap(
            descendant(
                in: radiusSection,
                accessibilityIdentifier: "interface.bubbles.radius"
            ) as? UISlider
        )
        radiusSlider.setValue(12, animated: false)
        radiusSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(controller.draft.profile.bubbleRadius, 12)
        XCTAssertEqual(
            tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: 1),
            "Radius: 12"
        )
        XCTAssertEqual(
            controller.view.backgroundColor?.resolvedColor(with: .init(userInterfaceStyle: .light)),
            .systemGroupedBackground.resolvedColor(with: .init(userInterfaceStyle: .light))
        )
    }

    @MainActor
    func testAvatarEditorUsesWhiteChatRowsInsteadOfTheLegacyGridAndPositionControl() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .builtIn(name: "Honeycomb")
        document.profile.avatarMask = .rounded
        let controller = AppearanceAvatarViewController(document: document)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let galleryBackdrop = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.avatars.background"
            ) as? ChatBackgroundBackdropView
        )
        let listBackground = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.avatars.listBackground"
            )
        )
        XCTAssertTrue(galleryBackdrop.isHidden)
        XCTAssertEqual(
            controller.view.backgroundColor?.resolvedColor(with: .init(userInterfaceStyle: .light)),
            .white
        )
        XCTAssertEqual(
            listBackground.backgroundColor?.resolvedColor(with: .init(userInterfaceStyle: .light)),
            .white
        )
        XCTAssertNil(firstSubview(of: UICollectionView.self, in: controller.view))
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.avatars.position"))
        XCTAssertFalse(labels(in: controller.view).contains { $0.text == "Group message position" })

        let row = try XCTUnwrap(
            descendant(in: controller.view, accessibilityIdentifier: "interface.avatar.rounded")
        )
        let indicator = try XCTUnwrap(
            descendant(
                in: row,
                accessibilityIdentifier: "interface.avatar.rounded.selection"
            )
        )
        let avatar = try XCTUnwrap(
            descendant(
                in: row,
                accessibilityIdentifier: "interface.avatar.rounded.preview"
            )
        )
        let indicatorFrame = indicator.convert(indicator.bounds, to: row)
        let avatarFrame = avatar.convert(avatar.bounds, to: row)
        XCTAssertEqual(indicatorFrame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(
            indicator.convert(indicator.bounds, to: controller.view).minX,
            8,
            accuracy: 0.5
        )
        XCTAssertEqual(avatarFrame.minX - indicatorFrame.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(indicatorFrame.midY, avatarFrame.midY, accuracy: 0.5)
        XCTAssertEqual(indicator.accessibilityValue, "Selected")
        let chatCell = try XCTUnwrap(firstSubview(of: ChatListTableViewCell.self, in: row))
        XCTAssertEqual(chatCell.bounds.height, 84, accuracy: 0.5)
        XCTAssertEqual(chatCell.usernameLabel.text, "Alicia Torreaux")
        XCTAssertTrue(chatCell.accountIndicator.isHidden)
        XCTAssertNotNil(chatCell.avatarView.image)
    }

    @MainActor
    func testAvatarGalleryDeliversTheTappedMaskAndKeepsEachPreviewMaskSpecific() throws {
        let gallery = AppearanceAvatarMaskGalleryView(frame: CGRect(x: 0, y: 0, width: 358, height: 560))
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        gallery.configure(
            document: document,
            traits: .init(userInterfaceStyle: .light),
            masks: AppearanceAvatarMask.allCases,
            selectedMask: .circle,
            lockedMasks: [.star]
        )
        gallery.setNeedsLayout()
        gallery.layoutIfNeeded()

        var selectedMask: AppearanceAvatarMask?
        gallery.onMaskSelected = { selectedMask = $0 }
        let octagonRow = try XCTUnwrap(
            descendant(in: gallery, accessibilityIdentifier: "interface.avatar.octagon") as? UIControl
        )
        octagonRow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selectedMask, .octagon)

        for mask in AppearanceAvatarMask.allCases {
            let row = try XCTUnwrap(
                descendant(in: gallery, accessibilityIdentifier: "interface.avatar.\(mask.rawValue)")
            )
            XCTAssertNotNil(firstSubview(of: ChatListTableViewCell.self, in: row))
        }

        let squarePreview = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.avatar.square.preview"
            )
        )
        let starPreview = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.avatar.star.preview"
            )
        )
        XCTAssertNil(squarePreview.mask)
        XCTAssertNotNil(starPreview.mask)
        XCTAssertEqual(
            descendant(in: gallery, accessibilityIdentifier: "interface.avatar.star")?.accessibilityValue,
            "Premium"
        )
    }

    func testAvatarPickerPhotoAssetsAreAvailable() {
        [
            "interface_avatar_alicia",
            "interface_avatar_roberto",
            "interface_avatar_campus",
            "interface_avatar_veronica",
            "interface_avatar_animal_videos",
            "interface_avatar_little_sister",
            "interface_avatar_jennie"
        ].forEach { assetName in
            XCTAssertNotNil(UIImage(named: assetName), "Missing avatar asset: \(assetName)")
        }
    }

    func testChangeSetSeparatesPaintLayoutAndInterfaceStyle() {
        let old = AppearanceProfile.default(accent: .systemBlue)
        var paint = old
        paint.accentOverride = AppearanceColor(hex: "#FF5500")
        var layout = old
        layout.textSize = .points21
        var style = old
        style.interfaceStyle = .dark

        XCTAssertEqual(AppearanceChangeSet.between(old, paint), [.paint])
        XCTAssertEqual(AppearanceChangeSet.between(old, layout), [.layout])
        XCTAssertEqual(AppearanceChangeSet.between(old, style), [.paint, .interfaceStyle])
    }

    @MainActor
    func testPaintCommitInvalidatesOpenChatPresentation() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        var document = store.load()
        document.profile.accentOverride = AppearanceColor(hex: "#FF5500")
        let notification = expectation(forNotification: .chatInterfaceChanged, object: coordinator)

        let changes = try coordinator.commit(document)

        XCTAssertTrue(changes.contains(.paint))
        wait(for: [notification], timeout: 0.1)
    }

    func testCloudOwnerPrefersReadyPremiumThenAccountOrder() {
        let candidates = [
            AppearanceCloudOwnerCandidate(owner: "first@example.test", galleryIdentity: "basic", isEnabled: true, isPremium: false, isReady: true),
            AppearanceCloudOwnerCandidate(owner: "second@example.test", galleryIdentity: "premium", isEnabled: true, isPremium: true, isReady: true),
            AppearanceCloudOwnerCandidate(owner: "third@example.test", galleryIdentity: "premium", isEnabled: true, isPremium: true, isReady: true)
        ]

        XCTAssertEqual(AppearanceCloudOwnerSelector.select(from: candidates)?.owner, "second@example.test")
        XCTAssertEqual(
            AppearanceCloudOwnerSelector.select(from: Array(candidates.prefix(1)))?.owner,
            "first@example.test"
        )
    }

    func testCloudOwnerExcludesDisabledOrUnreadyAccounts() {
        let candidates = [
            AppearanceCloudOwnerCandidate(owner: "disabled@example.test", galleryIdentity: "premium", isEnabled: false, isPremium: true, isReady: true),
            AppearanceCloudOwnerCandidate(owner: "unready@example.test", galleryIdentity: "premium", isEnabled: true, isPremium: true, isReady: false)
        ]

        XCTAssertNil(AppearanceCloudOwnerSelector.select(from: candidates))
    }

    func testCloudOwnerUsesResolvedGalleryRequestContextForWallpaperUpload() throws {
        let context = CloudStorageGalleryRequestContext.make(
            owner: "wallpaper@example.test",
            galleryType: .basic,
            baseURL: try XCTUnwrap(URL(string: "https://gallery.example.test/api/")),
            token: "gallery-token"
        )

        let candidate = AppearanceCloudOwnerCandidate.fromUploadRequestContext(
            owner: "wallpaper@example.test",
            isEnabled: true,
            isPremium: false,
            requestContext: context
        )

        XCTAssertTrue(candidate.isReady)
        XCTAssertEqual(candidate.galleryIdentity, context.identity)
        XCTAssertEqual(AppearanceCloudOwnerSelector.select(from: [candidate])?.owner, context.owner)
    }

    func testCloudOwnerUsesLoadedEnabledAccountWithoutConnectionRelay() throws {
        let context = CloudStorageGalleryRequestContext.make(
            owner: "wallpaper@example.test",
            galleryType: .basic,
            baseURL: try XCTUnwrap(URL(string: "https://gallery.example.test/api/")),
            token: "gallery-token"
        )

        let candidate = AppearanceCloudOwnerCandidate.fromLoadedEnabledAccount(
            owner: context.owner,
            isPremium: false,
            requestContext: context
        )

        XCTAssertTrue(candidate.isEnabled)
        XCTAssertTrue(candidate.isReady)
        XCTAssertEqual(AppearanceCloudOwnerSelector.select(from: [candidate])?.owner, context.owner)
    }

    @MainActor
    func testWallpaperEditorPlacesActionsBelowBuiltInsAndUsesSelectedBackgroundForTiles() throws {
        let selectedColor = try XCTUnwrap(AppearanceColor(hex: "#2456A6"))
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .gradient(
            stops: [selectedColor],
            pattern: nil,
            intensity: 100
        )
        let controller = AppearanceWallpaperViewController(document: document)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let builtIns = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.wallpaper.builtInGrid"
            ) as? UICollectionView
        )
        let colorAction = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.wallpaper.setColor"
            ) as? UIButton
        )
        let photoAction = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.wallpaper.chooseFromIPhone"
            ) as? UIButton
        )
        let tileDocument = controller.builtInPreviewDocument(for: "Honeycomb")

        XCTAssertLessThanOrEqual(builtIns.frame.maxY, colorAction.frame.minY)
        XCTAssertLessThanOrEqual(builtIns.frame.maxY, photoAction.frame.minY)
        XCTAssertEqual(colorAction.configuration?.title, "Color")
        XCTAssertEqual(photoAction.configuration?.title, "Gallery")
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.wallpaper.blurred"))
        XCTAssertNil(descendant(in: controller.view, accessibilityIdentifier: "interface.wallpaper.motion"))
        guard case .gradient(let stops, let pattern, let intensity) = tileDocument.profile.wallpaper else {
            return XCTFail("Expected a gradient-backed built-in tile")
        }
        XCTAssertEqual(stops, [selectedColor])
        XCTAssertEqual(pattern, "honeycomb")
        XCTAssertEqual(intensity, 10)

        let cell = AppearanceWallpaperCell(frame: CGRect(x: 0, y: 0, width: 120, height: 150))
        cell.configure(
            name: "Honeycomb",
            selected: false,
            accent: .systemBlue,
            document: tileDocument
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let tileBackdrop = try XCTUnwrap(
            descendant(
                in: cell,
                accessibilityIdentifier: "interface.wallpaper.backdrop.Honeycomb"
            ) as? ChatBackgroundBackdropView
        )
        XCTAssertTrue(tileBackdrop.hasVisibleWallpaperImage)
    }

    func testTypographyExposesEightManualSliderStepsAndSystemChoice() {
        XCTAssertEqual(AppearanceTextSize.fixedCases.map(\.points), [14, 15, 16, 17, 18, 19, 20, 21])
        XCTAssertEqual(Set(AppearanceTextSize.fixedCases).union([.system]), Set(AppearanceTextSize.allCases))
        XCTAssertNil(AppearanceTextSize.system.points)
    }

    @MainActor
    func testTextSizePreviewKeepsMessageCellsWhileTypographyChanges() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.textSize = .points14
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 360, height: 330))
        preview.configure(document: document, traits: .init(userInterfaceStyle: .light), animated: false)
        preview.setNeedsLayout()
        preview.layoutIfNeeded()

        let incomingBefore = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.incoming"
            )
        )
        let outgoingBefore = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.outgoing"
            )
        )

        document.profile.textSize = .points21
        preview.configure(
            document: document,
            traits: .init(userInterfaceStyle: .light),
            animated: false,
            updatingTypographyInPlace: true
        )
        preview.setNeedsLayout()
        preview.layoutIfNeeded()

        let incomingAfter = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.incoming"
            )
        )
        let outgoingAfter = try XCTUnwrap(
            descendant(
                in: preview,
                accessibilityIdentifier: "interface.preview.message.outgoing"
            )
        )
        XCTAssertTrue(incomingBefore === incomingAfter)
        XCTAssertTrue(outgoingBefore === outgoingAfter)
    }

    func testWallpaperPhotoProcessorConstrainsLongEdgeAndProducesJPEG() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4200, height: 2100))
        let source = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 4200, height: 2100)))
        }

        let asset = try AppearanceWallpaperPhotoProcessor.process(source)
        let decoded = try XCTUnwrap(UIImage(data: asset.data))

        XCTAssertEqual(decoded.size.width, 3072, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 1536, accuracy: 1)
        XCTAssertEqual(asset.mimeType, "image/jpeg")
        XCTAssertEqual(asset.filename, "chat-wallpaper-\(asset.hash.prefix(12)).jpg")
    }

    func testWallpaperCacheRoundTripsByCloudIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterfaceAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        let cache = AppearanceWallpaperCache(rootDirectory: root)
        let reference = CloudWallpaperReference(
            owner: "wallpaper@example.test",
            galleryIdentity: "gallery-a",
            fileID: "42",
            url: "https://example.test/file.jpg",
            thumbnailURL: nil,
            hash: "deadbeef",
            mimeType: "image/jpeg"
        )
        let payload = Data("image-payload".utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        try cache.store(payload, for: reference)

        XCTAssertEqual(cache.data(for: reference), payload)
        XCTAssertTrue(cache.fileURL(for: reference).lastPathComponent.contains("deadbeef"))
    }

    private func descendant(
        in root: UIView,
        accessibilityIdentifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return match
            }
        }
        return nil
    }

    private func labels(in root: UIView) -> [UILabel] {
        var result: [UILabel] = []
        if let label = root as? UILabel {
            result.append(label)
        }
        for subview in root.subviews {
            result.append(contentsOf: labels(in: subview))
        }
        return result
    }

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let root = root as? T {
            return root
        }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class NonAnimatingNavigationController: UINavigationController {
    override func popViewController(animated: Bool) -> UIViewController? {
        super.popViewController(animated: false)
    }
}
