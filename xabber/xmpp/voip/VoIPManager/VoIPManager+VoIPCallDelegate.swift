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
import WebRTC
import CocoaLumberjack

extension VoIPManager: VoIPCallDelegate {
    private func terminationReasonForReject(
        call: VoIPCall,
        context: CallSessionContext,
        endReason: String?,
        callInitiator: String?,
        isCarbon: Bool,
        fromCurrentDevice: Bool
    ) -> CallTerminationReason {
        if isCarbon && !fromCurrentDevice {
            return call.outgoing ? .canceledByCaller : .declinedElsewhere
        }

        if context.phase == .awaitingConfirmation && !call.outgoing {
            return .canceledByCaller
        }

        if call.outgoing {
            if context.phase == .connected || call.isMade {
                return .remoteHangup
            }
            return self.terminationReasonFromRejectMessage(
                endReason: endReason,
                callInitiator: callInitiator,
                owner: call.owner,
                currentCallDirection: call.outgoing,
                stanzaDirection: false,
                duration: call.end?.timeIntervalSince(call.start ?? call.end ?? Date()) ?? 0,
                context: context
            )
        }

        if context.localAnswerRequested || context.phase == .connected || call.isMade {
            return .remoteHangup
        }

        return self.terminationReasonFromRejectMessage(
            endReason: endReason,
            callInitiator: callInitiator,
            owner: call.owner,
            currentCallDirection: call.outgoing,
            stanzaDirection: false,
            duration: call.end?.timeIntervalSince(call.start ?? call.end ?? Date()) ?? 0,
            context: context
        )
    }

    private func terminationReasonFor(error: Error?) -> CallTerminationReason {
        guard let error else { return .signalingError }
        if let voipError = error as? VoIPCallError {
            switch voipError {
            case .xmppErrorConnectionFailed, .xmppErrorInvalidPassword, .xmppErrorAuthenticationFailed:
                return .connectionError
            case .callAcceptedButNotConfirmed:
                return .signalingError
            }
        }
        return .signalingError
    }

    func VoIPCallEndCallAnswerElsewhere(_ call: VoIPCall) {
        self.finishCurrentCall(reason: .answeredElsewhere, trigger: .remoteEvent, shouldReportToCallKit: true)
    }
    
    func VoIPCallEndCallRejected(_ call: VoIPCall) {
        self.finishCurrentCall(reason: .declinedElsewhere, trigger: .remoteEvent, shouldReportToCallKit: true)
    }
    
    func VoIPCallDidChangeState(_ call: VoIPCall, to state: VoIPCall.State) {
        DispatchQueue.main.async {
            self.callScreenDelegate?.didChangeState(to: state)
        }

        guard let context = self.session(for: call.callId) else { return }

        switch state {
        case .confirmed:
            context.confirmationTimeoutTask?.cancel()
            context.confirmationTimeoutTask = nil
            if !call.outgoing && context.didReportIncomingCall {
                context.phase = .ringing
                if context.pendingAnswerRequested {
                    self.startConfirmedIncomingAnswer(call: call, context: context, action: context.pendingAnswerAction)
                } else {
                    self.scheduleIncomingTimeout(for: context)
                }
            }
        case .accepted:
            if call.outgoing {
                context.remoteAcceptReceived = true
                context.outgoingTimeoutTask?.cancel()
                context.outgoingTimeoutTask = nil
                context.phase = .waitingRemoteOffer
                self.scheduleMediaSetupTimeout(for: context)
            }
        case .connecting:
            if context.phase != .connected {
                context.phase = .connectingMedia
            }
        case .connected:
            context.cancelTimers()
            context.phase = .connected
        case .ended:
            if context.phase == .ending {
                context.phase = .ended
            }
        default:
            break
        }
    }
   
    func VoIPCallDidAccepted(_ call: VoIPCall) {
        guard let context = self.session(for: call.callId), call.outgoing else { return }
        context.remoteAcceptReceived = true
        context.outgoingTimeoutTask?.cancel()
        context.outgoingTimeoutTask = nil
        context.phase = .waitingRemoteOffer
        self.scheduleMediaSetupTimeout(for: context)
    }
   
    func VoIPCallDidExpired(_ call: VoIPCall) {
        self.finishCurrentCall(reason: .signalingError, trigger: .confirmationFailure, shouldReportToCallKit: true)
    }
   
    func VoIPCallDidHeld(_ call: VoIPCall) {}
   
    func VoIPCallDidEndWith(_ call: VoIPCall, error: Error?, byActiveStream: Bool) {
        let reason = terminationReasonFor(error: error)
        self.finishCurrentCall(reason: reason, trigger: .connectionFailure, shouldReportToCallKit: true)

        if byActiveStream {
            DispatchQueue.main.async {
                self.callScreenDelegate?.didChangeState(to: .ended)
            }
        }
    }
   
    func VoIPCallDidReceive(_ call: VoIPCall, sessionDescription: RTCSessionDescription) {
        guard let context = self.session(for: call.callId) else { return }

        switch sessionDescription.type {
        case .offer:
            guard call.outgoing, context.remoteAcceptReceived else {
                self.finishCurrentCall(reason: .signalingError, trigger: .confirmationFailure, shouldReportToCallKit: true)
                return
            }
            context.remoteOfferReceived = true
            self.webRTC?.set(remoteSdp: sessionDescription) { error in
                if let error {
                    DDLogDebug(error.localizedDescription)
                    self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                    return
                }
                self.webRTC?.answer { sdp, answerError in
                    if let answerError {
                        DDLogDebug(answerError.localizedDescription)
                        self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                        return
                    }
                    guard let sdp else {
                        self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                        return
                    }
                    context.phase = .connectingMedia
                    self.currentCall?.sessionDescription(sessionDescription: sdp)
                    self.scheduleMediaSetupTimeout(for: context)
                }
            }
               
        case .prAnswer:
            self.webRTC?.set(remoteSdp: sessionDescription) { error in
                if let error {
                    DDLogDebug(error.localizedDescription)
                    self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                }
            }
               
        case .answer:
            guard !call.outgoing, context.localAnswerRequested else {
                self.finishCurrentCall(reason: .signalingError, trigger: .confirmationFailure, shouldReportToCallKit: true)
                return
            }
            self.webRTC?.set(remoteSdp: sessionDescription) { error in
                if let error {
                    DDLogDebug(error.localizedDescription)
                    self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
                    return
                }
                context.remoteAnswerReceived = true
                context.phase = .connectingMedia
                self.scheduleMediaSetupTimeout(for: context)
            }
        default:
            break
        }
    }
   
    func VoIPCallDidReceive(_ call: VoIPCall, iceCandidate: RTCIceCandidate) {
        self.webRTC?.set(remoteCandidate: iceCandidate)
    }
   
    func VoIPCallDidChangeVideoState(_ call: VoIPCall, to state: VoIPCall.VideoState, myself: Bool) {
        if myself {
            self.callScreenDelegate?.didChangeMyVideoMode(to: state)
        } else {
            self.callScreenDelegate?.didChangeOpponentVideoMode(to: state)
        }
    }
   
    func VoIPCallDidUpdateContactJid(_ call: VoIPCall) {
        if let context = self.session(for: call.callId) {
            context.jid = call.jid
        }
        DispatchQueue.main.async {
            if self.shouldChangeVideoModeAfterConnecting {
                _ = self.currentCall?.changeVideoState(to: self.isVideoEnabled ? .enabled : .disabled)
                self.shouldChangeVideoModeAfterConnecting = false
            }
        }
    }
   
    func VoIPCallDidReceiveRejectMessage(_ call: VoIPCall, endReason: String?, callInitiator: String?, isCarbon: Bool, fromCurrentDevice: Bool) {
        guard let context = self.session(for: call.callId) else { return }
        if context.phase == .ending || context.phase == .ended {
            return
        }
        let reason = terminationReasonForReject(
            call: call,
            context: context,
            endReason: endReason,
            callInitiator: callInitiator,
            isCarbon: isCarbon,
            fromCurrentDevice: fromCurrentDevice
        )
        self.finishCurrentCall(reason: reason, trigger: .remoteEvent, shouldReportToCallKit: true)
    }
}
