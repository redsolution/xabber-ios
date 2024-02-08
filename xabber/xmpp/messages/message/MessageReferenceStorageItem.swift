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
import RealmSwift
import CocoaLumberjack
import Kingfisher
import AVFoundation
import CryptoSwift

class MessageReferenceStorageItem: Object {
    
    struct Model {
        let primary: String
        let messageId: String
        let owner: String
        let jid: String
        let kind_: String
        let mimeType: String
        let begin: Int
        let end: Int
        let metadata_: String
        let isDownloaded: Bool
        let isOriginalMissed: Bool
        
        var kind: Kind {
            get {
                return Kind(rawValue: kind_) ?? .none
            }
        }
        var range: NSRange {
            get {
                return NSRange(begin..<end)
            }
        }
        var metadata: [String: Any]? {
            get {
                if let data = metadata_.data(using: .utf8) {
                    do {
                        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    } catch {
                        DDLogDebug("cant create json object from reference metadata with id: \(messageId)")
                    }
                }
                return nil
            }
        }
        var sizeInBytesRaw: Int {
            get {
                return metadata?["size"] as? Int ?? 0
            }
        }
        
        var sizeInBytes: String? {
            get {
                guard let size = metadata?["size"] as? Int else { return nil}
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useKB, .useMB]
                formatter.countStyle = .binary
                return formatter
                    .string(fromByteCount: Int64(size))
                    .replacingOccurrences(of: ",", with: ".")
                    .replacingOccurrences(of: "MB", with: "MiB")
                    .replacingOccurrences(of: "KB", with: "KiB")
            }
        }
        
        var sizeInPx: CGSize? {
            get {
                guard let height = metadata?["height"] as? Int,
                    let width = metadata?["width"] as? Int else {
                        return nil
                }
                return CGSize(width: width, height: height)
            }
        }
        
//        var sizeInPxThumb: CGSize? {
//            get {
//                guard let height = metadata?["height_thumb"] as? Int,
//                    let width = metadata?["width_thumb"] as? Int else {
//                        return nil
//                }
//                return CGSize(width: width, height: height)
//            }
//        }
        
        var meteringLevels: [Float]? {
            get {
                if let metersString = self.metadata?["meters"] as? String {
                    return metersString.split(separator: " ").compactMap { return Float($0) }
                }
                return nil
            }
        }
        var uploadUrl: URL? {
            get {
                guard let uri = self.metadata?["putUri"] as? String else { return nil }
                return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
            }
        }
        
        var localFileUrl: URL? {
            get {
                guard let uri = self.metadata?["localFileUri"] as? String else { return nil }
                return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
            }
        }
        
        var downloadUrl: URL? {
            get {
                guard let uri = self.metadata?["uri"] as? String else { return nil }
                return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
            }
        }
        
        var videoPreviewKey: String? {
            get {
                guard let key = self.metadata?["thumbnail"] as? String else { return nil }
                return key
            }
        }
        
        var videoOrientation: String? {
            get {
                guard let orientation = self.metadata?["orientation"] as? String else { return nil }
                return orientation
            }
        }
        
        var audioDuration: CGFloat? {
            get {
                guard let duration = self.metadata?["duration"] as? CGFloat else { return nil }
                return duration
            }
        }
        
        var date: String? {
            get {
                guard let date = self.metadata?["date"] as? String else { return nil }
                return date
            }
        }
        
        var sender_name: String? {
            get {
                guard let sender = self.metadata?["sender_name"] as? String else { return nil }
                return sender
            }
        }
        
        var duration: String? {
            get {
                guard let duration = self.metadata?["video_duration"] as? String else { return nil }
                return duration
            }
        }
    }
    
    enum Kind: String {
        case media = "media"
        case voice = "voice"
        case forward = "forward"
        case markup = "markup"
        case mention = "mention"
        case quote = "quote"
        case groupchat = "groupchat"
        case call = "call"
        case systemMessage = "system-message"
        case none = ""
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    
    override static func indexedProperties() -> [String] {
        return ["owner", "messageId", "kind_", "date"]
    }
    
    @objc dynamic var primary: String = UUID().uuidString
    
    @objc dynamic var messageId: String = ""
    @objc dynamic var sentDate: Date = Date(timeIntervalSince1970: 0)
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var kind_: String = ""
    @objc dynamic var mimeType: String = ""
    @objc dynamic var begin: Int = 0
    @objc dynamic var end: Int = 0
    @objc dynamic var metadata_: String = ""
    @objc dynamic var isDownloaded: Bool = false
    @objc dynamic var isUploaded: Bool = false
    @objc dynamic var isMissed: Bool = false
    @objc dynamic var hasError: Bool = false
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var url: String? = nil
    
    override static func ignoredProperties() -> [String] {
        return ["temporaryData", "cachedMetadata", "model", "conversationType"]
    }
    
    var model: Model?
    
    public var temporaryData: Data? = nil
    
    var kind: Kind {
        get {
            return Kind(rawValue: kind_) ?? .none
        } set {
            kind_ = newValue.rawValue
        }
    }
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var range: NSRange {
        get {
            return NSRange(begin..<end)
        } set {
            begin = newValue.location
            end = newValue.location + newValue.length
        }
    }
    
    var uploadUrl: URL? {
        get {
            guard let uri = self.metadata?["putUri"] as? String else { return nil }
            return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
        } set {
            if let uri = newValue?.absoluteString {
                self.metadata?["putUri"] = uri
            }
        }
    }
    
    var localFileUrl: URL? {
        get {
            guard let uri = self.metadata?["localFileUri"] as? String else { return nil }
            return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
        } set {
            if let uri = newValue?.absoluteString {
                self.metadata?["localFileUri"] = uri
            }
        }
    }
    
    var downloadUrl: URL? {
        get {
            guard let uri = self.url else { return nil }
            return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
        }
        set {
            if let uri = newValue?.absoluteString {
                self.metadata?["uri"] = uri
                self.url = uri
            }
        }
    }
    
    var videoPreviewKey: String? {
        get {
            guard let key = self.metadata?["thumbnail"] as? String else { return nil }
            return key
        }
        set {
            self.metadata?["thumbnail"] = newValue
        }
    }
    
    var videoOrientation: String? {
        get {
            guard let orientation = self.metadata?["orientation"] as? String else { return nil }
            return orientation
        }
        set {
            self.metadata?["orientation"] = newValue
        }
    }
    
    var date: String? {
        get {
            guard let date = self.metadata?["date"] as? String else { return nil }
            return date
        }
        set {
            self.metadata?["date"] = newValue
        }
    }
    
    var sender_name: String? {
        get {
            guard let sender = self.metadata?["sender_name"] as? String else { return nil }
            return sender
        }
        set {
            self.metadata?["sender_name"] = newValue
        }
    }
    
    var video_duration: String? {
        get {
            guard let duration = self.metadata?["video_duration"] as? String else { return nil }
            return duration
        }
        set {
            self.metadata?["video_duration"] = newValue
        }
    }
    
    var isDownloading: Bool? {
        get {
            return self.metadata?["is_downloading"] as? Bool
        } set {
            self.metadata?["is_downloading"] = newValue
        }
    }
    
    var name: String? {
        get {
            guard let name = metadata?["name"] as? String else { return nil }
            return name
        }
        set {
            metadata?["name"] = newValue
        }
    }
    
    var filename: String? {
        get {
            guard let filename = metadata?["filename"] as? String else { return nil }
            return filename
        }
        set {
            self.metadata?["filename"] = newValue
        }
    }
    
    var filehash: String? {
        get {
            guard let hash = metadata?["hash"] as? String else { return nil }
            return hash
        }
        set {
            metadata?["hash"] = newValue
        }
    }
    
    var fileID: Int? {
        get {
            guard let id = metadata?["fileID"] as? Int else { return nil }
            return id
        }
        set {
            metadata?["fileID"] = newValue
        }
    }
    
    public final func loadModel() -> Model? {
        self.model = Model(
            primary: self.primary,
            messageId: self.messageId,
            owner: self.owner,
            jid: self.jid,
            kind_: self.kind_,
            mimeType: self.mimeType,
            begin: self.begin,
            end: self.end,
            metadata_: self.metadata_,
            isDownloaded: self.isDownloaded,
            isOriginalMissed: self.isMissed
        )
        return self.model
    }
    
    var metadata: [String: Any]? {
        get {
            if self.isInvalidated { return nil }
            if let data = metadata_.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("cant create json object from reference metadata with id: \(messageId)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    metadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode reference metadata with id: \(messageId)")
                }
            } else {
                metadata_ = ""
            }
        }
    }
    
    var sizeInBytesRaw: Int {
        get {
            return metadata?["size"] as? Int ?? 0
        }
    }
    
    var sizeInBytes: String? {
        get {
            guard let size = metadata?["size"] as? Int else { return nil}
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .binary
            return formatter
                .string(fromByteCount: Int64(size))
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "MB", with: "MiB")
                .replacingOccurrences(of: "KB", with: "KiB")
        }
    }
    
    var sizeInPx: CGSize? {
        get {
            guard let height = metadata?["height"] as? Int,
                let width = metadata?["width"] as? Int else {
                    return nil
            }
            return CGSize(width: width, height: height)
        }
    }
    
    var meteringLevels: [Float]? {
        get {
            if let metersString = self.metadata?["meters"] as? String {
                return metersString.split(separator: " ").compactMap { return Float($0) }
            }
            return nil
        } set {
            if let value = newValue {
                self.metadata?["meters"] = value.compactMap{ return "\($0)"}.joined(separator: " ")
            }
        }
    }
    
    var callState: VoIPCall.State {
        get {
            if let stateInt = self.metadata?["callState"] as? Int {
                return VoIPCall.State(rawValue: stateInt) ?? .ended
            }
            return .ended
        }
    }
    
    var xmlType: String {
        get {
            switch kind {
            case .voice, .media: return "mutable"
            default: return "mutable"
            }
        }
    }
    
    static public func prepareVoice(message primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                instance.references.forEach{ $0.prepare() }
                instance.inlineForwards.forEach { $0.references.forEach { $0.prepare() } }
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    static public func prepareVoice(inline messageId: String) {
        do {
            let realm = try  WRealm.safe()
            realm.objects(MessageForwardsInlineStorageItem.self).filter("messageId == %@", messageId).forEach {
                instance in
                instance.references.forEach { $0.prepare() }
                instance.subforwards.forEach { $0.references.forEach { $0.prepare() } }
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    static public func prepareVoice(for messageId: String, jid: String, metadata: String) {
        do {
            let realm = try  WRealm.safe()
            realm
                .objects(MessageReferenceStorageItem.self)
                .filter("messageId == %@ AND jid == %@ AND metadata_ == %@", messageId, jid, metadata)
                .forEach {
                $0.prepare()
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    static public func prepareVideo(message primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                instance.references.forEach{
                    if $0.mimeType == "video" {
                        $0.prepare()
                    }
                }
                instance.inlineForwards.forEach {
                    $0.references.forEach {
                        if $0.mimeType == "video" {
                            $0.prepare()
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    static public func prepareVideo(messageId: String, jid: String, metadata: String) {
        if CommonConfigManager.shared.config.use_file_enryption_by_default { return }
        do {
            let realm = try  WRealm.safe()
            realm
                .objects(MessageReferenceStorageItem.self)
                .filter("messageId == %@ AND jid == %@ AND metadata_ == %@", messageId, jid, metadata)
                .forEach {
                    $0.prepare()
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    func prepare() {
        if isDownloaded {
            return
        }
        switch kind {
        case .voice:
            guard let uri = metadata?["uri"] as? String,
                  let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") else {
                    return
            }
//            if OpusAudio.shared.isCached(url) && self.isDownloaded { return }
            let messageId = self.messageId
            let jid = self.jid
            let metadata_ = self.metadata_
//            OpusAudio.shared.add(url) { (result, meters, duration) in
//                guard result else { return }
//                do {
//                    let realm = try  WRealm.safe()
//                    let instances = realm
//                        .objects(MessageReferenceStorageItem.self)
//                        .filter("messageId == %@ AND jid == %@ AND metadata_ == %@ AND isDownloaded == %@", messageId, jid, metadata_, false)
//                    try realm.write {
//                        for instance in instances {
//                            instance.isDownloaded = true
//                            instance.metadata?["meters"] = meters.compactMap{ return "\($0)"}.joined(separator: " ")
//                            instance.metadata?["duration"] = duration
//                        }
//                    }
//                    
//                } catch {
//                    DDLogDebug(error.localizedDescription)
//                }
//            }
        case .media:
            if mimeType == "video" {
                
                if CommonConfigManager.shared.config.use_file_enryption_by_default {
                    let primary = self.primary
                    do {
                        let realm = try WRealm.safe()
                        try realm.write {
                            realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary)?.isDownloading = true
                        }
                    } catch {
                        DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
                    }
                    do {
                        guard let url = self.downloadUrl else { return }
                        let encryptedData = try Data(contentsOf: url)
                        guard let keyb64 = self.metadata?["encryption-key"] as? String,
                              let ivb64 =  self.metadata?["iv"] as? String else { return }
                        let encryptionKeyRaw = Array<UInt8>(base64: keyb64)
                        let ivRaw = Array<UInt8>(base64: ivb64)
                        let gcm = GCM(iv: ivRaw, mode: .combined)
                        let aes = try AES(key: encryptionKeyRaw, blockMode: gcm, padding: .noPadding)
                        let decrypted = try aes.decrypt(Array(encryptedData))
                        let data = Data(decrypted)
                        var path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                        path?.appendPathComponent(url.lastPathComponent)
                        guard let resultFilePath = path else { return }
                        try data.write(to: resultFilePath, options: Data.WritingOptions.completeFileProtection)
                        let primary = self.primary
                            
                        let realm = try WRealm.safe()
                        let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary)
                        try realm.write {
                            instance?.isDownloaded = true
                            instance?.localFileUrl = resultFilePath
                        }
                        
                        guard let key = self.videoPreviewKey else {
                            guard let url = self.downloadUrl?.absoluteString else { return }
                            let key = [self.jid, self.owner, url].prp()
                            let result = self.extractFrameFromVideo(forKey: key)
                            do {
                                let realm = try WRealm.safe()
                                let primary = self.primary
                                let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary)
                                try realm.write {
                                    instance?.isDownloaded = true
                                    instance?.videoPreviewKey = key
                                    instance?.video_duration = result.video_duration ?? ""
                                }
                                
                            } catch {
                                DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
                            }
                            
                            
                            return
                        }
                        _ = self.extractFrameFromVideo(forKey: key)
                        
                    } catch {
                        DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
                    }
                } else {
                    guard let key = videoPreviewKey else {
                        guard let url = downloadUrl?.absoluteString else { return }
                        let key = [jid, owner, url].prp()
                        let result = extractFrameFromVideo(forKey: key)
                        do {
                            let realm = try WRealm.safe()
                            let instances = realm
                                .objects(MessageReferenceStorageItem.self)
                                .filter("messageId == %@ AND jid == %@ AND metadata_ == %@", messageId, jid, metadata_)
                            try realm.write {
                                for instance in instances {
                                    instance.isDownloaded = true
                                    instance.videoPreviewKey = key
                                    instance.video_duration = result.video_duration ?? ""
                                }
                            }
                            
                        } catch {
                            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
                        }
                        
                        
                        return
                    }
                    _ = extractFrameFromVideo(forKey: key)
                }
                
            }
        default: break
        }
    }
    
    func extractFrameFromVideo(forKey key: String) -> (width: CGFloat?, height: CGFloat?, video_duration: String?){
        if !ImageCache.default.isCached(forKey: key) {
            var orientationImage: UIImage.Orientation = .up
            if videoOrientation != nil {
                let orientation = Orientations(rawValue: videoOrientation ?? "unknown") ?? .unknown
                switch orientation {
                case .portrait:
                    orientationImage = .right
                case .portraitUpsideDown:
                    orientationImage = .left
                case .landscapeRight:
                    orientationImage = .up
                case .landscapeLeft:
                    orientationImage = .down
                default: break
                }
            }
            
            guard let url = self.localFileUrl ?? downloadUrl else { return (nil, nil, nil) }
            let asset = AVAsset(url: url)
            let timeForFrame = CMTime(value: asset.duration.value / 2,
                                      timescale: asset.duration.timescale)
            
            let generator = AVAssetImageGenerator.init(asset: asset)
            let cgImage: CGImage
            
            do {
                cgImage = try generator.copyCGImage(at: timeForFrame, actualTime: nil)
            } catch {
                DDLogDebug("MessagereferenceStorageItem: \(#function). \(error.localizedDescription)")
                return (nil, nil, nil)
            }
            let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientationImage)//.rotate(radians: rotation)
            ImageCache.default.store(image, forKey: key)
            
            let time = CMTimeGetSeconds(asset.duration)
            let seconds = time.truncatingRemainder(dividingBy: 60)
            let minutes = (time - seconds).truncatingRemainder(dividingBy: 60)
            
            return (width: image.size.width, height: image.size.height,
                    video_duration: String(format: "%.0f:%2.0f", minutes, seconds).replacingOccurrences(of: " ", with: "0"))
        }
        return (nil, nil, nil)
    }
}
