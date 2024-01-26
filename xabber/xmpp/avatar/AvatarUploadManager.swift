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
    private let uploadLink: String = "v1/files/upload/"//"api/v1/avatar/upload/"
    
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
    
    fileprivate func posAvatarUpdate(image imageData: Data, mimeType: String, callback successCallback: (() -> Void)? = nil, failCallback: ((Int, String) -> Void)? = nil) {
        uploadAvatar(data: imageData,
                     filename: "\(NanoID.new(5)).png",
                     mimeType: mimeType,
                     successCallback: { (avatar) in

            
            
            do {
                let realm = try WRealm.safe()
                var maxUrl: String = avatar.file
                var minUrl: String? = nil
                avatar.thumbnails.forEach {
                    thumb in
                    let thumbUrl = thumb.url
                    let width = thumb.width
                    if width >= 512 {
                        maxUrl = thumbUrl
                        return
                    } else if width >= 256 {
                        maxUrl = thumbUrl
                        return
                    }
                }
                
                avatar.thumbnails.forEach {
                    thumb in
                    let thumbUrl = thumb.url
                    let width = thumb.width
                    if width < 256 && width >= 128 {
                        minUrl = thumbUrl
                        return
                    } else if width < 128 {
                        minUrl = thumbUrl
                        return
                    }
                }
                if let image = UIImage(data: imageData) {
                    ImageCache.default.store(image, forKey: maxUrl, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                    let thumbImage = image.resize(targetSize: CGSize(square: 256))
                    if let thumb = thumbImage.pngData(),
                       let minUrl = minUrl {
                        ImageCache.default.store(thumbImage, forKey: minUrl, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                    }
                }
                
                successCallback?()
                
                if let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                    try realm.write {
                        account.oldschoolAvatarKey = avatar.hash
                        account.avatarUpdatedTS = Date().timeIntervalSince1970
                        account.avatarMaxUrl = maxUrl
                        account.avatarMinUrl = minUrl
                    }
                }
                
                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                    user.avatarUploader.sendImageMetadata(stream, avatar: avatar)
                })
                
            } catch {
                DDLogDebug("AvatarUploadManager: \(#function). \(error.localizedDescription)")
            }
        }, failCallback: { status, failError in
            failCallback?(status, failError)
            DDLogDebug("AvatarUploadManager: \(#function). \(failError)")
        })
    }
    
    public final func setAvatar(image: UIImage?, successCallback: (() -> Void)? = nil, failureCallback: ((Int, String) -> Void)? = nil) {
        guard let imageData = image?.pngData() else { return }

        posAvatarUpdate(
            image: imageData,
            mimeType: "image/png",
            callback: successCallback,
            failCallback: failureCallback
        )
    }
    
    struct Thumbnail: Codable {
        let height: Int
        let url: String
        let width: Int
    }
    
    struct AvatarResponse: Codable {
        let file: String
        let hash: String
        let name: String
        let quota: Int
        let used: Int
        let size: Int
        let thumbnails: [Thumbnail]
    }
    
    struct AvatarErrorResponse: Codable {
        let status: Int
        let error: String
    }
    //MARK: - Sends avatar to the server, receives its thumbnails' urls
    private func uploadAvatar(data: Data, filename: String, mimeType: String,
                              successCallback: @escaping ((AvatarResponse) -> Void),
                              failCallback: @escaping ((Int, String) -> Void)) {
        guard isAvailable(), let node = self.node else {
            failCallback(400, "File upload not available")
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
        let createThumbnail: Bool = true
        Alamofire
            .upload(multipartFormData: { formData in
                formData.append(data, withName: "file", fileName: filename, mimeType: mimeType)
                formData.append("\(mimeType)".data(using: .utf8)!, withName: "media_type")
                formData.append(String(createThumbnail).data(using: .utf8)!, withName: "create_thumbnail")
                formData.append("avatar".data(using: .utf8)!, withName: "context")
            },
            usingThreshold: SessionManager.multipartFormDataEncodingMemoryThreshold,
            to: url,
            method: .post,
            headers: headers) { result in
                switch result {
                case .success(request: let request, streamingFromDisk: _, streamFileURL: _):
                    request.responseData(queue: .global(qos: .background)) { response in
                        print(response)
                        do {
                            if (response.response?.statusCode ?? 400) < 300 {
                                guard let data = response.value else {
                                    failCallback(400, "Unexpected error")
                                    return
                                }
                                let avatar =  try JSONDecoder().decode(AvatarResponse.self, from: data)
                                successCallback(avatar)
                            } else {
                                guard let data = response.value else {
                                    failCallback(400, "Unexpected error")
                                    return
                                }
                                let errorResponse = try JSONDecoder().decode(AvatarErrorResponse.self, from: data)
                                failCallback(errorResponse.status, errorResponse.error)
                            }
                        } catch {
                            failCallback(400, "Unexpected error")
                            DDLogDebug("AvatarUploadManager: \(#function). can't decode response)")
                        }
                    }
                case .failure(let error):
                    DDLogDebug("AvatarUploadManager: \(#function). \(error.localizedDescription)")
                    failCallback(400, "Unexpected error")
                }
            }
    }
    
    func getImageTypeMetaData(url: String) -> String {
        for item in mimeIcon {
            if item.value == .image {
                let start = item.key.lastIndex(of: "/") ?? item.key.startIndex
                if url.contains(item.key[start...].replacingOccurrences(of: "/", with: "")) {
                    return item.key
                }
            }
        }
        return "unknown"
    }
    //public func sendImageMetadata(_ xmppStream: XMPPStream, mainUrl: String, hash: String, size: Int, thumbnails: [Thumbnail], jid: String? = nil) {
    public func sendImageMetadata(_ xmppStream: XMPPStream, avatar: AvatarResponse) {
        
        let elementId = "Avatar: \(NanoID.new(8))"
        let metadata = DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata")
        let info = DDXMLElement(name: "info")
        
        info.addAttribute(withName: "bytes", integerValue: avatar.size)
        info.addAttribute(withName: "url", stringValue: avatar.file)
        info.addAttribute(withName: "id", stringValue: avatar.hash)
        info.addAttribute(withName: "type", stringValue: "image/png")
        
        avatar.thumbnails.forEach {
            thumbnail in
            let thumbnailInfo = DDXMLElement(name: "thumbnail", xmlns: "urn:xmpp:thumbs:1")
            thumbnailInfo.addAttribute(withName: "url", stringValue: thumbnail.url)
            let type = getImageTypeMetaData(url: thumbnail.url)
            thumbnailInfo.addAttribute(withName: "media-type", stringValue: type)
            thumbnailInfo.addAttribute(withName: "width", integerValue: thumbnail.width)
            thumbnailInfo.addAttribute(withName: "height", integerValue: thumbnail.height)
            info.addChild(thumbnailInfo)
        }
        
        metadata.addChild(info)
        
        let item = DDXMLElement(name: "item")
        item.addChild(metadata)
        item.addAttribute(withName: "id", stringValue: avatar.hash)
        
        let publish = DDXMLElement(name: "publish")
        publish.addChild(item)
        publish.addAttribute(withName: "node", stringValue: "urn:xmpp:avatar:metadata")
        
        
        let pubsub = DDXMLElement(name: "pubsub")
        pubsub.addChild(publish)
        pubsub.setXmlns("http://jabber.org/protocol/pubsub")
        
        let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        queryIds.insert(elementId)
    }
    
    public func sendClearMetadata(_ xmppStream: XMPPStream, finishCallback: (() -> Void)) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                let elementId = xmppStream.generateUUID
                let metadata = DDXMLElement(name: "metadata", xmlns: "urn:xmpp:avatar:metadata")
                
                let item = DDXMLElement(name: "item")
                item.addChild(metadata)
                item.addAttribute(DDXMLNode.attribute(withName: "id", stringValue: NanoID.new(8)) as! DDXMLNode)
                
                let publish = DDXMLElement(name: "publish")
                publish.addChild(item)
                publish.addAttribute(DDXMLNode.attribute(withName: "node", stringValue: "urn:xmpp:avatar:metadata") as! DDXMLNode)
                
                let pubsub = DDXMLElement(name: "pubsub")
                pubsub.addChild(publish)
                pubsub.setXmlns("http://jabber.org/protocol/pubsub")
                
                let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub)
                xmppStream.send(iq)
                queryIds.insert(elementId)
                try realm.write {
                    instance.avatarMaxUrl = nil
                    instance.avatarMinUrl = nil
                    instance.avatarUpdatedTS = Date().timeIntervalSince1970
                    instance.oldschoolAvatarKey = nil
                }
            }
        } catch {
            
        }
        finishCallback()
    }
}
