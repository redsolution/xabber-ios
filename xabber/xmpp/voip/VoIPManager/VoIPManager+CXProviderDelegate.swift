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
import XMPPFramework
import AVFoundation

extension VoIPManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        self.reset()
    }
   
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = self.currentCall,
              let context = self.currentSession else {
            action.fulfill(withDateEnded: Date())
            return
        }
        context.localEndRequested = true
        let reason = self.terminationReasonForLocalEnd(call: call, context: context)
        self.finishCurrentCall(reason: reason, sendReject: true, shouldReportToCallKit: false)
        action.fulfill(withDateEnded: Date())
    }
       
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = self.currentCall,
              let context = self.currentSession,
              let jid = XMPPJID(string: call.jid)?.bare else {
            action.fail()
            self.reset()
            return
        }
       
        let callScreenPresenter = CallScreenPresenter(jid: jid, owner: call.owner, hideAppTabBar: true)
        if callScreenPresenter.asyncGetPresenter() != nil {
            self.callScreenDelegate = callScreenPresenter.present(animated: true) {}
        }

        context.localAnswerRequested = true
        context.incomingTimeoutTask?.cancel()
        context.incomingTimeoutTask = nil

        guard call.acceptCall() else {
            action.fail()
            self.finishCurrentCall(reason: .signalingError, sendReject: false, shouldReportToCallKit: true)
            return
        }

        self.isCallAccepted = true
        self.inCallingProcess = true
        context.phase = .creatingLocalOffer
        self.scheduleMediaSetupTimeout(for: context)
       
        self.webRTC = WebRTCClient()
        self.webRTC?.delegate = self
        self.webRTC?.offer { sdp, error in
            if let error {
                print(error.localizedDescription)
                self.finishCurrentCall(reason: .webRTCFailure, sendReject: false, shouldReportToCallKit: true)
                return
            }
            guard let sdp else {
                self.finishCurrentCall(reason: .webRTCFailure, sendReject: false, shouldReportToCallKit: true)
                return
            }
            context.phase = .connectingMedia
            context.localOfferSent = true
            self.currentCall?.sessionDescription(sessionDescription: sdp)
        }
       
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.callScreenDelegate?.didChangeMicState(to: !action.isMuted)
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.finishCurrentCall(reason: .signalingError, sendReject: true, shouldReportToCallKit: true)
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        action.fail()
    }
   
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print(#function)
    }
   
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print(#function)
    }
}
