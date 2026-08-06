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

    internal var node: String? = nil
    internal var maxFileSize: Int? = nil
    private var pendingAvatarUploads: [AvatarUploadTarget: PendingAvatarUpload] = [:]

    private enum AvatarUploadTarget: Hashable {
        case account
        case groupchat(String)
    }

    private struct PendingAvatarUpload {
        let target: AvatarUploadTarget
        let imageData: Data
        let mimeType: String
    }

    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryTokenDidChange(_:)),
            name: .cloudStorageGalleryTokenDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func clearSession() {
        NotificationCenter.default.removeObserver(self)
        pendingAvatarUploads.removeAll()
        super.clearSession()
    }

    open func isAvailable() -> Bool {
        guard let node = AccountGalleryConfiguration(owner: owner).currentGalleryURL?.absoluteString else {
            return false
        }
        self.node = node
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size") ?? "")
        return node.isNotEmpty
    }

    private func currentGalleryRequestContext() -> CloudStorageGalleryRequestContext? {
        return CloudStorageGalleryRequestContext.resolve(owner: owner)
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == owner else { return }
        flushPendingAvatarUploadsIfReady()
    }

    @objc private func cloudStorageGalleryTokenDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == owner else { return }
        flushPendingAvatarUploadsIfReady()
    }

    private func enqueueAvatarUpload(_ upload: PendingAvatarUpload, queuedCallback: (() -> Void)?) {
        pendingAvatarUploads[upload.target] = upload
        queuedCallback?()
        requestAuthForCurrentGalleryIfPossible()
        DDLogDebug("AvatarUploadManager: queued avatar upload for \(owner).")
    }

    private func requeueAvatarUploadIfLatestSlotIsEmpty(_ upload: PendingAvatarUpload) {
        guard pendingAvatarUploads[upload.target] == nil else { return }
        pendingAvatarUploads[upload.target] = upload
    }

    private func flushPendingAvatarUploadsIfReady() {
        guard !pendingAvatarUploads.isEmpty else { return }
        guard currentGalleryRequestContext() != nil else {
            requestAuthForCurrentGalleryIfPossible()
            return
        }

        let uploads = Array(pendingAvatarUploads.values)
        uploads.forEach { pendingAvatarUploads.removeValue(forKey: $0.target) }
        uploads.forEach { uploadPendingAvatar($0) }
    }

    private func uploadPendingAvatar(_ upload: PendingAvatarUpload) {
        uploadAvatar(
            upload,
            successCallback: { [weak self] avatar in
                self?.handleAvatarUploadSuccess(avatar, upload: upload, successCallback: nil)
            },
            failCallback: { [weak self] status, error in
                self?.handleQueuedAvatarUploadFailure(upload, status: status, error: error)
            },
            queuedCallback: nil
        )
    }

    private func handleQueuedAvatarUploadFailure(_ upload: PendingAvatarUpload, status: Int, error: String) {
        DDLogDebug("AvatarUploadManager: queued avatar upload failed for \(owner). \(status): \(error)")
        switch status {
        case 401:
            requeueAvatarUploadIfLatestSlotIsEmpty(upload)
            requestAuthForCurrentGalleryIfPossible()
        case 409:
            requeueAvatarUploadIfLatestSlotIsEmpty(upload)
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingAvatarUploadsIfReady()
            }
        default:
            break
        }
    }

    private func requestAuthForCurrentGalleryIfPossible() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let baseURL = configuration.currentGalleryURL,
              configuration.token(for: configuration.currentGalleryType, baseURL: baseURL).isEmpty else {
            return
        }

        AccountManager.shared.find(for: owner)?.unsafeAction({ user, _ in
            user.cloudStorage.requestAuthIfNeeded(galleryType: configuration.currentGalleryType, baseURL: baseURL)
        })
    }

    fileprivate func posGroupAvatarUpdate(groupchat: String, image imageData: Data, mimeType: String, callback successCallback: (() -> Void)? = nil, failCallback: ((Int, String) -> Void)? = nil, queuedCallback: (() -> Void)? = nil) {
        let upload = PendingAvatarUpload(target: .groupchat(groupchat), imageData: imageData, mimeType: mimeType)
        uploadAvatar(upload,
                     successCallback: { [weak self] avatar in
            self?.handleAvatarUploadSuccess(avatar, upload: upload, successCallback: successCallback)
        }, failCallback: { status, failError in
            failCallback?(status, failError)
            DDLogDebug("AvatarUploadManager: \(#function). \(failError)")
        }, queuedCallback: queuedCallback)
    }

    private func handleAvatarUploadSuccess(_ avatar: AvatarResponse, upload: PendingAvatarUpload, successCallback: (() -> Void)?) {
        switch upload.target {
        case .groupchat(let groupchat):
            handleGroupAvatarUploadSuccess(groupchat: groupchat, avatar: avatar, imageData: upload.imageData, successCallback: successCallback)
        case .account:
            handleAccountAvatarUploadSuccess(avatar: avatar, imageData: upload.imageData, successCallback: successCallback)
        }
    }

    private func handleGroupAvatarUploadSuccess(groupchat: String, avatar: AvatarResponse, imageData: Data, successCallback: (() -> Void)?) {



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
                    if thumbImage.pngData() != nil,
                       let minUrl = minUrl {
                        ImageCache.default.store(thumbImage, forKey: minUrl, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                    }
                }

                successCallback?()

                if let group = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: groupchat, owner: self.owner)) {
                    try realm.write {
                        group.oldschoolAvatarKey = avatar.hash
                        group.avatarUpdatedTS = Date().timeIntervalSince1970
                        group.avatarMaxUrl = maxUrl
                        group.avatarMinUrl = minUrl
                    }
                }

                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                    user.avatarUploader.sendImageMetadata(stream, avatar: avatar, to: XMPPJID(string: groupchat))
                })

            } catch {
                DDLogDebug("AvatarUploadManager: \(#function). \(error.localizedDescription)")
            }
    }

    fileprivate func posAvatarUpdate(image imageData: Data, mimeType: String, callback successCallback: (() -> Void)? = nil, failCallback: ((Int, String) -> Void)? = nil, queuedCallback: (() -> Void)? = nil) {
        let upload = PendingAvatarUpload(target: .account, imageData: imageData, mimeType: mimeType)
        uploadAvatar(upload,
                     successCallback: { [weak self] avatar in
            self?.handleAvatarUploadSuccess(avatar, upload: upload, successCallback: successCallback)
        }, failCallback: { status, failError in
            failCallback?(status, failError)
            DDLogDebug("AvatarUploadManager: \(#function). \(failError)")
        }, queuedCallback: queuedCallback)
    }

    private func handleAccountAvatarUploadSuccess(avatar: AvatarResponse, imageData: Data, successCallback: (() -> Void)?) {



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
                    if thumbImage.pngData() != nil,
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
    }

    public final func setGrpoupAvatar(groupchat: String, image: UIImage?, successCallback: (() -> Void)? = nil, failureCallback: ((Int, String) -> Void)? = nil, queuedCallback: (() -> Void)? = nil) {
        guard let imageData = image?.pngData() else { return }

        posGroupAvatarUpdate(
            groupchat: groupchat,
            image: imageData,
            mimeType: "image/png",
            callback: successCallback,
            failCallback: failureCallback,
            queuedCallback: queuedCallback
        )
    }

    public final func setAvatar(image: UIImage?, successCallback: (() -> Void)? = nil, failureCallback: ((Int, String) -> Void)? = nil, queuedCallback: (() -> Void)? = nil) {
        guard let imageData = image?.pngData() else { return }

        posAvatarUpdate(
            image: imageData,
            mimeType: "image/png",
            callback: successCallback,
            failCallback: failureCallback,
            queuedCallback: queuedCallback
        )
    }

    struct Thumbnail: Codable {
        let height: Int
        let url: String
        let width: Int
    }

    struct AvatarResponse: Decodable {
        let file: String
        let hash: String
        let name: String
        let quota: Int
        let used: Int
        let size: Int
        let thumbnails: [Thumbnail]

        private enum CodingKeys: String, CodingKey {
            case file
            case hash
            case name
            case quota
            case used
            case size
            case thumbnail
            case thumbnails
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            hash = try container.decode(String.self, forKey: .hash)
            name = try container.decode(String.self, forKey: .name)
            quota = try container.decode(Int.self, forKey: .quota)
            used = try container.decode(Int.self, forKey: .used)
            size = try container.decode(Int.self, forKey: .size)

            if let thumbnails = try container.decodeIfPresent([Thumbnail].self, forKey: .thumbnails) {
                self.thumbnails = thumbnails
            } else if let thumbnail = try container.decodeIfPresent(Thumbnail.self, forKey: .thumbnail) {
                self.thumbnails = [thumbnail]
            } else {
                self.thumbnails = []
            }
        }
    }

    private static func avatarResponse(from value: Any?) -> AvatarResponse? {
        guard let value = value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(AvatarResponse.self, from: data)
    }

    struct AvatarErrorResponse: Codable {
        let status: Int
        let error: String
    }

    private static func avatarError(from value: Any?) -> AvatarErrorResponse? {
        guard let value = value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(AvatarErrorResponse.self, from: data)
    }

    //MARK: - Sends avatar to the server, receives its thumbnails' urls
    private func uploadAvatar(_ upload: PendingAvatarUpload,
                              successCallback: @escaping ((AvatarResponse) -> Void),
                              failCallback: @escaping ((Int, String) -> Void),
                              queuedCallback: (() -> Void)?) {
        guard let context = currentGalleryRequestContext() else {
            enqueueAvatarUpload(upload, queuedCallback: queuedCallback)
            return
        }

        XabberUploadManager.quotaAPIClient.uploadFile(
            baseURL: context.baseURL,
            token: context.token,
            data: upload.imageData,
            filename: "\(NanoID.new(5)).png",
            fileMimeType: upload.mimeType,
            galleryMediaType: upload.mimeType,
            metadata: nil,
            context: "avatar",
            traceID: UUID().uuidString
        ) { [weak self] response in
            guard let self = self else { return }
            guard context.matchesCurrentSelection() else {
                failCallback(409, "Cloud Storage gallery changed")
                return
            }

            switch response {
            case .response(let code, let value, _):
                guard let code = code else {
                    failCallback(400, "Unexpected error")
                    return
                }
                if code >= 200 && code < 300,
                   let avatar = Self.avatarResponse(from: value) {
                    successCallback(avatar)
                    CloudStorageQuotaRefreshCoordinator.shared.refresh(owner: self.owner, reason: .uploadCompleted, force: true)
                } else if code == 401 {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, _ in
                        user.cloudStorage.handleUnauthorized(context: context)
                    })
                    failCallback(code, "Incorrect token")
                } else if let error = Self.avatarError(from: value) {
                    failCallback(error.status, error.error)
                } else {
                    failCallback(code, "Unexpected error")
                }
            case .failure(let code, let error, _):
                DDLogDebug("AvatarUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, _ in
                        user.cloudStorage.handleUnauthorized(context: context)
                    })
                }
                failCallback(code ?? 400, "Unexpected error")
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
    public func sendImageMetadata(_ xmppStream: XMPPStream, avatar: AvatarResponse, to: XMPPJID? = nil) {

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

        let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        queryIds.insert(elementId)
    }

    public func sendClearMetadata(_ xmppStream: XMPPStream, to: XMPPJID? = nil, finishCallback: (() -> Void)) {
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

                let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: pubsub)
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
