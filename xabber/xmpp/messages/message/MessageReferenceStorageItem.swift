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

protocol MessageReferenceVideoPreviewScheduling: AnyObject {
    func schedule(referencePrimary: String)
}

typealias MessageContactEntityKind = MessageReferenceStorageItem.ContactEntityKind

final class MessageReferenceVideoPreviewWorker: MessageReferenceVideoPreviewScheduling {
    static let shared = MessageReferenceVideoPreviewWorker()

    private let queue = DispatchQueue(
        label: "com.xabber.message-reference.video-preview",
        qos: .utility
    )
    private let lock = NSLock()
    private var inFlightPrimaryKeys: Set<String> = []
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 2) {
        self.timeout = max(timeout, 0.1)
    }

    func schedule(referencePrimary: String) {
        guard referencePrimary.isNotEmpty else { return }
        lock.lock()
        guard inFlightPrimaryKeys.insert(referencePrimary).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.inFlightPrimaryKeys.remove(referencePrimary)
                self.lock.unlock()
            }
            self.preparePreview(referencePrimary: referencePrimary)
        }
    }

    private func preparePreview(referencePrimary: String) {
        autoreleasepool {
            do {
                let realm = try WRealm.safe()
                guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary),
                      reference.isVideoPreviewCandidate,
                      let request = VideoPreviewRequest(reference: reference) else {
                    return
                }
                guard !ImageCache.default.isCached(forKey: request.key) else {
                    return
                }
                guard let result = Self.generatePreview(
                    url: request.fileURL,
                    key: request.key,
                    orientation: request.orientation,
                    timeout: timeout
                ) else {
                    return
                }
                guard let current = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) else {
                    return
                }
                try realm.write {
                    current.videoPreviewKey = request.key
                    if let duration = result.videoDuration {
                        current.video_duration = duration
                    }
                }
            } catch {
                DDLogDebug("MessageReferenceVideoPreviewWorker: \(#function). \(error.localizedDescription)")
            }
        }
    }

    private struct VideoPreviewRequest {
        let fileURL: URL
        let key: String
        let orientation: UIImage.Orientation

        init?(reference: MessageReferenceStorageItem) {
            guard let fileURL = reference.videoPreviewFileURL else {
                ChatArchiveDebugTrace.log("messageReferenceVideoPreviewSkipped", [
                    ("referencePrimary", reference.primary),
                    ("reason", "no-local-file"),
                    ("mimeType", reference.mimeType)
                ])
                return nil
            }
            self.fileURL = fileURL
            if let existingKey = reference.videoPreviewKey {
                self.key = existingKey
            } else {
                let stableURL = reference.downloadUrl?.absoluteString ?? fileURL.absoluteString
                self.key = [reference.jid, reference.owner, stableURL].prp()
            }
            self.orientation = reference.videoPreviewImageOrientation
        }
    }

    static func generatePreview(
        url: URL,
        key: String,
        orientation: UIImage.Orientation,
        timeout: TimeInterval
    ) -> (width: CGFloat?, height: CGFloat?, videoDuration: String?, image: UIImage?)? {
        guard url.isFileURL else { return nil }
        let boundedTimeout = max(timeout, 0.1)
        let asset = AVAsset(url: url)
        let durationKey = "duration"
        let durationSemaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: [durationKey]) {
            durationSemaphore.signal()
        }
        guard durationSemaphore.wait(timeout: dispatchTimeout(after: boundedTimeout)) == .success else {
            return nil
        }

        var durationError: NSError?
        guard asset.statusOfValue(forKey: durationKey, error: &durationError) == .loaded else {
            return nil
        }
        let duration = asset.duration
        guard duration.isValid, duration.timescale > 0 else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        let imageSemaphore = DispatchSemaphore(value: 0)
        let imageLock = NSLock()
        var generatedImage: UIImage?
        let frameTime = CMTime(value: min(max(duration.value, 1), Int64(duration.timescale)), timescale: duration.timescale)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: frameTime)]) { _, cgImage, _, result, _ in
            if result == .succeeded, let cgImage {
                imageLock.lock()
                generatedImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
                imageLock.unlock()
            }
            imageSemaphore.signal()
        }
        guard imageSemaphore.wait(timeout: dispatchTimeout(after: boundedTimeout)) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }

        imageLock.lock()
        let image = generatedImage
        imageLock.unlock()
        guard let image else {
            return nil
        }
        ImageCache.default.store(image, forKey: key)

        let time = CMTimeGetSeconds(duration)
        let seconds = time.truncatingRemainder(dividingBy: 60)
        let minutes = floor(time / 60)

        return (
            width: image.size.width,
            height: image.size.height,
            videoDuration: String(format: "%.0f:%02.0f", minutes, seconds),
            image: image
        )
    }

    private static func dispatchTimeout(after timeout: TimeInterval) -> DispatchTime {
        .now() + .milliseconds(Int(max(timeout, 0.1) * 1000))
    }
}


class MessageReferenceStorageItem: Object {
    static var videoPreviewScheduler: MessageReferenceVideoPreviewScheduling = MessageReferenceVideoPreviewWorker.shared
    
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
        case geoloc = "geoloc"
        case contact = "contact"
        case none = ""
    }

    enum ContactEntityKind: String {
        case contact
        case groupchat
        case incognito

        static func rawString(from value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        static func metadataEntity(_ metadata: [String: Any]?) -> ContactEntityKind? {
            guard let raw = rawString(from: metadata?["entity"]) else {
                return nil
            }
            return ContactEntityKind(rawValue: raw)
        }

        static func inferred(owner: String, jid: String) -> ContactEntityKind? {
            guard owner.isNotEmpty, jid.isNotEmpty else {
                return nil
            }
            do {
                let realm = try WRealm.safe()
                guard let group = realm.object(
                    ofType: GroupChatStorageItem.self,
                    forPrimaryKey: GroupChatStorageItem.genPrimary(jid: jid, owner: owner)
                ),
                      group.isDeleted == false,
                      group.peerToPeer == false else {
                    return nil
                }
                return group.privacy == .incognito ? .incognito : .groupchat
            } catch {
                return nil
            }
        }

        static func resolved(metadata: [String: Any]?, owner: String, jid: String) -> ContactEntityKind {
            if let entity = metadataEntity(metadata) {
                return entity
            }
            return inferred(owner: owner, jid: jid) ?? .contact
        }
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
    
    @objc dynamic var isSensitive: Bool = false
    @objc dynamic var isSensitiveChecked: Bool = false
    @objc dynamic var sensitivityCheckedAt: Date? = nil
    @objc dynamic var sensitivityAnalysisFailedAt: Date? = nil
    @objc dynamic var sensitivityAnalysisError: String? = nil
    @objc dynamic var sensitivitySource: String? = nil
    @objc dynamic var isLocallyHiddenByReport: Bool = false
    @objc dynamic var localReportState: String? = nil
    @objc dynamic var lastReportedAt: Date? = nil
    @objc dynamic var lastReportReason: String? = nil
    @objc dynamic var reportCount: Int = 0
    
    override static func ignoredProperties() -> [String] {
        return ["temporaryData", "cachedMetadata", "model", "conversationType"]
    }
        
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
            guard ![Kind.geoloc, .contact].contains(kind) else { return nil }
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

    var fileSharingURI: String? {
        if let uri = metadata?["uri"] as? String,
           uri.isNotEmpty {
            return uri
        }
        if let uri = url,
           uri.isNotEmpty {
            return uri
        }
        return nil
    }
    
    var decodedUrl: URL? {
        get {
            guard let uri = self.metadata?["decodedUrl"] as? String else { return nil }
            return URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "")
        }
        set {
            if let uri = newValue?.absoluteString {
                self.metadata?["decodedUrl"] = uri
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
    
    var videoPreviewUrl: URL? {
        get {
            guard let key = self.metadata?["thumbnail"] as? String else { return nil }
            guard let url = URL(string: key) else { return nil }
            return url
        }
        set {
            self.metadata?["thumbnail"] = newValue?.absoluteString
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
    
    var duration: Int? {
        get {
            if let duration = self.metadata?["duration"] as? Int {
                return duration
            }
            if let duration = self.metadata?["duration"] as? String {
                return Int(duration)
            }
            return nil
        }
        set {
            self.metadata?["duration"] = newValue
        }
    }

    var isVideoPreviewCandidate: Bool {
        guard kind == .media else { return false }
        if mimeType == "video" || mimeType.hasPrefix("video/") {
            return true
        }
        return metadata?["media-type"] as? String == "video"
    }

    var videoPreviewFileURL: URL? {
        if let localFileUrl, localFileUrl.isFileURL {
            return localFileUrl
        }
        if let downloadUrl, downloadUrl.isFileURL {
            return downloadUrl
        }
        return nil
    }

    var videoPreviewImageOrientation: UIImage.Orientation {
        guard let videoOrientation else {
            return .up
        }
        let orientation = Orientations(rawValue: videoOrientation) ?? .unknown
        switch orientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeRight:
            return .up
        case .landscapeLeft:
            return .down
        default:
            return .up
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
            if let metersString = self.metadata?["pcm"] as? String {
                return metersString.split(separator: " ").compactMap { return Float($0) }
            }
            return nil
        } set {
            if let value = newValue {
                self.metadata?["pcm"] = value.compactMap{ return "\($0)"}.joined(separator: " ")
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
            case .markup, .mention, .quote:
                return "decoration"
            case .voice, .media: return "mutable"
            default: return "mutable"
            }
        }
    }
    
    static public func prepareVideo(message primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                instance.references.forEach{
                    if SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .video {
                        $0.prepare()
                    }
                }
                instance.inlineForwards.forEach {
                    $0.references.forEach {
                        if SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .video {
                            $0.prepare()
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    private static let sensitivityScanQueue = DispatchQueue(
        label: "com.xabber.sensitive-media.startup-scan",
        qos: .utility
    )

    static func checkAllUndefinedForSesitive() {
        sensitivityScanQueue.async {
            do {
                let realm = try WRealm.safe()
                let primaryKeys = pendingSensitiveAnalysisPrimaryKeys(in: realm)
                Task.detached(priority: .utility) {
                    for primaryKey in primaryKeys {
                        await SensitiveMediaAnalysisService.shared.analyzeMessageReference(primaryKey: primaryKey)
                    }
                }
            } catch {
                DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
            }
        }
    }

    static func pendingSensitiveAnalysisPrimaryKeys(in realm: Realm) -> [String] {
        let objects = realm
            .objects(MessageReferenceStorageItem.self)
            .filter("isSensitive == %@ AND isSensitiveChecked == %@", false, false)

        return Array(objects.map { $0.primary })
    }
    
    func checkIsSensitive() {
        SensitiveMediaAnalysisService.shared.checkIsSensitive(messageReferencePrimaryKey: self.primary)
    }
    
    func prepare() {
        self.checkIsSensitive()
        if isDownloaded {
            return
        }
        switch kind {
            case .voice:
                break
//                guard let uri = metadata?["uri"] as? String,
//                      let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") else {
//                        return
//                }
    //            if OpusAudio.shared.isCached(url) && self.isDownloaded { return }
//                let messageId = self.messageId
//                let jid = self.jid
//                let metadata_ = self.metadata_
                
//                do {
//                    try AudioMessageReceiver.shared.receive(primary: self.primary)
//                } catch {
//                    DDLogDebug("MessageReferenceStorageItem: \(#function). \(error.localizedDescription)")
//                }
                
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
                if isVideoPreviewCandidate {
                    Self.videoPreviewScheduler.schedule(referencePrimary: primary)
                }
            default: break
        }
    }
    
    func extractFrameFromVideo(forKey key: String) -> (width: CGFloat?, height: CGFloat?, video_duration: String?, image: UIImage?){
        guard !ImageCache.default.isCached(forKey: key),
              let url = videoPreviewFileURL,
              let result = MessageReferenceVideoPreviewWorker.generatePreview(
                url: url,
                key: key,
                orientation: videoPreviewImageOrientation,
                timeout: 2
              ) else {
            return (nil, nil, nil, nil)
        }
        return (
            width: result.width,
            height: result.height,
            video_duration: result.videoDuration,
            image: result.image
        )
    }
}
