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
    func providerDidReset(_ provider: CXProvider) {}
   
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print(#function)
        performEndCallActions()
        action.fulfill(withDateEnded: Date())
    }
       
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print(#function, action)
        guard let owner = self.currentCall?.owner,
              let jidRaw = self.currentCall?.jid,
              let jid = XMPPJID(string: jidRaw)?.bare else {
            action.fail()
            self.reset()
            return
        }
       
        let callScreenPresenter = CallScreenPresenter(jid: jid, owner: owner, hideAppTabBar: true)
        if callScreenPresenter.asyncGetPresenter() != nil {
            self.callScreenDelegate = callScreenPresenter.present(animated: true) {}
        }
       
        _ = self.currentCall?.acceptCall()
        self.isCallAccepted = true
        self.inCallingProcess = true
       
        self.webRTC = WebRTCClient()
        self.webRTC?.delegate = self
        self.webRTC?.offer { sdp in
            self.currentCall?.sessionDescription(sessionDescription: sdp)
        }
       
        action.fulfill(withDateConnected: Date())
    }
   
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        self.callScreenDelegate?.didChangeMicState(to: !action.isMuted)
        action.fulfill()
    }
   
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        self.reset()
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
