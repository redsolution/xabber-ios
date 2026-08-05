import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentPickerEntryPointTests: XCTestCase {
    private var previousTelegramAttachmentPickerFlag: Bool?

    override func setUp() {
        super.setUp()
        previousTelegramAttachmentPickerFlag = CommonConfigManager.shared.config.use_telegram_attachment_picker
    }

    override func tearDown() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = previousTelegramAttachmentPickerFlag
        super.tearDown()
    }

    func testLegacyFeatureFlagOffStillPresentsCurrentAttachmentFlow() {
        let plan = ChatAttachmentPickerEntryPlan.make(
            isTelegramAttachmentPickerEnabled: false,
            availabilityState: .ready(endpoint: URL(string: "https://files.example.com")!)
        )

        XCTAssertTrue(plan.presentsPicker)
        XCTAssertFalse(plan.resumesAvailability)
    }

    func testMissingConfigFlagStillPresentsCurrentAttachmentFlow() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = nil

        XCTAssertTrue(CommonConfigManager.shared.isTelegramAttachmentPickerEnabled)

        let plan = ChatAttachmentPickerEntryPlan.make(
            isTelegramAttachmentPickerEnabled: CommonConfigManager.shared.config.use_telegram_attachment_picker,
            availabilityState: .unsupported
        )

        XCTAssertTrue(plan.presentsPicker)
        XCTAssertFalse(plan.resumesAvailability)
    }

    func testEveryCloudStorageAvailabilityStatePresentsAndOnlyTemporaryStatesResume() {
        let endpoint = URL(string: "https://files.example.com")!
        let cases: [(state: CloudStorageAvailabilityState, resumesAvailability: Bool)] = [
            (.discovering, true),
            (.authorizing(endpoint: endpoint), true),
            (.retryableFailure(stage: .authorization, endpoint: endpoint), true),
            (.unsupported, false),
            (.ready(endpoint: endpoint), false)
        ]

        for testCase in cases {
            let plan = ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: true,
                availabilityState: testCase.state
            )

            XCTAssertTrue(plan.presentsPicker, "Expected the picker to open for \(testCase.state)")
            XCTAssertEqual(
                plan.resumesAvailability,
                testCase.resumesAvailability,
                "Unexpected availability recovery behavior for \(testCase.state)"
            )
        }
    }

    func testAttachmentButtonTouchUpNotifiesDelegateExactlyOnce() {
        let inputView = ModernXabberInputView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 390,
                height: ModernXabberInputView.defaultBarHeight
            )
        )
        let delegate = AttachmentButtonDelegateSpy()
        inputView.delegate = delegate

        inputView.attachButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.attachmentTouchCount, 1)
    }

    func testOrdinaryReappearanceRebindsInputInteractionsAfterTerminalTeardown() {
        let (controller, window) = makeLoadedChatController()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
        }
        assertInputInteractionsAreBound(controller)

        controller.performTerminalChatResourceTeardownForTesting()

        assertInputInteractionsAreUnbound(controller)

        controller.viewWillAppear(false)

        assertInputInteractionsAreBound(controller)
    }

    func testAttachmentTapAfterOrdinaryReappearanceStartsPickerAgain() {
        let (controller, window) = makeLoadedChatController()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
        }
        var presentationCount = 0
        controller.chatAttachmentPickerEntryHandlerForTesting = {
            presentationCount += 1
        }

        controller.xabberInputView.attachButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(presentationCount, 1)

        controller.performTerminalChatResourceTeardownForTesting()
        controller.viewWillAppear(false)
        controller.xabberInputView.attachButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(presentationCount, 2)
    }

    private func makeLoadedChatController() -> (ChatViewController, UIWindow) {
        let controller = ChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "contact@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Contact")
        controller.showSkeletonObserver.accept(false)

        let navigationController = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        return (controller, window)
    }

    private func assertInputInteractionsAreBound(
        _ controller: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(controller.xabberInputView.delegate === controller, file: file, line: line)
        XCTAssertTrue(
            controller.xabberInputView.contextPreviewPanel.delegate === controller,
            file: file,
            line: line
        )
        XCTAssertTrue(
            controller.xabberInputView.selectionPanel.delegate === controller,
            file: file,
            line: line
        )
        XCTAssertNotNil(
            controller.xabberInputView.searchPanel.onChangeConversationTypeCallback,
            file: file,
            line: line
        )
        XCTAssertNotNil(
            controller.xabberInputView.searchPanel.onChangeViewStateCallback,
            file: file,
            line: line
        )
        XCTAssertNotNil(
            controller.xabberInputView.searchPanel.onCalendarCallback,
            file: file,
            line: line
        )
        XCTAssertNotNil(controller.xabberInputView.mentionCandidatesProvider, file: file, line: line)
        XCTAssertNotNil(controller.xabberInputView.mentionMembersCountProvider, file: file, line: line)
        XCTAssertNotNil(controller.xabberInputView.mentionUsersReloadHandler, file: file, line: line)
    }

    private func assertInputInteractionsAreUnbound(
        _ controller: ChatViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(controller.xabberInputView.delegate, file: file, line: line)
        XCTAssertNil(controller.xabberInputView.contextPreviewPanel.delegate, file: file, line: line)
        XCTAssertNil(controller.xabberInputView.selectionPanel.delegate, file: file, line: line)
        XCTAssertNil(
            controller.xabberInputView.searchPanel.onChangeConversationTypeCallback,
            file: file,
            line: line
        )
        XCTAssertNil(
            controller.xabberInputView.searchPanel.onChangeViewStateCallback,
            file: file,
            line: line
        )
        XCTAssertNil(controller.xabberInputView.searchPanel.onCalendarCallback, file: file, line: line)
        XCTAssertNil(controller.xabberInputView.mentionCandidatesProvider, file: file, line: line)
        XCTAssertNil(controller.xabberInputView.mentionMembersCountProvider, file: file, line: line)
        XCTAssertNil(controller.xabberInputView.mentionUsersReloadHandler, file: file, line: line)
    }
}

@MainActor
private final class AttachmentButtonDelegateSpy: XabberInputBarDelegate {
    private(set) var attachmentTouchCount = 0

    func attachmentButtonTouchUp() {
        attachmentTouchCount += 1
    }

    func sendButtonTouchUp(with text: String) {}
    func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload) {}
    func scheduledMessagesButtonTouchUp() {}
    func onAfterburnButtonTouchUp() {}
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {}
    func onCheckDevices() {}
    func onCheckContactDevices() {}
    func onUpdateSignature() {}
    func onIdentityVerification() {}
    func onTextDidChange(to text: String?) {}
    func onAudioMessageStartRecord(sessionID: UUID) {}
    func onAudioMessageDidCancel(sessionID: UUID) {}
    func onAudioMessageDidFinish(sessionID: UUID, intent: VoiceRecordingFinishIntent) {}
    func onAudioMessagePreviewSend(sessionID: UUID) {}
    func onAudioMessagePreviewDelete(sessionID: UUID) {}
    func recordAndPlayPanelPlayButtonTouchUp(sessionID: UUID) {}
    func didStopPlayingAudio() {}
    func didSetAudioPositionBar(percentage: Float) -> TimeInterval { 0 }
}
