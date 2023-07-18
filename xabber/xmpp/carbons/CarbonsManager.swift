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

class CarbonsManager: AbstractXMPPManager {
    
    enum State {
        case enabled
        case disabled
    }
    
    override func namespaces() -> [String] {
        return [
            "urn:xmpp:carbons:2",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    open func set(_ xmppStream: XMPPStream, to state: State) {
        let element: DDXMLElement
        switch state {
        case .enabled:
            element = DDXMLElement.element(withName: "enable") as! DDXMLElement
        case .disabled:
            element = DDXMLElement.element(withName: "disable") as! DDXMLElement
        }
        element.setXmlns(getPrimaryNamespace())
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: owner), elementID: elementId, child: element)
        xmppStream.send(iq)
//        queryIds.insert(elementId)
    }
    
    open func privateCopy(_ message: XMPPMessage) -> XMPPMessage {
        let privateTag = DDXMLElement.element(withName: "private") as! DDXMLElement
        privateTag.setXmlns(getPrimaryNamespace())
        message.addChild(privateTag)
        let noCopy = DDXMLElement.element(withName: "no-copy") as! DDXMLElement
        noCopy.setXmlns("urn:xmpp:hints")
        message.addChild(noCopy)
        return message
    }
    
}
