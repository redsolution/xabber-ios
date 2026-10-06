import Foundation
import RealmSwift
import UIKit
import XCTest
@testable import xabber

/// UI coverage prepared before N08 implementation; no UIAlertAction KVC.
@MainActor
final class OMEMO2NormativeOptOutUITests: XCTestCase {
    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    private let owner = "n08-ui-owner@example.test"
    private let peer = "n08-ui-peer@example.test"

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N08-UI-\(UUID().uuidString.lowercased())")
        keeper = try WRealm.safe()
    }
    override func tearDown() {
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testPendingOptOutShowsReviewActionAndBlocksEncryptedComposer() throws {
        try withController(type: .omemo) { controller, _ in
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
            XCTAssertEqual(controller.xabberInputView.stateButton.accessibilityIdentifier, "omemo.optout.review")
            XCTAssertFalse(controller.xabberInputView.stateButton.isHidden)
            XCTAssertTrue(controller.xabberInputView.textField.isHidden)
            XCTAssertTrue(controller.xabberInputView.attachButton.isHidden)
            XCTAssertTrue(controller.xabberInputView.recordButton.isHidden)
            XCTAssertFalse(controller.xabberInputView.isSendButtonEnabled)
        }
    }

    func testPendingOptOutBlocksRegularComposerAndReadinessRefresh() throws {
        try withController(type: .regular) { controller, _ in
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            XCTAssertEqual(controller.currentOmemoSendAvailability(), .blockedByPendingOptOut)
            controller.applyBaseSendButtonReadiness(isSkeletonVisible: false,
                isAccountConnecting: false, hasPendingOrFailedMessage: false)
            XCTAssertFalse(controller.xabberInputView.isSendButtonEnabled)
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
        }
    }

    func testPendingOptOutPreservesExistingDraft() throws {
        try withController(type: .omemo) { controller, _ in
            controller.draftMessageText.accept("Unsent draft")
            controller.xabberInputView.setComposerText("Unsent draft")
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            XCTAssertEqual(controller.draftMessageText.value, "Unsent draft")
            XCTAssertEqual(controller.xabberInputView.textField.text, "Unsent draft")
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
        }
    }

    func testPendingOptOutCancelsActiveRecordingBeforeHidingItsControls() throws {
        try withController(type: .omemo) { controller, _ in
            let sessionID = UUID()
            controller.activeAudioRecordingSessionID = sessionID
            _ = controller.xabberInputView.voiceRecordingInteraction.beginPress(sessionID: sessionID, at: 10)
            _ = controller.xabberInputView.voiceRecordingInteraction.recorderStarted(sessionID: sessionID)
            controller.xabberInputView.changeState(to: .record)
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            XCTAssertNil(controller.activeAudioRecordingSessionID)
            XCTAssertEqual(controller.xabberInputView.voiceRecordingInteraction.state, .idle)
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
        }
    }

    func testReviewPromptShowsExplicitChoicesAndReasonWithoutImplicitResolution() throws {
        try withController(type: .omemo, reason: "Contact prefers plaintext.") { controller, _ in
            var decisions: [OMEMO2OptOutPolicy.Decision] = []
            controller.omemoOptOutDecisionExecutor = { decision, _ in decisions.append(decision) }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.presentOMEMO2OptOutDecisionPrompt()
            let prompt = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
            XCTAssertEqual(prompt.view.accessibilityIdentifier, "omemo.optout.confirmation")
            XCTAssertEqual(prompt.actions.map(\.style), [.cancel, .default, .destructive])
            XCTAssertTrue(prompt.message?.contains("Contact prefers plaintext.") == true)
            XCTAssertTrue(decisions.isEmpty)
            XCTAssertEqual(try projectedDecision(), .pending)
        }
    }

    func testDismissingPromptLeavesPendingGateAndComposerBlocked() throws {
        try withController(type: .regular) { controller, _ in
            var resolutions = 0
            controller.omemoOptOutDecisionExecutor = { _, _ in resolutions += 1 }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.presentOMEMO2OptOutDecisionPrompt()
            XCTAssertNotNil(controller.presentedViewController)
            controller.dismiss(animated: false)
            XCTAssertEqual(resolutions, 0)
            XCTAssertEqual(try projectedDecision(), .pending)
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
            XCTAssertFalse(controller.xabberInputView.isSendButtonEnabled)
        }
    }

    func testExplicitPlaintextChoiceRoutesNewRegularChatAndPreservesEncryptedHistory() throws {
        try installEncryptedHistory()
        try withController(type: .omemo) { controller, navigation in
            var decisions: [OMEMO2OptOutPolicy.Decision] = []
            controller.omemoOptOutDecisionExecutor = { decision, completion in
                decisions.append(decision)
                do {
                    try self.setProjectedDecision(decision)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.performOMEMO2OptOutDecision(.plaintext)
            let regular = try XCTUnwrap(navigation.topViewController as? ChatViewController)
            XCTAssertFalse(regular === controller)
            XCTAssertEqual(regular.owner, owner)
            XCTAssertEqual(regular.jid, peer)
            XCTAssertEqual(regular.conversationType, .regular)
            XCTAssertEqual(controller.conversationType, .omemo)
            XCTAssertEqual(decisions, [.plaintext])
            let history = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self,
                forPrimaryKey: MessageStorageItem.genPrimary(messageId: "n08-encrypted-history", owner: owner)))
            XCTAssertEqual(history.body, "Saved encrypted history")
            XCTAssertEqual(history.conversationType, .omemo)
            XCTAssertEqual(try projectedDecision(), .plaintext)
        }
    }

    func testExplicitKeepEncryptionChoiceRetainsEncryptedRoute() throws {
        try withController(type: .omemo) { controller, navigation in
            var decisions: [OMEMO2OptOutPolicy.Decision] = []
            controller.omemoOptOutDecisionExecutor = { decision, completion in
                decisions.append(decision)
                do {
                    try self.setProjectedDecision(decision)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.performOMEMO2OptOutDecision(.omemo)
            XCTAssertTrue(navigation.topViewController === controller)
            XCTAssertEqual(controller.conversationType, .omemo)
            XCTAssertEqual(decisions, [.omemo])
            XCTAssertEqual(try projectedDecision(), .omemo)
            XCTAssertNotEqual(controller.xabberInputView.state, .pendingOptOut)
        }
    }

    func testFailedDecisionKeepsPendingRouteAndAllowsReviewRetry() throws {
        try withController(type: .omemo) { controller, navigation in
            controller.omemoOptOutDecisionExecutor = { _, completion in
                completion(.failure(NSError(domain: "N08-UI", code: 1)))
            }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.performOMEMO2OptOutDecision(.plaintext)
            XCTAssertTrue(navigation.topViewController === controller)
            XCTAssertEqual(try projectedDecision(), .pending)
            XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut)
            XCTAssertFalse(controller.xabberInputView.isSendButtonEnabled)
            XCTAssertTrue(controller.xabberInputView.stateButton.isEnabled)
        }
    }

    func testExplicitKeepEncryptionFromRegularChatRoutesNewOMEMOController() throws {
        try withController(type: .regular) { controller, navigation in
            controller.omemoOptOutDecisionExecutor = { decision, completion in
                do {
                    try self.setProjectedDecision(decision)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.performOMEMO2OptOutDecision(.omemo)
            let encrypted = try XCTUnwrap(navigation.topViewController as? ChatViewController)
            XCTAssertFalse(encrypted === controller)
            XCTAssertEqual(encrypted.owner, owner)
            XCTAssertEqual(encrypted.jid, peer)
            XCTAssertEqual(encrypted.conversationType, .omemo)
            XCTAssertEqual(controller.conversationType, .regular)
            XCTAssertEqual(try projectedDecision(), .omemo)
        }
    }

    func testDecisionInFlightCannotQueueConflictingSecondDecision() throws {
        try withController(type: .omemo) { controller, _ in
            var decisions: [OMEMO2OptOutPolicy.Decision] = []
            var finish: ((Result<Void, Error>) -> Void)?
            controller.omemoOptOutDecisionExecutor = { decision, completion in
                decisions.append(decision)
                finish = completion
            }
            controller.onUpdateOmemoSendAvailability(.blockedByPendingOptOut)
            controller.performOMEMO2OptOutDecision(.plaintext)
            controller.performOMEMO2OptOutDecision(.omemo)
            XCTAssertEqual(decisions, [.plaintext])
            XCTAssertFalse(controller.xabberInputView.stateButton.isEnabled)
            try XCTUnwrap(finish)(.failure(NSError(domain: "N08-UI", code: 2)))
            XCTAssertTrue(controller.xabberInputView.stateButton.isEnabled)
            XCTAssertEqual(try projectedDecision(), .pending)
        }
    }

    func testProjectionIsScopedToPeerAndAccount() throws {
        try installPending(peer: "other@example.test", account: owner)
        try installPending(peer: peer, account: "other-owner@example.test")
        let controller = ChatViewController()
        controller.owner = owner; controller.jid = peer; controller.conversationType = .regular
        XCTAssertEqual(controller.currentOmemoSendAvailability(), .canSend)
    }

    func testRejectedComposerAdmissionRetainsDraftAndAttachmentsForRegularAndOMEMO() throws {
        for type in [ClientSynchronizationManager.ConversationType.regular, .omemo] {
            try withController(type: type) { controller, _ in
                try setProjectedDecision(.none)
                try installTrustedSendProjection()
                controller.refreshOmemoSendAvailability()
                controller.xabberInputView.setComposerText("Unsent draft")
                controller.draftMessageText.accept("Unsent draft")
                controller.attachedMessagesIds.accept(["held-forward"])
                var admissions = 0
                controller.omemoComposerSendAdmissionExecutor = { payload, forwards, completion in
                    admissions += 1
                    XCTAssertEqual(payload.body, "Unsent draft")
                    XCTAssertEqual(forwards, ["held-forward"])
                    do { try self.setProjectedDecision(.pending) }
                    catch { XCTFail("Could not update pending presentation: \(error)") }
                    completion("")
                }

                prepareLoadedComposerSendFixture(controller)
                controller.sendButtonTouchUp(with: "Unsent draft")

                XCTAssertEqual(admissions, 1, type.rawValue)
                XCTAssertEqual(controller.xabberInputView.textField.text, "Unsent draft", type.rawValue)
                XCTAssertEqual(controller.draftMessageText.value, "Unsent draft", type.rawValue)
                XCTAssertEqual(controller.attachedMessagesIds.value, ["held-forward"], type.rawValue)
                XCTAssertEqual(controller.xabberInputView.state, .pendingOptOut, type.rawValue)
                XCTAssertNil(controller.pendingOutgoingAutoScrollRequest, type.rawValue)
            }
        }
    }

    func testAsynchronousAdmissionPreservesNewTypingAndClearsOnlyMatchingCapturedComposer() throws {
        for type in [ClientSynchronizationManager.ConversationType.regular, .omemo] {
            try withController(type: type) { controller, _ in
                try setProjectedDecision(.none)
                try installTrustedSendProjection()
                controller.refreshOmemoSendAvailability()
                controller.xabberInputView.setComposerText("Original draft")
                controller.draftMessageText.accept("Original draft")
                controller.attachedMessagesIds.accept(["original-forward"])
                var completion: ((String) -> Void)?
                controller.omemoComposerSendAdmissionExecutor = { _, _, finish in completion = finish }
                prepareLoadedComposerSendFixture(controller)
                controller.sendButtonTouchUp(with: "Original draft")
                XCTAssertEqual(controller.xabberInputView.textField.text, "Original draft", type.rawValue)
                XCTAssertEqual(controller.attachedMessagesIds.value, ["original-forward"], type.rawValue)
                guard let firstCompletion = completion else { return XCTFail("Expected deferred send admission") }

                controller.xabberInputView.setComposerText("New typing")
                controller.draftMessageText.accept("New typing")
                controller.attachedMessagesIds.accept(["new-forward"])
                firstCompletion("admitted-first")

                XCTAssertEqual(controller.xabberInputView.textField.text, "New typing", type.rawValue)
                XCTAssertEqual(controller.draftMessageText.value, "New typing", type.rawValue)
                XCTAssertEqual(controller.attachedMessagesIds.value, ["new-forward"], type.rawValue)
                completion = nil
                prepareLoadedComposerSendFixture(controller)
                controller.sendButtonTouchUp(with: "New typing")
                guard let secondCompletion = completion else { return XCTFail("Expected second deferred send admission") }
                secondCompletion("admitted-second")
                XCTAssertTrue(controller.xabberInputView.textField.text.isEmpty, type.rawValue)
                XCTAssertNil(controller.draftMessageText.value, type.rawValue)
                XCTAssertTrue(controller.attachedMessagesIds.value.isEmpty, type.rawValue)
            }
        }
    }

    private func prepareLoadedComposerSendFixture(_ controller: ChatViewController,
        file: StaticString = #filePath, line: UInt = #line) {
        // The accountless presentation starts an offline archive skeleton during
        // UIKit appearance. These admission scenarios begin with a loaded chat.
        controller.showSkeletonObserver.accept(false)
        XCTAssertFalse(controller.showSkeletonObserver.value, file: file, line: line)
        XCTAssertFalse(controller.isComposerSendAdmissionInFlight, file: file, line: line)
        XCTAssertTrue(controller.currentOmemoSendAvailability().canSend, file: file, line: line)
        XCTAssertEqual(controller.xabberInputView.state, .normal, file: file, line: line)
        XCTAssertNil(controller.recordedReferenceObject, file: file, line: line)
        XCTAssertNil(controller.editMessageId.value, file: file, line: line)
        #if DEBUG || CHAT_PERFORMANCE_LAB
        XCTAssertNil(controller.performanceFixtureSendHandler, file: file, line: line)
        #endif
    }

    private func installTrustedSendProjection() throws {
        try keeper.write {
            for jid in [owner, peer] {
                let list = keeper.object(ofType: OMEMO2DeviceListStorageItem.self,
                    forPrimaryKey: OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: jid)) ?? OMEMO2DeviceListStorageItem()
                if list.realm == nil {
                    list.owner = owner; list.jid = jid
                    list.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: jid)
                }
                list.isKnown = true
                list.deviceIDs.removeAll(); list.deviceIDs.append(41)
                let device = keeper.object(ofType: SignalDeviceStorageItem.self,
                    forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: 41)) ?? SignalDeviceStorageItem()
                if device.realm == nil {
                    device.owner = owner; device.jid = jid; device.deviceId = 41
                    device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: 41)
                }
                device.state = .trusted; device.isInDeviceList = true
                keeper.add(list, update: .modified)
                keeper.add(device, update: .modified)
            }
        }
    }

    private func installPending(peer: String? = nil, account: String? = nil, reason: String? = nil) throws {
        let item = OMEMO2OptOutStorageItem()
        item.owner = account ?? owner; item.jid = peer ?? self.peer
        item.primary = OMEMO2OptOutStorageItem.genPrimary(owner: item.owner, jid: item.jid)
        item.decisionRaw = OMEMO2OptOutPolicy.Decision.pending.rawValue
        item.reason = reason
        try keeper.write { keeper.add(item, update: .modified) }
    }
    private func projectedDecision() throws -> OMEMO2OptOutPolicy.Decision {
        OMEMO2OptOutPolicy.projectedDecision(owner: owner, jid: peer, realm: keeper)
    }
    private func setProjectedDecision(_ decision: OMEMO2OptOutPolicy.Decision) throws {
        let item = try XCTUnwrap(keeper.object(ofType: OMEMO2OptOutStorageItem.self,
            forPrimaryKey: OMEMO2OptOutStorageItem.genPrimary(owner: owner, jid: peer)))
        try keeper.write { item.decisionRaw = decision.rawValue }
    }
    private func installEncryptedHistory() throws {
        let item = MessageStorageItem()
        item.owner = owner; item.opponent = peer; item.messageId = "n08-encrypted-history"
        item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: owner)
        item.body = "Saved encrypted history"; item.conversationType = .omemo
        item.date = Date(timeIntervalSince1970: 100); item.sentDate = item.date
        try keeper.write { keeper.add(item, update: .modified) }
    }
    private func withController(type: ClientSynchronizationManager.ConversationType, reason: String? = nil,
        _ body: (ChatViewController, UINavigationController) throws -> Void) throws {
        try installPending(reason: reason)
        let controller = ChatViewController()
        controller.owner = owner; controller.jid = peer; controller.conversationType = type
        let navigation = UINavigationController(rootViewController: UIViewController())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = navigation
        navigation.loadViewIfNeeded()
        window.makeKeyAndVisible()
        navigation.pushViewController(controller, animated: false)
        defer {
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.loadViewIfNeeded(); controller.view.frame = window.bounds
        controller.isTimeSignatureBlockingPanelopen = false
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        controller.showSkeletonObserver.accept(false)
        XCTAssertTrue(controller.navigationController === navigation)
        XCTAssertTrue(navigation.topViewController === controller)
        XCTAssertTrue(controller.view.window === window)
        try body(controller, navigation)
    }
}
