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

enum CloudStorageQuotaRefreshReason: String {
    case appLaunch
    case foreground
    case premiumEntitlementChanged
    case screenOpen
    case uploadCompleted
    case uploadQuotaExceeded
    case tokenReceived
    case manual
}

enum CloudStorageQuotaRefreshResult: String {
    case success
    case unavailable
    case unauthorized
    case failure
}

extension Notification.Name {
    static let cloudStorageQuotaRefreshDidStart = Notification.Name("CloudStorageQuotaRefreshDidStart")
    static let cloudStorageQuotaRefreshDidFinish = Notification.Name("CloudStorageQuotaRefreshDidFinish")
    static let premiumEntitlementDidChange = Notification.Name("PremiumEntitlementDidChange")
}

struct CloudStorageQuotaCategory: Equatable {
    let used: Int
    let count: Int
}

struct CloudStorageQuotaStatsPayload: Equatable {
    let quota: Int
    let total: CloudStorageQuotaCategory
    let images: CloudStorageQuotaCategory?
    let videos: CloudStorageQuotaCategory?
    let files: CloudStorageQuotaCategory?
    let audio: CloudStorageQuotaCategory?
    let voices: CloudStorageQuotaCategory?
    let avatars: CloudStorageQuotaCategory?
    
    static func parse(_ value: Any) -> CloudStorageQuotaStatsPayload? {
        guard let root = dictionary(from: value),
              let quota = int(from: root["quota"]),
              let totalRoot = dictionary(from: root["total"]),
              let totalUsed = int(from: totalRoot["used"]) else {
            return nil
        }
        
        return CloudStorageQuotaStatsPayload(
            quota: quota,
            total: CloudStorageQuotaCategory(used: totalUsed, count: int(from: totalRoot["count"]) ?? 0),
            images: category(from: root["images"]),
            videos: category(from: root["videos"]),
            files: category(from: root["files"]),
            audio: category(from: root["audio"]),
            voices: category(from: root["voices"]),
            avatars: category(from: root["avatars"])
        )
    }
    
    private static func category(from value: Any?) -> CloudStorageQuotaCategory? {
        guard let root = dictionary(from: value) else { return nil }
        guard int(from: root["used"]) != nil || int(from: root["count"]) != nil else { return nil }
        return CloudStorageQuotaCategory(
            used: int(from: root["used"]) ?? 0,
            count: int(from: root["count"]) ?? 0
        )
    }
    
    private static func dictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }
    
    private static func int(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

struct CloudStorageUploadSlotRequest {
    let size: Int
    let name: String
    let hash: String
}

enum CloudStorageQuotaAPIResponse {
    case response(statusCode: Int?, value: Any?)
    case failure(statusCode: Int?, error: Error?)
}

protocol CloudStorageQuotaAPIClient {
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
}

final class AlamofireCloudStorageQuotaAPIClient: CloudStorageQuotaAPIClient {
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/stats/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }
        
        AF.request(
            url,
            method: .get,
            parameters: nil,
            encoding: JSONEncoding.default,
            headers: HTTPHeaders(["Authorization": "Bearer \(token)"])
        ).responseJSON { response in
            switch response.result {
            case .success(let value):
                completion(.response(statusCode: response.response?.statusCode, value: value))
            case .failure(let error):
                completion(.failure(statusCode: response.response?.statusCode, error: error))
            }
        }
    }
    
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/slot/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }
        
        AF.request(
            url,
            method: .get,
            parameters: [
                "size": request.size,
                "name": request.name,
                "hash": request.hash
            ],
            encoding: URLEncoding.default,
            headers: HTTPHeaders(["Authorization": "Bearer \(token)"])
        ).responseJSON { response in
            switch response.result {
            case .success(let value):
                completion(.response(statusCode: response.response?.statusCode, value: value))
            case .failure(let error):
                completion(.failure(statusCode: response.response?.statusCode, error: error))
            }
        }
    }
    
    private static func apiURL(baseURL: URL, path: String) -> URL? {
        let base = baseURL.absoluteString
        let separator = base.hasSuffix("/") ? "" : "/"
        return URL(string: base + separator + path)
    }
}

final class CloudStorageQuotaRefreshCoordinator {
    static let shared = CloudStorageQuotaRefreshCoordinator()
    
    var ownersProvider: () -> [String] = {
        AccountManager.shared.users.map { $0.jid }
    }
    
    var refreshOwnerHandler: (String, CloudStorageQuotaRefreshReason, Bool, ((CloudStorageQuotaRefreshResult) -> Void)?) -> Void = {
        owner, reason, force, completion in
        AccountManager.shared.find(for: owner)?.action { user, _ in
            user.cloudStorage.refreshQuota(reason: reason, force: force, completion: completion)
        }
    }
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(premiumEntitlementDidChange(_:)),
            name: .premiumEntitlementDidChange,
            object: nil
        )
    }
    
    func refreshAll(reason: CloudStorageQuotaRefreshReason, force: Bool = false) {
        ownersProvider().forEach {
            refresh(owner: $0, reason: reason, force: force)
        }
    }
    
    func refresh(owner: String, reason: CloudStorageQuotaRefreshReason, force: Bool = false, completion: ((CloudStorageQuotaRefreshResult) -> Void)? = nil) {
        guard owner.isNotEmpty else {
            completion?(.unavailable)
            return
        }
        refreshOwnerHandler(owner, reason, force, completion)
    }
    
    @objc private func premiumEntitlementDidChange(_ notification: Notification) {
        guard let owner = notification.userInfo?["jid"] as? String else { return }
        refresh(owner: owner, reason: .premiumEntitlementChanged, force: true)
    }
    
    func resetTestingHooks() {
        ownersProvider = { AccountManager.shared.users.map { $0.jid } }
        refreshOwnerHandler = { owner, reason, force, completion in
            AccountManager.shared.find(for: owner)?.action { user, _ in
                user.cloudStorage.refreshQuota(reason: reason, force: force, completion: completion)
            }
        }
    }
}


/**
*       XabberUploadManager sends inquiry to the server, which gets non-permanent code.
*       It is used for receiving user's token for messages and files exchange
**/
class XabberUploadManager: AbstractXMPPManager {
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
    static var quotaAPIClient: CloudStorageQuotaAPIClient = AlamofireCloudStorageQuotaAPIClient()
    static var tokenExpiredTestingHandler: ((String) -> Void)?
    
    internal var node: String? = nil
    
    internal var namespace: String = ""
    internal var maxFileSize: Int? = nil
    private let quotaRefreshLock = NSLock()
    private var isQuotaRefreshInFlight = false
    private var quotaRefreshCallbacks: [(CloudStorageQuotaRefreshResult) -> Void] = []
    
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
        
        preflightUploadSlot(data: data, filename: filename, errorCallback: errorCallback) { [weak self] shouldContinue in
            guard let self = self, shouldContinue else { return }
            
        let headers: [String: String] = [
            "Authorization" : "Bearer \(self.token)",
        ]
//        print("TOKEN:\n\(token)")
        
        let mime: String = mimeType ?? ""
        var jsonMetadata: Data? = nil
        if let metadata = metadata {
            do {
                jsonMetadata = try JSONSerialization.data(withJSONObject: metadata)
            } catch {
                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        AF.upload(
            multipartFormData: { formData in
                formData.append(data, withName: "file", fileName: filename, mimeType: mimeType ?? "")
                formData.append(mime.data(using: .utf8)!, withName: "media_type")
                formData.append("file".data(using: .utf8)!, withName: "context")
                //Takes type of file, e.g. "audio" from "audio/ogg"
                
                if let jsonMetadata = jsonMetadata {
                    formData.append(jsonMetadata, withName: "metadata")
                }
            },
            to: url,
            method: .post,
            headers: HTTPHeaders(headers))
        .validate()
        .responseJSON { response in
            guard let code = response.response?.statusCode else { return }
            if code >= 200 && code < 300 {
                guard let json = response.value as? NSDictionary,
                      let fileUrl = json["file"] as? String,
                      let name = json["name"] as? String,
                      let hash = json["hash"] as? String,
                      let quota = json["quota"] as? Int,
                      let used = json["used"] as? Int,
                      let fileID = json["id"] as? Int else {
                    guard let json = response.value as? NSDictionary,
                          let statusCode = json["status"] as? Int else {
                              errorCallback(response.response?.statusCode)
                              return
                          }
                    errorCallback(statusCode)
                    return
                }
                
                let thumbnailUrl = (json["thumbnail"] as? NSDictionary)?["url"] as? String

                successCallback(fileUrl, thumbnailUrl, fileID, name, hash, url, quota, used)
                self.refreshQuota(reason: .uploadCompleted, force: true)
            } else if code == 401 {
                self.tokenWasExpired()
                guard let json = response.value as? NSDictionary,
                      let statusCode = json["status"] as? Int else {
                          errorCallback(response.response?.statusCode)
                          return
                      }
                errorCallback(statusCode)
            } else if code > 401 {
                guard let json = response.value as? NSDictionary,
                      let statusCode = json["status"] as? Int else {
                          errorCallback(response.response?.statusCode)
                          if response.response?.statusCode == 403 {
                              self.refreshQuota(reason: .uploadQuotaExceeded, force: true)
                          }
                          return
                      }
                if statusCode == 403 {
                    self.refreshQuota(reason: .uploadQuotaExceeded, force: true)
                }
                errorCallback(statusCode)
            }
        }
        }
//        { result in
//                switch result {
//                    
//                case .success(request: let request, streamingFromDisk: let streamingFromDisk, streamFileURL: let streamFileURL):
//                    request.responseJSON(queue: nil, options: []) { response in
//                        guard let code = response.response?.statusCode else { return }
//                        if code >= 200 && code < 300 {
//                            guard let json = response.result.value as? NSDictionary,
//                                  let fileUrl = json["file"] as? String,
//                                  let name = json["name"] as? String,
//                                  let hash = json["hash"] as? String,
//                                  let quota = json["quota"] as? Int,
//                                  let used = json["used"] as? Int,
//                                  let fileID = json["id"] as? Int else {
//                                guard let json = response.result.value as? NSDictionary,
//                                      let statusCode = json["status"] as? Int else {
//                                          errorCallback(response.response?.statusCode)
//                                          return
//                                      }
//                                errorCallback(statusCode)
//                                return
//                            }
//                            
//                            let thumbnailUrl = (json["thumbnail"] as? NSDictionary)?["url"] as? String
//
//                            successCallback(fileUrl, thumbnailUrl, fileID, name, hash, url, quota, used)
//                            self.getStats()
//                        } else if code == 401 {
//                            self.tokenWasExpired()
//                            guard let json = response.result.value as? NSDictionary,
//                                  let statusCode = json["status"] as? Int else {
//                                      errorCallback(response.response?.statusCode)
//                                      return
//                                  }
//                            errorCallback(statusCode)
//                        } else if code > 401 {
//                            guard let json = response.result.value as? NSDictionary,
//                                  let statusCode = json["status"] as? Int else {
//                                      errorCallback(response.response?.statusCode)
//                                      return
//                                  }
//                            errorCallback(statusCode)
//                        }
//                    }
//                    
//                case .failure(let error):
//                    DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
//                    failCallback(error)
//                }
//            }
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
                    if reference.localFileUrl != nil || reference.decodedUrl != nil {
                        do {
                            var metadata: [String: String]? = nil
                            var mimeType: String? = nil
                            let referencePrimary = reference.primary
                            guard let filename = reference.filename else { return }
//                            if reference.conversationType_ != ClientSynchronizationManager.ConversationType.omemo.rawValue && reference.conversationType_ != ClientSynchronizationManager.ConversationType.omemo1.rawValue && reference.conversationType_ != ClientSynchronizationManager.ConversationType.axolotl.rawValue {
                                guard let mediaType = reference.metadata?["media-type"] else { return }
                                mimeType = mediaType as? String
                                switch reference.mimeType {
                                    case "image":
                                        break
                                    case "video":
    //                                    let videoDuration = reference.loadModel()?.duration
                                        let videoPreviewKey = reference.videoPreviewKey
                                        metadata = [:]
    //                                    metadata!["duration"] = videoDuration
                                        metadata!["video_preview_key"] = videoPreviewKey
                                        break
                                    case "voice", "audio":
                                        let meteringLevels = reference.metadata?["meters"]
                                        let audioDuration = reference.metadata?["duration"]
                                        metadata = [:]
                                        metadata!["meters"] = meteringLevels as? String
                                        metadata!["duration"] = audioDuration as? String
                                        if reference.localFileUrl == nil,
                                           let url = reference.decodedUrl {
                                            let unwrUrl = URL(fileURLWithPath: url.absoluteString)
                                            
                                            try realm.write {
                                                reference.localFileUrl = try? AudioMessageReceiver.shared.encode(url: unwrUrl)
                                            }
                                            
                                        }
                                    default:
                                        break
                                }
//                            }
                            guard reference.localFileUrl != nil else { return }
                            var data = try Data(contentsOf: reference.localFileUrl! as URL)
                            let encryptionKeyb64 = reference.metadata?["encryption-key"] as? String
                            let ivb64 = reference.metadata?["iv"] as? String
                            var encryptedFiles = false
                            if CommonConfigManager.shared.config.use_file_enryption_by_default {
                                if reference.conversationType.isEncrypted {
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
//                                                if let thumbnailUrl = thumbnailUrl {
//                                                    uploadedReference.videoPreviewKey = thumbnailUrl
//                                                }
                                            }
                                        }
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
                                                if let image = UIImage(data: decryptedData) {
                                                    ImageCache.default.storeToDisk(decryptedData, forKey: getUrl)
                                                    let thumb = image.resize(targetSize: CGSize(square: 24))
                                                    if let b64_thumb = thumb.jpegData(compressionQuality: 0.5)?.base64EncodedString() {
                                                        let realm = try WRealm.safe()
                                                        if let uploadedReference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                                                            try realm.write {
                                                                uploadedReference.metadata?["thumbnail-height"] = thumb.size.height
                                                                uploadedReference.metadata?["thumbnail-width"] = thumb.size.width
                                                                uploadedReference.metadata?["thumbnail-uri"] = "data:image/jpeg;base64,\(b64_thumb)"
                                                            }
                                                        }
                                                    }
                                                }
                                            } catch {
//                                                print(error)
                                            }
                                            
                                        } else {
                                            if let image = UIImage(data: data) {
                                                ImageCache.default.storeToDisk(data, forKey: getUrl)
                                                let thumb = image.resize(targetSize: CGSize(square: 24))
                                                if let b64_thumb = thumb.jpegData(compressionQuality: 0.5)?.base64EncodedString() {
                                                    let realm = try WRealm.safe()
                                                    if let uploadedReference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                                                        try realm.write {
                                                            uploadedReference.metadata?["thumbnail-height"] = thumb.size.height
                                                            uploadedReference.metadata?["thumbnail-width"] = thumb.size.width
                                                            uploadedReference.metadata?["thumbnail-uri"] = "data:image/jpeg;base64,\(b64_thumb)"
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        callSuccessCallback()
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
    public func getStats(_ callback: (() -> Void)? = nil) {
        refreshQuota(reason: .manual, force: false) { _ in
            callback?()
        }
    }
    
    public func refreshQuota(
        reason: CloudStorageQuotaRefreshReason = .manual,
        force: Bool = false,
        completion: ((CloudStorageQuotaRefreshResult) -> Void)? = nil
    ) {
        guard isAvailable(), let node = node, let baseURL = URL(string: node) else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            completion?(.unavailable)
            postQuotaRefreshDidFinish(reason: reason, result: .unavailable)
            return
        }
        
        quotaRefreshLock.lock()
        if isQuotaRefreshInFlight {
            if let completion = completion {
                quotaRefreshCallbacks.append(completion)
            }
            quotaRefreshLock.unlock()
            return
        }
        isQuotaRefreshInFlight = true
        quotaRefreshCallbacks = completion.map { [$0] } ?? []
        quotaRefreshLock.unlock()
        
        postQuotaRefreshDidStart(reason: reason)
        Self.quotaAPIClient.getStats(baseURL: baseURL, token: token) { [weak self] response in
            guard let self = self else { return }
            
            let result: CloudStorageQuotaRefreshResult
            switch response {
            case .response(let code, let value):
                if code == 401 {
                    self.tokenWasExpired()
                    result = .unauthorized
                } else if let code = code, code >= 200 && code < 300, let value = value, let payload = CloudStorageQuotaStatsPayload.parse(value) {
                    result = self.storeQuota(payload) ? .success : .failure
                } else {
                    result = .failure
                }
                
            case .failure(let code, let error):
                if code == 401 {
                    self.tokenWasExpired()
                    result = .unauthorized
                } else {
                    DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                    result = .failure
                }
            }
            
            self.finishQuotaRefresh(reason: reason, result: result)
        }
    }
    
    @discardableResult
    private func storeQuota(_ payload: CloudStorageQuotaStatsPayload) -> Bool {
        do {
            let realm = try WRealm.safe()
            let primary = AccountQuotaStorageItem.genPrimary(jid: owner)
            let item = realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: primary) ?? AccountQuotaStorageItem()
            let isNew = item.primary.isEmpty
            if isNew {
                item.primary = primary
                item.jid = owner
            }
            
            try realm.write {
                item.quotaBytes = payload.quota
                item.totalBytes = payload.total.used
                item.totalCount = payload.total.count
                self.apply(payload.images, bytes: \.imagesBytes, count: \.imagesCount, to: item)
                self.apply(payload.videos, bytes: \.videosBytes, count: \.videosCount, to: item)
                self.apply(payload.files, bytes: \.filesBytes, count: \.filesCount, to: item)
                self.apply(payload.audio, bytes: \.audioBytes, count: \.audioCount, to: item)
                self.apply(payload.voices, bytes: \.voicesBytes, count: \.voicesCount, to: item)
                self.apply(payload.avatars, bytes: \.avatarsBytes, count: \.avatarsCount, to: item)
                if isNew {
                    realm.add(item, update: .modified)
                }
            }
            return true
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    private func apply(
        _ category: CloudStorageQuotaCategory?,
        bytes: ReferenceWritableKeyPath<AccountQuotaStorageItem, Int>,
        count: ReferenceWritableKeyPath<AccountQuotaStorageItem, Int>,
        to item: AccountQuotaStorageItem
    ) {
        guard let category = category else { return }
        item[keyPath: bytes] = category.used
        item[keyPath: count] = category.count
    }
    
    private func finishQuotaRefresh(reason: CloudStorageQuotaRefreshReason, result: CloudStorageQuotaRefreshResult) {
        quotaRefreshLock.lock()
        let callbacks = quotaRefreshCallbacks
        quotaRefreshCallbacks = []
        isQuotaRefreshInFlight = false
        quotaRefreshLock.unlock()
        
        postQuotaRefreshDidFinish(reason: reason, result: result)
        callbacks.forEach { $0(result) }
    }
    
    private func postQuotaRefreshDidStart(reason: CloudStorageQuotaRefreshReason) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cloudStorageQuotaRefreshDidStart,
                object: self,
                userInfo: ["jid": self.owner, "reason": reason.rawValue]
            )
        }
    }
    
    private func postQuotaRefreshDidFinish(reason: CloudStorageQuotaRefreshReason, result: CloudStorageQuotaRefreshResult) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cloudStorageQuotaRefreshDidFinish,
                object: self,
                userInfo: ["jid": self.owner, "reason": reason.rawValue, "result": result.rawValue]
            )
        }
    }
    
    func preflightUploadSlot(data: Data, filename: String, errorCallback: @escaping ((Int?) -> Void), completion: @escaping (Bool) -> Void) {
        guard isAvailable(), let node = node, let baseURL = URL(string: node) else {
            completion(true)
            return
        }
        
        let request = CloudStorageUploadSlotRequest(
            size: data.count,
            name: filename,
            hash: data.sha256Data.hexEncodedString()
        )
        
        Self.quotaAPIClient.requestSlot(baseURL: baseURL, token: token, request: request) { [weak self] response in
            guard let self = self else { return }
            
            let code: Int?
            switch response {
            case .response(let statusCode, _):
                code = statusCode
            case .failure(let statusCode, _):
                code = statusCode
            }
            
            if code == 403 {
                errorCallback(403)
                self.refreshQuota(reason: .uploadQuotaExceeded, force: true)
                completion(false)
            } else {
                if code == 401 {
                    self.tokenWasExpired()
                }
                completion(true)
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
        
        AF
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
        if let handler = Self.tokenExpiredTestingHandler {
            handler(owner)
            return
        }
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            guard let fullJID = stream.myJID?.full else { return }
            user.cloudStorage.getCode(fullJID: fullJID)
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
        
        AF
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
        
        AF
            .request(url,
                     method: .delete,
                     parameters: params,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
        
        AF
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
        
        let stringUrl = node + "v1/files/"
        
        guard let url = URL(string: stringUrl),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "contexts", value: "avatar"),
            URLQueryItem(name: "page", value: String(page))
        ]
        let headers: [String: String] = [
            "Authorization": "Bearer \(self.token)"
        ]
        
        AF
            .request(components,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
        
        let stringUrl = node + "v1/files/percent/\(percent)/"
        
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
        
        AF
            .request(url,
                     method: .get,
                     parameters: nil,
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
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
    public func deleteMediaFor(percent: Int, callback: (() -> Void)?) {
        guard self.isAvailable(),
              let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/files/percent/" + "\(percent)"
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        
        
        guard let url = URL(string: stringUrl) else { return }
        
        AF
            .request(url,
                     method: .delete,
                     parameters: [:],
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
                .responseJSON { response in
                    switch response.result {
                    case .success(_):
                        callback?()
                    case .failure(_):
                        callback?()
                }
            }
    }
    
    enum FilesContext: String {
        case avatar = "avatar"
        case file = "file"
        case voice = "voice"
    }
    
    public func deleteMediaForAll(callback: (() -> Void)?) {
        guard self.isAvailable(),
              let node = node else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        
        let stringUrl = node + "v1/files/"
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        guard var url = URLComponents(string: stringUrl) else {
            DDLogDebug("XabberUploadManager: \(#function). Error with upload url.")
            return
        }
        url.queryItems = [
            URLQueryItem(name: "context", value: FilesContext.avatar.rawValue),
            URLQueryItem(name: "context", value: FilesContext.voice.rawValue),
            URLQueryItem(name: "context", value: FilesContext.file.rawValue),
        ]
        AF
            .request(url,
                     method: .delete,
                     parameters: [:],
                     encoding: JSONEncoding.default,
                     headers: HTTPHeaders(headers))
                .responseJSON { response in
                    switch response.result {
                    case .success(_):
                        callback?()
                    case .failure(_):
                        callback?()
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
        
        let stringUrl = node + "v1/account/xmpp_code_request/"
        
        let params: [String: String] = ["jid": fullJID,
                                       "type": "iq"]
        let headers: [String: String] = [:]
        
        guard let url = URL(string: stringUrl) else {
            failCallback?(nil)
            return
        }
        AF
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: HTTPHeaders(headers)
            ).responseJSON { response in
                print("ResponseJSON (from getKey): \(response)")
                
                switch response.result {
                    case .success(let value):
                        DDLogDebug(value)
                    case .failure(let error):
                        DispatchQueue.main.async {
                            ToastPresenter().presentError(message: "Cloud storage is inactive")
                        }
                        failCallback?(error.localizedDescription)
                        DDLogDebug(error.localizedDescription)
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
        
        AF
            .request(
                url,
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default,
                headers: HTTPHeaders(headers)
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
                    self.refreshQuota(reason: .tokenReceived, force: true)
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
