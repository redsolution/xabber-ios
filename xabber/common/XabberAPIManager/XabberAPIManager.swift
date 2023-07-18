// //
// //  XabberAPIManager.swift
// //  xabber
// //
// //
// //
// //
// //  This program is free software; you can redistribute it and/or
// //  modify it under the terms of the GNU General Public License as
// //  published by the Free Software Foundation; either version 3 of the
// //  License.
// //
// //  This program is distributed in the hope that it will be useful,
// //  but WITHOUT ANY WARRANTY; without even the implied warranty of
// //  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// //  General Public License for more details.
// //
// //  You should have received a copy of the GNU General Public License along
// //  with this program; if not, write to the Free Software Foundation, Inc.,
// //  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// //
// //
// //

// import Foundation
// import Alamofire
// import CocoaLumberjack

// public struct APISecrets: Codable {
//     var APIDomain: String
//     var NoCaptchaXabberAPIKey: String
//     var avatar_masks: [String]
// }

// class XabberAPIManager: NSObject {
    
//     open class var shared: XabberAPIManager {
//         struct XabberAPIManagerSingleton {
//             static let instance = XabberAPIManager()
//         }
//         return XabberAPIManagerSingleton.instance
//     }
    
//     private var noCaptchaAPIKey: String? = nil
    
//     override init() {
//         if  let path = Bundle.main.path(forResource: "XASettingsDebug", ofType: "plist"),
//             let xml = FileManager.default.contents(atPath: path),
//             let secrets = try? PropertyListDecoder().decode(APISecrets.self, from: xml)
//         {
//             self.noCaptchaAPIKey = secrets.NoCaptchaXabberAPIKey
//         }
//     }
    
//     private func apiURL(_ path: String) -> URL {
//         if _DEBUG {
//             guard let url = URL(string: "https://api.dev.xabber.com/api/\(path)") else {
//                 fatalError()
//             }
//             return url
//         } else {
//             guard let url = URL(string: "https://api.dev.xabber.com/api/\(path)") else {
//                 fatalError()
//             }
//             return url
//         }
//     }
    
//     public func getAvailableHosts(_ callback: (([String]) -> Void)?) {
//         DispatchQueue.global(qos: .background).async {
//             let url = self.apiURL("v2/accounts/xmpp/hosts/")
//             let params: [String: Any] = [:]
//             let headers: [String: String] = [:]
            
//             Alamofire
//                 .request(
//                     url,
//                     method: .get,
//                     parameters: params,
//                     encoding: URLEncoding.default,
//                     headers: headers
//                 ).responseJSON {
//                     response in
//                     switch response.result {
//                     case .success(let data):
//                         guard let data = data as? NSDictionary,
//                               let results = data["results"] as? NSArray else {
//                             callback?([])
//                             return
//                         }
//                         let hosts = results
//                             .compactMap { $0 as? NSDictionary }
//                             .filter{ ($0["is_free"] as? Bool) ?? false }
//                             .compactMap { $0["host"] as? String }
//                         callback?(hosts)
//                     case .failure(let error):
//                         callback?([])
//                         DDLogDebug(error.localizedDescription)
//                     }
//                 }
//         }
//     }
    
//     public func checkUsernameAvailability(username: String, host: String, callback: @escaping ((Bool, String?) -> Void)) {
//         DispatchQueue.global(qos: .background).async {
//             let url = self.apiURL("v2/accounts/account/exist/")
//             let params: [String: Any] = [
//                 "username": username,
//                 "host": host,
//                 "no_captcha_key": self.noCaptchaAPIKey!
//             ]
//             let headers: [String: String] = [:]
//             Alamofire
//                 .request(
//                     url,
//                     method: .post,
//                     parameters: params,
//                     encoding: JSONEncoding.default,
//                     headers: headers
//                 ).responseJSON {
//                     response in
//                     print(response)
//                     switch response.result {
//                     case .success(let data):
//                         guard let data = data as? NSDictionary else {
//                             callback(true, nil)
//                             return
//                         }
//                         if data.allKeys.isEmpty {
//                             callback(true, nil)
//                             return
//                         } else {
//                             if let usernameError = (data["username"] as? Array<String>)?.first {
//                                 callback(false, usernameError)
//                                 return
//                             }
//                             callback(false, nil)
//                             return
//                         }
//                     case .failure(let error):
//                         callback(false, nil)
//                         DDLogDebug(error.localizedDescription)
//                         return
//                     }
//                 }
//         }
//     }
    
//     public final func registerAccount(username: String, host: String, password: String, callback: @escaping ((Bool, String?) -> Void)) {
//         DispatchQueue.global(qos: .background).async {
//             let url = self.apiURL("v2/accounts/signup/")
//             let params: [String: Any] = [
//                 "username": username,
//                 "host": host,
//                 "password": password,
//                 "no_captcha_key": self.noCaptchaAPIKey!
//             ]
//             let headers: [String: String] = [:]
//             Alamofire
//                 .request(
//                     url,
//                     method: .post,
//                     parameters: params,
//                     encoding: JSONEncoding.default,
//                     headers: headers
//                 ).responseJSON {
//                     response in
//                     print(response)
//                     switch response.result {
//                     case .success(let data):
//                         guard let data = data as? NSDictionary else {
//                             callback(false, nil)
//                             return
//                         }
//                         if (data["account_status"] as? String) == "registered" {
//                             callback(true, nil)
//                             return
//                         } else {
//                             if let usernameError = (data["username"] as? Array<String>)?.first {
//                                 callback(false, usernameError)
//                                 return
//                             }
//                             callback(false, nil)
//                             return
//                         }
//                     case .failure(let error):
//                         callback(false, nil)
//                         DDLogDebug(error.localizedDescription)
//                         return
//                     }
//                 }
//         }
//     }
    
// }
