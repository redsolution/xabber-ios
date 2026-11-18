import XCTest
import UIKit
import XMPPFramework
@testable import xabber

@MainActor
final class ScheduledComposerSubmissionTests: XCTestCase {
    func testOMEMO2ComposerOnlyUsesTheEncryptedScheduleRoute() {
        let (controller, service) = makeController()
        controller.conversationType = .omemo
        service.canScheduleOMEMO2 = true
        controller.sendScheduledMessage(
            payload: controller.xabberInputView.currentPayload(),
            deliverAt: Date().addingTimeInterval(3600)
        )

        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(service.encryptedRequests.first?.body, "Original draft")
        XCTAssertEqual(service.encryptedRequests.first?.conversationType, .omemo)
        XCTAssertNil(controller.draftMessageText.value)
    }

    func testScheduledStickerPreservesTheComposerAndUsesThePreparedPacket() throws {
        let (controller, service) = makeController()
        let sticker = ChatStickerDescriptor(
            name: "Owl", packURL: try XCTUnwrap(URL(string: "https://stickers.example.org/pack.xml")),
            imageURL: try XCTUnwrap(URL(string: "https://stickers.example.org/owl.png")), emoji: "🦉"
        )

        controller.sendScheduledSticker(sticker, deliverAt: Date().addingTimeInterval(3600))

        XCTAssertEqual(controller.draftMessageText.value, "Original draft")
        let payload = try XCTUnwrap(service.preparedRequest?.payload)
        XCTAssertEqual(payload.body, "🦉")
        XCTAssertTrue(ChatStickerWireCodec.containsSticker(in: payload))
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testUploadedFileWithoutCaptionMakesAScheduleWithTheExactChatRoute() throws {
        let service = ScheduleService()
        let context = ChatAttachmentFlowContext(
            owner: "second@example.com", jid: "peer@example.com", conversationType: .regular,
            forwardedMessageIds: []
        )
        let attachment = makeUploadedFile(owner: context.owner, jid: context.jid)
        let date = Date().addingTimeInterval(3600)
        var accepted = false

        ChatScheduledMessageSendCoordinator(service: service).scheduleAttachments(
            [attachment], caption: .init(), context: context, deliverAt: date
        ) { result in
            if case .success = result { accepted = true }
        }

        XCTAssertTrue(accepted)
        XCTAssertTrue(service.requests.isEmpty)
        let submitted = try XCTUnwrap(service.preparedRequest)
        XCTAssertEqual(submitted.owner, context.owner)
        XCTAssertEqual(submitted.conversation, context.jid)
        XCTAssertEqual(submitted.type, context.conversationType)
        XCTAssertEqual(submitted.deliverAt, date)
        XCTAssertEqual(submitted.payload.body, attachment.fileSharingURI)
        XCTAssertTrue(submitted.payload.xmlString.contains("file-sharing"))
    }

    func testUnuploadedOrExpiredAttachmentNeverReachesScheduleService() {
        let service = ScheduleService()
        let context = ChatAttachmentFlowContext(
            owner: "second@example.com", jid: "peer@example.com", conversationType: .regular,
            forwardedMessageIds: []
        )
        let attachment = makeUploadedFile(owner: context.owner, jid: context.jid)
        let coordinator = ChatScheduledMessageSendCoordinator(service: service)
        var failures: [XMPPMessageScheduleManager.ScheduleError] = []
        func record(_ result: Result<Void, XMPPMessageScheduleManager.ScheduleError>) {
            if case .failure(let error) = result { failures.append(error) }
        }

        coordinator.scheduleAttachments([attachment], caption: .init(), context: context,
                                         deliverAt: Date().addingTimeInterval(-60), completion: record)
        attachment.isUploaded = false
        coordinator.scheduleAttachments([attachment], caption: .init(), context: context,
                                         deliverAt: Date().addingTimeInterval(3600), completion: record)

        XCTAssertEqual(failures, [.notAcceptable, .malformedPayload])
        XCTAssertNil(service.preparedRequest)
    }

    func testNativeScheduledComposerPreservesMemberMentionIntent() {
        let (controller, service) = makeController()
        controller.conversationType = .group
        let payload = ComposerMessagePayload(
            body: "Hello @Lena", references: [], groupMentionIntent: .members(["member-lena"]),
            groupMentionSenderRole: .member
        )

        controller.sendScheduledMessage(payload: payload, deliverAt: Date().addingTimeInterval(3600))

        XCTAssertEqual(service.requests.first?.groupMentionIntent, .members(["member-lena"]))
    }

    private func makeUploadedFile(owner: String, jid: String) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.owner = owner
        reference.jid = jid
        reference.isUploaded = true
        reference.metadata = [
            "uri": "https://files.example.com/report.pdf",
            "filename": "report.pdf", "name": "report.pdf",
            "media-type": "application/pdf", "size": 100
        ]
        return reference
    }

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
    private(set) var encryptedRequests: [ChatScheduledMessageSendRequest] = []
    var canScheduleOMEMO2 = false
    private var callback: XMPPMessageScheduleManager.ScheduleCallback?
    private(set) var preparedRequest: (
        payload: XMPPMessage, owner: String, conversation: String,
        type: ClientSynchronizationManager.ConversationType, deliverAt: Date
    )?

    func isScheduleAvailable(owner: String) -> Bool { true }

    func validateOMEMO2ScheduleRoute(owner: String, conversation: String) -> XMPPMessageScheduleManager.ScheduleError? {
        canScheduleOMEMO2 ? nil : .forbidden
    }

    func scheduleOMEMO2Message(
        _ request: ChatScheduledMessageSendRequest,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        encryptedRequests.append(request)
        callback(.success(.init(
            scheduledId: "sealed-id", conversation: request.conversation, conversationType: .omemo,
            deliverAt: request.deliverAt, status: .pending, messageXML: "<message/>"
        )))
    }

    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        requests.append(request)
        self.callback = callback
        return "request"
    }

    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        preparedRequest = (payload, owner, conversation, conversationType, deliverAt)
        callback?(.success(.init(
            scheduledId: "prepared-id", conversation: conversation, conversationType: conversationType,
            deliverAt: deliverAt, status: .pending, messageXML: payload.xmlString
        )))
        return "prepared-query"
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
