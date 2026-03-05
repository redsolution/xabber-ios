//
//  XabberAccountManager.swift
//  xabber
//
//  Created by Игорь Болдин on 05.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//
import Foundation
import Alamofire
import XMPPFramework
import CocoaLumberjack

class XabberAccountManager: NSObject {
    open class var shared: XabberAccountManager {
        struct XabberAccountManagerSingleton {
            static let instance = XabberAccountManager()
        }
        return XabberAccountManagerSingleton.instance
    }
    
    class AuthTaskItem: NSObject {
        var requestId: String
        var callback: ((String?) -> Void)?
        
        init(requestId: String, callback: ((String?) -> Void)? = nil) {
            self.requestId = requestId
            self.callback = callback
        }
    }
    
    var tasks: [AuthTaskItem] = []
    
    func token(for account: String) -> String? {
        if let token = CredentialsManager.getXabberAccountToken(for: account) {
            return token
        }
        return nil
    }
    
    func storeToken(for account: String, token: String, expire: Double) {
        CredentialsManager.shared.setXabberAccountToken(for: account, token: token)
        CredentialsManager.shared.setXabberAccountTokenExpire(for: account, expire: expire)
    }
    
    func requestToken(for account: String, callback: ((String?) -> Void)? = nil) -> Bool {
            
        let stringUrl = CommonConfigManager.shared.config.xabber_account_api_url + "xmpp_auth/code_request/"
        guard let jid = AccountManager.shared.find(for: account)?.xmppStream.myJID?.full else {
            return false
        }
        
        let params: [String: String] = ["jid": jid,
                                       "type": "iq"]
        let headers: [String: String] = [:]
        
        guard let url = URL(string: stringUrl) else {
            return false
        }
        AF
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: HTTPHeaders(headers)
            ).responseJSON { response in
                print("ResponseJSON: \(response)")
                
                switch response.result {
                    case .success(let value):
                        DDLogDebug(value)
                        guard let data = value as? NSDictionary,
                              let requestId = data["request_id"] as? String else {
                            return
                        }
                        self.tasks.append(AuthTaskItem(requestId: requestId, callback: callback))
                    case .failure(let error):
                        DDLogDebug(error.localizedDescription)
                }
            }
        return true
    }
    
    func read(_ xmppStream: XMPPStream, with iq: XMPPIQ) -> Bool {
        guard self.tasks.isNotEmpty else {
            return false
        }
        let taskIds = Set(self.tasks.compactMap{ $0.requestId })
        guard taskIds.contains(iq.elementID ?? "none") else {
            return false
        }
        guard let confirm = iq.element(forName: "confirm", xmlns: "http://jabber.org/protocol/http-auth"),
              let code = confirm.attributeStringValue(forName: "id"),
//              let urlRaw = confirm.attributeStringValue(forName: "url"),/xmpp_auth/confirm/
              let url = URL(string: CommonConfigManager.shared.config.xabber_account_api_url + "xmpp_auth/confirm/") else {
            return false
        }
        
        guard let taskId = self.tasks.firstIndex(where: { $0.requestId == iq.elementID }) else {
            return false
        }
        
        let iq = XMPPIQ(iqType: .result, to: iq.from, elementID: iq.elementID)
        xmppStream.send(iq)
        guard let jid = xmppStream.myJID?.bare else {
            return false
        }
        
        let params: [String: String] = ["jid": jid,
                                       "code": code]
        let headers: [String: String] = [:]
        
        AF
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: HTTPHeaders(headers)
            ).responseJSON { response in
                print("ResponseJSON: \(response)")
                
                switch response.result {
                    case .success(let value):
                        DDLogDebug(value)
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        guard let data = value as? NSDictionary,
                              let token = data["token"] as? String,
                              let expires = data["expires"] as? String,
                              let expiresTS = formatter.date(from: expires)?.timeIntervalSince1970 else {
                            return
                        }
                        self.storeToken(for: jid, token: token, expire: expiresTS)
                        self.tasks[taskId].callback?(token)
                    case .failure(let error):
                        DDLogDebug(error.localizedDescription)
                }
            }
        
        return true
    }
}
