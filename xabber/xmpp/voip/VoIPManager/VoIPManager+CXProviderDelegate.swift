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
import WebRTC
import CocoaLumberjack

extension VoIPManager: CXProviderDelegate {
    func providerDidBegin(_ provider: CXProvider) {
        DDLogDebug("VoIPManager: CallKit provider did begin")
    }

    func providerDidReset(_ provider: CXProvider) {
        self.reset()
    }

    func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
        return false
    }
   
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        SoundManager.configureAudioSession()
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
        self.finishCurrentCall(reason: reason, trigger: .localEnd, shouldReportToCallKit: false)
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

        self.requestIncomingAnswer(call: call, context: context, action: action)
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard self.currentCall != nil else {
            action.fail()
            return
        }
        if action.isMuted {
            self.disableAudio()
        } else {
            self.enableAudio()
        }
        self.callScreenDelegate?.didChangeMicState(to: !action.isMuted)
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        let trigger: CallTerminationTrigger
        switch action {
        case is CXEndCallAction:
            trigger = .endActionTimeout
        case is CXAnswerCallAction:
            trigger = .answerActionTimeout
        default:
            trigger = .appAcceptFailure
        }
        self.finishCurrentCall(reason: .signalingError, trigger: trigger, shouldReportToCallKit: true)
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        action.fail()
    }
   
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidActivate(audioSession)
        rtcSession.isAudioEnabled = true
    }
   
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.isAudioEnabled = false
        rtcSession.audioSessionDidDeactivate(audioSession)
    }
}
