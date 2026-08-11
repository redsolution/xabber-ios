//
//  CommonContactsMetadataManager.swift
//  xabber
//
//  Created by Игорь Болдин on 23.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import CryptoKit
import ImageIO
import Intents
import UIKit

struct PushNotificationAvatarIdentity: Equatable, Hashable {
    enum Scope: String {
        case contact
        case groupParticipant
    }

    let scope: Scope
    let owner: String
    let entityJid: String
    let participantId: String?

    init(owner: String, contactJid: String) {
        scope = .contact
        self.owner = Self.normalizedBareJid(owner)
        entityJid = Self.normalizedBareJid(contactJid)
        participantId = nil
    }

    init(owner: String, groupchat: String, participantId: String) {
        scope = .groupParticipant
        self.owner = Self.normalizedBareJid(owner)
        entityJid = Self.normalizedBareJid(groupchat)
        let trimmedParticipant = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.participantId = trimmedParticipant.contains("@")
            ? Self.normalizedBareJid(trimmedParticipant)
            : trimmedParticipant
    }

    fileprivate var canonicalValue: String {
        [
            "v1",
            scope.rawValue,
            owner,
            entityJid,
            participantId ?? ""
        ].joined(separator: "\u{0}")
    }

    fileprivate static func normalizedBareJid(_ value: String) -> String {
        let bare = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A stable sender handle for communication notifications. Group
    /// participants deliberately use an opaque value so they can never be
    /// interpreted as entries that should be added to the system address book.
    var notificationSenderHandle: String {
        switch scope {
        case .contact:
            return entityJid
        case .groupParticipant:
            let digest = SHA256.hash(data: Data(canonicalValue.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "xabber-group-participant:\(digest)"
        }
    }
}

enum PushAvatarSnapshotSourceScope: Hashable {
    case managed
    case unmanagedTransient
}

final class PushAvatarSnapshotGenerationGate {
    struct Token: Hashable {
        let identity: PushNotificationAvatarIdentity
        let sourceKey: String
        let metadataRevision: String?
        let sourceScope: PushAvatarSnapshotSourceScope
        fileprivate let generation: UInt64
        fileprivate let ownerEpoch: UInt64
        fileprivate let globalEpoch: UInt64
    }

    private struct SourceDescriptor: Equatable {
        let sourceKey: String
        let metadataRevision: String?
        let sourceScope: PushAvatarSnapshotSourceScope
    }

    static let shared = PushAvatarSnapshotGenerationGate()

    private let lock = NSLock()
    private var generations: [PushNotificationAvatarIdentity: UInt64] = [:]
    private var sourceDescriptors: [PushNotificationAvatarIdentity: SourceDescriptor] = [:]
    private var ownerEpochs: [String: UInt64] = [:]
    private var globalEpoch: UInt64 = 0

    func begin(
        identity: PushNotificationAvatarIdentity,
        sourceKey: String,
        metadataRevision: String? = nil,
        sourceScope: PushAvatarSnapshotSourceScope = .managed
    ) -> Token {
        lock.lock()
        defer { lock.unlock() }
        let sourceDescriptor = SourceDescriptor(
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            sourceScope: sourceScope
        )
        let generation: UInt64
        if sourceDescriptors[identity] == sourceDescriptor,
           let currentGeneration = generations[identity] {
            generation = currentGeneration
        } else {
            generation = (generations[identity] ?? 0) &+ 1
            generations[identity] = generation
            sourceDescriptors[identity] = sourceDescriptor
        }
        return Token(
            identity: identity,
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            sourceScope: sourceScope,
            generation: generation,
            ownerEpoch: ownerEpochs[identity.owner] ?? 0,
            globalEpoch: globalEpoch
        )
    }

    func invalidate(identity: PushNotificationAvatarIdentity) {
        invalidate(identities: [identity])
    }

    func invalidate(identities: [PushNotificationAvatarIdentity]) {
        let identities = Set(identities)
        guard !identities.isEmpty else { return }
        lock.lock()
        identities.forEach { identity in
            generations[identity] = (generations[identity] ?? 0) &+ 1
        }
        lock.unlock()
    }

    func invalidate(owner: String) {
        let normalizedOwner = PushNotificationAvatarIdentity.normalizedBareJid(owner)
        lock.lock()
        ownerEpochs[normalizedOwner] = (ownerEpochs[normalizedOwner] ?? 0) &+ 1
        let ownerIdentities = generations.keys.filter { $0.owner == normalizedOwner }
        ownerIdentities.forEach {
            generations.removeValue(forKey: $0)
            sourceDescriptors.removeValue(forKey: $0)
        }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        globalEpoch &+= 1
        generations.removeAll(keepingCapacity: false)
        sourceDescriptors.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(token)
    }

    private func isCurrentLocked(_ token: Token) -> Bool {
        generations[token.identity] == token.generation
            && (ownerEpochs[token.identity.owner] ?? 0) == token.ownerEpoch
            && globalEpoch == token.globalEpoch
    }
}

final class PushNotificationAvatarStore {
    enum StoreError: Error, Equatable {
        case unavailableContainer
        case invalidImage
        case imageTooLarge
    }

    static let shared = PushNotificationAvatarStore(rootURL: defaultRootURL())

    private static let schemaVersion = "v1"
    private static let manifestSchemaVersion = 1
    private let rootURL: URL?
    private let fileManager: FileManager
    private let maximumFileSize: Int
    private let maximumPixelDimension: Int

    init(
        rootURL: URL?,
        fileManager: FileManager = .default,
        maximumFileSize: Int = 2 * 1024 * 1024,
        maximumPixelDimension: Int = 4_096
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maximumFileSize = maximumFileSize
        self.maximumPixelDimension = maximumPixelDimension
    }

    func store(imageData: Data, for identity: PushNotificationAvatarIdentity) throws {
        try storePending(imageData: imageData, for: identity)
        clearDeletionMarkers(for: identity)
    }

    func storePending(imageData: Data, for identity: PushNotificationAvatarIdentity) throws {
        let destination = try prepareDestination(for: identity, imageData: imageData)
        try? fileManager.removeItem(at: manifestURL(for: identity))
        try imageData.write(to: destination, options: .atomic)
        applyProtectedCacheAttributes(to: destination)
    }

    func store(
        imageData: Data,
        for identity: PushNotificationAvatarIdentity,
        sourceKey: String
    ) throws {
        try storePending(
            imageData: imageData,
            for: identity,
            sourceKey: sourceKey
        )
        clearDeletionMarkers(for: identity)
    }

    func storePending(
        imageData: Data,
        for identity: PushNotificationAvatarIdentity,
        sourceKey: String
    ) throws {
        let destination = try prepareDestination(for: identity, imageData: imageData)
        let manifestDestination = manifestURL(for: identity)
        try? fileManager.removeItem(at: manifestDestination)
        try imageData.write(to: destination, options: .atomic)
        applyProtectedCacheAttributes(to: destination)

        let manifest = Manifest(
            schemaVersion: Self.manifestSchemaVersion,
            sourceKeyHash: Self.digest(sourceKey),
            imageByteCount: imageData.count,
            writtenAt: Date().timeIntervalSince1970
        )
        try JSONEncoder().encode(manifest).write(
            to: manifestDestination,
            options: .atomic
        )
        applyProtectedCacheAttributes(to: manifestDestination)
    }

    func hasValidSnapshot(
        for identity: PushNotificationAvatarIdentity,
        sourceKey: String
    ) -> Bool {
        guard rootURL != nil,
              let manifestData = try? Data(contentsOf: manifestURL(for: identity)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.schemaVersion == Self.manifestSchemaVersion,
              manifest.sourceKeyHash == Self.digest(sourceKey),
              let imageData = imageData(for: identity),
              imageData.count == manifest.imageByteCount else {
            return false
        }
        return true
    }

    private func prepareDestination(
        for identity: PushNotificationAvatarIdentity,
        imageData: Data
    ) throws -> URL {
        guard imageData.count <= maximumFileSize else {
            throw StoreError.imageTooLarge
        }
        guard isValidImage(imageData) else {
            throw StoreError.invalidImage
        }
        guard rootURL != nil else {
            throw StoreError.unavailableContainer
        }

        let destination = fileURL(for: identity)
        if isOwnerMarkedDeleted(identity.owner) {
            try? fileManager.removeItem(at: destination.deletingLastPathComponent())
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        return destination
    }

    func store(image: UIImage, for identity: PushNotificationAvatarIdentity) throws {
        guard let data = Self.snapshotData(from: image) else {
            throw StoreError.invalidImage
        }
        try store(imageData: data, for: identity)
    }

    func store(
        image: UIImage,
        for identity: PushNotificationAvatarIdentity,
        sourceKey: String
    ) throws {
        guard let data = Self.snapshotData(from: image) else {
            throw StoreError.invalidImage
        }
        try store(imageData: data, for: identity, sourceKey: sourceKey)
    }

    func imageData(for identity: PushNotificationAvatarIdentity) -> Data? {
        guard rootURL != nil,
              !isMarkedDeleted(identity) else {
            return nil
        }
        let url = fileURL(for: identity)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              isValidImage(data) else {
            return nil
        }
        return data
    }

    func fileURL(for identity: PushNotificationAvatarIdentity) -> URL {
        let unavailableRoot = fileManager.temporaryDirectory
            .appendingPathComponent("xabber-unavailable-push-avatars", isDirectory: true)
        return (rootURL ?? unavailableRoot)
            .appendingPathComponent(Self.ownerComponent(identity.owner), isDirectory: true)
            .appendingPathComponent("\(Self.digest(identity.canonicalValue)).avatar")
    }

    func remove(for identity: PushNotificationAvatarIdentity) {
        guard rootURL != nil else { return }
        try? fileManager.removeItem(at: fileURL(for: identity))
        try? fileManager.removeItem(at: manifestURL(for: identity))
    }

    func markDeleted(identity: PushNotificationAvatarIdentity) throws {
        try writeDeletionMarker(to: identityDeletionMarkerURL(for: identity))
    }

    func markDeleted(owner: String) throws {
        try writeDeletionMarker(to: ownerDeletionMarkerURL(for: owner))
    }

    func clearDeletionMarkers(for identity: PushNotificationAvatarIdentity) {
        guard rootURL != nil else { return }
        try? fileManager.removeItem(at: identityDeletionMarkerURL(for: identity))
        try? fileManager.removeItem(at: ownerDeletionMarkerURL(for: identity.owner))
    }

    func removeAll(owner: String) {
        guard let rootURL else { return }
        let ownerDirectory = rootURL.appendingPathComponent(
            Self.ownerComponent(PushNotificationAvatarIdentity.normalizedBareJid(owner)),
            isDirectory: true
        )
        try? fileManager.removeItem(at: ownerDirectory)
    }

    func removeAll() {
        guard let rootURL else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func isValidImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumFileSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension else {
            return false
        }
        return true
    }

    private static func defaultRootURL() -> URL? {
        FileManager.default
            .containerURL(
                forSecurityApplicationGroupIdentifier: CredentialsManager.uniqueAccessGroup()
            )?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PushAvatars", isDirectory: true)
            .appendingPathComponent(schemaVersion, isDirectory: true)
    }

    private static func ownerComponent(_ owner: String) -> String {
        "owner-\(digest(owner))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func snapshotData(from image: UIImage) -> Data? {
        let maximumSide: CGFloat = 256
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(1, maximumSide / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return normalized.pngData()
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let sourceKeyHash: String
        let imageByteCount: Int
        let writtenAt: TimeInterval
    }

    private func manifestURL(for identity: PushNotificationAvatarIdentity) -> URL {
        fileURL(for: identity).appendingPathExtension("json")
    }

    private func isMarkedDeleted(_ identity: PushNotificationAvatarIdentity) -> Bool {
        isOwnerMarkedDeleted(identity.owner)
            || fileManager.fileExists(atPath: identityDeletionMarkerURL(for: identity).path)
    }

    private func isOwnerMarkedDeleted(_ owner: String) -> Bool {
        fileManager.fileExists(atPath: ownerDeletionMarkerURL(for: owner).path)
    }

    private func deletionMarkersRootURL() -> URL {
        let unavailableRoot = fileManager.temporaryDirectory
            .appendingPathComponent("xabber-unavailable-push-avatar-deletions", isDirectory: true)
        return (rootURL ?? unavailableRoot)
            .appendingPathComponent(".deletions", isDirectory: true)
    }

    private func ownerDeletionMarkerURL(for owner: String) -> URL {
        deletionMarkersRootURL()
            .appendingPathComponent(
                Self.ownerComponent(PushNotificationAvatarIdentity.normalizedBareJid(owner)),
                isDirectory: true
            )
            .appendingPathComponent("owner.tombstone")
    }

    private func identityDeletionMarkerURL(
        for identity: PushNotificationAvatarIdentity
    ) -> URL {
        deletionMarkersRootURL()
            .appendingPathComponent(Self.ownerComponent(identity.owner), isDirectory: true)
            .appendingPathComponent("\(Self.digest(identity.canonicalValue)).tombstone")
    }

    private func writeDeletionMarker(to url: URL) throws {
        guard rootURL != nil else { throw StoreError.unavailableContainer }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data([1]).write(to: url, options: .atomic)
        applyProtectedCacheAttributes(to: url)
    }

    private func applyProtectedCacheAttributes(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}

enum PushNotificationInitialsRenderer {
    private static let materialLightColors: [UIColor] = [
        UIColor(red: 0.94, green: 0.62, blue: 0.62, alpha: 1),
        UIColor(red: 0.80, green: 0.58, blue: 0.86, alpha: 1),
        UIColor(red: 0.62, green: 0.66, blue: 0.91, alpha: 1),
        UIColor(red: 0.50, green: 0.76, blue: 0.96, alpha: 1),
        UIColor(red: 0.50, green: 0.80, blue: 0.77, alpha: 1),
        UIColor(red: 0.65, green: 0.84, blue: 0.65, alpha: 1),
        UIColor(red: 0.87, green: 0.88, blue: 0.54, alpha: 1),
        UIColor(red: 1.00, green: 0.80, blue: 0.50, alpha: 1),
        UIColor(red: 0.74, green: 0.67, blue: 0.64, alpha: 1),
        UIColor(red: 0.69, green: 0.75, blue: 0.77, alpha: 1)
    ]

    static func initials(displayName: String?, jid: String) -> String {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackNode = PushNotificationAvatarIdentity.normalizedBareJid(jid)
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let source = trimmedName.isEmpty ? fallbackNode : trimmedName
        let words = source.split(whereSeparator: { $0.isWhitespace })
        guard let firstWord = words.first,
              let first = firstWord.first else {
            return "?"
        }
        if words.count > 1,
           let lastWord = words.last,
           let last = lastWord.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        return String(first).uppercased()
    }

    static func imageData(displayName: String?, jid: String, size: CGFloat = 128) -> Data {
        let size = max(1, size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: format
        ).pngData { context in
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            backgroundColor(for: jid).setFill()
            context.cgContext.fillEllipse(in: bounds)

            let text = initials(displayName: displayName, jid: jid)
            let font = UIFont.systemFont(ofSize: size * 0.38, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(white: 0.08, alpha: 1)
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let origin = CGPoint(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2
            )
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    private static func backgroundColor(for jid: String) -> UIColor {
        let bareJid = PushNotificationAvatarIdentity.normalizedBareJid(jid)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bareJid.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return materialLightColors[Int(hash % UInt64(materialLightColors.count))]
    }
}

extension PushNotificationRoutePayload {
    var senderAvatarIdentity: PushNotificationAvatarIdentity? {
        if let groupchat = groupchat ?? (conversationType == "group" ? routeJid : nil) {
            guard let participant = senderUserId ?? senderJid,
                  !participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: groupchat,
                participantId: participant
            )
        }

        guard let contactJid = senderJid ?? inviterJid ?? routeJid else {
            return nil
        }
        return PushNotificationAvatarIdentity(owner: owner, contactJid: contactJid)
    }

    /// Ordered cache identities used to resolve the avatar. A group-specific
    /// snapshot wins, with the regular roster snapshot as a safe fallback.
    var senderAvatarLookupIdentities: [PushNotificationAvatarIdentity] {
        var identities: [PushNotificationAvatarIdentity] = []
        if let senderAvatarIdentity {
            identities.append(senderAvatarIdentity)
        }
        if let senderJid = senderJid ?? inviterJid {
            let contactIdentity = PushNotificationAvatarIdentity(
                owner: owner,
                contactJid: senderJid
            )
            if !identities.contains(contactIdentity) {
                identities.append(contactIdentity)
            }
        }
        return identities
    }

    func stableSenderHandle(fallback: String) -> String {
        if let groupchat = groupchat ?? (conversationType == "group" ? routeJid : nil) {
            let participant = senderUserId
                ?? senderJid
                ?? senderNickname
                ?? fallback
            let trimmedParticipant = participant.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmedParticipant.isEmpty {
                return PushNotificationAvatarIdentity(
                    owner: owner,
                    groupchat: groupchat,
                    participantId: trimmedParticipant
                ).notificationSenderHandle
            }
        }
        let candidate = senderJid ?? inviterJid ?? routeJid ?? fallback
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

class CommonContactsMetadataManager: NSObject {
    open class var shared: CommonContactsMetadataManager {
        struct CommonContactsMetadataManagerSingleton {
            static let instance = CommonContactsMetadataManager()
        }
        return CommonContactsMetadataManagerSingleton.instance
    }
    
    struct Metadata {
        let jid: String
        let owner: String
        let username: String?
        let avatarUrl: String?
    }
    
    let key: String = "contacts_metadata"
    
    public func clear(for owner: String) {
        PushAvatarSnapshotGenerationGate.shared.invalidate(owner: owner)
        try? PushNotificationAvatarStore.shared.markDeleted(owner: owner)
        PushNotificationAvatarStore.shared.removeAll(owner: owner)
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            return
        }
        let legacyPrefix = [key, owner].prp() + "_"
        userDefaults.dictionaryRepresentation().keys.forEach {
            let metadataOwner = userDefaults.dictionary(forKey: $0)?["owner"] as? String
            if metadataOwner?.caseInsensitiveCompare(owner) == .orderedSame || $0.hasPrefix(legacyPrefix) {
                userDefaults.removeObject(forKey: $0)
            }
        }
    }

    public func remove(owner: String, jid: String) {
        let identity = PushNotificationAvatarIdentity(owner: owner, contactJid: jid)
        PushAvatarSnapshotGenerationGate.shared.invalidate(identity: identity)
        try? PushNotificationAvatarStore.shared.markDeleted(identity: identity)
        PushNotificationAvatarStore.shared.remove(for: identity)
        guard let userDefaults = UserDefaults(
            suiteName: CredentialsManager.uniqueAccessGroup()
        ) else {
            return
        }
        userDefaults.removeObject(forKey: [key, owner, jid].prp())
        userDefaults.dictionaryRepresentation().forEach { metadataKey, value in
            guard let metadata = value as? [String: Any],
                  let metadataOwner = metadata["owner"] as? String,
                  let metadataJid = metadata["jid"] as? String,
                  metadataOwner.caseInsensitiveCompare(owner) == .orderedSame,
                  metadataJid.caseInsensitiveCompare(jid) == .orderedSame else {
                return
            }
            userDefaults.removeObject(forKey: metadataKey)
        }
    }
    
    public func update(owner: String, jid: String, username: String?, avatarUrl: String?) {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            return
        }
        let metadataKey = [key, owner, jid].prp()
        var metadata: [String: Any] = userDefaults.dictionary(forKey: metadataKey) ?? [:]
        let storedAvatarUrl = normalizedAvatarUrl(metadata["avatarUrl"] as? String)
        let newAvatarUrl = normalizedAvatarUrl(avatarUrl)
        if storedAvatarUrl != newAvatarUrl {
            let identity = PushNotificationAvatarIdentity(owner: owner, contactJid: jid)
            PushAvatarSnapshotGenerationGate.shared.invalidate(identity: identity)
            try? PushNotificationAvatarStore.shared.markDeleted(identity: identity)
            PushNotificationAvatarStore.shared.remove(for: identity)
        }
        metadata["owner"] = owner
        metadata["jid"] = jid
        if let username = username {
            metadata["username"] = username
        }
        if let newAvatarUrl {
            metadata["avatarUrl"] = newAvatarUrl
        } else {
            metadata.removeValue(forKey: "avatarUrl")
        }
        userDefaults.setValue(metadata, forKey: metadataKey)
    }

    private func normalizedAvatarUrl(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
    
    public func getItem(owner: String, jid: String) -> Metadata {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            return Metadata(jid: jid, owner: owner, username: nil, avatarUrl: nil)
        }
        if let metadata: [String: Any] = userDefaults.dictionary(forKey: ["contacts_metadata", owner, jid].prp()) {
            let avatarUrl = (metadata["avatarUrl"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Metadata(
                jid: jid,
                owner: owner,
                username: metadata["username"] as? String,
                avatarUrl: avatarUrl?.isEmpty == false ? avatarUrl : nil
            )
        }
        return Metadata(jid: jid, owner: owner, username: nil, avatarUrl: nil)
    }
}
