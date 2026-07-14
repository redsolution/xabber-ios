//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest
@testable import xabber

@MainActor
final class ChatSearchTopChromeTests: XCTestCase {
    func testReferenceGeometryAtIPhone16eWidth() {
        let frames = ChatSearchNavigationLayout.frames(containerWidth: 390)

        XCTAssertEqual(ChatSearchNavigationLayout.nominalHeight, 60, accuracy: 0.001)
        XCTAssertEqual(frames.field, CGRect(x: 16, y: 6, width: 306, height: 44))
        XCTAssertEqual(frames.cancel, CGRect(x: 330, y: 6, width: 44, height: 44))
        XCTAssertEqual(frames.cancel.minX - frames.field.maxX, 8, accuracy: 0.001)
    }

    func testSafeAreaInsetsAreAddedToBaseHorizontalInsets() {
        let frames = ChatSearchNavigationLayout.frames(
            containerWidth: 430,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 24)
        )

        XCTAssertEqual(frames.field.minX, 36, accuracy: 0.001)
        XCTAssertEqual(430 - frames.cancel.maxX, 40, accuracy: 0.001)
        XCTAssertEqual(frames.cancel.minX - frames.field.maxX, 8, accuracy: 0.001)
    }

    func testControlsUseOneFieldCapsuleAndDetachedCancelGeometry() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))

        view.layoutIfNeeded()

        XCTAssertEqual(view.intrinsicContentSize.height, 60, accuracy: 0.001)
        XCTAssertEqual(view.surfaceView.frame, CGRect(x: 16, y: 6, width: 306, height: 44))
        XCTAssertEqual(view.cancelButton.frame, CGRect(x: 330, y: 6, width: 44, height: 44))
        XCTAssertTrue(view.submitButton.isDescendant(of: view.surfaceView.contentView))
        XCTAssertTrue(view.clearButton.isDescendant(of: view.surfaceView.contentView))
        XCTAssertFalse(view.cancelButton.isDescendant(of: view.surfaceView))
        XCTAssertEqual(view.submitButton.accessibilityIdentifier, "chat_search_submit")
        XCTAssertEqual(view.cancelButton.accessibilityIdentifier, "chat_search_cancel")
        XCTAssertEqual(view.clearButton.accessibilityIdentifier, "chat_search_clear")
        XCTAssertEqual(view.textField.accessibilityIdentifier, "chat_search_input")
    }

    func testLeadingSearchIconUsesCompactOpticalInsetsInsideHitArea() throws {
        let view = ChatSearchNavigationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60),
            prefersNativeGlass: true
        )

        view.layoutIfNeeded()

        XCTAssertEqual(
            view.submitButton.frame,
            CGRect(x: 0, y: 0, width: 44, height: 44)
        )
        XCTAssertTrue(
            view.submitButton.translatesAutoresizingMaskIntoConstraints,
            "The manually framed leading control must not be collapsed to its intrinsic image size by UIVisualEffectView Auto Layout."
        )
        XCTAssertTrue(view.clearButton.translatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(view.cancelButton.translatesAutoresizingMaskIntoConstraints)
        let configuration = try XCTUnwrap(view.submitButton.configuration)
        XCTAssertEqual(configuration.contentInsets.top, 8, accuracy: 0.001)
        XCTAssertEqual(configuration.contentInsets.leading, 8, accuracy: 0.001)
        XCTAssertEqual(configuration.contentInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(configuration.contentInsets.trailing, 0, accuracy: 0.001)

        let image = try XCTUnwrap(configuration.image)
        XCTAssertLessThanOrEqual(image.size.width, 20)
        XCTAssertLessThanOrEqual(image.size.height, 20)
    }

    func testRemoteSearchingSwapsLeadingIconForSpinnerWithoutMovingText() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        view.render(.init(query: "test", isRemoteSearching: false))
        view.layoutIfNeeded()
        let textFrame = view.textField.frame
        let leadingFrame = view.submitButton.frame

        view.render(.init(query: "test", isRemoteSearching: true))
        view.layoutIfNeeded()

        XCTAssertTrue(view.submitButton.isHidden)
        XCTAssertFalse(view.loadingIndicator.isHidden)
        XCTAssertTrue(view.loadingIndicator.isAnimating)
        XCTAssertEqual(view.loadingIndicator.accessibilityIdentifier, "chat_search_loading")
        XCTAssertEqual(view.loadingIndicator.frame, leadingFrame)
        XCTAssertEqual(view.textField.frame, textFrame)
    }

    func testClearIsQueryDependentAndClearsWithoutEndingInputFocusContract() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        var clearCount = 0
        view.onClear = { clearCount += 1 }

        view.render(.init(query: "test", isRemoteSearching: false))
        XCTAssertFalse(view.clearButton.isHidden)
        view.clearButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(view.text, "")
        XCTAssertTrue(view.clearButton.isHidden)
        XCTAssertFalse(view.hasPendingFocusRequest)
    }

    func testCancelInvokesDedicatedTopChromeCallback() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        var cancelCount = 0
        view.onCancel = { cancelCount += 1 }

        view.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(cancelCount, 1)
    }

    func testSubmitControlAndReturnFlushCurrentQueryExactlyOnceEach() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        var submissions: [String] = []
        view.onSubmit = { submissions.append($0) }
        view.text = "test"

        view.submitButton.sendActions(for: .touchUpInside)
        let shouldReturn = view.textField.delegate?.textFieldShouldReturn?(view.textField)

        XCTAssertEqual(shouldReturn, true)
        XCTAssertEqual(submissions, ["test", "test"])
    }

    func testAccessibilityTextSizeAndLongQueryKeepSingleFixedHeightRow() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        view.textField.font = .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        ))
        view.text = Array(repeating: "long test query", count: 80).joined(separator: " ")

        view.layoutIfNeeded()

        XCTAssertEqual(view.intrinsicContentSize.height, 60, accuracy: 0.001)
        XCTAssertEqual(view.bounds.height, 60, accuracy: 0.001)
        XCTAssertEqual(view.textField.frame.height, 44, accuracy: 0.001)
        XCTAssertEqual(view.textField.maxLines, 1)
    }

    func testFallbackAndNativePreferenceKeepIdenticalGeometry() {
        let fallback = ChatSearchNavigationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60),
            prefersNativeGlass: false
        )
        let preferred = ChatSearchNavigationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60),
            prefersNativeGlass: true
        )

        fallback.layoutIfNeeded()
        preferred.layoutIfNeeded()

        XCTAssertEqual(fallback.surfaceView.frame, preferred.surfaceView.frame)
        XCTAssertEqual(fallback.cancelButton.frame, preferred.cancelButton.frame)
        XCTAssertTrue(fallback.surfaceView.effect is UIBlurEffect)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(preferred.surfaceView.effect is UIGlassEffect)
        }
    }

    func testInputFocusIsDeferredUntilViewIsAttachedToWindow() {
        let view = ChatSearchNavigationView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))

        XCTAssertFalse(view.requestInputFocusWhenAttached())
        XCTAssertTrue(view.hasPendingFocusRequest)
        XCTAssertEqual(view.focusAttemptCount, 0)

        let host = UIViewController()
        host.view.addSubview(view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        view.didMoveToWindowForTesting()

        XCTAssertFalse(view.hasPendingFocusRequest)
        XCTAssertEqual(view.focusAttemptCount, 1)
        window.isHidden = true
    }

    func testRepeatedConfigureIsIdempotentAndClearsStaleNavigationChrome() {
        let controller = ChatViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        controller.navigationItem.titleView = UILabel()
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "back", style: .plain, target: nil, action: nil)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "avatar", style: .plain, target: nil, action: nil)
        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        controller.configureSearchBar(activateKeyboard: true, animated: false)
        let initialConstraints = controller.searchInputBarConstraints
        controller.configureSearchBar(activateKeyboard: true, animated: false)

        XCTAssertNil(controller.navigationItem.titleView)
        XCTAssertNil(controller.navigationItem.leftBarButtonItem)
        XCTAssertNil(controller.navigationItem.rightBarButtonItem)
        XCTAssertTrue(controller.navigationItem.hidesBackButton)
        XCTAssertIdentical(controller.searchNavigationView.superview, controller.view)
        XCTAssertEqual(controller.searchInputBarConstraints.count, initialConstraints.count)
        XCTAssertEqual(controller.searchInputBarHeightConstraint?.constant ?? -1, 60, accuracy: 0.001)
        XCTAssertNotNil(controller.searchInputBarBottomConstraint)
        XCTAssertTrue(controller.xabberInputView.searchPanel.cancelButton.isHidden)
        XCTAssertTrue(controller.searchNavigationView.hasPendingFocusRequest)
        XCTAssertEqual(controller.searchNavigationView.focusAttemptCount, 0)
    }

    func testTopClearKeepsSearchModeWhileTopCancelClosesIt() {
        let controller = ChatViewController()
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.activateSearchModeFromExternalRoute(activateKeyboard: false, animated: false)
        controller.searchNavigationView.text = "test"
        controller.searchTextObserver.accept("test")
        controller.currentSearchQueryId = "query-test"
        controller.selectedSearchResultId = "archive-test"

        controller.searchNavigationView.clearButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(controller.inSearchMode.value)
        XCTAssertNil(controller.searchTextObserver.value)
        XCTAssertNil(controller.currentSearchQueryId)
        XCTAssertNil(controller.selectedSearchResultId)
        XCTAssertEqual(controller.searchNavigationView.text, "")

        controller.showSkeletonObserver.accept(false)
        controller.searchNavigationView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.inSearchMode.value)
        XCTAssertEqual(controller.xabberInputView.state, .normal)
        XCTAssertNil(controller.searchNavigationView.superview)
    }
}
