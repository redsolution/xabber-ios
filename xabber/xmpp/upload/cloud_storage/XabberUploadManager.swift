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

//import UIKit
import Foundation
import XMPPFramework
import Alamofire
import CocoaLumberjack
import RealmSwift
import Kingfisher


/**
*       XabberUploadManager sends inquiry to the server, which gets non-permanent code.
*       It is used for receiving user's token for messages and files exchange
**/
class XabberUploadManager: AbstractXMPPManager, UploadManagerExtendedProtocol {
    enum UploadError: Error {
        case notAvailable
    }
    
    enum QuotaFileTypes: String, CaseIterable {
        case images = "image"
        case videos = "video"
        case files = "application"
        case audio = "audio"
    }
    
    private static let httpAuthNamespace: String = "http://jabber.org/protocol/http-auth"
    
    internal var node: String? = nil
    
    internal var namespace: String = ""
    internal var maxFileSize: Int? = nil
    
    var token: String {
        get {
            return SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "userToken") ?? ""
        }
        set {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "userToken", value: newValue)
        }
    }
    
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
    }
    
    open func isAvailable() -> Bool {
        guard let node = SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "node") else {
            return false
        }
        self.node = node
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size") ?? "")
        return node.isNotEmpty
    }
    
    enum XabberUploaderError: Error {
        case unauthorized
        case unexpected
    }
    
    struct UploadErrorResponse: Codable {
        let status: Int
        let error: String
    }
    
    private final func checkResponse(_ code: Int?, success: (() -> Void)? = nil, fail: ((Error?) -> Void)? = nil) {
        guard let code = code else {
            fail?(nil)
            return
        }
        if code >= 200 && code < 300 {
            success?()
        } else if code == 401 {
            fail?(XabberUploaderError.unauthorized)
        } else if code > 401 {
            fail?(XabberUploaderError.unexpected)
        }
    }
    
    //MARK: - Uploads user's file on the server, receives file's and thumbnail's urls
    //MARK: - It is called in Account if the user doesn't have any token yet
    private func uploadFile(message primary: String, data: Data, filename: String, mimeType: String? = nil, metadata: [String: String]? = nil, successCallback: @escaping ((String, String?, Int, String, String, URL, Int, Int) -> Void), failCallback: @escaping ((Error?) -> Void), errorCallback: @escaping ((Int?) -> Void)) {
        
        guard isAvailable(), let node = node else {
            failCallback(UploadError.notAvailable)
            return
        }
        
        let stringUrl = node + "v1/files/upload/"
        
        guard let url = URL(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Url is incorrect")
            return
        }
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        print("TOKEN:\n\(token)")
        
        let mime: String = mimeType ?? ""
        var jsonMetadata: Data? = nil
        if let metadata = metadata {
            do {
                jsonMetadata = try JSONSerialization.data(withJSONObject: metadata)
            } catch {
                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        Alamofire.upload(
            multipartFormData: { formData in
                formData.append(data, withName: "file", fileName: filename, mimeType: mimeType ?? "")
                formData.append(mime.data(using: .utf8)!, withName: "media_type")
                //Takes type of file, e.g. "audio" from "audio/ogg"
                
                if let jsonMetadata = jsonMetadata {
                    formData.append(jsonMetadata, withName: "metadata")
                }
            },
            usingThreshold: SessionManager.multipartFormDataEncodingMemoryThreshold,
            to: url,
            method: .post,
            headers: headers) { result in
                switch result {
                    
                case .success(request: let request, streamingFromDisk: let streamingFromDisk, streamFileURL: let streamFileURL):
                    request.responseJSON(queue: nil, options: []) { response in
                        if (response.response?.statusCode ?? 404) < 400 {
                            guard let json = response.result.value as? NSDictionary,
                                  let fileUrl = json["file"] as? String,
                                  let name = json["name"] as? String,
                                  let hash = json["hash"] as? String,
                                  let quota = json["quota"] as? Int,
                                  let used = json["used"] as? Int,
                                  let fileID = json["id"] as? Int else {
                                guard let json = response.result.value as? NSDictionary,
                                      let statusCode = json["status"] as? Int else {
                                          errorCallback(response.response?.statusCode)
                                          return
                                      }
                                errorCallback(statusCode)
                                return
                            }
                            
                            let thumbnailUrl = json["thumbnail"] as? String

                            successCallback(fileUrl, thumbnailUrl, fileID, name, hash, url, quota, used)
                        } else {
                            guard let json = response.result.value as? NSDictionary,
                                  let statusCode = json["status"] as? Int else {
                                      errorCallback(response.response?.statusCode)
                                      return
                                  }
                            errorCallback(statusCode)
                        }
                    }
                    
                case .failure(let error):
                    DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
                    failCallback(error)
                }
            }
    }
    
    //MARK: - Gets voice & media references from sent message, calls uploadFile func
    //MARK: - and saves file's url on the server
    public func getFileData(message primary: String, successCallback: @escaping (() -> Void), failCallback: @escaping (() -> Void)) {
        func callSuccessCallback() {
            do {
                let realm = try WRealm.safe()
                if realm.objects(MessageReferenceStorageItem.self)
                    .filter("owner == %@ AND messageId == %@ AND kind_ IN %@ AND isUploaded == false",
                            owner,
                            primary,
                            [MessageReferenceStorageItem.Kind.voice.rawValue, MessageReferenceStorageItem.Kind.media.rawValue])
                    .isEmpty {
                    successCallback()
                }
            } catch {
                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        do {
            let realm = try WRealm.safe()
            realm.objects(MessageReferenceStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND kind_ IN %@ AND isUploaded == false",
                        owner,
                        primary,
                        [MessageReferenceStorageItem.Kind.voice.rawValue, MessageReferenceStorageItem.Kind.media.rawValue])
                .forEach {
                    reference in
                    if reference.localFileUrl != nil {
                        do {
                            var metadata: [String: String]? = nil
                            var mimeType: String? = nil
                            let referencePrimary = reference.primary
                            guard let filename = reference.filename else { return }
                            if reference.conversationType_ != ClientSynchronizationManager.ConversationType.omemo.rawValue && reference.conversationType_ != ClientSynchronizationManager.ConversationType.omemo1.rawValue && reference.conversationType_ != ClientSynchronizationManager.ConversationType.axolotl.rawValue {
                                guard let mediaType = reference.metadata?["media-type"] else { return }
                                mimeType = mediaType as? String
                                switch reference.mimeType {
                                case "image":
                                    break
                                case "video":
                                    let videoDuration = reference.loadModel()?.duration
                                    let videoPreviewKey = reference.videoPreviewKey
                                    metadata = [:]
                                    metadata!["duration"] = videoDuration
                                    metadata!["video_preview_key"] = videoPreviewKey
                                    break
                                case "voice":
                                    let meteringLevels = reference.metadata?["meters"]
                                    let audioDuration = reference.metadata?["duration"]
                                    metadata = [:]
                                    metadata!["meters"] = meteringLevels as? String
                                    metadata!["duration"] = audioDuration as? String
                                    break
                                default:
                                    break
                                }
                            }
                            
                            var data = try Data(contentsOf: reference.localFileUrl! as URL)
                            let encryptionKeyb64 = reference.metadata?["encryption-key"] as? String
                            let ivb64 = reference.metadata?["iv"] as? String
                            var encryptedFiles = false
                            if CommonConfigManager.shared.config.use_file_enryption_by_default {
                                if [.omemo, .omemo1, .axolotl].contains(reference.conversationType) {
                                    guard let encryptionKeyb64 = encryptionKeyb64,
                                          let ivb64 = ivb64 else {
                                        return
                                    }
                                    let encryptionKey = Array<UInt8>(base64: encryptionKeyb64)
                                    let iv = Array<UInt8>(base64: ivb64)
                                    let encrypted = try! data.encrypt(key: encryptionKey, iv: iv)
                                    
                                    guard let encrypted = encrypted else {
                                        return
                                    }
                                    
                                    data = encrypted
                                    encryptedFiles = true
                                }
                            }
                            
                            uploadFile(
                                message: primary,
                                data: data,
                                filename: filename,
                                mimeType: mimeType,
                                metadata: metadata,
                                successCallback: {
                                    (getUrl, thumbnailUrl, fileID, name, hash, uploadUrl, quota, used) in
                                    //Receives file's name and hash, which were used to delete the file
                                    //Now fileID is used for deletion
                                    
                                    
                                    
                                    
                                    //Writing upload_url, get_url and thumbnail (if exists) in realm
                                    do {
                                        let realm = try WRealm.safe()
                                        if let uploadedReference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                                            try realm.write {
                                                uploadedReference.uploadUrl = uploadUrl
                                                uploadedReference.metadata?["uri"] = getUrl
                                                uploadedReference.metadata?["fileID"] = fileID
                                                uploadedReference.metadata?["filename"] = name
                                                uploadedReference.metadata?["hash"] = hash
                                                uploadedReference.isUploaded = true
                                                uploadedReference.url = getUrl
                                                if let thumbnailUrl = thumbnailUrl {
                                                    uploadedReference.metadata?["thumbnail"] = thumbnailUrl
                                                }
                                            }
                                        }
                                        callSuccessCallback()
                                        if encryptedFiles  {
                                            do {
                                                guard let encryptionKeyb64 = encryptionKeyb64,
                                                      let ivb64 = ivb64 else {
                                                    return
                                                }
                                                let encryptionKey = Array<UInt8>(base64: encryptionKeyb64)
                                                let iv = Array<UInt8>(base64: ivb64)
                                                guard let decryptedData = try Data.decrypt(data, key: encryptionKey, iv: iv) else {
                                                    return
                                                }
                                                if let _ = UIImage(data: decryptedData) {
                                                    ImageCache.default.storeToDisk(decryptedData, forKey: getUrl)
                                                }
                                            } catch {
                                                print(error)
                                            }
                                            
                                        } else {
                                            if let _ = UIImage(data: data) {
                                                ImageCache.default.storeToDisk(data, forKey: getUrl)
                                            }
                                        }
                                    } catch {
                                        DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
                                    }
                                },
                                failCallback: {
                                    fail_error in
                                    DDLogDebug("XabberUploadManager: \(#function). \(String(describing: fail_error?.localizedDescription))")
                                    self.writeErrorInRealm(messageId: primary)
                                },
                                errorCallback: { errorCode in
                                    self.writeErrorInRealm(messageId: primary, errorCode: errorCode)
                                })
                        } catch {
                            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
                        }
                    } else {
                        DDLogDebug("XabberUploadManager: \(#function). localFileUrl is nil")
                    }
                }
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    //MARK: - Prepares information for error info view
    //MARK: - messageId is primary: it already contains owner
    private func writeErrorInRealm(messageId: String, errorCode: Int? = nil) {
        var errorText = "Undefined upload error".localizeString(id: "upload_error_undefined", arguments: [])
        switch errorCode {
        case 400: errorText = "No file attached".localizeString(id: "upload_error_no_attach", arguments: [])
        case 401: errorText = "Incorrect token: unauthorized by server".localizeString(id: "upload_error_incorrect_token", arguments: [])
        case 403: errorText = "Quota exceeded".localizeString(id: "upload_error_quota_exceeded", arguments: [])
        case 413: errorText = "File is too large".localizeString(id: "upload_error_file_too_large", arguments: [])
        case 502: errorText = "Bad gateway: server error (502)".localizeString(id: "upload_error_bad_gateway", arguments: [])
        case 503: errorText = "Server unavailable".localizeString(id: "upload_error_server_unavailable", arguments: [])
        default: errorText = "Undefined upload error".localizeString(id: "upload_error_undefined", arguments: [])
        }
        
        do {
            let realm = try WRealm.safe()
            if let message = realm
                .object(ofType: MessageStorageItem.self,
                        forPrimaryKey: messageId) {
                try realm.write {
                    if message.isInvalidated { return }
                    message.messageError = errorText
                    message.messageErrorCode = "\(errorCode ?? 500)"
                    message.state = .error
                    message.references.forEach({
                        $0.hasError = true
                    })
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: message.opponent, owner: message.owner, conversationType: message.conversationType))?.hasErrorInChat = true
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    //MARK: - Receives quota info, file types' stats and writes it in realm
    public func getQuotaInfo(_ callback: (() -> Void)?) {
        func saveInRealm(quota: Int, used: Int, imagesStats: Int, videosStats: Int, filesStats: Int, voicesStats: Int) {
            do {
                let realm = try WRealm.safe()
                if let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
                                                forPrimaryKey: self.owner) {
                    try realm.write {
                        quotaItem.rawQuota = quota
                        quotaItem.rawUsed = used
                        quotaItem.rawImages = imagesStats
                        quotaItem.rawVideos = videosStats
                        quotaItem.rawFiles = filesStats
                        quotaItem.rawVoices = voicesStats
                    }
                } else {
                    let quotaItem = AccountQuotaStorageItem()
                    quotaItem.jid = self.owner
                    quotaItem.rawQuota = quota
                    quotaItem.rawUsed = used
                    quotaItem.rawImages = imagesStats
                    quotaItem.rawVideos = videosStats
                    quotaItem.rawFiles = filesStats
                    quotaItem.rawVoices = voicesStats
                    try realm.write {
                        realm.add(quotaItem)
                    }
                }
            } catch {
                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        guard isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager: \(#function). Xabber uploader is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/account/quota/"
        
        guard let url = URL(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Url is incorrect")
            return
        }
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(self.token)",
        ]
        print("TOKEN: \(token)\n")
        Alamofire
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                self.checkResponse(response.response?.statusCode) {
                    switch response.result {
                    case .success(let value):
                        guard let json = value as? NSDictionary,
                              let quota = json["quota"] as? Int,
                              let used = json["used"] as? Int else {
                                  DDLogDebug("XabberUplaodManager: \(#function). Error with Alamofire request.")
                                  return
                              }
                        
                        self.getStats() { imagesStats, videosStats, filesStats, voicesStats in
                            saveInRealm(quota: quota,
                                        used: used,
                                        imagesStats: imagesStats,
                                        videosStats: videosStats,
                                        filesStats: filesStats,
                                        voicesStats: voicesStats)
                            callback?()
                        }
                    case .failure(let value):
                        DDLogDebug("XabberUploadManager: \(#function). \(value.localizedDescription)")
                    }
                } fail: { error in
                    guard let error = error as? XabberUploaderError else { return }
                    switch error {
                    case .unauthorized:
                        self.tokenWasExpired()
                    case .unexpected:
                        break
                    }
                }

                
                
            }
    }
    
    private func getStats(successCallback: @escaping ((Int, Int, Int, Int) -> Void)) {
        guard isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        let stringUrl = node + "v1/files/stats/"
        
        guard let url = URL(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(self.token)",
        ]
        
        Alamofire
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: headers
            ).responseJSON { response in
                print("ResponseJSON (statistics): \(response)")
                switch response.result {
                case .success(let value):
                    guard let json = value as? NSDictionary,
                          let images = json["images"] as? NSDictionary,
                          let imagesStats = images["used"] as? Int,
                          let videos = json["videos"] as? NSDictionary,
                          let videosStats = videos["used"] as? Int,
                          let files = json["files"] as? NSDictionary,
                          let filesStats = files["used"] as? Int,
                          let voices = json["voices"] as? NSDictionary,
                          let voicesStats = voices["used"] as? Int else { return }
                    
                    successCallback(imagesStats, videosStats, filesStats, voicesStats)
                case .failure(let value):
                    DDLogDebug("XabberUploadManager: \(#function). \(value.localizedDescription)")
                }
            }
    }
    
    //MARK: - Deletes one media file with selected id
    public func deleteMediaFromServer(fileID: Int) {
        guard isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/files/"
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        
        let params: [String: Int] = [
            "id" : fileID
        ]
        
        guard let url = URL(string: stringUrl) else { return }
        
        Alamofire
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                guard let code = response.response?.statusCode else { return }
                if code >= 200 && code < 300 {
                    switch response.result {
                    case .success(_):
                        print("Deletion success, status code: \(String(describing: response.response?.statusCode))")
                    case .failure(let error):
                        
                        print("Deletion failure: \(error.localizedDescription)")
                    }
                } else if code == 401 {
                    self.tokenWasExpired()
                } else if code > 401 {
                    //fail
                }
            }
    }
    

    private final func tokenWasExpired() {
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            self.getCode(fullJID: stream.myJID!.full)
        })
    }

    //MARK: - Deletes avatar with selected id
    public func deleteAvatarFromServer(fileID: Int) {
        guard isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/avatar/"
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        let params: [String: Int] = [
            "id" : fileID
        ]
        guard let url = URL(string: stringUrl) else { return }
        
        Alamofire
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                guard let code = response.response?.statusCode else { return }
                if code >= 200 && code < 300 {
                    switch response.result {
                    case .success(_):
                        print("Deletion success, status code: \(String(describing: response.response?.statusCode))")
                    case .failure(let error):
                        
                        print("Deletion failure: \(error.localizedDescription)")
                    }
                } else if code == 401 {
                    self.tokenWasExpired()
                } else if code > 401 {
                    //fail
                }
            }
    }
        
    public func deleteGallery(jid: String) {
        
        guard isAvailable(),
              let node = node,
              let url = URL(string: node + "v1/account/") else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let headers: [String : String] = [
            "Authorization" : "Bearer \(token)",
        ]
        
        let params: [String : String] = [
            "jid" : jid
        ]
        
        Alamofire
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                guard let code = response.response?.statusCode else { return }
                if code >= 200 && code < 300 {
                    switch response.result {
                    case .success(_):
                        print("Deletion success, status code: \(String(describing: response.response?.statusCode))")
                    case .failure(let error):
                        print("Deletion failure: \(error.localizedDescription)")
                    }
                } else if code == 401 {
                    self.tokenWasExpired()
                } else if code > 401 {
                    //fail
                }
            }
    }
    
    func getFilesOfType(type: MimeIconTypes, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard self.isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + String(format: "v1/files/")
        
        guard var url = URLComponents(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        url.queryItems = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "page", value: String(page))
        ]
        
        
        let headers: [String: String] = [
            "Authorization": "Bearer \(self.token)"
        ]
        
        Alamofire
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                print("ResponseJSON (of type): \(response)")
                
                switch response.result {
                case .success(let value):
                    guard let json = value as? NSDictionary,
                          let totalObjects = json["total_objects"] as? Int,
                          let objPerPage = json["obj_per_page"] as? Int,
                          let totalPages = json["total_pages"] as? Int else { return }
                    callback(json["items"] as! [NSDictionary], totalObjects, objPerPage, totalPages)
                case .failure(let value):
                    DDLogDebug("XabberUploadManager: \(#function). \(value.localizedDescription)")
                    return
                }
        }
    }
    
    func getAvatars(page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard self.isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + String(format: "v1/avatar/")
        
        guard var url = URLComponents(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        url.queryItems = [
          URLQueryItem(name: "page", value: String(page))
        ]
        let headers: [String: String] = [
            "Authorization": "Bearer \(self.token)"
        ]
        
        Alamofire
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                print("ResponseJSON (avatars): \(response)")
                
                switch response.result {
                case .success(let value):
                    guard let json = value as? NSDictionary,
                          let totalObjects = json["total_objects"] as? Int,
                          let objPerPage = json["obj_per_page"] as? Int,
                          let totalPages = json["total_pages"] as? Int else { return }
                    callback(json["items"] as! [NSDictionary], totalObjects, objPerPage, totalPages)
                case .failure(let value):
                    DDLogDebug("XabberUploadManager: \(#function). \(value.localizedDescription)")
                    return
                }
            }
    }
    
    func getFilesToDeleteByPercent(percent: Int, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard self.isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + String(format: "v1/files/", String(percent))
        
        guard var url = URLComponents(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        
        url.queryItems = [
            URLQueryItem(name: "percent", value: String(percent)),
            URLQueryItem(name: "page", value: String(page))
        ]
        
        let headers: [String: String] = [
            "Authorization": "Bearer \(self.token)"
        ]
        
        Alamofire
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                print("ResponseJSON (from percent): \(response)")
                
                switch response.result {
                case .success(let value):
                    guard let json = value as? NSDictionary,
                          let totalObjects = json["total_objects"] as? Int,
                          let objPerPage = json["obj_per_page"] as? Int,
                          let totalPages = json["total_pages"] as? Int else { return }
                    if totalObjects > 0 {
                        callback(json["items"] as! [NSDictionary], totalObjects, objPerPage, totalPages)
                    }
                case .failure(let value):
                    DDLogDebug("XabberUploadManager: \(#function). \(value.localizedDescription)")
                    return
                }
        }
    }
    
    //MARK: - Deletes all media files for selected period
    public func deleteMediaForSelectedPeriod(earlierThanDate: String, successCallback: @escaping (() -> Void)) {
        guard self.isAvailable(), let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/files/"
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        
        let params: [String: String] = [
            "date_lte" : earlierThanDate
        ]
        
        guard let url = URL(string: stringUrl) else { return }
        
        Alamofire
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: headers)
            .responseJSON { response in
                switch response.result {
                case .success(let value):
                    print("Response success, status code: \(response.response?.statusCode ?? 000)")
                    guard let json = value as? NSDictionary,
                          let status = json["status"] as? Int,
                          let error = json["error"] as? String else { successCallback(); return }
                    print("Status code from server: \(status), error: \(error)")
                    successCallback()
                case .failure(let error):
                    print("Deletion failure: \(error.localizedDescription)")
                }
            }
    }
    
    public final func enable() {
        guard self.token.isEmpty,
              let fulljid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            return
        }
        getCode(fullJID: fulljid)
    }
    
    //MARK: - Sends inquiry to the server in order to get non-permanent code
    private func getCode(fullJID: String, failCallback: ((String?) -> Void)? = nil) {
        guard self.isAvailable(), let node = node else {
            return
        }
        
        let stringUrl = node + "v1/account/xmpp_code_request/"//"api/v1/account/xmpp_code_request/"
        
        let params: [String: String] = ["jid": fullJID,
                                       "type": "iq"]
        let headers: [String: String] = [:]
        
        guard let url = URL(string: stringUrl) else {
            failCallback?(nil)
            return
        }
        Alamofire
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: headers
            ).responseJSON { response in
                print("ResponseJSON (from getKey): \(response)")
                
                switch response.result {
                case .success(let value):
                    print(value)
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
    }
    
    
    //MARK: - Function is called in AccountStremDelegate and gets iq received from the server
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case parseCodeFromStanza(withIQ: iq): return true
        default: return false
        }
    }
    
    
    
    //MARK: - Parses non-permanent code from received stanza; non-permanent code is active for 1 minute
    private func parseCodeFromStanza(withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .get,
              let code = iq.element(
                forName: "confirm",
                xmlns: XabberUploadManager.httpAuthNamespace
              )?.attributeStringValue(forName: "id") else {
                return false
              }
        getToken(withCode: code, failCallback: nil)
        return true
    }
    
    
    //MARK: - Receives token from API by sending non-permanent code
    //MARK: - Token is saved in UserDefaults
    private func getToken(withCode code: String, failCallback: ((Error?) -> Void)?) {
        guard self.isAvailable(), let node = node else {
            return
        }
        let stringUrl = node + "v1/account/xmpp_auth/"
        let params: [String: String] = ["code": code,
                                         "jid": self.owner]
        let headers: [String: String] = [:]
        
        guard let url = URL(string: stringUrl) else {
            failCallback?(nil)
            return
        }
        
        Alamofire
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: headers
            ).responseJSON { [unowned self] response in
                switch response.result {
                case .success(let value):
                    print(value)
                    guard let data = value as? NSDictionary,
                          let token = data["token"] as? String else {
                              failCallback?(nil)
                              return
                          }
                    self.token = token
                    self.getQuotaInfo(nil)
                    print("Received user token: \(token)")
                case .failure(let error):
                    print(error.localizedDescription)
                    failCallback?(error)
                }
            }
    }
    
    
    //MARK: - Removes token from UserDefaults
    static func removeToken(for owner: String) {
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: "userToken")
    }
}
