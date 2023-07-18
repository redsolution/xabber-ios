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
    func VoIPCallDidChangeState(_ call: VoIPCall, to state: VoIPCall.State) {
        //print(#function, state)
        DispatchQueue.main.async {
            self.callScreenDelegate?.didChangeState(to: state)
            if state == .ended {
                let transaction = CXTransaction(action: CXEndCallAction(call: call.callUUID))
                self.controller.request(transaction) { (error) in
                    if let error = error {
                        //print(error.localizedDescription)
                        DDLogDebug(error.localizedDescription)
                        self.provider.invalidate()
                    }
                }
            }
        }
    }
    
    func VoIPCallDidAccepted(_ call: VoIPCall) {
        //print(#function)
        
    }
    
    func VoIPCallDidExpired(_ call: VoIPCall) {
        print(#function)
        let transaction = CXTransaction(action: CXEndCallAction(call: call.callUUID))
        self.controller.request(transaction) { (error) in
            if let error = error {
                //print(error.localizedDescription)
                DDLogDebug(error.localizedDescription)
                self.provider.invalidate()
            }
        }
        self.reset()
    }
    
    func VoIPCallDidHeld(_ call: VoIPCall) {
        //print(#function)
    }
    
    func VoIPCallDidEndWith(_ call: VoIPCall, error: Error?, byActiveStream: Bool) {
        //print(#function, error)
        if let error = error {
            NotifyManager.shared.showSimpleNotify(withTitle: #function, subtitle: "fail", body: error.localizedDescription)
            DDLogDebug(error)
            self.provider.invalidate()
        } else {
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
            
            let transaction = CXTransaction(action: CXEndCallAction(call: call.callUUID))
            self.controller.request(transaction) { (error) in
                if let error = error {
                    //print(error.localizedDescription)
                    DDLogDebug(error.localizedDescription)
                    self.provider.invalidate()
                }
            }
            
            if byActiveStream {
                self.callScreenDelegate?.didChangeState(to: .ended)
            }
        }
        
        print(#function, 1)
        self.reset()
    }
    
    func VoIPCallDidReceive(_ call: VoIPCall, sessionDescription: RTCSessionDescription) {
//        if self.web
        switch sessionDescription.type {
        case .offer:
            self.webRTC?.set(remoteSdp: sessionDescription, completion: { (error) in
                if let error = error {
                    print(error.localizedDescription)
//                    self.provider.invalidate()ddddd
                    self.reset()
                } else {
                    self.webRTC?.answer(completion: { (sdp) in
                        self.currentCall?.sessionDescription(sessionDescription: sdp)
                    })
                }
            })
            
        case .prAnswer, .answer:
            self.webRTC?.set(remoteSdp: sessionDescription, completion: { (error) in
                if let error = error {
                    print(error.localizedDescription)
//                    self.provider.invalidate()dddddd
                    self.reset()
                }
            })
        @unknown default:
            break
        }
    }
    
    func VoIPCallDidReceive(_ call: VoIPCall, iceCandidate: RTCIceCandidate) {
        self.webRTC?.set(remoteCandidate: iceCandidate)
    }
    
    func VoIPCallDidChangeVideoState(_ call: VoIPCall, to state: VoIPCall.VideoState, myself: Bool) {
        //print(state)
        if myself {
            self.callScreenDelegate?.didChangeMyVideoMode(to: state)
        } else {
            self.callScreenDelegate?.didChangeOpponentVideoMode(to: state)
        }
    }
    
    func VoIPCallDidUpdateContactJid(_ call: VoIPCall) {
        DispatchQueue.main.async {
            if self.shouldChangeVideoModeAfterConnecting {
                _ = self.currentCall?.changeVideoState(to: self.isVideoEnabled ? .enabled : .disabled)
            }
        }
    }
    
    func VoIPCallDidReceiveRejectMessage(_ call: VoIPCall) {
        self.isCallEnded = true
    }
}
