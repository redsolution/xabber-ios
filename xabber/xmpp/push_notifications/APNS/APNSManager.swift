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
import CryptoSwift
import RealmSwift

class APNSManager: NSObject {
    
    struct NodeData: Codable {
        let action: String
        let node: String?
        let jid: String?
        let result: String?
        let service: String?
        let encrypted: String?
        
        private enum CodingKeys: String, CodingKey {
            case action = "action"
            case node = "node"
            case jid = "jid"
            case result = "result"
            case service = "service"
            case encrypted = "encrypted"
        }
    }
    
    enum TargetType {
        case node(String)
        case xabberAccount(String)
    }
    enum PushType {
        case registration
        case message
    }
    
    enum APNSError: Error {
        case undefinedTargetType
        case failedToDecodeString
        case registrationFailed
        case invalidPayload
        case userNotExist
        case registrationSuccess
        case featureNotImplemented
    }
    
    public struct PushService: Codable {
        var release_url: String
        var debug_url: String
        var release_key: String
        var debug_key: String
    }
    
    open class var shared: APNSManager {
        struct APNSManagerSingleton {
            static let instance = APNSManager()
        }
        return APNSManagerSingleton.instance
    }
    
    internal var voipToken: String? = nil
    internal var deviceToken: String? = nil
    
    static func apiUrl(for url: String) -> String {
        guard let path = Bundle.main.path(forResource: "push_service", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let service = try? PropertyListDecoder().decode(PushService.self, from: xml) else {
              return ""
          }
        var api = ""
        #if RELEASE
        api = service.release_url
        #else
        api = service.debug_url
        #endif
        
        print("\(api)\(url)")
        if url.starts(with: "/") {
            return "\(api)/\(url)"
        } else {
            return "\(api)/\(url)"
        }
    }
    
    static func authKey() -> String {
        guard let path = Bundle.main.path(forResource: "push_service", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let service = try? PropertyListDecoder().decode(PushService.self, from: xml) else {
              return ""
          }
        var key = ""
        #if RELEASE
        key = service.release_key
        #else
        key = service.debug_key
        #endif
        return "Key \(key)"
    }
    
    
    public func receive(voipToken token: String) {
        self.voipToken = token
        AccountManager.shared.activeUsers.value.forEach {
            AccountManager.shared.find(for: $0)?.registerVoIPPushForAccount()
        }        
    }
    
    public func receive(deviceToken token: String) {
        self.deviceToken = token
        AccountManager.shared.activeUsers.value.forEach {
            AccountManager.shared.find(for: $0)?.registerRegularPushForAccount()
        }
    }
    
    func receive(_ pushData: [AnyHashable: Any], completionHandler: (() -> Void)?) throws {
//        logThisPush()
//        return
        DDLogDebug("receive push, start check target type, \(pushData)")
        let dict = pushData as NSDictionary
//        guard let targetTypeStr = dict.value(forKey: "target_type") as? String else { throw APNSError.invalidPayload }
        let targetTypeStr = "node"
        let target = dict.value(forKey: "target") as? String
        print(target)
        let targetType: TargetType
        DDLogDebug(["receive push", "type \(targetTypeStr)", #function].joined(separator: ". "))
        switch targetTypeStr {
        case "node":
            DDLogDebug("receive push. start check node body")
            
            print(dict.value(forKey: "body"))
            guard let nodeBody = dict.value(forKey: "body") as? String else { throw APNSError.invalidPayload }
            targetType = .node(nodeBody)
            break
        case "xaccount":
            targetType = .xabberAccount("sfds")
            break
        default: throw APNSError.undefinedTargetType
        }
        
        DDLogDebug(["receive push", "target type \(targetType)", #function].joined(separator: ". "))
        switch targetType {
        case .node(let base64EncodedString):
            DDLogDebug("receive push. start check base64 encoded json. \(base64EncodedString)")
//            guard let JSONData = base64EncodedString.fromBase64()?.data(using: .utf8) else {
            guard let JSONData = base64EncodedString.data(using: .utf8) else {
                throw APNSError.failedToDecodeString
            }
            let json = try JSONDecoder().decode(NodeData.self, from: JSONData)
            DDLogDebug(["receive push", "json action \(json.action)", #function].joined(separator: ". "))
            switch json.action{
            case "regjid":
                print("REGJID json", json)
                try self.register(json, completionHandler: completionHandler)
                break
//            case "message":
//                try self.message(json, completionHandler: completionHandler)
//                break
            case "displayed":
                try self.displayed(json, target: target, completionHandler: completionHandler)
                break
            case "data":
                try self.data(json, target: target, completionHandler: completionHandler)
            default: break
            }
            
            
            
            break
        case .xabberAccount(_):
            throw APNSError.featureNotImplemented
        }
    }
    
    func data(_ dataInfo: NodeData, target: String?, completionHandler: (() -> Void)?) throws {
        
    }
    
    func register(_ registrationInfo: NodeData, completionHandler: (() -> Void)?) throws {
        print("register")
//        return
        print(registrationInfo)
        guard let result = registrationInfo.result else { throw APNSError.registrationFailed }
        print(result)
        if result != "success" { throw APNSError.registrationFailed }
        guard let jid = registrationInfo.jid else { throw APNSError.invalidPayload }
        print(jid)
        guard let service = registrationInfo.service else { throw APNSError.invalidPayload }
        print(service)
        guard let decoratedJid = XMPPJID(string: jid) else { throw APNSError.invalidPayload }
        guard AccountManager.shared.find(for: decoratedJid.bare) != nil else {
            throw APNSError.userNotExist
        }
        print("REGISTR INFO", registrationInfo.node, service)
        AccountManager.shared.find(for: decoratedJid.bare)?.update(forPushNode: registrationInfo.node!, withService: service)
//        PushLogger.shared.push("receive node & service of push service for \(jid)")
        
//        AccountManager.shared.find(for: decoratedJid.bare)?.action { (user, stream) in
//            user.push.enable(xmppStream: stream, callback: { (result) in
//                user.pushStatusMessage.accept(result)
//            })
//        }
        completionHandler?()
        
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Reg jid push receive").present(animated: true)
//        }
        
        throw APNSError.registrationSuccess
    }
    
    func displayed(_ displayedInfo: NodeData, target: String?, completionHandler: (() -> Void)?) throws {
//        return
        guard let encrypted = displayedInfo.encrypted else {
            throw APNSError.invalidPayload
        }
        
        guard let target = target,
            let defaults  = UserDefaults.init(suiteName: PushNotificationsManager.suitName),
            let creditionals = defaults.dictionary(forKey: target),
            let key = creditionals["secret"] as? String else {
            throw APNSError.invalidPayload
        }
        
        let doc = try DDXMLDocument(xmlString: encrypted, options: 0)
        
        guard let rootElement = doc.rootElement(),
            rootElement.xmlns() == "https://xabber.com/protocol/push",
            let encryptedStr = rootElement.stringValue else {
            throw APNSError.invalidPayload
        }
        
        let ivLength = rootElement.attributeIntegerValue(forName: "iv-length")
        
        guard let data = Data(base64Encoded: encryptedStr, options: .ignoreUnknownCharacters),
            ivLength < data.count else {
            throw APNSError.invalidPayload
        }
        
        let iv = data.bytes.prefix(upTo: ivLength)
        let encryptedData = Padding.zeroPadding.add(to: Array(data.bytes.suffix(from: ivLength)), blockSize: 16)
        let encryptedLen = data.bytes.suffix(from: ivLength).count
        
        let decrypted = try AES(key: Array(key.utf8),
                                blockMode: CBC(iv: Array(iv)),
                                padding: .zeroPadding).decrypt(encryptedData)
        if let decrypted = String(bytes: decrypted.prefix(upTo: encryptedLen), encoding: .utf8),
            let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
            let displayedElement = document.rootElement() {
            
            let stanzaIds = displayedElement
                .elements(forName: "stanza-id")
                .compactMap { return $0.attributeStringValue(forName: "id") }
            print(stanzaIds)
            UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
                stanzaIds.forEach {
                    stanzaId in
                    if let userInfo = notifications.first(where: { return $0.request.content.userInfo["stanzaId"] as? String == stanzaId })?.request.content.userInfo,
                        let timestamp = userInfo["timestamp"] as? TimeInterval,
                        let jid = userInfo["jid"] as? String,
                        let owner = userInfo["owner"] as? String {
                        UNUserNotificationCenter
                            .current()
                            .removeDeliveredNotifications(
                                withIdentifiers: notifications
                                    .filter({ $0.request.content.userInfo["jid"] as? String == jid && $0.request.content.userInfo["owner"] as? String == owner })
                                    .filter({ $0.request.content.userInfo["timestamp"] as? TimeInterval ?? 0 <= timestamp })
                                    .compactMap({ $0.request.identifier })
                        )
                    }
                }
            }
        } else {
            completionHandler?()
        }
    }
}
