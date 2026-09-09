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

    func testResolverUsesExplicitLightAndDarkPalettes() {
        let theme = AppearanceThemeCatalog.builtInThemes[0]
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.themeID = theme.id
        document.profile.accentOverride = nil

        let light = AppearanceResolver.resolve(document: document, traitStyle: .light)
        let dark = AppearanceResolver.resolve(document: document, traitStyle: .dark)

        XCTAssertEqual(light.palette, theme.lightPalette)
        XCTAssertEqual(dark.palette, theme.darkPalette)
        XCTAssertEqual(light.accent, theme.lightPalette.accent)
        XCTAssertEqual(dark.accent, theme.darkPalette.accent)
    }

    func testLayoutSignatureChangesForEveryGeometrySetting() {
        let document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        let base = AppearanceResolver.resolve(document: document, traitStyle: .light).layoutSignature

        let mutations: [(inout AppearanceProfile) -> Void] = [
            { $0.textSize = .points22 },
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

        controller.tableView(tableView, didSelectRowAt: IndexPath(row: 0, section: 3))

        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.topViewController is AppearanceDraftViewController)
        XCTAssertNil(navigationController.topViewController?.navigationItem.leftBarButtonItem)
    }

    @MainActor
    func testInterfaceSettingsRemovesChatThemesRow() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )

        XCTAssertEqual(controller.tableView(tableView, numberOfRowsInSection: 1), 2)
        let firstColorThemeRow = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        let firstConfiguration = try XCTUnwrap(firstColorThemeRow.contentConfiguration as? UIListContentConfiguration)

        XCTAssertEqual(firstConfiguration.text, "Chat Wallpaper")
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
            cellForRowAt: IndexPath(row: 2, section: 3)
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
    func testInlineAppearanceChoiceCommitsTappedModeWithoutNavigation() throws {
        let store = AppearanceSettingsStore(defaults: defaults, defaultAccentHex: "#0099FF")
        let coordinator = AppearanceCoordinator(store: store)
        let controller = InterfaceSettingsViewController(appearanceCoordinator: coordinator)
        let navigationController = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let tableView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? UITableView }.first
        )
        let cell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )
        let dark = try XCTUnwrap(
            descendant(in: cell, accessibilityIdentifier: "interface.mode.dark") as? UIControl
        )

        dark.sendActions(for: .touchUpInside)

        XCTAssertEqual(navigationController.viewControllers.count, 1)
        XCTAssertTrue(navigationController.topViewController === controller)
        XCTAssertEqual(coordinator.document.profile.interfaceStyle, .dark)
        XCTAssertEqual(store.load().profile.interfaceStyle, .dark)

        let refreshedCell = controller.tableView(
            tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        )
        let selectedDark = try XCTUnwrap(
            descendant(in: refreshedCell, accessibilityIdentifier: "interface.mode.dark") as? UIControl
        )
        XCTAssertEqual(selectedDark.accessibilityValue, "Selected")
        XCTAssertTrue(selectedDark.accessibilityTraits.contains(.selected))
    }

    @MainActor
    func testOverviewThemeTapCommitsImmediatelyWithoutNavigation() throws {
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
        XCTAssertEqual(coordinator.document.profile.themeID, theme.id)
        XCTAssertNil(coordinator.document.profile.accentOverride)
        XCTAssertEqual(store.load().profile.themeID, theme.id)

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
        let palette = rose.palette(for: .light)

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
        XCTAssertFalse(free.canSelect(.stripes, currentlyApplied: .noTail))
        XCTAssertFalse(free.canSelect(.wedge, currentlyApplied: .noTail))
        XCTAssertTrue(free.canSelect(.wedge, currentlyApplied: .wedge))
        XCTAssertFalse(free.canSelect(.star, currentlyApplied: .circle))
        XCTAssertTrue(paid.canSelect(.star, currentlyApplied: .circle))
        XCTAssertTrue(paid.canSelect(.transparent, currentlyApplied: .noTail))
    }

    func testDisabledSubscriptionsHidePremiumOptions() {
        let policy = AppearancePremiumPolicy(isEntitled: false, subscriptionsEnabled: false)

        XCTAssertEqual(Set(policy.visibleBubbleStyles), Set(AppearanceBubbleStyle.freeCases))
        XCTAssertEqual(Set(policy.visibleAvatarMasks), Set(AppearanceAvatarMask.freeCases))
    }

    @MainActor
    func testBubbleGalleryKeepsIncomingSamplesSelectedGeometryAndPremiumStatusLockStableAcrossRadiusChanges() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .builtIn(name: "Honeycomb")
        document.profile.bubbleStyle = .smooth
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
            XCTAssertLessThan(
                cell.messageContainerView.frame.midX,
                cell.bounds.midX,
                "\(style.displayName) must remain an incoming, left-aligned sample"
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
            XCTAssertEqual(gap, 16, accuracy: 0.5)
        }

        let selectedIndicator = try XCTUnwrap(
            descendant(
                in: gallery,
                accessibilityIdentifier: "interface.bubble.smooth.selection"
            )
        )
        XCTAssertEqual(selectedIndicator.accessibilityValue, "Selected")
        XCTAssertEqual(selectedIndicator.layer.cornerRadius, selectedIndicator.bounds.width / 2, accuracy: 0.5)
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
    func testBubbleEditorRendersWallpaperAcrossThePageAndLeavesGalleryTransparent() throws {
        var document = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        document.profile.wallpaper = .builtIn(name: "Honeycomb")
        let controller = AppearanceBubbleViewController(document: document)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let pageBackdrop = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.pageBackground"
            ) as? ChatBackgroundBackdropView
        )
        let galleryBackdrop = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "interface.bubbles.background"
            ) as? ChatBackgroundBackdropView
        )

        XCTAssertTrue(pageBackdrop.hasVisibleWallpaperImage)
        XCTAssertTrue(galleryBackdrop.isHidden)
        XCTAssertEqual(
            pageBackdrop.convert(pageBackdrop.bounds, to: controller.view),
            controller.view.bounds
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
        layout.textSize = .points22
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

    func testTypographyExposesSevenFixedStepsAndSystem() {
        XCTAssertEqual(AppearanceTextSize.fixedCases.map(\.points), [14, 15, 16, 17, 18, 20, 22])
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

        document.profile.textSize = .points22
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
