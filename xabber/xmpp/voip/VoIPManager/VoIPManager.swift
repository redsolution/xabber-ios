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
//

import Foundation
import CallKit
import UIKit
import CryptoSwift
import RealmSwift
import RxSwift
import RxCocoa
import XMPPFramework
import CocoaLumberjack
import WebRTC

protocol VoIPScheduledTask {
    func cancel()
}

protocol VoIPCallTimeoutScheduling {
    @discardableResult
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> VoIPScheduledTask
}

final class DispatchVoIPScheduledTask: VoIPScheduledTask {
    private var workItem: DispatchWorkItem?

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

final class DispatchVoIPCallTimeoutScheduler: VoIPCallTimeoutScheduling {
    @discardableResult
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> VoIPScheduledTask {
        let workItem = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchVoIPScheduledTask(workItem: workItem)
    }
}

enum CallSessionPhase {
    case awaitingConfirmation
    case ringing
    case waitingRemoteOffer
    case creatingLocalOffer
    case connectingMedia
    case connected
    case ending
    case ended
}

enum CallTerminationTrigger {
    case localEnd
    case incomingUnansweredTimeout
    case outgoingUnansweredTimeout
    case confirmationFailure
    case mediaFailure
    case appAcceptFailure
    case answerActionTimeout
    case endActionTimeout
    case remoteEvent
    case connectionFailure
}

enum CallTerminationReason: String {
    case missed
    case rejectedByCallee
    case canceledByCaller
    case incomingUnansweredTimeout
    case outgoingUnansweredTimeout
    case remoteHangup
    case localHangup
    case connectionError
    case signalingError
    case webRTCFailure
    case answeredElsewhere
    case declinedElsewhere

    func legacyState(outgoing: Bool) -> MessageStorageItem.VoIPCallState {
        switch self {
        case .missed, .incomingUnansweredTimeout:
            return .missed
        case .canceledByCaller:
            return outgoing ? .noanswer : .missed
        case .rejectedByCallee, .declinedElsewhere:
            return .busy
        case .outgoingUnansweredTimeout:
            return .noanswer
        case .remoteHangup, .localHangup, .answeredElsewhere:
            return .made
        case .connectionError, .signalingError, .webRTCFailure:
            return outgoing ? .noanswer : .missed
        }
    }

    func callKitReason(outgoing: Bool) -> CXCallEndedReason {
        switch self {
        case .incomingUnansweredTimeout, .outgoingUnansweredTimeout, .missed:
            return .unanswered
        case .answeredElsewhere:
            return .answeredElsewhere
        case .rejectedByCallee, .canceledByCaller, .remoteHangup, .declinedElsewhere:
            return .remoteEnded
        case .localHangup:
            return .remoteEnded
        case .connectionError, .signalingError, .webRTCFailure:
            return .failed
        }
    }
}

final class CallSessionContext {
    let callId: String
    let callUUID: UUID
    let owner: String
    var jid: String
    let outgoing: Bool

    var phase: CallSessionPhase
    var incomingTimeoutTask: VoIPScheduledTask?
    var outgoingTimeoutTask: VoIPScheduledTask?
    var confirmationTimeoutTask: VoIPScheduledTask?
    var mediaSetupTimeoutTask: VoIPScheduledTask?
    var didReportIncomingCall: Bool = false
    var localEndRequested: Bool = false
    var localAnswerRequested: Bool = false
    var remoteAcceptReceived: Bool = false
    var remoteOfferReceived: Bool = false
    var localOfferSent: Bool = false
    var remoteAnswerReceived: Bool = false
    var lastTerminationReason: CallTerminationReason?
    var pendingAnswerRequested: Bool = false
    var pendingAnswerAction: CXAnswerCallAction?

    init(callId: String, callUUID: UUID, owner: String, jid: String, outgoing: Bool, phase: CallSessionPhase) {
        self.callId = callId
        self.callUUID = callUUID
        self.owner = owner
        self.jid = jid
        self.outgoing = outgoing
        self.phase = phase
    }

    func cancelTimers() {
        incomingTimeoutTask?.cancel()
        outgoingTimeoutTask?.cancel()
        confirmationTimeoutTask?.cancel()
        mediaSetupTimeoutTask?.cancel()
        incomingTimeoutTask = nil
        outgoingTimeoutTask = nil
        confirmationTimeoutTask = nil
        mediaSetupTimeoutTask = nil
    }

    func setPendingAnswerAction(_ action: CXAnswerCallAction?) {
        pendingAnswerAction?.fail()
        pendingAnswerRequested = true
        pendingAnswerAction = action
    }

    func clearPendingAnswerRequest(failAction: Bool) {
        if failAction {
            pendingAnswerAction?.fail()
        }
        pendingAnswerAction = nil
        pendingAnswerRequested = false
    }
}

class VoIPManager: NSObject {
   
    open class var shared: VoIPManager {
        struct VoIPManagerSingleton {
            static let instance = VoIPManager()
        }
        return VoIPManagerSingleton.instance
    }
   
    class CameraResolution {
        var height: Float
        var width: Float
       
        var horizontalAspectRatio: Float {
            return width / height
        }
        var verticalAspectRatio: Float {
            return height / width
        }
       
        init(height: Float, width: Float) {
            self.height = height
            self.width = width
        }
    }
   
    internal var provider: CXProvider
    internal var controller: CXCallController
    internal var update: CXCallUpdate? = nil
    internal var webRTC: WebRTCClient? = nil
   
    internal var callOwner: String?
    internal var callOpponent: String?
    internal var timeoutScheduler: VoIPCallTimeoutScheduling = DispatchVoIPCallTimeoutScheduler()
    internal var sessionsByCallId: [String: CallSessionContext] = [:]
    internal var currentSession: CallSessionContext? = nil
    internal var pendingSignalingCalls: [String: VoIPCall] = [:]
   
    internal var hasActiveCall: Bool = false
   
    internal var inCallingProcess: Bool = false
    internal var isCallAccepted: Bool = false
   
    internal var isCallEnded: Bool = false
   
    internal var currentCall: VoIPCall? = nil
    internal var callsQueue: [VoIPCall] = []
   
    internal var callScreenDelegate: VoIPCallManagerDelegate? = nil
   
    public var cameraPosition: AVCaptureDevice.Position = .front
       
    internal final var isVideoEnabled: Bool = false
    internal final var shouldChangeVideoModeAfterConnecting: Bool = false
   
    public var cameraResolution: BehaviorRelay<CameraResolution> = BehaviorRelay(value: CameraResolution(height: 640, width: 480))
   
    static func providerConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.emailAddress]
        configuration.includesCallsInRecents = false
        configuration.iconTemplateImageData = UIImage(named: "xabber_icon_call_kit")?.pngData()
        return configuration
    }

    static func callUpdate() -> CXCallUpdate {
        let update = CXCallUpdate()
        configureCallUpdateCapabilities(update)
        return update
    }

    static func configureCallUpdateCapabilities(_ update: CXCallUpdate) {
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
    }
   
    override init() {
        let configuration = VoIPManager.providerConfiguration()
        self.provider = CXProvider(configuration: configuration)
        self.controller = CXCallController(queue: DispatchQueue.main)
       
        super.init()
        provider.setDelegate(self, queue: DispatchQueue.main)
        addObservers()
    }
   
    private func addObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: UIApplication.shared)
    }
   
    @objc private func willEnterForeground() {
        if let callState = self.currentCall?.state {
            self.callScreenDelegate?.didChangeState(to: callState)
        } else if self.currentCall == nil && self.callScreenDelegate != nil {
            self.callScreenDelegate?.shouldDismiss()
            self.endCall()
        }
    }
   
    @objc private func willEnterBackground() {}
   
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    internal func session(for callId: String?) -> CallSessionContext? {
        guard let callId else { return nil }
        return sessionsByCallId[callId]
    }

    @discardableResult
    internal func registerSession(
        callId: String,
        callUUID: UUID,
        owner: String,
        jid: String,
        outgoing: Bool,
        phase: CallSessionPhase
    ) -> CallSessionContext {
        let context = CallSessionContext(
            callId: callId,
            callUUID: callUUID,
            owner: owner,
            jid: jid,
            outgoing: outgoing,
            phase: phase
        )
        sessionsByCallId[callId] = context
        currentSession = context
        return context
    }

    internal func scheduleIncomingTimeout(for context: CallSessionContext) {
        context.incomingTimeoutTask?.cancel()
        context.incomingTimeoutTask = timeoutScheduler.schedule(after: 30.0) { [weak self] in
            guard let self,
                  self.currentSession?.callId == context.callId,
                  context.phase == .ringing else { return }
            self.finishCurrentCall(
                reason: .incomingUnansweredTimeout,
                trigger: .incomingUnansweredTimeout,
                shouldReportToCallKit: true
            )
        }
    }

    internal func scheduleOutgoingTimeout(for context: CallSessionContext) {
        context.outgoingTimeoutTask?.cancel()
        context.outgoingTimeoutTask = timeoutScheduler.schedule(after: 30.0) { [weak self] in
            guard let self,
                  self.currentSession?.callId == context.callId,
                  [.awaitingConfirmation, .waitingRemoteOffer].contains(context.phase) else { return }
            self.finishCurrentCall(
                reason: .outgoingUnansweredTimeout,
                trigger: .outgoingUnansweredTimeout,
                shouldReportToCallKit: true
            )
        }
    }

    internal func scheduleConfirmationTimeout(for context: CallSessionContext) {
        context.confirmationTimeoutTask?.cancel()
        context.confirmationTimeoutTask = timeoutScheduler.schedule(after: 5.0) { [weak self] in
            guard let self,
                  self.currentSession?.callId == context.callId,
                  context.phase == .awaitingConfirmation else { return }
            self.finishCurrentCall(
                reason: .signalingError,
                trigger: .confirmationFailure,
                shouldReportToCallKit: true
            )
        }
    }

    internal func scheduleMediaSetupTimeout(for context: CallSessionContext) {
        context.mediaSetupTimeoutTask?.cancel()
        context.mediaSetupTimeoutTask = timeoutScheduler.schedule(after: 30.0) { [weak self] in
            guard let self,
                  self.currentSession?.callId == context.callId,
                  [.waitingRemoteOffer, .creatingLocalOffer, .connectingMedia].contains(context.phase) else { return }
            let reason: CallTerminationReason = context.remoteAnswerReceived ? .webRTCFailure : .signalingError
            self.finishCurrentCall(reason: reason, trigger: .mediaFailure, shouldReportToCallKit: true)
        }
    }

    internal func callWasOutgoing(
        callInitiator: String?,
        owner: String,
        fallbackOutgoing: Bool
    ) -> Bool {
        guard let callInitiator,
              let initiatorBare = XMPPJID(string: callInitiator)?.bare else {
            return fallbackOutgoing
        }
        let ownerBare = XMPPJID(string: owner)?.bare ?? owner
        return initiatorBare == ownerBare
    }

    internal func terminationReasonForLocalEnd(call: VoIPCall, context: CallSessionContext) -> CallTerminationReason {
        if call.isMade || context.phase == .connected || context.phase == .connectingMedia || context.localAnswerRequested {
            return .localHangup
        }

        return call.outgoing ? .canceledByCaller : .rejectedByCallee
    }

    internal func terminationReasonFromRejectMessage(
        endReason: String?,
        callInitiator: String?,
        owner: String,
        currentCallDirection: Bool?,
        stanzaDirection: Bool,
        duration: TimeInterval,
        context: CallSessionContext? = nil
    ) -> CallTerminationReason {
        let originalCallOutgoing = callWasOutgoing(
            callInitiator: callInitiator,
            owner: owner,
            fallbackOutgoing: currentCallDirection ?? stanzaDirection
        )

        switch endReason {
        case MessageStorageItem.VoIPCallState.missed.rawValue:
            return originalCallOutgoing ? .outgoingUnansweredTimeout : .incomingUnansweredTimeout
        case MessageStorageItem.VoIPCallState.noanswer.rawValue:
            return .canceledByCaller
        case MessageStorageItem.VoIPCallState.busy.rawValue:
            return .rejectedByCallee
        default:
            _ = duration
            if let context,
               context.phase != .connected,
               !context.localAnswerRequested,
               !context.remoteAnswerReceived,
               !context.remoteOfferReceived,
               !context.outgoing {
                return .canceledByCaller
            }
            return stanzaDirection ? .localHangup : .remoteHangup
        }
    }

    internal func terminationReasonFromRejectMessage(
        endReason: String?,
        outgoing: Bool,
        duration: TimeInterval
    ) -> CallTerminationReason {
        return terminationReasonFromRejectMessage(
            endReason: endReason,
            callInitiator: nil,
            owner: "",
            currentCallDirection: outgoing,
            stanzaDirection: outgoing,
            duration: duration,
            context: nil
        )
    }

    internal func legacyStateFromRejectMessage(
        endReason: String?,
        outgoing: Bool,
        duration: TimeInterval
    ) -> MessageStorageItem.VoIPCallState {
        return terminationReasonFromRejectMessage(
            endReason: endReason,
            outgoing: outgoing,
            duration: duration
        ).legacyState(outgoing: outgoing)
    }

    internal func shouldDismissCallScreenAfterFinish(reason: CallTerminationReason, outgoing: Bool) -> Bool {
        switch reason {
        case .outgoingUnansweredTimeout:
            return outgoing
        default:
            return false
        }
    }

    internal func notifyCallScreenDidFinish(reason: CallTerminationReason, outgoing: Bool) {
        self.callScreenDelegate?.didChangeState(to: .ended)
        if shouldDismissCallScreenAfterFinish(reason: reason, outgoing: outgoing) {
            self.callScreenDelegate?.shouldDismiss()
        }
    }

    internal func shouldSendReject(
        trigger: CallTerminationTrigger,
        call: VoIPCall,
        context: CallSessionContext
    ) -> Bool {
        guard call.shouldSendReject,
              context.phase != .ending,
              context.phase != .ended else {
            return false
        }

        switch trigger {
        case .localEnd, .endActionTimeout, .outgoingUnansweredTimeout:
            return true
        case .incomingUnansweredTimeout,
             .confirmationFailure,
             .mediaFailure,
             .appAcceptFailure,
             .answerActionTimeout,
             .remoteEvent,
             .connectionFailure:
            return false
        }
    }
   
    public final func reset() {
        self.reset(keepPendingSignalingCalls: false)
    }

    internal final func reset(keepPendingSignalingCalls: Bool) {
        sessionsByCallId.values.forEach {
            $0.clearPendingAnswerRequest(failAction: true)
            $0.cancelTimers()
        }
        sessionsByCallId.removeAll()
        currentSession = nil
        if !keepPendingSignalingCalls {
            pendingSignalingCalls.removeAll()
        }
        self.callScreenDelegate = nil
        self.hasActiveCall = false
        self.callOwner = nil
        self.callOpponent = nil
        self.update = nil
        self.webRTC = nil
        self.inCallingProcess = false
        self.isCallAccepted = false
        self.currentCall = nil
        self.isVideoEnabled = false
        self.shouldChangeVideoModeAfterConnecting = false
        self.callsQueue.removeAll()
       
        AccountManager.shared.users.forEach {
            if !$0.xmppStream.isAuthenticated { return }
            $0.action { (user, stream) in
                user.csi.active(stream, by: .voip)
            }
        }
        AccountManager.shared.load(true)
    }

    internal func finishCurrentCall(
        reason: CallTerminationReason,
        trigger: CallTerminationTrigger,
        shouldReportToCallKit: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.finishCurrentCall(
                    reason: reason,
                    trigger: trigger,
                    shouldReportToCallKit: shouldReportToCallKit
                )
            }
            return
        }
        guard let call = self.currentCall,
              let context = self.session(for: call.callId) else { return }
        let sendReject = self.shouldSendReject(trigger: trigger, call: call, context: context)
        self.finishCurrentCall(
            reason: reason,
            sendReject: sendReject,
            shouldReportToCallKit: shouldReportToCallKit
        )
    }

    internal func finishCurrentCall(
        reason: CallTerminationReason,
        sendReject: Bool,
        shouldReportToCallKit: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.finishCurrentCall(
                    reason: reason,
                    sendReject: sendReject,
                    shouldReportToCallKit: shouldReportToCallKit
                )
            }
            return
        }
        guard let call = self.currentCall,
              let context = self.session(for: call.callId) else { return }
        guard context.phase != .ending && context.phase != .ended else { return }

        context.phase = .ending
        context.lastTerminationReason = reason
        context.cancelTimers()
        context.clearPendingAnswerRequest(failAction: true)

        if call.end == nil {
            call.end = Date()
        }

        if sendReject && call.shouldSendReject {
            self.pendingSignalingCalls[call.callId] = call
            call.queuedRejectDidFinish = { [weak self, weak call] in
                guard let call else { return }
                self?.pendingSignalingCalls.removeValue(forKey: call.callId)
            }
            call.rejectCall(reason: reason.legacyState(outgoing: call.outgoing))
            if !call.shouldDisconnectAfterQueuedRejectSend {
                call.queuedRejectDidFinish = nil
                self.pendingSignalingCalls.removeValue(forKey: call.callId)
            }
        } else if !sendReject {
            call.shouldSendReject = false
            call.disconnect()
        }
        let shouldKeepPendingSignalingCall = self.pendingSignalingCalls[call.callId] != nil

        var duration: TimeInterval?
        if let end = call.end, let start = call.start {
            let calculatedDuration = TimeInterval(Int(end.timeIntervalSince1970 - start.timeIntervalSince1970))
            duration = calculatedDuration > 1 ? calculatedDuration : nil
        }

        self.updateMessage(
            call.callId,
            jid: call.jid,
            owner: call.owner,
            callStqte: reason.legacyState(outgoing: call.outgoing),
            duration: duration,
            terminationReason: reason
        )

        context.phase = .ended
        self.webRTC?.delegate = nil
        self.webRTC?.disconnect()
        self.webRTC = nil

        if shouldReportToCallKit {
            self.provider.reportCall(
                with: call.callUUID,
                endedAt: Date(),
                reason: reason.callKitReason(outgoing: call.outgoing)
            )
        }

        self.notifyCallScreenDidFinish(reason: reason, outgoing: call.outgoing)
        self.reset(keepPendingSignalingCalls: shouldKeepPendingSignalingCall)
    }

    internal func requestIncomingAnswer(
        call: VoIPCall,
        context: CallSessionContext,
        action: CXAnswerCallAction?
    ) {
        guard !call.outgoing else {
            action?.fail()
            self.finishCurrentCall(
                reason: .signalingError,
                trigger: .appAcceptFailure,
                shouldReportToCallKit: true
            )
            return
        }

        if context.phase == .awaitingConfirmation {
            context.incomingTimeoutTask?.cancel()
            context.incomingTimeoutTask = nil
            context.setPendingAnswerAction(action)
            return
        }

        guard context.phase == .ringing, call.isConfirmed else {
            action?.fail()
            self.finishCurrentCall(
                reason: .signalingError,
                trigger: .appAcceptFailure,
                shouldReportToCallKit: true
            )
            return
        }

        self.startConfirmedIncomingAnswer(call: call, context: context, action: action)
    }

    internal func startConfirmedIncomingAnswer(
        call: VoIPCall,
        context: CallSessionContext,
        action: CXAnswerCallAction?
    ) {
        context.clearPendingAnswerRequest(failAction: false)
        context.incomingTimeoutTask?.cancel()
        context.incomingTimeoutTask = nil

        guard !call.outgoing, call.isConfirmed else {
            action?.fail()
            self.finishCurrentCall(
                reason: .signalingError,
                trigger: .appAcceptFailure,
                shouldReportToCallKit: true
            )
            return
        }

        guard call.acceptCall() else {
            action?.fail()
            self.finishCurrentCall(
                reason: .signalingError,
                trigger: .appAcceptFailure,
                shouldReportToCallKit: true
            )
            return
        }

        context.localAnswerRequested = true
        self.isCallAccepted = true
        self.inCallingProcess = true
        context.phase = .creatingLocalOffer
        self.scheduleMediaSetupTimeout(for: context)

        self.webRTC = WebRTCClient()
        self.webRTC?.delegate = self
        self.webRTC?.offer { sdp, error in
            if let error {
                print(error.localizedDescription)
                self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                return
            }
            guard let sdp else {
                self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                return
            }
            context.phase = .connectingMedia
            context.localOfferSent = true
            self.currentCall?.sessionDescription(sessionDescription: sdp)
        }

        action?.fulfill()
    }
   
    private final func internalStartCall(owner: String, jid: String) {
        SoundManager.configureAudioSession()
       
        AccountManager.shared.users.forEach {
            if !$0.xmppStream.isAuthenticated { return }
            $0.action { (user, stream) in
                user.csi.inactive(stream, by: .voip)
            }
        }
       
        let callUUID = UUID()
        let handle = CXHandle(type: .emailAddress, value: jid)
        let action = CXStartCallAction(call: callUUID, handle: handle)
        let transaction = CXTransaction(action: action)
       
        self.callScreenDelegate?.shouldDismiss()
       
        let callScreenPresenter = CallScreenPresenter(jid: jid, owner: owner, hideAppTabBar: true)
        if callScreenPresenter.asyncGetPresenter() != nil {
            self.callScreenDelegate = callScreenPresenter.present(animated: true) {}
        }
        self.currentCall = VoIPCall(owner: owner, fullJid: jid, callId: callUUID.uuidString, callUUID: callUUID, outgoing: true)
        self.currentCall?.delegate = self
        let context = self.registerSession(
            callId: callUUID.uuidString,
            callUUID: callUUID,
            owner: owner,
            jid: jid,
            outgoing: true,
            phase: .awaitingConfirmation
        )
       
        self.controller.request(transaction) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                self.callScreenDelegate?.shouldDismiss()
                return
            }
           
            self.inCallingProcess = true
            self.update = Self.callUpdate()
           
            do {
                let realm = try WRealm.safe()
                if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())?.displayName {
                    self.update?.localizedCallerName = name
                }
            } catch {
                DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
            }
           
            self.provider.reportCall(with: callUUID, updated: self.update!)
           
            self.webRTC = WebRTCClient()
            self.webRTC?.delegate = self
            self.currentCall?.start(shouldConfirmOnAuthenticate: false)
            self.currentCall?.proposeCall()
            context.phase = .waitingRemoteOffer
            self.scheduleOutgoingTimeout(for: context)
           
            let messageItem = MessageStorageItem()
            messageItem.configureVoIPCallMessage(
                opponent: jid,
                owner: owner,
                date: Date(),
                isRead: true,
                callId: callUUID.uuidString,
                archivedId: nil,
                outgoing: true,
                duration: 0,
                callState: .none
            )
           
            if !messageItem.isInStorage() {
                _ = messageItem.save(commitTransaction: true, silentNotifications: true)
            }
        }
    }
   
    public final func startCall(owner: String, jid: String) {
        self.internalStartCall(owner: owner, jid: jid)
    }
   
    public final func receiveAnotherCall(payload: [AnyHashable: Any]) {
        let callUUID = UUID()

        guard let body = payload["body"] as? String else { return }

        let data = EncryptedPushDate(body)

        guard let target = payload["target"] as? String,
              let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
              let credentials = defaults.dictionary(forKey: target),
              let secret = credentials["secret"] as? String, !secret.isEmpty,
              let username = credentials["username"] as? String,
              let host = credentials["host"] as? String else {
            return
        }

        let owner = [username, host].joined(separator: "@")

        guard let decrypted = data.payloadStanza(key: secret),
              let from = decrypted.attributeStringValue(forName: "from"),
              let propose = decrypted.element(forName: "propose", xmlns: VoIPCall.namespace),
              let callId = propose.attributeStringValue(forName: "id") else {
            return
        }

        let bareJid = XMPPJID(string: from)?.bare ?? from
        let anotherUpdate = Self.callUpdate()

        do {
            let realm = try WRealm.safe()
            if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [bareJid, owner].prp())?.displayName {
                anotherUpdate.localizedCallerName = name
            } else {
                anotherUpdate.localizedCallerName = bareJid
            }
        } catch {
            DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
            anotherUpdate.localizedCallerName = bareJid
        }

        anotherUpdate.remoteHandle = CXHandle(type: .emailAddress, value: bareJid)

        provider.reportNewIncomingCall(with: callUUID, update: anotherUpdate) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
            }
            self.provider.reportCall(with: callUUID, endedAt: nil, reason: .failed)

            let anotherCall = VoIPCall(owner: owner, fullJid: from, callId: callId, callUUID: callUUID, outgoing: false)
            anotherCall.start(shouldConfirmOnAuthenticate: false)
            anotherCall.rejectCall(reason: .busy)

            let messageItem = MessageStorageItem()
            messageItem.configureVoIPCallMessage(
                opponent: bareJid,
                owner: owner,
                date: Date(),
                isRead: true,
                callId: callId,
                archivedId: nil,
                outgoing: false,
                duration: 0,
                callState: .busy,
                terminationReason: CallTerminationReason.rejectedByCallee.rawValue
            )

            if !messageItem.isInStorage() {
                _ = messageItem.save(commitTransaction: true, silentNotifications: true)
            }
           
            self.callsQueue.append(anotherCall)
        }
    }
   
    public final func receiveCall(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        self.inCallingProcess = false
       
        let callUUID = UUID()
        self.update = Self.callUpdate()
       
        guard let body = payload["body"] as? String else {
            self.reportFailedIncomingPush(callUUID: callUUID, completion: completion)
            return
        }
       
        let data = EncryptedPushDate(body)
       
        guard let target = payload["target"] as? String,
              let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
              let credentials = defaults.dictionary(forKey: target),
              let secret = credentials["secret"] as? String, !secret.isEmpty,
              let username = credentials["username"] as? String,
              let host = credentials["host"] as? String else {
            self.reportFailedIncomingPush(callUUID: callUUID, completion: completion)
            return
        }
       
        let owner = [username, host].joined(separator: "@")
       
        guard let decrypted = data.payloadStanza(key: secret),
              let from = decrypted.attributeStringValue(forName: "from"),
              let fromJid = XMPPJID(string: from),
              fromJid.isFull,
              let propose = decrypted.element(forName: "propose", xmlns: VoIPCall.namespace),
              let callId = propose.attributeStringValue(forName: "id") else {
            self.reportFailedIncomingPush(callUUID: callUUID, completion: completion)
            return
        }

        if let activeSession = self.currentSession {
            if activeSession.callId == callId {
                completion()
                return
            }
            self.receiveAnotherCall(payload: payload)
            completion()
            return
        }
       
        let bareJid = fromJid.bare
        let context = self.registerSession(
            callId: callId,
            callUUID: callUUID,
            owner: owner,
            jid: fromJid.full,
            outgoing: false,
            phase: .awaitingConfirmation
        )
        self.currentCall = VoIPCall(
            owner: owner,
            fullJid: fromJid.full,
            callId: callId,
            callUUID: callUUID,
            outgoing: false
        )
        self.currentCall?.delegate = self
       
        
        func processIncomingCall() {
            
            do {
                let realm = try WRealm.safe()
                if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [bareJid, owner].prp())?.displayName {
                    self.update?.localizedCallerName = name
                } else {
                    self.update?.localizedCallerName = bareJid
                }
            } catch {
                self.update?.localizedCallerName = bareJid
            }
           
            self.update?.remoteHandle = CXHandle(type: .emailAddress, value: bareJid)
           
            let stanzaIdRaw = decrypted
                .elements(forName: "stanza-id")
                .first(where: { $0.attributeStringValue(forName: "by") == owner })?
                .attributeStringValue(forName: "id")
           
            let messageItem = MessageStorageItem()
            messageItem.configureVoIPCallMessage(
                opponent: bareJid,
                owner: owner,
                date: Date(),
                isRead: true,
                callId: callId,
                archivedId: stanzaIdRaw ?? "",
                outgoing: false,
                duration: 0,
                callState: .none
            )
           
            if !messageItem.isInStorage() {
                do {
                    let realm = try WRealm.safe()
                    if realm.isInWriteTransaction { return }
                    if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messageItem.primary) == nil {
                        try realm.write {
                            _ = messageItem.save(commitTransaction: false, silentNotifications: true)
                        }
                    }
                } catch {
                    DDLogDebug(error.localizedDescription)
                }
            }
            context.didReportIncomingCall = true
            self.currentCall?.start(shouldConfirmOnAuthenticate: true)
            self.scheduleConfirmationTimeout(for: context)
            
            completion()
        }
       
        var nick: String? = nil
        
        do {
            let realm = try WRealm.safe()
            nick = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: bareJid, owner: owner))?.displayName ?? bareJid
        } catch {
            DDLogDebug("VoIPManager; \(#function). \(error.localizedDescription)")
        }
        self.update?.localizedCallerName = nick//"Xabber voice call".localizeString(id: "voice_call_message", arguments: [])
       
        provider.reportNewIncomingCall(with: callUUID, update: update!) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                self.reset()
                completion()
                return
            }
            processIncomingCall()
        }
    }

    private func reportFailedIncomingPush(callUUID: UUID, completion: @escaping () -> Void) {
        let failedUpdate = Self.callUpdate()
        failedUpdate.localizedCallerName = "Xabber voice call"
        failedUpdate.remoteHandle = CXHandle(type: .emailAddress, value: "unknown")
        provider.reportNewIncomingCall(with: callUUID, update: failedUpdate) { error in
            if let error {
                DDLogDebug(error.localizedDescription)
                completion()
                return
            }
            self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
            completion()
        }
    }
   
    public final func cancelCall(uuid: String) {
        self.endCall()
    }
   
    public final func endCall() {
        guard let call = self.currentCall,
              let context = self.currentSession else { return }
        let callUUID = call.callUUID
        context.localEndRequested = true
        let transaction = CXTransaction(action: CXEndCallAction(call: callUUID))
        self.controller.request(transaction) { error in
            if let error {
                DDLogDebug(error.localizedDescription)
                let reason = self.terminationReasonForLocalEnd(call: call, context: context)
                self.finishCurrentCall(reason: reason, trigger: .localEnd, shouldReportToCallKit: true)
            }
        }
    }
   
    public final func enableVideo() {
        self.isVideoEnabled = true
        self.webRTC?.enableVideo()
        if (self.currentCall?.changeVideoState(to: .enabled) ?? false) {
            self.shouldChangeVideoModeAfterConnecting = false
        } else {
            self.shouldChangeVideoModeAfterConnecting = true
        }
    }
   
    public final func disableVideo() {
        self.isVideoEnabled = false
        self.webRTC?.disableVideo()
        if (self.currentCall?.changeVideoState(to: .disabled) ?? false) {
            self.shouldChangeVideoModeAfterConnecting = false
        } else {
            self.shouldChangeVideoModeAfterConnecting = true
        }
    }
   
    public final func enableAudio() {
        self.webRTC?.unmuteAudio()
    }
   
    public final func disableAudio() {
        self.webRTC?.muteAudio()
    }
   
    public final func enableRemoteVideo(_ renderer: RTCVideoRenderer) {
        self.webRTC?.renderRemoteVideo(to: renderer)
    }
   
    public final func disableRemoteVideo(_ renderer: RTCVideoRenderer, completionHandler: (() -> Void)?) {
        self.webRTC?.stopRenderRemoteVideo(renderer)
        completionHandler?()
    }
   
    open func enableLocalVideo(_ renderer: RTCVideoRenderer) {
        self.webRTC?.enableVideo()
        self.webRTC?.startCaptureLocalVideo(renderer: renderer, camera: self.cameraPosition)
    }
   
    open func disableLocalVideo(_ completionHandler: (() -> Void)?) {
        self.webRTC?.disableVideo()
        self.webRTC?.stopCaptureLocalVideo(completionHandler)
    }
   
    open func switchCamera(local: RTCVideoRenderer) {
        self.webRTC?.stopCaptureLocalVideo {
            self.cameraPosition = self.cameraPosition == .front ? .back : .front
            self.webRTC?.startCaptureLocalVideo(renderer: local, camera: self.cameraPosition)
        }
    }
   
    public final func onReceiveMessage(_ message: DDXMLElement, owner: String, archivedDate: Date?, commitTransaction: Bool = true, runtime: Bool = false, outgoing: Bool = false, realm activeRealm: Realm? = nil) -> Bool {
        do {
            if message.element(forName: "propose", xmlns: VoIPCall.namespace) != nil {
                guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                      let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                      let toJidUnwr = message.attributeStringValue(forName: "to"),
                      let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                    return false
                }
               
                if runtime { return true }
               
                let instance = MessageStorageItem()
                let isOutgoing = owner == fromJid
               
                guard let callId = message.element(forName: "propose", xmlns: VoIPCall.namespace)?
                        .attributeStringValue(forName: "id") else {
                    return true
                }
               
                instance.configureVoIPCallMessage(
                    opponent: isOutgoing ? toJid : fromJid,
                    owner: owner,
                    date: archivedDate ?? Date(),
                    isRead: true,
                    callId: callId,
                    archivedId: getStanzaId(XMPPMessage(from: message), owner: owner),
                    outgoing: isOutgoing,
                    duration: 0,
                    callState: .received
                )
                instance.archivedId = getUniqueMessageId(XMPPMessage(from: message), owner: owner)
               
                if instance.isInStorage() { return true }
               
                _ = instance.save(commitTransaction: commitTransaction, silentNotifications: true)
                return true
            } else if let accept = message.element(forName: "accept", xmlns: VoIPCall.namespace),
                      let callId = accept.attributeStringValue(forName: "id") {
                if runtime,
                   let deviceId = AccountManager.shared.find(for: owner)?.devices.deviceId,
                   let fromDeviceId = message.element(forName: "device")?.attributeStringValue(forName: "id"),
                   deviceId != fromDeviceId,
                   let currentCall = self.currentCall,
                   callId == currentCall.callId {
                    currentCall.shouldSendReject = false
                    self.finishCurrentCall(reason: .answeredElsewhere, trigger: .remoteEvent, shouldReportToCallKit: true)
                    return true
                }

                guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                      let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                      let toJidUnwr = message.attributeStringValue(forName: "to"),
                      let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                    return true
                }

                let outgoing = owner == fromJid
                let jid = outgoing ? toJid : fromJid
                self.updateMessage(
                    callId,
                    jid: jid,
                    owner: owner,
                    callStqte: .made,
                    duration: nil,
                    terminationReason: nil,
                    realm: activeRealm
                )
                return true
            } else if let reject = message.element(forName: "reject", xmlns: VoIPCall.namespace) {
                if self.currentCall?.onReject(XMPPMessage(from: message)) ?? false {
                    return true
                }
                guard let callId = reject.attributeStringValue(forName: "id") else {
                    return true
                }
                let call = reject.element(forName: "call")
                let duration = call?.attributeDoubleValue(forName: "duration") ?? 0
                let endReason = call?.attributeStringValue(forName: "end-reason")
                let callInitiator = call?.attributeStringValue(forName: "initiator")
                if let date = archivedDate {
                    guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                        let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                        let toJidUnwr = message.attributeStringValue(forName: "to"),
                        let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                        return false
                    }
                    let instance = MessageStorageItem()
                    let stanzaDirection: Bool = owner == fromJid
                    let currentCallDirection = self.currentCall?.callId == callId ? self.currentCall?.outgoing : nil
                    let originalCallOutgoing = self.callWasOutgoing(
                        callInitiator: callInitiator,
                        owner: owner,
                        fallbackOutgoing: currentCallDirection ?? stanzaDirection
                    )
                    let terminationReason = self.terminationReasonFromRejectMessage(
                        endReason: endReason,
                        callInitiator: callInitiator,
                        owner: owner,
                        currentCallDirection: originalCallOutgoing,
                        stanzaDirection: stanzaDirection,
                        duration: duration,
                        context: self.session(for: callId)
                    )

                    instance.configureVoIPCallMessage(
                        opponent: stanzaDirection ? toJid : fromJid,
                        owner: owner,
                        date: date,
                        isRead: true,
                        callId: callId,
                        archivedId: getStanzaId(XMPPMessage(from: message), owner: owner),
                        outgoing: originalCallOutgoing,
                        duration: duration,
                        callState: terminationReason.legacyState(outgoing: originalCallOutgoing),
                        terminationReason: terminationReason.rawValue
                    )
                    if instance.isInStorage() {
                        self.updateMessage(
                            callId,
                            jid: stanzaDirection ? toJid : fromJid,
                            owner: owner,
                            callStqte: terminationReason.legacyState(outgoing: originalCallOutgoing),
                            duration: duration > 0 ? duration : nil,
                            terminationReason: terminationReason,
                            realm: activeRealm
                        )
                        return true
                    }
                    _ = instance.save(commitTransaction: commitTransaction, silentNotifications: true)

                    return true
                }

                guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                      let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                      let toJidUnwr = message.attributeStringValue(forName: "to"),
                      let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                    return true
                }

                let stanzaDirection = owner == fromJid
                let jid = stanzaDirection ? toJid : fromJid
                let currentCallDirection = self.currentCall?.callId == callId ? self.currentCall?.outgoing : nil
                let originalCallOutgoing = self.callWasOutgoing(
                    callInitiator: callInitiator,
                    owner: owner,
                    fallbackOutgoing: currentCallDirection ?? stanzaDirection
                )
                let terminationReason = self.terminationReasonFromRejectMessage(
                    endReason: endReason,
                    callInitiator: callInitiator,
                    owner: owner,
                    currentCallDirection: originalCallOutgoing,
                    stanzaDirection: stanzaDirection,
                    duration: duration,
                    context: self.session(for: callId)
                )
                self.updateMessage(
                    callId,
                    jid: jid,
                    owner: owner,
                    callStqte: terminationReason.legacyState(outgoing: originalCallOutgoing),
                    duration: duration > 0 ? duration : nil,
                    terminationReason: terminationReason,
                    realm: activeRealm
                )
                return true
            }
              
        } catch {
            return false
        }
       
        return false
    }
   
    public final func onReceivePushUpdate(_ payload: [AnyHashable: Any]) -> Bool {
        guard let currentCall = self.currentCall else {
            return false
        }
        guard let body = payload["body"] as? String else {
            print("FAIL 0")
            return false
        }
        let data = EncryptedPushDate(body)
//            let data = try JSONDecoder().decode(EncryptedPushDate.self, from: encodedBody)
        guard let target = payload["target"] as? String,
            let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            print("FAIL 1")
            return false
        }
        guard let creditionals = defaults.dictionary(forKey: target) else {
            print("FAIL 2")
            return false
        }

        guard let secret = creditionals["secret"] as? String,
              secret.isNotEmpty else {
            print("FAIL 3")
            return false
        }

        guard let username = creditionals["username"] as? String,
              let host = creditionals["host"] as? String else {
            print("FAIL 4")
            return false
        }

        let owner = [username, host].joined(separator: "@")

        guard let decrypted = data.payloadStanza(key: secret) else {
            print("FAIL 4.5")
            return false
        }

        guard let callId = decrypted.attributeStringValue(forName: "id") else {
            print("FAIL 5")
            return false
        }

        if callId != currentCall.callId {
            return false
        }
        guard let fullJid = currentCall.jid.isEmpty ? nil : currentCall.jid,
              let jid = XMPPJID(string: fullJid)?.bare else {
            return false
        }
        print("VOIP PUSH DECRYPTED", decrypted)
        switch decrypted.name {
        case "reject":
            let call = decrypted.element(forName: "call")
            let duration = call?.attributeDoubleValue(forName: "duration") ?? 0
            let endReason = call?.attributeStringValue(forName: "end-reason")
            let callInitiator = call?.attributeStringValue(forName: "initiator")
            let context = self.session(for: callId)
            let terminationReason = self.terminationReasonFromRejectMessage(
                endReason: endReason,
                callInitiator: callInitiator,
                owner: owner,
                currentCallDirection: currentCall.outgoing,
                stanzaDirection: false,
                duration: duration,
                context: context
            )

            self.updateMessage(
                callId,
                jid: jid,
                owner: owner,
                callStqte: terminationReason.legacyState(outgoing: currentCall.outgoing),
                duration: duration > 0 ? duration : nil,
                terminationReason: terminationReason
            )

            currentCall.shouldSendReject = false
            self.finishCurrentCall(reason: terminationReason, trigger: .remoteEvent, shouldReportToCallKit: true)
        default:
            return false
        }
        return true
    }
   
    internal final func updateMessage(
        _ callId: String,
        jid: String,
        owner: String,
        callStqte: MessageStorageItem.VoIPCallState? = nil,
        duration: TimeInterval? = nil,
        terminationReason: CallTerminationReason? = nil,
        realm activeRealm: Realm? = nil
    ) {
        guard let jid = XMPPJID(string: jid)?.bare else { return }
        do {
            let realm = try activeRealm ?? WRealm.safe()
            if let referencePrimary = realm
                .object(ofType: MessageStorageItem.self,
                        forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?
                .references.first?.primary,
               let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                let updateBlock = {
                    if instance.isInvalidated { return }
                    if let callState = callStqte {
                        instance.metadata?["callState"] = callState.rawValue
                    }
                    if let duration = duration {
                        instance.metadata?["duration"] = duration
                    }
                    if let terminationReason = terminationReason {
                        instance.metadata?["terminationReason"] = terminationReason.rawValue
                    }
                    realm.object(ofType: MessageStorageItem.self,
                                 forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?.isRead = true
                }
                if realm.isInWriteTransaction {
                    updateBlock()
                } else {
                    try realm.write {
                        updateBlock()
                    }
                }
            }
        } catch {
            DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
        }
    }
   
    public static func isVoIPMessage(_ message: DDXMLElement) -> Bool {
        return message.element(forName: "reject", xmlns: VoIPCall.namespace) != nil ||
               message.element(forName: "accept", xmlns: VoIPCall.namespace) != nil ||
               message.element(forName: "propose", xmlns: VoIPCall.namespace) != nil
    }
}
