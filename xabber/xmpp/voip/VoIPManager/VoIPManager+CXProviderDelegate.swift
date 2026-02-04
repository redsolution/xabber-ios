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
    
    func providerDidBegin(_ provider: CXProvider) {
        self.reset()
    }
    
    func providerDidReset(_ provider: CXProvider) {
//        self.reset()
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print(#function)
        
        if self.isCallAccepted {
            var reason: MessageStorageItem.VoIPCallState = .none
            if let call = self.currentCall {
                if !call.isMade {
                    reason = call.outgoing ? .noanswer : .missed
                }
            }
            self.currentCall?.rejectCall(reason: reason)
        } else {
            self.currentCall?.rejectCall(reason: .noanswer)
        }
        if let call = currentCall {
            var duration: TimeInterval = 0.0
            if let end = call.end,
               let start = call.start {
                duration = TimeInterval(Int(end.timeIntervalSince1970 - start.timeIntervalSince1970))
            }
            self.updateMessage(
                call.callId,
                jid: call.jid,
                owner: call.owner,
                callStqte: call.isMade ? .made : (call.outgoing ? .noanswer : .missed),
                duration: duration > 1 ? duration : nil
            )
        }
        action.fulfill(withDateEnded: Date())
    }
        
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print(#function, action)
        guard let owner = self.currentCall?.owner,
              let jidRaw = self.currentCall?.jid,
              let jid = XMPPJID(string: jidRaw)?.bare else {
                  action.fail()
                  print(#function)
                  self.reset()
                  return
              }
        DispatchQueue.main.async {
            let callScreenPresenter = CallScreenPresenter(jid: jid, owner: owner, hideAppTabBar: true)
            if callScreenPresenter.asyncGetPresenter() != nil {
                self.callScreenDelegate = callScreenPresenter.present(animated: true) {
                    
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    let callScreenPresenter = CallScreenPresenter(jid: jid, owner: owner, hideAppTabBar: true)
                    self.callScreenDelegate = callScreenPresenter.present(animated: true) {
                        
                    }
                }
            }
            _ = self.currentCall?.acceptCall()
            self.isCallAccepted = true
            self.inCallingProcess = true
            self.webRTC = WebRTCClient()
            self.webRTC?.delegate = self
            self.webRTC?.offer(completion: { (sdp) in
                self.currentCall?.sessionDescription(sessionDescription: sdp)
            })
        }
//        _ = self.currentCall?.acceptCall()
//        self.isCallAccepted = true
//        self.inCallingProcess = true
//        self.webRTC = WebRTCClient()
//        self.webRTC?.delegate = self
//        self.webRTC?.offer(completion: { (sdp) in
//            self.currentCall?.sessionDescription(sessionDescription: sdp)
//        })
        action.fulfill(withDateConnected: Date())
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print(#function, action)
        self.callScreenDelegate?.didChangeMicState(to: !action.isMuted)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        print(#function, action)
        self.reset()
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        print(#function, action)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        print(#function, action)
        action.fail()
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        print(#function, action)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print(#function)
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print(#function)
    }
}
