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


class PingManager: AbstractXMPPManager {
    
    var domain: String
    
    let undeliveredQueryLimit: Int = 2
    let querySendTimeout: TimeInterval = 60
    
    override init(withOwner owner: String) {
        self.domain = XMPPJID(string: owner)?.domain ?? ""
        super.init(withOwner: owner)
    }
    
    override func namespaces() -> [String] {
        return ["urn:xmpp:ping"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    func send(onSuccess: (DDXMLElement)->Void, onFailure: ()->Void) {
        let elementId: String = UUID().uuidString
        self.queryIds.insert(elementId)
        if self.queryIds.count > self.undeliveredQueryLimit {
            self.queryIds.removeAll()
            onFailure()
        } else {
            onSuccess(XMPPIQ(
                iqType: .get,
                to: XMPPJID(string: domain),
                elementID: elementId,
                child: DDXMLElement(name: "ping",
                                    xmlns: getPrimaryNamespace())))
        }
    }
    
    private final func readResult(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            iq.iqType == .result,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        return true
    }
    
    private final func readRequest(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .get,
              iq.element(forName: "ping") != nil,
              let elementId = iq.elementID,
              let from = iq.from else {
            return false
        }
        
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.ping.response(stream, to: from, id: elementId)
        })
        
        return true
    }
    
    public final func response(_ xmppStream: XMPPStream, to jid: XMPPJID, id elementId: String) {
        xmppStream.send(XMPPIQ(iqType: .result, to: jid, elementID: elementId, child: nil))
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readRequest(iq): return true
        case readResult(iq): return true
        default: return false
        }
    }
}

