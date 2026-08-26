//
//  MessageMediaAttachmentStorageItem.swift
//  xabber
//
//  Created by Игорь Болдин on 12.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack
import UIKit

enum MessageMediaThumbnailDataURLPolicy {
    /// Inline XEP thumbnail payloads are intended to be tiny. Bounding the
    /// decoded value before it enters the resident timeline prevents one
    /// malformed row from retaining an arbitrarily large base64 string in the
    /// thumbnail pipeline.
    static let maximumDecodedByteCount = 128 * 1_024

    static func dataURLString(
        base64: String?,
        preferredMediaType: String?
    ) -> String? {
        guard let base64 = normalizedBase64(base64),
              let data = decodedBoundedData(base64) else {
            return nil
        }
        let mediaType = normalizedImageMediaType(preferredMediaType)
            ?? detectedMediaType(data)
            ?? "image/jpeg"
        return "data:\(mediaType);base64,\(base64)"
    }

    static func url(from rawValue: String?) -> URL? {
        guard let parsed = parsed(rawValue),
              parsed.data.count <= maximumDecodedByteCount else {
            return nil
        }
        return URL(string: parsed.normalizedRawValue)
    }

    static func decodedData(from url: URL) -> Data? {
        parsed(url.absoluteString)?.data
    }

    static func mediaType(fromDataURL rawValue: String) -> String? {
        parsed(rawValue)?.mediaType
    }

    private static func parsed(
        _ rawValue: String?
    ) -> (normalizedRawValue: String, mediaType: String, data: Data)? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isNotEmpty,
              let comma = rawValue.firstIndex(of: ",") else {
            return nil
        }
        let header = String(rawValue[..<comma])
        let headerComponents = header.split(separator: ";", omittingEmptySubsequences: false)
        guard headerComponents.count == 2,
              headerComponents[1].lowercased() == "base64",
              headerComponents[0].lowercased().hasPrefix("data:image/") else {
            return nil
        }
        let rawMediaType = String(headerComponents[0].dropFirst("data:".count))
        guard let mediaType = normalizedImageMediaType(rawMediaType) else {
            return nil
        }
        let payload = String(rawValue[rawValue.index(after: comma)...])
        guard let base64 = normalizedBase64(payload),
              let data = decodedBoundedData(base64) else {
            return nil
        }
        return (
            normalizedRawValue: "data:\(mediaType);base64,\(base64)",
            mediaType: mediaType,
            data: data
        )
    }

    private static func normalizedBase64(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        let maximumEncodedByteCount = ((maximumDecodedByteCount + 2) / 3) * 4
        guard value.utf8.count <= maximumEncodedByteCount else {
            return nil
        }
        return value
    }

    private static func decodedBoundedData(_ base64: String) -> Data? {
        guard let data = Data(base64Encoded: base64),
              !data.isEmpty,
              data.count <= maximumDecodedByteCount else {
            return nil
        }
        return data
    }

    private static func normalizedImageMediaType(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              value.hasPrefix("image/"),
              value.count > "image/".count else {
            return nil
        }
        let subtype = value.dropFirst("image/".count)
        guard subtype.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                ".+-".unicodeScalars.contains(scalar)
        }) else {
            return nil
        }
        return value
    }

    private static func detectedMediaType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.starts(with: Array("GIF87a".utf8)) ||
            bytes.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }
}

class MessageMediaAttachmentStorageItem: Object {
    
    public static func genPrimary(jid: String, owner: String, url: String, messagePrimary: String) -> String {
        return [jid, owner, url, messagePrimary].prp()
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    override static func indexedProperties() -> [String] {
        return ["jid", "owner", "date", "conversationType_", "kind_"]
    }
    
    enum Kind: String {
        case none = ""
        case image = "image"
        case file = "file"
        case video = "video"
        case voice = "voice"
        case audio = "audio"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ""
    @objc dynamic var messagePrimary: String = ""
    @objc dynamic var archiveId: String = ""
    @objc dynamic var kind_ = ""
    @objc dynamic var filename: String = ""
    @objc dynamic var isEncrypted: Bool = false
    @objc dynamic var outgoing: Bool = false
    @objc dynamic var date: Date = Date()
    @objc dynamic var url_: String = ""
    @objc dynamic var isDownloaded: Bool = false
    @objc dynamic var verySmallThumb: String? = nil
    @objc dynamic var sizeBytes: Int = 0
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
    
    @objc dynamic var metadata_: String = ""
    
    var metadata: [String: Any]? {
        get {
            if self.isInvalidated { return nil }
            if let data = metadata_.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("MessageMediaAttachmentStorageItem: \(#function). \(error.localizedDescription)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    metadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("MessageMediaAttachmentStorageItem: \(#function). \(error.localizedDescription)")
                }
            } else {
                metadata_ = ""
            }
        }
    }
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var kind: Kind {
        get {
            return Kind(rawValue: self.kind_) ?? .none
        } set {
            self.kind_ = newValue.rawValue
        }
    }
    
    var url: URL? {
        get {
            return URL(string: self.url_)
        } set {
            self.url_ = newValue?.absoluteString ?? ""
        }
    }
    
    func subtitle() -> String {
        switch kind {
            case .file:
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useKB, .useMB]
                formatter.countStyle = .binary
                return formatter
                    .string(fromByteCount: Int64(self.sizeBytes))
                    .replacingOccurrences(of: ",", with: ".")
                    .replacingOccurrences(of: "MB", with: "MiB")
                    .replacingOccurrences(of: "KB", with: "KiB")
            case .video:
                break
            default:
                break
//                let formatter = For
        }
        return ""
    }
    
    var thumb: UIImage? {
        get {
            guard let b64 = self.verySmallThumb,
                  let data = Data(base64Encoded: b64),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image
        } set {
            self.verySmallThumb = newValue?.jpegData(compressionQuality: 0.5)?.base64EncodedString()
        }
    }

    var timelineThumbnailDataURLRaw: String? {
        MessageMediaThumbnailDataURLPolicy.dataURLString(
            base64: verySmallThumb,
            preferredMediaType: metadata?["thumbnail-media-type"] as? String
        )
    }
}
