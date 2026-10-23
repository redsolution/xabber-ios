import XCTest
import UIKit
@testable import xabber

@MainActor
final class EncryptedChatBackgroundAppearanceTests: XCTestCase {
    private let encryptedConversationTypes: [ClientSynchronizationManager.ConversationType] = [
        .omemo, .omemo1
    ]

    func testEncryptedLegacyBackgroundUsesActiveThemeAndWallpaperLikeRegularChat() {
        let document = activeDocument

        for conversationType in [.regular] + encryptedConversationTypes {
            let controller = makeController(conversationType: conversationType)

            controller.updateBackground()

            XCTAssertEqual(
                controller.gradient.colors as? [CGColor],
                expectedGradientColors(document: document, traits: controller.traitCollection),
                conversationType.rawValue
            )
            XCTAssertEqual(
                controller.backgroundImage.image != nil,
                hasAvailableWallpaperImage(document.profile.wallpaper),
                conversationType.rawValue
            )
        }
    }

    func testEncryptedLocalBackdropUsesActiveWallpaperAndTheme() throws {
        let document = activeDocument

        for conversationType in encryptedConversationTypes {
            let controller = makeController(conversationType: conversationType)
            controller.backgroundPresentationMode = .localChatBackdrop

            controller.configureBackground()

            let backdrop = try XCTUnwrap(localBackdrop(in: controller))
            let gradient = try XCTUnwrap(
                backdrop.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first
            )
            XCTAssertEqual(backdrop.representedWallpaper, document.profile.wallpaper, conversationType.rawValue)
            XCTAssertEqual(
                backdrop.hasVisibleWallpaperImage,
                hasAvailableWallpaperImage(document.profile.wallpaper),
                conversationType.rawValue
            )
            XCTAssertEqual(
                gradient.colors as? [CGColor],
                expectedGradientColors(document: document, traits: backdrop.traitCollection),
                conversationType.rawValue
            )
            XCTAssertEqual(controller.messagesCollectionView.backgroundColor, .clear)
            XCTAssertTrue(controller.view.isOpaque)
        }
    }

    func testEncryptedSharedBackdropKeepsChatTransparentWithoutLocalBackdrop() {
        for conversationType in encryptedConversationTypes {
            let controller = makeController(conversationType: conversationType)
            controller.backgroundPresentationMode = .sharedSplitBackdrop

            controller.configureBackground()

            XCTAssertEqual(controller.view.backgroundColor, .clear, conversationType.rawValue)
            XCTAssertFalse(controller.view.isOpaque, conversationType.rawValue)
            XCTAssertEqual(controller.messagesCollectionView.backgroundColor, .clear)
            XCTAssertNil(localBackdrop(in: controller), conversationType.rawValue)
            XCTAssertNil(controller.backgroundView.superview, conversationType.rawValue)
        }
    }

    func testEncryptedChatRemovesLocalBackdropWhenSwitchingToSharedBackdrop() throws {
        for conversationType in encryptedConversationTypes {
            let controller = makeController(conversationType: conversationType)
            controller.backgroundPresentationMode = .localChatBackdrop
            controller.configureBackground()
            let previousBackdrop = try XCTUnwrap(localBackdrop(in: controller))

            controller.backgroundPresentationMode = .sharedSplitBackdrop
            controller.configureBackground()

            XCTAssertNil(previousBackdrop.superview, conversationType.rawValue)
            XCTAssertNil(localBackdrop(in: controller), conversationType.rawValue)
            XCTAssertEqual(controller.view.backgroundColor, .clear, conversationType.rawValue)
            XCTAssertFalse(controller.view.isOpaque, conversationType.rawValue)
            XCTAssertEqual(controller.messagesCollectionView.backgroundColor, .clear)
        }
    }

    private var activeDocument: AppearanceSettingsDocument {
        AppearanceSettingsStore()?.load()
            ?? AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
    }

    private func expectedGradientColors(
        document: AppearanceSettingsDocument,
        traits: UITraitCollection
    ) -> [CGColor] {
        if case .gradient(let stops, _, _) = document.profile.wallpaper, !stops.isEmpty {
            return stops.map { $0.uiColor.cgColor }
        }
        return AppearanceResolver.resolve(
            document: document,
            traitStyle: traits.userInterfaceStyle
        ).palette.backgroundStops.map { $0.uiColor.cgColor }
    }

    private func hasAvailableWallpaperImage(_ wallpaper: AppearanceWallpaper) -> Bool {
        switch wallpaper {
        case .none:
            return false
        case .builtIn(let name):
            return UIImage(named: name.lowercased()) != nil
        case .gradient(_, let pattern, _):
            return pattern.flatMap { UIImage(named: $0.lowercased()) } != nil
        case .cloud(let reference, _, _):
            return AppearanceWallpaperCache().image(for: reference) != nil
        }
    }

    private func makeController(
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatViewController {
        let controller = BackgroundOnlyChatViewController()
        controller.owner = "background-owner@example.com"
        controller.jid = "background-contact@example.com"
        controller.conversationType = conversationType
        controller.loadViewIfNeeded()
        return controller
    }

    private func localBackdrop(in controller: ChatViewController) -> ChatBackgroundBackdropView? {
        controller.view.subviews.compactMap { $0 as? ChatBackgroundBackdropView }.first
    }

    private final class BackgroundOnlyChatViewController: ChatViewController {
        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }

        override func viewDidLoad() {}
        override func shouldChangeFrame() {}
    }
}
