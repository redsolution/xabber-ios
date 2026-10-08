import Foundation
import RealmSwift
import UIKit
import XCTest
@testable import xabber

@MainActor
final class ForwardComposerIntentTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private var keeper: Realm!
    private var window: UIWindow?
    private var previousKeyWindow: UIWindow?
    private var controller: ChatViewController?

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ForwardComposerIntent-\(UUID())")
        keeper = try! WRealm.safe()
    }

    override func tearDown() {
        controller?.performTerminalChatResourceTeardownForTesting()
        window?.isHidden = true
        window?.rootViewController = nil
        previousKeyWindow?.makeKey()
        controller = nil
        window = nil
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testSelectionReplySubmitsExplicitReplyIntentAndSuccessfulAdmissionResetsIt() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        chat.xabberInputView.setComposerText("reply comment")
        chat.draftMessageText.accept("reply comment")
        var submittedIntent: ForwardSendIntent?
        chat.omemoComposerSendAdmissionExecutor = { payload, selected, completion in
            submittedIntent = payload.forwardIntent
            XCTAssertEqual(selected, ["selected-message"])
            completion("admitted-carrier")
        }

        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "reply comment")

        XCTAssertEqual(submittedIntent, .reply)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testOwnMentionCombiningCharactersRoundTripScalarWireAndUTF16ComposerRanges() throws {
        try assertOwnMentionRange(
            body: "e\u{301} & @A\u{301}", mention: "@A\u{301}",
            rawRange: NSRange(location: 5, length: 3), wireRange: NSRange(location: 9, length: 3)
        )
    }

    func testOwnMentionZWJPrefixAndNonBMPMentionRoundTripScalarWireAndUTF16ComposerRanges() throws {
        try assertOwnMentionRange(
            body: "👩‍👩‍👧‍👦 & @😀", mention: "@😀",
            rawRange: NSRange(location: 14, length: 3), wireRange: NSRange(location: 14, length: 2)
        )
    }

    func testSelectionReplyCancelsEditTargetWithoutClearingComment() throws {
        let chat = try makeController()
        chat.editMessageId.accept("old-edit-target")
        chat.xabberInputView.setComposerText("reply comment")
        chat.draftMessageText.accept("reply comment")

        stageSelectionReply(in: chat)

        XCTAssertNil(chat.editMessageId.value)
        XCTAssertEqual(chat.xabberInputView.textField.text, "reply comment")
        XCTAssertEqual(chat.draftMessageText.value, "reply comment")
    }

    func testSwipeReplyCancelsEditTargetWithoutClearingComment() throws {
        let chat = try makeController()
        chat.editMessageId.accept("old-edit-target")
        chat.xabberInputView.setComposerText("reply comment")
        chat.draftMessageText.accept("reply comment")
        let originalCollection = chat.messagesCollectionView
        let collection = SwipeFixtureMessagesCollectionView()
        let cell = MessageCollectionViewCell(frame: .zero)
        collection.swipedCell = cell
        chat.messagesCollectionView = collection
        defer { chat.messagesCollectionView = originalCollection }
        chat.datasource = [makeSwipeRow(in: chat)]

        chat.onSwipe(cell: cell)

        XCTAssertNil(chat.editMessageId.value)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["swiped-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
        XCTAssertEqual(chat.xabberInputView.textField.text, "reply comment")
        XCTAssertEqual(chat.draftMessageText.value, "reply comment")
    }

    func testRejectedReplyAdmissionPreservesCommentSelectionAndIntent() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        chat.xabberInputView.setComposerText("unsent reply")
        chat.draftMessageText.accept("unsent reply")
        var attempts = 0
        chat.omemoComposerSendAdmissionExecutor = { payload, _, completion in
            attempts += 1
            XCTAssertEqual(payload.forwardIntent, .reply)
            completion("")
        }

        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "unsent reply")

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(chat.xabberInputView.textField.text, "unsent reply")
        XCTAssertEqual(chat.draftMessageText.value, "unsent reply")
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testDelayedReplyAdmissionDoesNotClearNewForwardSelectionWithSameIDsAndText() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        chat.xabberInputView.setComposerText("unchanged text")
        chat.draftMessageText.accept("unchanged text")
        var completion: ((String) -> Void)?
        chat.omemoComposerSendAdmissionExecutor = { payload, _, finish in
            XCTAssertEqual(payload.forwardIntent, .reply)
            completion = finish
        }
        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "unchanged text")
        let finish = try XCTUnwrap(completion)
        chat.setComposerForwardSelection(["selected-message"], intent: .forward)

        finish("admitted-old-reply")

        XCTAssertEqual(chat.xabberInputView.textField.text, "unchanged text")
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testContextPreviewRemovalAndClearAttachmentsResetReplyIntent() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)

        chat.messagesPanelOnClose()

        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        XCTAssertEqual(chat.composerForwardIntent, .forward)
        stageSelectionReply(in: chat)
        chat.clearAttachments()
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testConversationReuseDropsReplySelectionBeforeNextPeerOrOwnerSend() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)

        chat.jid = "different-peer@example.test"

        XCTAssertEqual(chat.composerForwardIntent, .forward)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        stageSelectionReply(in: chat)
        chat.owner = "different-owner@example.test"
        XCTAssertEqual(chat.composerForwardIntent, .forward)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        stageSelectionReply(in: chat)
        chat.conversationType = .omemo
        XCTAssertEqual(chat.composerForwardIntent, .forward)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
    }

    func testShareDestinationAlwaysStagesForwardAfterSourceReply() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let navigation = try XCTUnwrap(chat.navigationController)

        chat.open(owner: chat.owner, jid: "forward-target@example.test", conversationType: .regular,
                  forwarded: ["selected-message"])

        let destination = try XCTUnwrap(navigation.topViewController as? ChatViewController)
        XCTAssertFalse(destination === chat)
        XCTAssertEqual(destination.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(destination.composerForwardIntent, .forward)
        destination.performTerminalChatResourceTeardownForTesting()
    }

    func testAttachmentContextFreezesReplyIntentBeforeComposerChanges() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let context = chat.makeAttachmentFlowContext()
        chat.setComposerForwardSelection(["different-message"], intent: .forward)
        let sender = RecordingMediaSender()
        let pipeline = ChatAttachmentSendPipeline(mediaMessageSender: sender)
        var result: ChatAttachmentSendResult?

        pipeline.send(drafts: [contactDraft()], captionState: ChatAttachmentCaptionState(rawText: "caption"),
                      context: context) { result = $0 }

        XCTAssertEqual(sender.contexts.count, 1)
        XCTAssertEqual(sender.contexts.first?.forwardIntent, .reply)
        XCTAssertEqual(sender.contexts.first?.forwardedMessageIds, ["selected-message"])
        XCTAssertEqual(result, .sent(referenceCount: 1))
        XCTAssertEqual(chat.composerForwardIntent, .forward)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["different-message"])
    }

    func testMatchingAttachmentAdmissionClearsReplySelectionAndReleasesCoordinator() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testLateAttachmentAdmissionPreservesNewReplySelection() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator
        chat.setComposerForwardSelection(["new-reply-message"], intent: .reply)

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["new-reply-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testLateAttachmentAdmissionPreservesNewForwardWithSameSelectedIDs() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator
        chat.setComposerForwardSelection(["selected-message"], intent: .forward)

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testLateAttachmentAdmissionPreservesSelectionAfterOwnerReuse() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator
        chat.owner = "new-owner@example.test"
        chat.setComposerForwardSelection(["selected-message"], intent: .reply)

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testLateAttachmentAdmissionPreservesSelectionAfterPeerReuse() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator
        chat.jid = "new-peer@example.test"
        chat.setComposerForwardSelection(["selected-message"], intent: .reply)

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testLateAttachmentAdmissionPreservesSelectionAfterConversationTypeReuse() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let coordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = coordinator
        chat.conversationType = .omemo
        chat.setComposerForwardSelection(["selected-message"], intent: .reply)

        chat.chatAttachmentFlowCoordinatorDidSend(coordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testLateAttachmentAdmissionDoesNotConsumeSelectionOwnedByNewPicker() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let oldCoordinator = makeAttachmentCoordinator(in: chat)
        let newCoordinator = makeAttachmentCoordinator(in: chat)
        chat.chatAttachmentFlowCoordinator = newCoordinator

        chat.chatAttachmentFlowCoordinatorDidSend(oldCoordinator)

        XCTAssertTrue(chat.chatAttachmentFlowCoordinator === newCoordinator)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testAudioReplyUsesCapturedIntentAndRejectionRetainsRecordingAndSelection() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let sender = RecordingMediaSender()
        sender.didAdmit = false
        chat.audioMessageSender = sender
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.url = "/tmp/unsent-reply.m4a"
        chat.recordedReferenceObject = reference

        chat.sendAudioMessage(reference)

        XCTAssertEqual(sender.contexts.first?.forwardIntent, .reply)
        XCTAssertEqual(sender.contexts.first?.forwardedMessageIds, ["selected-message"])
        XCTAssertTrue(chat.recordedReferenceObject === reference)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    func testAudioAdmissionSuccessClearsOnlyMatchingReplyRecordingAndIntent() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let sender = RecordingMediaSender()
        chat.audioMessageSender = sender
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.url = "/tmp/admitted-reply.m4a"
        chat.recordedReferenceObject = reference

        chat.sendAudioMessage(reference)

        XCTAssertEqual(sender.contexts.first?.forwardIntent, .reply)
        XCTAssertNil(chat.recordedReferenceObject)
        XCTAssertTrue(chat.attachedMessagesIds.value.isEmpty)
        XCTAssertEqual(chat.composerForwardIntent, .forward)
    }

    func testRecordedPreviewReplyRejectionDoesNotRunSuccessfulSendCleanup() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let sender = RecordingMediaSender()
        sender.didAdmit = false
        chat.audioMessageSender = sender
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.url = "/tmp/rejected-preview-reply.m4a"
        let sessionID = UUID()
        chat.recordedReferenceObject = reference
        chat.recordedReferenceSessionID = sessionID
        chat.xabberInputView.audioRecordingPreviewReady(sessionID: sessionID)
        let attempted = expectation(description: "preview admission rejected")
        sender.onCompletion = { attempted.fulfill() }

        chat.onAudioMessagePreviewSend(sessionID: sessionID)
        wait(for: [attempted], timeout: 2)

        XCTAssertTrue(chat.recordedReferenceObject === reference)
        XCTAssertEqual(chat.recordedReferenceSessionID, sessionID)
        XCTAssertEqual(chat.composerForwardIntent, .reply)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
    }

    func testDelayedAudioAdmissionIgnoresSecondTapAndRejectionAllowsRetry() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let sender = RecordingMediaSender()
        sender.completesImmediately = false
        chat.audioMessageSender = sender
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.url = "/tmp/delayed-reply.m4a"
        chat.recordedReferenceObject = reference

        chat.sendAudioMessage(reference)
        chat.sendAudioMessage(reference)

        XCTAssertEqual(sender.contexts.count, 1)
        XCTAssertTrue(chat.isComposerSendAdmissionInFlight)
        let rejected = try XCTUnwrap(sender.pendingCompletions.first)
        rejected(false)
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
        XCTAssertTrue(chat.recordedReferenceObject === reference)
        XCTAssertEqual(chat.composerForwardIntent, .reply)
        chat.sendAudioMessage(reference)
        XCTAssertEqual(sender.contexts.count, 2)
        XCTAssertTrue(chat.isComposerSendAdmissionInFlight)
        let admitted = try XCTUnwrap(sender.pendingCompletions.dropFirst().first)
        admitted(true)
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
        XCTAssertNil(chat.recordedReferenceObject)
    }

    func testAudioAdmissionAfterOwnerChangeResetsGuardAndPreservesNewRecording() throws {
        let chat = try makeController()
        stageSelectionReply(in: chat)
        let sender = RecordingMediaSender()
        sender.completesImmediately = false
        chat.audioMessageSender = sender
        let oldReference = MessageReferenceStorageItem()
        oldReference.kind = .voice
        oldReference.url = "/tmp/old-owner-reply.m4a"
        chat.recordedReferenceObject = oldReference
        chat.sendAudioMessage(oldReference)
        let finish = try XCTUnwrap(sender.pendingCompletions.first)
        chat.owner = "new-owner@example.test"
        chat.setComposerForwardSelection(["new-selection"], intent: .reply)
        let newReference = MessageReferenceStorageItem()
        newReference.kind = .voice
        newReference.url = "/tmp/new-owner-reply.m4a"
        let newSessionID = UUID()
        chat.recordedReferenceObject = newReference
        chat.recordedReferenceSessionID = newSessionID

        finish(true)

        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
        XCTAssertTrue(chat.recordedReferenceObject === newReference)
        XCTAssertEqual(chat.recordedReferenceSessionID, newSessionID)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["new-selection"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
        chat.sendAudioMessage(newReference)
        XCTAssertEqual(sender.contexts.count, 2)
    }

    func testRejectedEditAdmissionPreservesCommentAndEditTarget() throws {
        let chat = try makeController()
        chat.editMessageId.accept("editable-carrier")
        chat.xabberInputView.setComposerText("unsent edited comment")
        chat.draftMessageText.accept("unsent edited comment")
        var attempts = 0
        chat.omemoComposerEditAdmissionExecutor = { payload, primary, completion in
            attempts += 1
            XCTAssertEqual(payload.body, "unsent edited comment")
            XCTAssertEqual(primary, "editable-carrier")
            completion(false)
        }

        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "unsent edited comment")

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(chat.xabberInputView.textField.text, "unsent edited comment")
        XCTAssertEqual(chat.draftMessageText.value, "unsent edited comment")
        XCTAssertEqual(chat.editMessageId.value, "editable-carrier")
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
        XCTAssertNil(chat.pendingOutgoingAutoScrollRequest)
    }

    func testSuccessfulEditAdmissionClearsOnlyMatchingCommentAndEditTarget() throws {
        let chat = try makeController()
        chat.editMessageId.accept("editable-carrier")
        chat.xabberInputView.setComposerText("edited comment")
        chat.draftMessageText.accept("edited comment")
        chat.omemoComposerEditAdmissionExecutor = { _, _, completion in completion(true) }

        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "edited comment")

        XCTAssertTrue(chat.xabberInputView.textField.text.isEmpty)
        XCTAssertNil(chat.draftMessageText.value)
        XCTAssertNil(chat.editMessageId.value)
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
    }

    func testDelayedEditAdmissionDoesNotClearNewCommentOrNewEditTarget() throws {
        let chat = try makeController()
        chat.editMessageId.accept("old-carrier")
        chat.xabberInputView.setComposerText("old comment")
        chat.draftMessageText.accept("old comment")
        var completion: ((Bool) -> Void)?
        chat.omemoComposerEditAdmissionExecutor = { _, _, finish in completion = finish }
        prepareLoadedComposerSendFixture(chat)
        chat.sendButtonTouchUp(with: "old comment")
        let finish = try XCTUnwrap(completion)
        chat.editMessageId.accept("new-carrier")
        chat.xabberInputView.setComposerText("new comment")
        chat.draftMessageText.accept("new comment")

        finish(true)

        XCTAssertEqual(chat.xabberInputView.textField.text, "new comment")
        XCTAssertEqual(chat.draftMessageText.value, "new comment")
        XCTAssertEqual(chat.editMessageId.value, "new-carrier")
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight)
    }

    private func makeController() throws -> ChatViewController {
        let chat = ChatViewController()
        chat.owner = "composer-forward@example.test"
        chat.jid = "peer@example.test"
        chat.conversationType = .regular
        let navigation = UINavigationController(rootViewController: UIViewController())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        host.frame = scene.coordinateSpace.bounds
        host.rootViewController = navigation
        host.makeKeyAndVisible()
        navigation.pushViewController(chat, animated: false)
        chat.loadViewIfNeeded()
        chat.view.frame = host.bounds
        chat.isTimeSignatureBlockingPanelopen = false
        navigation.view.layoutIfNeeded()
        prepareLoadedComposerSendFixture(chat)
        window = host
        controller = chat
        return chat
    }

    private func prepareLoadedComposerSendFixture(_ chat: ChatViewController,
        file: StaticString = #filePath, line: UInt = #line) {
        // Accountless UIKit appearance starts an offline opening skeleton.
        // Admission cases begin after an empty archive was committed; set the
        // archive presentation contract as well as its visible indicator.
        chat.archiveWindowState = .authoritativeEmpty(target: .latest,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "composer-fixture-empty"))
        chat.archiveWindowCommittedCoverageGeneration = 0
        chat.setSkeletonVisible(false)
        chat.refreshOmemoSendAvailability()
        XCTAssertFalse(chat.showSkeletonObserver.value, file: file, line: line)
        XCTAssertFalse(chat.isComposerSendAdmissionInFlight, file: file, line: line)
        XCTAssertTrue(chat.currentOmemoSendAvailability().canSend, file: file, line: line)
        XCTAssertEqual(chat.xabberInputView.state, .normal, file: file, line: line)
        XCTAssertNil(chat.recordedReferenceObject, file: file, line: line)
        #if DEBUG || CHAT_PERFORMANCE_LAB
        XCTAssertNil(chat.performanceFixtureSendHandler, file: file, line: line)
        #endif
    }

    private func stageSelectionReply(in chat: ChatViewController) {
        chat.forwardedIds.accept(["selected-message"])
        chat.selectionPanel(onReply: chat.xabberInputView.selectionPanel)
        XCTAssertEqual(chat.attachedMessagesIds.value, ["selected-message"])
        XCTAssertEqual(chat.composerForwardIntent, .reply)
    }

    private func assertOwnMentionRange(body: String, mention: String, rawRange: NSRange, wireRange: NSRange,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let candidate = ComposerMentionCandidate(memberId: "member-unicode", nickname: mention,
            uri: "xmpp:group@example.test?members;id=member-unicode", node: nil, jid: nil,
            secondaryText: "member-unicode")
        let attributed = NSMutableAttributedString(string: body)
        attributed.addAttribute(.composerMention, value: candidate.mentionEntity, range: rawRange)

        let payload = ComposerMentionSerializer.payload(from: attributed)
        let reference = try XCTUnwrap(payload.references.first, file: file, line: line)

        XCTAssertEqual((body as NSString).substring(with: rawRange), mention, file: file, line: line)
        XCTAssertEqual(payload.references.count, 1, file: file, line: line)
        XCTAssertEqual(reference.range, wireRange, file: file, line: line)
        XCTAssertEqual(ComposerMentionRangeCodec.escapedRange(for: rawRange, in: body), wireRange,
            file: file, line: line)
        XCTAssertEqual(ComposerMentionRangeCodec.rawRange(for: wireRange, in: body), rawRange,
            file: file, line: line)
        let restored = ComposerMentionSerializer.attributedText(body: body, references: [reference],
            baseAttributes: [:], mentionAttributesProvider: { [.composerMention: $0] })
        var restoredRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertNotNil(restored.attribute(.composerMention, at: rawRange.location,
            effectiveRange: &restoredRange), file: file, line: line)
        XCTAssertEqual(restoredRange, rawRange, file: file, line: line)
    }

    private func makeAttachmentCoordinator(in chat: ChatViewController) -> ChatAttachmentFlowCoordinator {
        ChatAttachmentFlowCoordinator(presentingViewController: chat, context: chat.makeAttachmentFlowContext())
    }

    private func makeSwipeRow(in chat: ChatViewController) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "swiped-message", jid: chat.jid, owner: chat.owner, outgoing: false,
            sender: Sender(id: chat.jid, displayName: "Peer"), messageId: "swiped-message",
            sentDate: Date(timeIntervalSince1970: 100), editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Original")),
            withAuthor: false, withAvatar: false, error: false, errorType: "",
            canPinMessage: false, canEditMessage: false, canDeleteMessage: true,
            forwards: [], isOutgoing: false, isEdited: false,
            groupchatAuthorRole: "", groupchatAuthorId: "", groupchatAuthorNickname: "", groupchatAuthorBadge: "",
            isHasAttachedMessages: false, isDownloaded: true, state: .deliver,
            searchString: nil, burnDate: -1, afterburnInterval: -1,
            archivedId: "swiped-message", queryIds: nil, isRead: true,
            images: [], videos: [], files: [], audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"), indicator: .none, avatarUrl: nil
        )
    }

    private func contactDraft() -> AttachmentDraft {
        let contact = AttachmentPreparedContact(jid: "alice@example.test", nickname: "Alice", given: nil,
            family: nil, displayTitle: "Alice", avatarURL: nil, avatarMetadata: [:])
        return AttachmentDraft(id: "contact:alice@example.test", source: .contact, mediaKind: .contact,
            thumbnailState: .none, filename: "Alice", byteSize: 0, duration: nil, dimensions: nil,
            preparationState: .preparedContact(contact))
    }

    private final class RecordingMediaSender: ChatAttachmentMediaMessageSending {
        var contexts: [ChatAttachmentFlowContext] = []
        var didAdmit = true
        var onCompletion: (() -> Void)?
        var completesImmediately = true
        var pendingCompletions: [(Bool) -> Void] = []
        func sendMediaMessage(references: [MessageReferenceStorageItem], body: String, legacyBody: String,
                              requiresUpload: Bool, context: ChatAttachmentFlowContext,
                              completion: @escaping (Bool) -> Void) {
            contexts.append(context)
            if completesImmediately {
                completion(didAdmit)
                onCompletion?()
            } else {
                pendingCompletions.append(completion)
            }
        }
    }

    private final class SwipeFixtureMessagesCollectionView: MessagesCollectionView {
        weak var swipedCell: UICollectionViewCell?

        override func indexPath(for cell: UICollectionViewCell) -> IndexPath? {
            cell === swipedCell ? IndexPath(item: 0, section: 0) : nil
        }
    }
}
