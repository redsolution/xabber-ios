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
import Alamofire
import CocoaLumberjack
import KissXML
import CryptoKit

extension APNSManager {
    
    
       
    func sendRegistrationRequest(forJid jid: String, voip: Bool, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let endpointKey = voip ? self.voipToken : self.deviceToken,
              endpointKey.isNotEmpty,
              let target = endpointTarget(forJid: jid, voip: voip) else {
            completion?(false)
            return false
        }
        
        guard let voipToken = self.voipToken,
              let deviceToken = self.deviceToken,
              deviceToken.isNotEmpty else {
            completion?(false)
            return false
        }
        
        let url: String = APNSManager.apiUrl(for: "jid/endpoints/")
        
        let headers: [String : String] = [
            "Authorization" : APNSManager.authKey(),
            "Content-Type" : "application/json"
        ]
        
        let params: [String: String] = [
            "jid": jid,
            "provider": "apns",
            "endpoint_key": deviceToken,
            "call_endpoint_key": voipToken
        ]
//        let retrier = RequestRetrier()
//        self.sendDeleteRequest(jid: jid, voip: voip) {
            AF.request(url, method: .post, parameters: params, encoding: JSONEncoding.default, headers: HTTPHeaders(headers)).responseData { response in
                switch response.result {
                    case .success(let data):
                        guard let json = try? JSONDecoder().decode(NodeData.self, from: data) else {
                            completion?(false)
                            return
                        }
                        do {
                            try self.register(json, completionHandler: nil)
                            completion?(true)
                        } catch {
                            completion?(false)
                        }
                        break
                    case .failure:
                        completion?(false)
                        break
                }
            }
//        }
        
        return true
    }
    
    func sendDeleteRequest(jid: String, voip: Bool, callback: (() -> Void)? = nil) {
        guard let endpointKey = voip ? self.voipToken : self.deviceToken,
              endpointKey.isNotEmpty,
              let target = endpointTarget(forJid: jid, voip: voip) else {
            return
        }
        
        let url: String = APNSManager.apiUrl(for: "jid/endpoints/")
        
        let headers: [String : String] = [
            "Authorization" : APNSManager.authKey(),
            "Content-Type" : "application/json"
        ]
        let params = [
            "target": target,
            "endpoint_key": endpointKey
        ]
        AF.request(url, method: .delete, parameters: params, encoding: JSONEncoding.default, headers: HTTPHeaders(headers)).responseData { _ in
            callback?()
        }
    }
    
    func sendDeleteRequest(_ pushData: [AnyHashable: Any], voip: Bool) {
        guard let VoIPtoken = self.voipToken,
            let deviceToken = self.deviceToken else {
            return
        }
        let dict = pushData as NSDictionary
        guard let target = dict.value(forKey: "target") as? String else {
            return
        }
        
        let url: String = APNSManager.apiUrl(for: "jid/endpoints/")
        
        let headers: [String : String] = [
            "Authorization" : APNSManager.authKey(),
            "Content-Type" : "application/json"
        ]
        
        let params = [
            "target": target,
            "endpoint_key": voip ? VoIPtoken : deviceToken
        ]
        AF.request(url, method: .delete, parameters: params, encoding: JSONEncoding.default, headers: HTTPHeaders(headers))
            .responseJSON { _ in }
    }
    
    func websocketLookup(for jid: String, callback: @escaping ((String?) -> Void)) {
        let wsLookupUri = ")/.well-known/host-meta"
        guard let domain = jid.split(separator: "@").last,
            let httpsUrl = URL(string: "https://\(domain)/.well-known/host-meta"),
            let httpUrl = URL(string: "http://\(domain)/.well-known/host-meta") else {
            callback(nil)
            return
        }
        
        func parse(_ response: String) throws -> String? {
            let xmlResponseDocument = try DDXMLDocument(xmlString: response, options: 0)
            let xmlResponse = xmlResponseDocument.rootElement()
            if xmlResponse?.attributeStringValue(forName: "rel") == "urn:xmpp:alt-connections:websocket",
                let uri = xmlResponse?.attributeStringValue(forName: "href") {
                return uri
            }
            return nil
        }
        
        func httpRequest() {
            do {
                let response = try String(contentsOf: httpUrl)
                if let uri = try parse(response) {
                    callback(uri)
                }
            } catch {
                callback(nil)
            }
        }
        
        func httpsRequest() {
            do {
                let response = try String(contentsOf: httpsUrl)
                if let uri = try parse(response) {
                    callback(uri)
                }
            } catch {
                httpRequest()
            }
        }
        httpsRequest()
    }
}
