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
import RealmSwift
import CocoaLumberjack
import Alamofire
import Kingfisher

class AvatarUploadManager: AbstractXMPPManager {
    enum UploadError: Error {
        case notAvailable
    }
    
    private static let httpAuthNamespace: String = "http://jabber.org/protocol/http-auth"
    private let uploadLink: String = "v1/avatar/upload/"//"api/v1/avatar/upload/"
    
    internal var node: String? = nil
    internal var maxFileSize: Int? = nil
    
    var token: String {
        get {
            return SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "userToken") ?? ""
        }
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
    }
    
    open func isAvailable() -> Bool {
        guard let node = SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "node") else {
            //self.node = "https://gallery.clandestino.chat/api/"//"https://gallery.dev.xabber.com/api/"
            return false
        }
        self.node = node
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size") ?? "")
        return node.isNotEmpty
    }
    
    fileprivate func posAvatarUpdate(image pngData: Data, mimeType: String, avatar avatarPrimary: String, callback callSuccessCallback: (() -> Void)? = nil) {
        uploadAvatar(data: pngData,
                     filename: "\(UUID().uuidString).png",
                     mimeType: mimeType,
                     //successCallback: { (uploadUrl, hash, size, thumbnails) in
                     successCallback: { (avatar) in
            
            guard let hash = avatar.hash,
                  let uploadUrl = avatar.file,
                  let thumbnails = avatar.thumbnails else { return }
            
            DefaultAvatarManager.shared.removeFromCache(jid: self.owner, owner: self.owner, url: uploadUrl)
            
            if let _ = UIImage(data: pngData) {
                ImageCache.default.storeToDisk(pngData, forKey: uploadUrl)
                for thumbnail in thumbnails {
                    if let height = thumbnail.height,
                       let width = thumbnail.width,
                       let url = thumbnail.url,
                       let image = UIImage(data: pngData)?.resize(targetSize: CGSize(square: CGFloat(height))) {
                        ImageCache.default.store(image, forKey: url)
                    }
                }
            }
            
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.avatarUploader.sendImageMetadata(stream, avatar: avatar)
            })
            
            do {
                let realm = try WRealm.safe()
                
                if let avatarItem = realm.object(ofType: AvatarStorageItem.self,
                                                 forPrimaryKey: avatarPrimary) {
                    try realm.write {
                        if avatarItem.isInvalidated { return }
                        avatarItem.uploadUrl = uploadUrl
                        avatarItem.imageHash = hash
                        avatarItem.image32 = thumbnails.first(where: { $0.url!.contains("/32_") })?.url
                        avatarItem.image48 = thumbnails.first(where: { $0.url!.contains("/48_") })?.url
                        avatarItem.image64 = thumbnails.first(where: { $0.url!.contains("/64_") })?.url
                        avatarItem.image96 = thumbnails.first(where: { $0.url!.contains("/96_") })?.url
                        avatarItem.image128 = thumbnails.first(where: { $0.url!.contains("/128_") })?.url
                        avatarItem.image192 = thumbnails.first(where: { $0.url!.contains("/192_") })?.url
                        avatarItem.image256 = thumbnails.first(where: { $0.url!.contains("/256_") })?.url
                        avatarItem.image384 = thumbnails.first(where: { $0.url!.contains("/384_") })?.url
                        avatarItem.image512 = thumbnails.first(where: { $0.url!.contains("/512_") })?.url
                    }
                } else {
                    let instance = AvatarStorageItem()
                    instance.primary = avatarPrimary
                    instance.owner = self.owner
                    instance.jid = self.owner
                    
                    instance.uploadUrl = uploadUrl
                    instance.imageHash = hash
                    instance.image32 = thumbnails.first(where: { $0.url!.contains("/32_") })?.url
                    instance.image48 = thumbnails.first(where: { $0.url!.contains("/48_") })?.url
                    instance.image64 = thumbnails.first(where: { $0.url!.contains("/64_") })?.url
                    instance.image96 = thumbnails.first(where: { $0.url!.contains("/96_") })?.url
                    instance.image128 = thumbnails.first(where: { $0.url!.contains("/128_") })?.url
                    instance.image192 = thumbnails.first(where: { $0.url!.contains("/192_") })?.url
                    instance.image256 = thumbnails.first(where: { $0.url!.contains("/256_") })?.url
                    instance.image384 = thumbnails.first(where: { $0.url!.contains("/384_") })?.url
                    instance.image512 = thumbnails.first(where: { $0.url!.contains("/512_") })?.url
                    try realm.write {
                        realm.add(instance)
                    }
                }
                callSuccessCallback?()
            } catch {
                DDLogDebug("AvatarUploadManager: \(#function). \(error.localizedDescription)")
            }
        }, failCallback: { fail_error in
            DDLogDebug("AvatarUploadManager: \(#function). \(fail_error.localizedDescription)")
        })
    }
    
    public final func setAvatar(image: UIImage?, successCallback: (() -> Void)? = nil, failureCallback: (() -> Void)? = nil) {
        guard let pngData = image?.pngData() else { return }

        posAvatarUpdate(
            image: pngData,
            mimeType: "image/png",
            avatar: AvatarStorageItem.genPrimary(jid: self.owner, owner: self.owner),
            callback: successCallback
        )
    }
    
    struct Thumbnail: Codable {
        let height: Int?
        let url: String?
        let width: Int?
    }
    
    struct AvatarResponse: Codable {
        let created_at: String?
        let file: String?
        let hash: String?
        let name: String?
        let quota: Int?
        let used: Int?
        let size: Int?
        let thumbnails: [Thumbnail]?
    }
    //MARK: - Sends avatar to the server, receives its thumbnails' urls
    private func uploadAvatar(data: Data, filename: String, mimeType: String,
                              //successCallback: @escaping ((String, String, Int, [Thumbnail]) -> Void),
                              successCallback: @escaping ((AvatarResponse) -> Void),
                              failCallback: @escaping ((Error) -> Void), needsThumb: Bool = true) {
        guard isAvailable(), let node = self.node else {
            failCallback(UploadError.notAvailable)
            return
        }
        
        let stringUrl = node + uploadLink
        guard let url = URL(string: stringUrl) else {
            DDLogDebug("AvatarUploadManager: \(#function). Url is incorrect")
            return
        }
        
        let headers: [String: String] = [
            "Authorization" : "Bearer \(token)",
        ]
        
        Alamofire
            .upload(multipartFormData: { formData in
                formData.append(data, withName: "some_file_name.png", fileName: filename, mimeType: mimeType)
                formData.append("\(mimeType)".data(using: .utf8)!, withName: "media_type")
                formData.append(String(needsThumb).data(using: .utf8)!, withName: "create_thumbnail")
            },
                        usingThreshold: SessionManager.multipartFormDataEncodingMemoryThreshold,
                        to: url,
                        method: .post,
                        headers: headers) { result in
                switch result {
                case .success(request: let request, streamingFromDisk: _, streamFileURL: _):
                    request.responseData(queue: .global(qos: .background)) { response in
                        do {
                            guard let data = response.value else { return }
                            let avatar =  try JSONDecoder().decode(AvatarResponse.self, from: data)
                            if let used = avatar.used, let quota = avatar.quota {
                                self.saveQuotaInRealm(quota: quota, used: used)
                            }
                            successCallback(avatar)
                        } catch {
                            DDLogDebug("AvatarUploadManager: \(#function). can't decode response)")
                        }
                    }
                case .failure(let error):
                    DDLogDebug("AvatarUploadManager: \(#function). \(error.localizedDescription)")
                    failCallback(error)
                }
            }
    }
    
    func getImageTypeMetaData(url: String) -> String {
        for item in mimeIcon {
            if item.value == .image {
                let start = item.key.lastIndex(of: "/") ?? item.key.startIndex
                if url.contains(item.key[start...].replacingOccurrences(of: "/", with: "")) {
                    return  item.key
                }
            }
        }
        return "unknown"
    }
    //public func sendImageMetadata(_ xmppStream: XMPPStream, mainUrl: String, hash: String, size: Int, thumbnails: [Thumbnail], jid: String? = nil) {
    public func sendImageMetadata(_ xmppStream: XMPPStream, avatar: AvatarResponse) {
        
        let elementId = xmppStream.generateUUID
        let metadata = DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata")
        let info = DDXMLElement(name: "info")
        
        guard let bytes = avatar.size,
              let url = avatar.file,
              let id = avatar.hash,
              let thumbnails = avatar.thumbnails else { return }
        
        info.addAttribute(withName: "bytes", stringValue: String(bytes))
        info.addAttribute(withName: "url", stringValue: url)
        info.addAttribute(withName: "id", stringValue: id)
        let type  = getImageTypeMetaData(url: url)
        info.addAttribute(withName: "type", stringValue: type)
        info.addAttribute(withName: "height", stringValue: "original")
        info.addAttribute(withName: "width", stringValue: "original")
        
        for thumbnail in thumbnails {
            guard let url = thumbnail.url,
                  let width = thumbnail.width,
                  let height = thumbnail.height else { continue }
            let thumbnailInfo = DDXMLElement(name: "thumbnail", xmlns: "urn:xmpp:thumbs:1")
            thumbnailInfo.addAttribute(withName: "url", stringValue: url)
            let type = getImageTypeMetaData(url: thumbnail.url!)
            thumbnailInfo.addAttribute(withName: "media-type", stringValue: type)
            thumbnailInfo.addAttribute(withName: "width", stringValue: String(width))
            thumbnailInfo.addAttribute(withName: "height", stringValue: String(height))
            info.addChild(thumbnailInfo)
        }
        
        metadata.addChild(info)
        
        let item = DDXMLElement(name: "item")
        item.addChild(metadata)
        item.addAttribute(DDXMLNode.attribute(withName: "id", stringValue: id) as! DDXMLNode)
        
        let publish = DDXMLElement(name: "publish")
        publish.addChild(item)
        publish.addAttribute(DDXMLNode.attribute(withName: "node", stringValue: "urn:xmpp:avatar:metadata") as! DDXMLNode)
        
        let pubsub = DDXMLElement(name: "pubsub")
        pubsub.addChild(publish)
        pubsub.setXmlns("http://jabber.org/protocol/pubsub")
        
        let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        queryIds.insert(elementId)
    }
    
    public func sendClearMetadata(_ xmppStream: XMPPStream, hash: String, stringUrl: String, finishCallback: (() -> Void)) {
        let elementId = xmppStream.generateUUID
        let metadata = DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata")
        
        let item = DDXMLElement(name: "item")
        item.addChild(metadata)
        item.addAttribute(DDXMLNode.attribute(withName: "id", stringValue: hash) as! DDXMLNode)
        
        let publish = DDXMLElement(name: "publish")
        publish.addChild(item)
        publish.addAttribute(DDXMLNode.attribute(withName: "node", stringValue: "urn:xmpp:avatar:metadata") as! DDXMLNode)
        
        let pubsub = DDXMLElement(name: "pubsub")
        pubsub.addChild(publish)
        pubsub.setXmlns("http://jabber.org/protocol/pubsub")
        
        let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        queryIds.insert(elementId)
        
        finishCallback()
    }
    
    func saveQuotaInRealm(quota: Int, used: Int) {
        do {
            let realm = try WRealm.safe()
            if let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
                                            forPrimaryKey: self.owner) {
                try realm.write {
                    quotaItem.rawQuota = quota
                    quotaItem.rawUsed = used
                }
            } else {
                let quotaItem = AccountQuotaStorageItem()
                quotaItem.jid = self.owner
                quotaItem.rawQuota = quota
                quotaItem.rawUsed = used
                try realm.write {
                    realm.add(quotaItem)
                }
            }
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
        }
    }
}
