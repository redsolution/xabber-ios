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
    
    
       
    func sendRegistrationRequest(forJid jid: String, voip: Bool) -> Bool {
        guard let voipToken = self.voipToken,
            let deviceToken = self.deviceToken else {
            print("cant get tokens. \(#function)")
            return false
        }
        
        print("SEND REGJID REQUEST FOR \(jid)")
        
        let url: String = APNSManager.apiUrl(for: "jid/endpoints/")
        
        let headers: [String : String] = [
            "Authorization" : APNSManager.authKey(),
            "Content-Type" : "application/json"
        ]
        
        let hashString = [String(describing: UIDevice.current.identifierForVendor!), CommonConfigManager.shared.config.bundle_id, "prod"].prp()
        
        
        let params: [String: String] = [
            "target": [jid, hashString].joined(separator: "/"),
            "endpoint_key": voip ? voipToken : deviceToken,
            "provider": voip ? "apns.voip" : "apns",
        ]
//        let retrier = RequestRetrier()
        /*SUCCESS: {"action":"regjid","result":"success","jid":"igor.boldin@xmppdev01.xabber.com/3F02F22F-5185-43A9-9116-B1C1E306F6C7","node":"65be5460-5052-4ada-8483-a3a869731e16","service":"pubsub.devpush.xabber.com"}
         */
        Alamofire.request(url, method: .post, parameters: params, encoding: JSONEncoding.default, headers: headers).responseData { response in
            switch response.result {
            case .success(let data):
                guard let json = try? JSONDecoder().decode(NodeData.self, from: data) else {
                    return
                }
                switch json.action{
                case "regjid":
                    if !voip {
                        try? self.register(json, completionHandler: nil)
                    }
                    break
                default: break
                }
                break
            case .failure(let error):
                print(error.localizedDescription)
                break
            }
        }
        return true
    }
    
    func sendDeleteRequest(jid: String, voip: Bool) {
        guard let VoIPtoken = self.voipToken,
            let deviceToken = self.deviceToken else {
            DDLogDebug("cant get voip token. \(#function)")
            return
        }
        
        let url: String = APNSManager.apiUrl(for: "jid/endpoints/")
        
        let headers: [String : String] = [
            "Authorization" : APNSManager.authKey(),
            "Content-Type" : "application/json"
        ]
        let hashString = [String(describing: UIDevice.current.identifierForVendor!), CommonConfigManager.shared.config.bundle_id, "prod"].prp()
        
        let params = [
            "target": [jid, hashString].joined(separator: "/"),
            "endpoint_key": voip ? VoIPtoken : deviceToken
        ]
        Alamofire.request(url, method: .delete, parameters: params, encoding: JSONEncoding.default, headers: headers)
    }
    
    func sendDeleteRequest(_ pushData: [AnyHashable: Any], voip: Bool) {
        guard let VoIPtoken = self.voipToken,
            let deviceToken = self.deviceToken else {
            DDLogDebug("cant get voip token. \(#function)")
            return
        }
        let dict = pushData as NSDictionary
        guard let target = dict.value(forKey: "target") as? String else {
            DDLogDebug("cant get target from pushData. \(#function)")
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
        print(url, #function, params)
        Alamofire.request(url, method: .delete, parameters: params, encoding: JSONEncoding.default, headers: headers)
            .responseJSON {
                response in
                switch response.result {
                case .success(let value):
                    DDLogError("Send delete endpoint request. Success. \(value)")
                case .failure(let error):
                    DDLogError("Send delete endpoint request. Failure. \(error.localizedDescription)")
                }
        }
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
                print(httpUrl)
                let response = try String(contentsOf: httpUrl)
                if let uri = try parse(response) {
                    callback(uri)
                }
            } catch {
                print(error.localizedDescription)
                callback(nil)
            }
        }
        
        func httpsRequest() {
            do {
                print(httpsUrl)
                let response = try String(contentsOf: httpsUrl)
                if let uri = try parse(response) {
                    callback(uri)
                }
            } catch {
                print(error.localizedDescription)
                httpRequest()
            }
        }
        httpsRequest()
    }
}
