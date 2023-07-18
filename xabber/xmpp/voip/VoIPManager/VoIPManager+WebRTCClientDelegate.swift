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
        //print(#function, candidate)
        self.currentCall?.candidate(iceCandidate: candidate)
    }
    
    func webRTCClient(_ client: WebRTCClient, didUpdateState state: RTCIceConnectionState) {
        //print(#function, state)
        switch state {
        case .new:
            self.currentCall?.state = .connecting
        case .checking:
            self.currentCall?.state = .connecting
        case .connected:
            self.currentCall?.state = .connected
        case .completed:
            break
        case .failed:
            self.currentCall?.state = .disconnected
        case .disconnected:
            self.currentCall?.state = .disconnected
        case .closed:
            self.currentCall?.state = .disconnected
        case .count:
            break
        @unknown default:
            break
        }
        
    }
    
    func webRTCClient(_ client: WebRTCClient, didUpdateCameraResolution resolution: VoIPManager.CameraResolution) {
        //print(#function, resolution)
    }
    
    
}
