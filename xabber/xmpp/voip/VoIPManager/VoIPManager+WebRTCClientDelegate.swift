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
        DispatchQueue.main.async {
            self.currentCall?.candidate(iceCandidate: candidate)
        }
    }

    func webRTCClient(_ client: WebRTCClient, didUpdateState state: RTCIceConnectionState) {
        DispatchQueue.main.async {
            self.handleWebRTCStateUpdate(state)
        }
    }

    private func handleWebRTCStateUpdate(_ state: RTCIceConnectionState) {
        guard let call = self.currentCall else { return }
        let context = self.currentSession

        switch state {
        case .new:
            call.state = .connecting
            context?.phase = .connectingMedia
            if call.outgoing {
                self.provider.reportOutgoingCall(with: call.callUUID, startedConnectingAt: Date())
            }
        case .checking:
            call.state = .connecting
            context?.phase = .connectingMedia
        case .connected, .completed:
            call.state = .connected
            context?.cancelTimers()
            context?.phase = .connected
            if call.outgoing {
                self.provider.reportOutgoingCall(with: call.callUUID, connectedAt: Date())
            }
        case .disconnected:
            call.state = .disconnected
        case .failed, .closed:
            call.state = .disconnected
            self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
        default:
            break
        }
    }

    func webRTCClient(_ client: WebRTCClient, didFail error: Error) {
        DispatchQueue.main.async {
            self.finishCurrentCall(reason: .webRTCFailure, trigger: .mediaFailure, shouldReportToCallKit: true)
        }
    }

    func webRTCClient(_ client: WebRTCClient, didUpdateCameraResolution resolution: CameraResolution) {}
}
