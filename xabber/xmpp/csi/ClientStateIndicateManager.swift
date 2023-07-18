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

class ClientStateIndicateManager: AbstractXMPPManager {
    
    enum Module: Int {
        case synchronization
        case chatUpdater
        case voip
    }
    
    internal var affectedModules: SynchronizedArray<Module> = SynchronizedArray<Module>()
    
    override func namespaces() -> [String] {
        return ["urn:xmpp:csi:0"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    final func isActive() -> Bool {
        return affectedModules.isEmpty
    }
    
    final func isInactive() -> Bool {
        return affectedModules.isNotEmpty
    }
    
    func active(_ xmppStream: XMPPStream, by affector: Module) {
        if affectedModules.contains(affector) {
            affectedModules.remove(affector)
            if affectedModules.isEmpty {
//                let csi = DDXMLElement.element(withName: "active") as! DDXMLElement
//                csi.setXmlns("urn:xmpp:csi:0")
//                xmppStream.send(csi)
//                xmppStream.send(DDXMLElement(name: "active", xmlns: getPrimaryNamespace()))
            }
        }
    }
    
    func inactive(_ xmppStream: XMPPStream, by affector: Module) {
        if affectedModules.isEmpty {
//            let csi = DDXMLElement.element(withName: "inactive") as! DDXMLElement
//            csi.setXmlns("urn:xmpp:csi:0")
//            xmppStream.send(csi)
//            xmppStream.send(DDXMLElement(name: "inactive", xmlns: getPrimaryNamespace()))
        }
        affectedModules.insert(affector)
    }
}
