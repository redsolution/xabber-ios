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
import Starscream

extension WebsocketManager: WebSocketDelegate {
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(_):
            processAuth(received: nil)
        case .disconnected(_, _):
            self.delegate?.didDisconnectWithError("disconnected")
        case .text(let message):
            if let stanza = read(message: message) {
                route(stanza)
            }
        case .reconnectSuggested(_):
            self.socket.connect()
        case .cancelled:
            self.delegate?.didDisconnectWithError("cancelled")
        default: break
        }
    }
}
