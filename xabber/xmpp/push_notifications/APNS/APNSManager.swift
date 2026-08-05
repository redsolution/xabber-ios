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
import UIKit
import XMPPFramework
import CryptoSwift
import RealmSwift

class APNSManager: NSObject {

    private let diagnostics: APNSDiagnosticLogger
    
    struct NodeData: Codable {
        let action: String?
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
        case featureNotImplemented
    }

    enum ReceiveResult: Equatable {
        case registration
        case displayed
        case data
        case ignored
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

    override init() {
        self.diagnostics = .live
        super.init()
    }

    init(diagnostics: APNSDiagnosticLogger) {
        self.diagnostics = diagnostics
        super.init()
    }
    
    internal var voipToken: String? = nil
    internal var deviceToken: String? = nil

    internal var buildEnvironmentComponent: String {
        #if RELEASE
        return "prod"
        #else
        return "dev"
        #endif
    }
    
    static func apiUrl(
        for url: String,
        diagnostics: APNSDiagnosticLogger = .live
    ) -> String {
        let pathCategory = APNSDiagnosticPathCategory.classify(url)
        guard let path = Bundle.main.path(forResource: "push_service", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let service = try? PropertyListDecoder().decode(PushService.self, from: xml) else {
              diagnostics.record(
                .endpointResolved(
                    hasScheme: false,
                    hasHost: false,
                    pathCategory: pathCategory
                )
              )
              return ""
          }
        var api = ""
        #if RELEASE
        api = service.release_url
        #else
        api = service.debug_url
        #endif
        
        let resolvedURL = "\(api)/\(url)"
        let components = URLComponents(string: resolvedURL)
        diagnostics.record(
            .endpointResolved(
                hasScheme: components?.scheme?.isEmpty == false,
                hasHost: components?.host?.isEmpty == false,
                pathCategory: pathCategory
            )
        )
        return resolvedURL
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
        AccountManager.shared.users.compactMap({ $0.jid }).forEach {
            AccountManager.shared.find(for: $0)?.registerVoIPPushForAccount()
        }        
    }
    
    public func receive(deviceToken token: String) {
        self.deviceToken = token
        AccountManager.shared.activeUsers.value.forEach {
            AccountManager.shared.find(for: $0)?.registerRegularPushForAccount()
        }
    }

    internal func token(for pushType: PushType) -> String? {
        switch pushType {
        case .registration:
            return deviceToken
        case .message:
            return voipToken
        }
    }

    internal func canSendRegistrationRequest(voip: Bool) -> Bool {
        let pushType: PushType = voip ? .message : .registration
        return token(for: pushType)?.isNotEmpty ?? false
    }

    internal func endpointTarget(forJid jid: String, voip: Bool) -> String? {
        let token = voip ? voipToken : deviceToken
        guard let token, token.isNotEmpty,
              let identifier = UIDevice.current.identifierForVendor?.uuidString else {
            return nil
        }
        let hashString = [identifier, CommonConfigManager.shared.config.bundle_id].prp()
        return [jid, hashString].joined(separator: "/")
    }

    static func decodeNodeData(from payloadBody: String) throws -> NodeData {
        if let plainData = payloadBody.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(NodeData.self, from: plainData) {
            return decoded
        }

        guard let decodedBody = Data(base64Encoded: payloadBody, options: .ignoreUnknownCharacters),
              let decoded = try? JSONDecoder().decode(NodeData.self, from: decodedBody) else {
            throw APNSError.failedToDecodeString
        }

        return decoded
    }

    func receive(_ pushData: [AnyHashable: Any], completionHandler: (() -> Void)?) throws -> ReceiveResult {
//        logThisPush()
//        return
        let dict = pushData as NSDictionary
        let targetTypeStr = dict.value(forKey: "target_type") as? String ?? "node"
        let target = dict.value(forKey: "target") as? String
        diagnostics.record(
            .received(
                targetType: APNSDiagnosticTargetCategory.classify(targetTypeStr),
                hasTarget: target?.isEmpty == false,
                hasBody: dict.value(forKey: "body") != nil
            )
        )
        let targetType: TargetType
        switch targetTypeStr {
        case "node":
            guard let nodeBody = dict.value(forKey: "body") as? String else { throw APNSError.invalidPayload }
            targetType = .node(nodeBody)
            break
        case "xaccount":
            targetType = .xabberAccount("sfds")
            break
        default: throw APNSError.undefinedTargetType
        }
        
        switch targetType {
        case .node(let base64EncodedString):
            let json = try Self.decodeNodeData(from: base64EncodedString)
            diagnostics.record(
                .decoded(
                    action: APNSDiagnosticActionCategory.classify(json.action)
                )
            )
            switch json.action{
            case "regjid":
                try self.register(json, completionHandler: completionHandler)
                return .registration
//            case "message":
//                try self.message(json, completionHandler: completionHandler)
//                break
            case "displayed":
                try self.displayed(json, target: target, completionHandler: completionHandler)
                return .displayed
            case "data":
                try self.data(json, target: target, completionHandler: completionHandler)
                return .data
            default:
                return .ignored
            }
        case .xabberAccount(_):
            throw APNSError.featureNotImplemented
        }
    }
    
    func data(_ dataInfo: NodeData, target: String?, completionHandler: (() -> Void)?) throws {
        
    }
    
    func register(_ registrationInfo: NodeData, completionHandler: (() -> Void)?) throws {
//        return
        diagnostics.record(
            .registration(
                result: APNSDiagnosticRegistrationResultCategory.classify(
                    registrationInfo.result
                ),
                hasJID: registrationInfo.jid?.isEmpty == false,
                hasNode: registrationInfo.node?.isEmpty == false,
                hasService: registrationInfo.service?.isEmpty == false
            )
        )
        guard let result = registrationInfo.result else { throw APNSError.registrationFailed }
        if result != "success" { throw APNSError.registrationFailed }
        guard let jid = registrationInfo.jid else { throw APNSError.invalidPayload }
        guard let service = registrationInfo.service else { throw APNSError.invalidPayload }
        guard let decoratedJid = XMPPJID(string: jid) else { throw APNSError.invalidPayload }
        guard AccountManager.shared.find(for: decoratedJid.bare) != nil else {
            throw APNSError.userNotExist
        }
        guard let node = registrationInfo.node, node.isNotEmpty else {
            throw APNSError.invalidPayload
        }
        AccountManager.shared.find(for: decoratedJid.bare)?.update(forPushNode: node, withService: service)
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
    }
    
    func displayed(_ displayedInfo: NodeData, target: String?, completionHandler: (() -> Void)?) throws {
//        return
        guard let encrypted = displayedInfo.encrypted else {
            throw APNSError.invalidPayload
        }
        
        guard let target = target,
            let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()),
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
            diagnostics.record(
                .displayed(stanzaIDCount: stanzaIds.count)
            )
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
