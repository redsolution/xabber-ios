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
        DispatchQueue.main.async {
            self.callScreenDelegate?.didChangeState(to: state)
           
            // Завершаем звонок в CallKit только если он ещё не завершён
            if state == .ended && self.currentCall?.callUUID != nil {
                let transaction = CXTransaction(action: CXEndCallAction(call: call.callUUID))
                self.controller.request(transaction) { error in
                    if let error = error {
                        DDLogDebug(error.localizedDescription)
                        // invalidate только при реальной ошибке транзакции
                        self.provider.invalidate()
                    }
                }
            }
        }
    }
   
    func VoIPCallDidAccepted(_ call: VoIPCall) {
        // Заготовка: можно использовать для дополнительной логики после получения <accept>
        // (например, обновление UI или статистики)
    }
   
    func VoIPCallDidExpired(_ call: VoIPCall) {
        let transaction = CXTransaction(action: CXEndCallAction(call: call.callUUID))
        self.controller.request(transaction) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                self.provider.invalidate()
            }
        }
        self.reset()
    }
   
    func VoIPCallDidHeld(_ call: VoIPCall) {
        // Заготовка: обработка удержания звонка (hold)
    }
   
    func VoIPCallDidEndWith(_ call: VoIPCall, error: Error?, byActiveStream: Bool) {
        if let error = error {
            NotifyManager.shared.showSimpleNotify(withTitle: #function, subtitle: "fail", body: error.localizedDescription)
            DDLogDebug(error)
            self.provider.invalidate()
        }
       
        // Централизованная логика завершения (updateMessage, reject, очистка WebRTC)
        // Вызываем метод из основного класса, чтобы избежать дублирования
        self.performEndCallActions()
       
        if byActiveStream {
            DispatchQueue.main.async {
                self.callScreenDelegate?.didChangeState(to: .ended)
            }
        }
    }
   
    func VoIPCallDidReceive(_ call: VoIPCall, sessionDescription: RTCSessionDescription) {
        switch sessionDescription.type {
            case .offer:
                self.webRTC?.set(remoteSdp: sessionDescription) { error in
                    if let error = error {
                        DDLogDebug(error.localizedDescription)
                        self.provider.invalidate()
                        self.reset()
                    } else {
                        self.webRTC?.answer { sdp in
                            self.currentCall?.sessionDescription(sessionDescription: sdp)
                        }
                    }
                }
               
            case .prAnswer:
                // prAnswer — временный ответ, просто применяем (аналогично answer)
                self.webRTC?.set(remoteSdp: sessionDescription) { error in
                    if let error = error {
                        DDLogDebug(error.localizedDescription)
                        self.provider.invalidate()
                        self.reset()
                    }
                }
               
            case .answer:
                self.webRTC?.set(remoteSdp: sessionDescription) { error in
                    if let error = error {
                        DDLogDebug(error.localizedDescription)
                        self.provider.invalidate()
                        self.reset()
                    }
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
        DispatchQueue.main.async {
            if self.shouldChangeVideoModeAfterConnecting {
                _ = self.currentCall?.changeVideoState(to: self.isVideoEnabled ? .enabled : .disabled)
                self.shouldChangeVideoModeAfterConnecting = false
            }
        }
    }
   
    func VoIPCallDidReceiveRejectMessage(_ call: VoIPCall) {
        self.isCallEnded = true
    }
}
