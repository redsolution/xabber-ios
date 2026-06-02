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
import XMPPFramework
import RxSwift
import RxCocoa

open class AbstractXMPPManager: NSObject {
    var owner: String
    
    public final var queryIds: SynchronizedArray<String> = SynchronizedArray<String>()//Set<String> = Set<String>()
    
    init(withOwner owner: String) {
        self.owner = owner
        queryIds = SynchronizedArray<String>()
        super.init()
    }
    
    func onStreamPrepared(_ stream: XMPPStream) {
        
    }
    
    func read(withIQ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        return true
    }
    
    func clearSession() {
        
    }
    
    func namespaces() -> [String] {
        return [""]
    }
    
    func getPrimaryNamespace() -> String {
        return ""
    }

    @discardableResult
    func sendPrimaryAware(
        _ stanza: XMPPElement,
        on stream: XMPPStream,
        replayPolicy: PrimaryStreamReplayPolicy = .notReplayable
    ) -> PrimaryStreamSendResult {
        if let account = PrimaryStreamSendRouting.primaryAccount(owner: owner, stream: stream) {
            return account.sendPrimaryStanza(stanza, replayPolicy: replayPolicy)
        }

        let stanzaId = stanza.attributeStringValue(forName: "id") ?? ""
        stream.send(stanza)
        return .sent(stanzaId: stanzaId)
    }
    
    deinit {
        clearSession()
        self.owner = ""
    }
}
