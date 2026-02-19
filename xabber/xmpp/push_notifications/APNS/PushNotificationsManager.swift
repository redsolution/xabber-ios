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
import dnssd
import XMPPFramework

class PushNotificationsManager: AbstractXMPPManager {
    
    static let suitName: String = "group.com.xabber"
    
    var enable: Bool = true
    var node: String = ""
    var service: String = ""
    var websocketUrl: String? = nil
    
    typealias DNSLookupHandler = ([String: String]?) -> Void

//    static public func WSLookup(for domainName: String) -> [String: String]? {
//        var result: [String: String] = [:]
//        var recordHandler: DNSLookupHandler = {
//            (record) -> Void in
//            if (record != nil) {
//                for (k, v) in record! {
//                    result.updateValue(v, forKey: k)
//                }
//            }
//        }
//
//        let callback: DNSServiceQueryRecordReply = {
//            (sdRef, flags, interfaceIndex, errorCode, fullname, rrtype, rrclass, rdlen, rdata, ttl, context) -> Void in
//            guard let handlerPtr = context?.assumingMemoryBound(to: DNSLookupHandler.self) else {
//                return
//            }
//            let handler = handlerPtr.pointee
//            if (errorCode != kDNSServiceErr_NoError) {
//                return
//            }
//            guard let txtPtr = rdata?.assumingMemoryBound(to: UInt8.self) else {
//                return
//            }
//            let txt = String(cString: txtPtr.advanced(by: 1))
//            var record: [String: String] = [:]
//            let parts = txt.components(separatedBy: "=")
//            print(parts)
//            record[parts[0]] = parts[1]
//            handler(record)
//        }
//
//        let serviceRef: UnsafeMutablePointer<DNSServiceRef?> = UnsafeMutablePointer.allocate(capacity: MemoryLayout<DNSServiceRef>.size)
//        let code = DNSServiceQueryRecord(serviceRef, kDNSServiceFlagsTimeout, 0, domainName, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), callback, &recordHandler)
//        if (code != kDNSServiceErr_NoError) {
//            return nil
//        }
//        DNSServiceProcessResult(serviceRef.pointee)
//        DNSServiceRefDeallocate(serviceRef.pointee)
//
//        return result
//    }
    
    static private func getDomainForLookup(_ domain: String) -> String {
        return "_xmppconnect.\(domain)"
    }
    
    override func namespaces() -> [String] {
        return ["https://xabber.com/protocol/push"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override init(withOwner owner: String) {
        
        super.init(withOwner: owner)
//        DispatchQueue.global(qos: .background).async {
//            if let domain = XMPPJID(string: owner)?.domain {
//                self.websocketUrl = PushNotificationsManager
//                    .WSLookup(for: PushNotificationsManager
//                                .getDomainForLookup(domain))?["_xmpp-client-websocket"]
//                if self.websocketUrl == nil {
//                    self.websocketUrl = PushNotificationsManager
//                        .WSLookup(for: PushNotificationsManager
//                                    .getDomainForLookup("xabber.com"))?["_xmpp-client-websocket"]
//                }
//            }
//        }
//        print("DNS LOOKUP", query(domainName: "_xmppconnect.xabber.com"))
        
    }
    
    internal func isAvailable(_ host: String) -> Bool {
        return true
//        return ["xmppdev01.xabber.com", "xmpp.protostation.ru", "redsolution.com"].contains(host)//
    }
    
    func configure(node: String, service: String) {
        self.node = node
        self.service = service
        print("PUSH DEFAULTS", PushNotificationsManager.getDefaultsForPush(for: node))
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.push.enable(xmppStream: stream) { result in
                user.pushStatusMessage.accept(result)
            }
        })
    }
    
    var enabled: Bool = false
    
    func enable(xmppStream: XMPPStream, callback: (Bool)->Void) {
        guard let jid = xmppStream.myJID,
            node.isNotEmpty else {
                callback(false)
                return
        }
        
        if enabled {
            callback(true)
            return
        }
        
        let elementId = xmppStream.generateUUID
        
        let secret = "iAPfsdcpEduGqwPBQTPpPQroMYlCNhUA" //String.randomString(length: 32, includeNumber: false)
        print("secret key: \(secret)")
        let enable: DDXMLElement
        if isAvailable(jid.domain) {
            enable = DDXMLElement(name: "enable", xmlns: getPrimaryNamespace())
        } else {
            enable = DDXMLElement(name: "enable", xmlns: "urn:xmpp:push:0")
        }
        enable.addAttribute(withName: "node", stringValue: self.node)
        enable.addAttribute(withName: "jid", stringValue: self.service)
        let key = DDXMLElement(name: "encryption-key", stringValue: secret.toBase64())
        let security = DDXMLElement(name: "security", xmlns: getPrimaryNamespace())
        security.addAttribute(withName: "cipher", stringValue: "urn:xmpp:ciphers:aes-256cbc")
        security.addChild(key)
        if isAvailable(jid.domain) {
            enable.addChild(security)
        }
        xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: enable))

        do {
            let pushSecrets = try CredentialsManager.shared.getPushCredentials(for: self.node)
            try CredentialsManager.shared.storePushCredentials(
                node: self.node,
                jid: pushSecrets.jid,
                host: pushSecrets.host,
                secret: secret,
                service: pushSecrets.service,
                jwt: ""
            )
        } catch {
            try? CredentialsManager.shared.storePushCredentials(
                node: node,
                jid: self.owner,
                host: jid.domain,
                secret: secret,
                service: "",
                jwt: ""
            )
            print(error)
        }
        
        
        PushNotificationsManager.updateDefaultsForPush(node, key: "username", value: jid.user!)
        PushNotificationsManager.updateDefaultsForPush(node, key: "host", value: jid.domain)
        PushNotificationsManager.updateDefaultsForPush(node, key: "resource", value: jid.resource ?? "xabber-push-service")
        PushNotificationsManager.updateDefaultsForPush(node, key: "secret", value: secret)
        PushNotificationsManager.updateDefaultsForPush(node, key: "websocket_url", value: websocketUrl ?? "")
        
        queryIds.insert(elementId)
        callback(true)
        enabled = true
    }
    
    func disable(xmppStream: XMPPStream) {
        guard let jid = xmppStream.myJID,
            service.isNotEmpty else {
            return
        }
        let elementId = xmppStream.generateUUID
        let disable: DDXMLElement
        if isAvailable(jid.domain) {
            disable = DDXMLElement(name: "disable", xmlns: getPrimaryNamespace())
        } else {
            disable = DDXMLElement(name: "disable", xmlns: "urn:xmpp:push:0")
        }
        disable.addAttribute(withName: "jid", stringValue: self.service)
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: disable))
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        return readPushRegistrationResult(iq)
    }
        
    private final func readPushRegistrationResult(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              queryIds.contains(elementId),
              let x = iq.element(forName: "x", xmlns: "jabber:x:data"),
              let url = x.elements(forName: "field").first(where: { $0.attributeStringValue(forName: "var") == "url" })?.element(forName: "value")?.stringValue,
              let jwt = x.elements(forName: "field").first(where: { $0.attributeStringValue(forName: "var") == "jwt" })?.element(forName: "value")?.stringValue else {
            return false
        }
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Enable push receive").present(animated: true)
//        }
//        queryIds.remove(elementId)
        do {
            let pushSecrets = try CredentialsManager.shared.getPushCredentials(for: self.node)
            try CredentialsManager.shared.storePushCredentials(
                node: self.node,
                jid: pushSecrets.jid,
                host: pushSecrets.host,
                secret: pushSecrets.secret,
                service: url,
                jwt: jwt
            )
        } catch {
            DDLogDebug(error.localizedDescription)
        }
        
//        PushNotificationsManager.updateDefaultsForPush(self.node, key: "get_url", value: url)
        return true
    }
    
    static public func removeDefaultsForPush(target: String, jid: String) {
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.removeObject(forKey: target)
            defaults.removeObject(forKey: [jid, "state"].prp())
        }
    }
    
    static public func getDefaultsForPush(for target: String) -> [String: String] {
        if let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
           let dict = defaults.dictionary(forKey: target) as? [String: String] {
            return dict
        }
        return [:]
    }
     
    static public func updateDefaultsForPush(_ target: String, key: String, value: String) {
        var dict = PushNotificationsManager.getDefaultsForPush(for: target)
        dict[key] = value
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.set(dict, forKey: target)
            print("dict", getDefaultsForPush(for: target))
            print("set user defaults for \(key): \(value)")
        }
    }
    
    static public func setAccountStateForPush(jid: String, active: Bool) {
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.set(active, forKey: [jid, "state"].prp())
        }
    }
}
