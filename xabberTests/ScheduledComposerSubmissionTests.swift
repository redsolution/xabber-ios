import XCTest
import UIKit
@testable import xabber

@MainActor
final class ScheduledComposerSubmissionTests: XCTestCase {
    func testLateConfirmationPreservesADifferentDraftAndPreventsDuplicateSubmission() {
        let (controller, service) = makeController()
        let payload = controller.xabberInputView.currentPayload()
        let date = Date().addingTimeInterval(3600)

        controller.sendScheduledMessage(payload: payload, deliverAt: date)
        controller.sendScheduledMessage(payload: payload, deliverAt: date)
        controller.xabberInputView.setComposerText("New draft")
        controller.draftMessageText.accept("New draft")
        service.confirm()

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertFalse(controller.isComposerSendAdmissionInFlight)
        XCTAssertEqual(controller.xabberInputView.textField.text, "New draft")
        XCTAssertEqual(controller.draftMessageText.value, "New draft")
    }

    func testConfirmationClearsOnlyTheSubmittedComposer() {
        let (controller, service) = makeController()

        controller.sendScheduledMessage(
            payload: controller.xabberInputView.currentPayload(),
            deliverAt: Date().addingTimeInterval(3600)
        )
        service.confirm()

        XCTAssertFalse(controller.isComposerSendAdmissionInFlight)
        XCTAssertTrue((controller.xabberInputView.textField.text ?? "").isEmpty)
        XCTAssertNil(controller.draftMessageText.value)
    }

    func testLateConfirmationAfterSwitchingChatKeepsTheNewDraft() {
        let (controller, service) = makeController()

        controller.sendScheduledMessage(
            payload: controller.xabberInputView.currentPayload(),
            deliverAt: Date().addingTimeInterval(3600)
        )
        controller.jid = "another@example.com"
        service.confirm()

        XCTAssertEqual(controller.draftMessageText.value, "Original draft")
        XCTAssertFalse(controller.isComposerSendAdmissionInFlight)
    }

    func testUnknownOutcomePreservesTheDraftAndReleasesTheComposer() {
        let (controller, service) = makeController()

        controller.sendScheduledMessage(
            payload: controller.xabberInputView.currentPayload(),
            deliverAt: Date().addingTimeInterval(3600)
        )
        service.timeout()

        XCTAssertEqual(service.requests.count, 1)
        XCTAssertFalse(controller.isComposerSendAdmissionInFlight)
        XCTAssertEqual(controller.xabberInputView.textField.text, "Original draft")
        XCTAssertEqual(controller.draftMessageText.value, "Original draft")
    }

    func testRecoveryKeepsTheCalendarAvailableAfterTheLastScheduleWasCancelled() throws {
        let (controller, service) = makeController()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ScheduledMessageActionJournal(directory: directory)
        let item = ScheduledMessageListItem(
            scheduledId: "cancelled-id",
            deliverAt: Date().addingTimeInterval(3600),
            status: .pending,
            bodyPreview: "Recover this",
            owner: controller.owner,
            conversation: controller.jid,
            conversationType: .regular,
            messageXML: "<message xmlns='jabber:client'><body>Recover this</body></message>"
        )
        XCTAssertTrue(journal.begin(item: item, action: .sendNow))
        controller.scheduledMessageActionCoordinator = ScheduledMessageActionCoordinator(service: service, journal: journal)
        controller.xabberInputView.clearComposer()

        controller.refreshScheduledMessagesComposerButtonState()

        XCTAssertTrue(controller.xabberInputView.hasScheduledMessagesForCurrentChat)
    }

    private func makeController() -> (ChatViewController, ScheduleService) {
        let service = ScheduleService()
        let controller = ChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "peer@example.com"
        controller.conversationType = .regular
        controller.xabberInputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        controller.xabberInputView.setComposerText("Original draft")
        controller.draftMessageText.accept("Original draft")
        controller.scheduledMessageService = service
        return (controller, service)
    }
}

private final class ScheduleService: ChatScheduledMessageServicing {
    private(set) var requests: [ChatScheduledMessageSendRequest] = []
    private var callback: XMPPMessageScheduleManager.ScheduleCallback?

    func isScheduleAvailable(owner: String) -> Bool { true }

    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        requests.append(request)
        self.callback = callback
        return "request"
    }

    func confirm() {
        guard let request = requests.first else {
            XCTFail("Expected a submitted schedule")
            return
        }
        callback?(.success(.init(
            scheduledId: "server-id",
            conversation: request.conversation,
            conversationType: request.conversationType,
            deliverAt: request.deliverAt,
            status: .pending,
            messageXML: "<message><body>Original draft</body></message>"
        )))
        callback = nil
    }

    func timeout() {
        callback?(.failure(.timeout))
        callback = nil
    }

    func listScheduledMessages(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        callback: XMPPMessageScheduleManager.ListCallback?
    ) -> String? { nil }

    func cancelScheduledMessage(
        owner: String,
        scheduledId: String,
        callback: XMPPMessageScheduleManager.CancelCallback?
    ) -> String? { nil }
}
