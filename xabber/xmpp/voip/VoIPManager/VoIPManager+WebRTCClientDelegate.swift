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
import WebRTC

extension VoIPManager: WebRTCClientDelegate {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        self.currentCall?.candidate(iceCandidate: candidate)
    }
   
    func webRTCClient(_ client: WebRTCClient, didUpdateState state: RTCIceConnectionState) {
        switch state {
        case .new:
            self.currentCall?.state = .connecting
            // Для исходящих звонков — начинаем «соединение»
            if let uuid = self.currentCall?.callUUID, self.currentCall?.outgoing == true {
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
        case .checking:
            self.currentCall?.state = .connecting
        case .connected, .completed:
            self.currentCall?.state = .connected
            // Только для исходящих звонков — отчёт о полном соединении
            if let uuid = self.currentCall?.callUUID, self.currentCall?.outgoing == true {
                self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
            // Для входящих звонков соединение уже отчётовано при answer (dateConnected)
        case .failed, .disconnected, .closed:
            self.currentCall?.state = .disconnected
        default:
            break
        }
    }
   
    func webRTCClient(_ client: WebRTCClient, didUpdateCameraResolution resolution: CameraResolution) {}
}
