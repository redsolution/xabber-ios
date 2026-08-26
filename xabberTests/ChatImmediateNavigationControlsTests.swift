import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatImmediateNavigationControlsTests: XCTestCase {
    func testLastChatsPreparesVisibleBackChevronBeforeChatPush() throws {
        let lastChats = LastChatsViewController()
        let navigationController = UINavigationController(
            rootViewController: lastChats
        )
        navigationController.loadViewIfNeeded()

        lastChats.beginOutgoingChatOpenNavigationDeferral(token: nil)

        let backItem = try XCTUnwrap(lastChats.navigationItem.backBarButtonItem)
        XCTAssertNil(
            backItem.image,
            "the source item must not duplicate UIKit's Back indicator"
        )
        let image = try XCTUnwrap(
            navigationController.navigationBar.backIndicatorImage,
            "the navigation bar must own an eager Back indicator before the push"
        )
        XCTAssertNotNil(image.cgImage, "the first frame must not depend on deferred SF Symbol resolution")
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
        XCTAssertTrue(
            imageHasVisiblePixels(image),
            "expected an eager bitmap-backed chevron, got \(image) cgImage=\(String(describing: image.cgImage))"
        )
        XCTAssertEqual(
            backItem.accessibilityIdentifier,
            LastChatsViewController.nativeChatBackAccessibilityIdentifier
        )
        XCTAssertNil(backItem.target)
        XCTAssertNil(backItem.action)
        XCTAssertNotNil(
            navigationController.navigationBar.backIndicatorTransitionMaskImage
        )
    }

    func testConfigureNavbarKeepsSystemBackIndicatorAvailableImmediately() {
        let root = UIViewController()
        root.navigationItem.backButtonDisplayMode = .minimal
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "friend@example.com"
        chat.conversationType = .regular

        chat.configureNavbar()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(chat, animated: false)

        XCTAssertFalse(chat.navigationItem.hidesBackButton)
        XCTAssertIdentical(navigationController.topViewController, chat)
        XCTAssertIdentical(navigationController.navigationBar.backItem, root.navigationItem)
        XCTAssertEqual(root.navigationItem.backButtonDisplayMode, .minimal)
        XCTAssertNotNil(chat.navigationItem.rightBarButtonItem?.image)
    }

    func testAvatarItemHasVisibleRoundedFallbackBeforeAsyncImageArrives() throws {
        let action = #selector(dummyAction)
        let item = ChatNavigationAvatarItemFactory.makeItem(
            image: nil,
            target: self,
            action: action
        )

        let image = try XCTUnwrap(item.image)
        XCTAssertEqual(
            image.size.width,
            ChatNavigationAvatarItemFactory.imageSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            image.size.height,
            ChatNavigationAvatarItemFactory.imageSize,
            accuracy: 0.001
        )
        XCTAssertEqual(image.renderingMode, .alwaysOriginal)
        XCTAssertTrue(imageHasVisiblePixels(image))
        let avatarButton = try XCTUnwrap(
            item.customView as? RoundedAvatarButton,
            "the first frame must own a concrete avatar view instead of a deferred bar-item snapshot"
        )
        let buttonImage = try XCTUnwrap(avatarButton.image(for: .normal))
        XCTAssertTrue(imageHasVisiblePixels(buttonImage))
        XCTAssertEqual(
            avatarButton.bounds.size,
            CGSize(
                width: ChatNavigationAvatarItemFactory.controlSize,
                height: ChatNavigationAvatarItemFactory.controlSize
            )
        )
        XCTAssertEqual(
            avatarButton.actions(
                forTarget: self,
                forControlEvent: .touchUpInside
            ),
            [NSStringFromSelector(action)]
        )
        XCTAssertEqual(item.action, action)
        XCTAssertTrue(item.target === self)
        XCTAssertEqual(
            item.accessibilityIdentifier,
            ChatNavigationAvatarItemFactory.accessibilityIdentifier
        )
    }

    private func imageHasVisiblePixels(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let alphaOffset: Int?
        switch cgImage.alphaInfo {
        case .premultipliedLast, .last:
            alphaOffset = bytesPerPixel - 1
        case .premultipliedFirst, .first:
            alphaOffset = 0
        case .noneSkipLast:
            alphaOffset = nil
        case .noneSkipFirst:
            alphaOffset = nil
        case .none, .alphaOnly:
            alphaOffset = cgImage.alphaInfo == .alphaOnly ? 0 : nil
        @unknown default:
            alphaOffset = nil
        }
        guard let alphaOffset else {
            return cgImage.width > 0 && cgImage.height > 0
        }
        let length = CFDataGetLength(data)
        guard alphaOffset < length else { return false }
        var index = alphaOffset
        while index < length {
            if bytes[index] != 0 {
                return true
            }
            index += bytesPerPixel
        }
        return false
    }

    @objc private func dummyAction() {}
}
