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
import CoreLocation
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import XMPPFramework

struct ChatDatasourceSnapshot {
    static let empty = ChatDatasourceSnapshot(
        items: [],
        primaryIndex: [:],
        archivedIdIndex: [:],
        hasDuplicatePrimaries: false,
        hasDuplicateArchivedIds: false
    )

    let items: [ChatViewController.Datasource]
    let primaryIndex: [String: Int]
    let archivedIdIndex: [String: Int]
    let hasDuplicatePrimaries: Bool
    let hasDuplicateArchivedIds: Bool

    var hasDuplicateKeys: Bool {
        hasDuplicatePrimaries || hasDuplicateArchivedIds
    }

    init(items: [ChatViewController.Datasource]) {
        self.items = items
        var primaryIndex: [String: Int] = [:]
        var archivedIdIndex: [String: Int] = [:]
        var duplicatePrimaryCount = 0
        var duplicateArchivedIdCount = 0

        for (offset, item) in items.enumerated() {
            if primaryIndex.updateValue(offset, forKey: item.primary) != nil {
                duplicatePrimaryCount += 1
            }

            guard let archivedId = item.archivedId, archivedId.isNotEmpty else { continue }

            if archivedIdIndex.updateValue(offset, forKey: archivedId) != nil {
                duplicateArchivedIdCount += 1
            }
        }

        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = duplicatePrimaryCount > 0
        self.hasDuplicateArchivedIds = duplicateArchivedIdCount > 0

        if duplicatePrimaryCount > 0 || duplicateArchivedIdCount > 0 {
            DDLogWarn(
                "ChatDatasourceSnapshot detected duplicate keys. primary duplicates: \(duplicatePrimaryCount); archivedId duplicates: \(duplicateArchivedIdCount)"
            )
        }
    }

    init(
        items: [ChatViewController.Datasource],
        primaryIndex: [String: Int],
        archivedIdIndex: [String: Int],
        hasDuplicatePrimaries: Bool,
        hasDuplicateArchivedIds: Bool
    ) {
        self.items = items
        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = hasDuplicatePrimaries
        self.hasDuplicateArchivedIds = hasDuplicateArchivedIds
    }
}

struct SavedMessageAuthorProfile {
    let jid: String
    let displayName: String
    let avatarUrl: String?
}

struct SavedMessageDisplayPolicy {
    struct Presentation {
        let isSavedMessage: Bool
        let isSavedForward: Bool
        let isDirectSavedNote: Bool
        let displayAuthorJid: String
        let displayAuthorName: String
        let displayAvatarSource: String?
        let displayOutgoing: Bool
        let visibleBody: String
        let visibleReferences: [MessageReferenceStorageItem]
        let visibleForwards: [MessageForwardsInlineStorageItem]
        let visibleDate: Date
        let groupchatAuthorRole: String
        let groupchatAuthorId: String
        let groupchatAuthorNickname: String
        let groupchatAuthorBadge: String
        let isDeleted: Bool
        let deleteState: MessageStorageItem.DeleteState
        let authorColorKey: String
    }

    private static let savedForwardCardSuffix = "_saved-forwarded"

    static func presentation(
        for item: MessageStorageItem,
        currentUserJid: String,
        currentUserName: String? = nil,
        authorProfileLookup: ((String, String) -> SavedMessageAuthorProfile?)? = nil
    ) -> Presentation {
        let resolvedAuthorProfile = authorProfileLookup ?? defaultAuthorProfile
        let isSavedMessage = item.conversationType == .saved
        let isSavedForward = isSavedMessage && isSyntheticSavedForwardCard(item.groupchatCard)
        let isDeleted = item.isDeleted || item.deleteState == .autoDeleted
        let references = isDeleted ? [] : item.references.toArray()
        let visibleForwards = isDeleted ? [] : item.inlineForwards.toArray()
        let directAuthorName = nonEmpty(currentUserName) ?? currentUserJid

        guard isSavedMessage else {
            let authorJid = item.outgoing ? currentUserJid : item.opponent
            let fallbackName = item.outgoing ? directAuthorName : authorJid
            let groupName = MessageStorageItem.getGroupchatAuthorNickname(references)
            let groupJid = MessageStorageItem.groupchatMessageAuthorJid(references)
            let groupId = MessageStorageItem.groupchatMessageAuthorId(references)
            return Presentation(
                isSavedMessage: false,
                isSavedForward: false,
                isDirectSavedNote: false,
                displayAuthorJid: nonEmpty(groupJid) ?? authorJid,
                displayAuthorName: nonEmpty(groupName) ?? fallbackName,
                displayAvatarSource: nonEmpty(item.groupchatCard?.avatarURI) ?? avatarSource(from: references),
                displayOutgoing: item.outgoing,
                visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
                visibleReferences: references,
                visibleForwards: visibleForwards,
                visibleDate: item.date,
                groupchatAuthorRole: item.groupchatMetadata?["role"] as? String ?? "member",
                groupchatAuthorId: nonEmpty(item.groupchatAuthorId) ?? nonEmpty(groupId) ?? "",
                groupchatAuthorNickname: nonEmpty(item.groupchatAuthorNickname) ?? nonEmpty(groupName) ?? "",
                groupchatAuthorBadge: nonEmpty(item.groupchatAuthorBadge) ?? "",
                isDeleted: isDeleted,
                deleteState: item.deleteState,
                authorColorKey: nonEmpty(groupId) ?? nonEmpty(groupJid) ?? authorJid
            )
        }

        if isSavedForward {
            let groupName = MessageStorageItem.getGroupchatAuthorNickname(references)
            let groupJid = MessageStorageItem.groupchatMessageAuthorJid(references)
            let groupId = MessageStorageItem.groupchatMessageAuthorId(references)
            let authorJid = nonEmpty(groupJid)
                ?? nonEmpty(item.groupchatCard?.jid)
                ?? nonEmpty(item.groupchatCard?.nickname)
                ?? currentUserJid
            let authorProfile = resolvedAuthorProfile(authorJid, currentUserJid)
            let groupDisplayName = displayNameCandidate(groupName, authorJid: authorJid)
            let cardDisplayName = displayNameCandidate(item.groupchatCard?.nickname, authorJid: authorJid)
            let authorName = groupDisplayName
                ?? authorProfile?.displayName
                ?? cardDisplayName
                ?? preparedJid(authorJid)
            let authorRole = nonEmpty(item.groupchatMetadata?["role"] as? String)
                ?? nonEmpty(item.groupchatCard?.role.rawValue)
                ?? "member"
            let authorAvatarSource = avatarSource(from: references)
                ?? authorProfile?.avatarUrl
                ?? nonEmpty(item.groupchatCard?.avatarURI)
            return Presentation(
                isSavedMessage: true,
                isSavedForward: true,
                isDirectSavedNote: false,
                displayAuthorJid: authorProfile?.jid ?? authorJid,
                displayAuthorName: authorName,
                displayAvatarSource: authorAvatarSource,
                displayOutgoing: isSameBareJid(authorJid, currentUserJid),
                visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
                visibleReferences: references,
                visibleForwards: visibleForwards,
                visibleDate: item.sentDate,
                groupchatAuthorRole: authorRole,
                groupchatAuthorId: nonEmpty(groupId) ?? nonEmpty(item.groupchatCard?.userId) ?? "",
                groupchatAuthorNickname: authorName,
                groupchatAuthorBadge: nonEmpty(item.groupchatAuthorBadge) ?? "",
                isDeleted: isDeleted,
                deleteState: item.deleteState,
                authorColorKey: nonEmpty(groupId) ?? nonEmpty(groupJid) ?? authorJid
            )
        }

        return Presentation(
            isSavedMessage: true,
            isSavedForward: false,
            isDirectSavedNote: true,
            displayAuthorJid: currentUserJid,
            displayAuthorName: directAuthorName,
            displayAvatarSource: nil,
            displayOutgoing: true,
            visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
            visibleReferences: references,
            visibleForwards: visibleForwards,
            visibleDate: item.date,
            groupchatAuthorRole: "member",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isDeleted: isDeleted,
            deleteState: item.deleteState,
            authorColorKey: currentUserJid
        )
    }

    static func attributedAuthor(for presentation: Presentation) -> NSAttributedString? {
        guard presentation.displayAuthorName.isNotEmpty else { return nil }
        return NSAttributedString(string: presentation.displayAuthorName, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: ChatViewController.getUsernamePalette(for: presentation.authorColorKey).tint500
        ])
    }

    static func attributedBody(
        for presentation: Presentation,
        attributes: [NSAttributedString.Key: Any],
        searchedText: String? = nil,
        searchedTextColor: UIColor? = nil
    ) -> NSAttributedString {
        let body = presentation.visibleBody
        let string = NSMutableAttributedString(string: body.trimmingCharacters(in: .newlines))
        if string.length > 0 {
            string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5
        paragraph.allowsDefaultTighteningForTruncation = true

        for reference in presentation.visibleReferences where !reference.isLocallyHiddenByReport {
            if reference.end <= reference.begin { continue }
            if reference.end > body.count { continue }
            switch reference.kind {
            case .markup:
                applyMarkup(reference, to: string)
            case .mention:
                string.addAttribute(.font, value: UIFont.systemFont(ofSize: 14, weight: .semibold), range: reference.range)
                string.addAttribute(.foregroundColor, value: AccountColorManager.shared.palette(for: presentation.displayAuthorJid).tint700, range: reference.range)
                if let url = reference.metadata?["uri"] as? String ?? reference.url {
                    string.addAttribute(.link, value: url, range: reference.range)
                }
            default:
                break
            }
        }

        if let searchedText = searchedText, searchedText.isNotEmpty {
            let range = (string.string as NSString).range(of: searchedText, options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound {
                string.addAttribute(.backgroundColor, value: searchedTextColor ?? MDCPalette.blue.tint200, range: range)
            }
        }
        if string.length > 0 {
            string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        }
        if string.string.starts(with: "\n") {
            string.deleteCharacters(in: NSRange(0..<"\n".count))
        }
        return string
    }

    private static func applyMarkup(_ reference: MessageReferenceStorageItem, to string: NSMutableAttributedString) {
        guard let styles = reference.metadata?["styles"] as? [String] else { return }
        for style in styles {
            if style == "bold" {
                string.addAttribute(.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).bold(), range: reference.range)
            }
            if style == "italic" {
                if styles.contains("bold") {
                    string.addAttribute(.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).boldItalic(), range: reference.range)
                } else {
                    string.addAttribute(.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).italic(), range: reference.range)
                }
            }
            if style == "underline" {
                string.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: reference.range)
            }
            if style == "strike" {
                string.addAttribute(.strikethroughStyle, value: 1, range: reference.range)
            }
            if style == "uri",
               let url = reference.metadata?["uri"] as? String {
                string.addAttribute(.link, value: url, range: reference.range)
            }
        }
    }

    private static func isSyntheticSavedForwardCard(_ card: GroupchatUserStorageItem?) -> Bool {
        card?.primary.hasSuffix(savedForwardCardSuffix) == true
    }

    private static func avatarSource(from references: [MessageReferenceStorageItem]) -> String? {
        nonEmpty(references.first(where: { $0.kind == .groupchat })?.metadata?["avatar_uri"] as? String)
    }

    private static func defaultAuthorProfile(jid: String, owner: String) -> SavedMessageAuthorProfile? {
        let bareJid = normalizedBareJid(jid)
        guard bareJid.isNotEmpty,
              let realm = try? WRealm.safe(),
              let roster = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: bareJid, owner: owner)
              ) else {
            return nil
        }

        return SavedMessageAuthorProfile(
            jid: bareJid,
            displayName: roster.displayName,
            avatarUrl: nonEmpty(roster.avatarMinUrl) ?? nonEmpty(roster.avatarMaxUrl) ?? nonEmpty(roster.oldschoolAvatarKey)
        )
    }

    private static func displayNameCandidate(_ value: String?, authorJid: String) -> String? {
        guard let value = nonEmpty(value),
              !isJidLikeDisplayName(value, authorJid: authorJid) else {
            return nil
        }
        return value
    }

    private static func isJidLikeDisplayName(_ value: String, authorJid: String) -> Bool {
        if isSameBareJid(value, authorJid) {
            return true
        }
        return value.contains("@") && XMPPJID(string: value) != nil
    }

    private static func preparedJid(_ value: String) -> String {
        JidManager.shared.prepareJid(jid: value)
    }

    private static func isSameBareJid(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBareJid(lhs).caseInsensitiveCompare(normalizedBareJid(rhs)) == .orderedSame
    }

    private static func normalizedBareJid(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return XMPPJID(string: trimmed)?.bare ?? trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }
}

struct ChatDisplayModelCacheContext: Hashable {
    let searchText: String?
    let localeIdentifier: String
    let contentSizeCategory: String
    let bodyFontName: String
    let bodyFontPointSize: CGFloat
    let interfaceStyleRawValue: Int

    static func current(searchText: String?, traitCollection: UITraitCollection) -> ChatDisplayModelCacheContext {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        return ChatDisplayModelCacheContext(
            searchText: searchText?.isEmpty == true ? nil : searchText,
            localeIdentifier: Locale.current.identifier,
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            bodyFontName: bodyFont.fontName,
            bodyFontPointSize: bodyFont.pointSize,
            interfaceStyleRawValue: traitCollection.userInterfaceStyle.rawValue
        )
    }
}

struct ChatDisplayModelCacheKey: Hashable {
    let messagePrimary: String
    let displayRevision: String
    let context: ChatDisplayModelCacheContext
}

struct ChatMappedReferenceAttachments {
    static let empty = ChatMappedReferenceAttachments(
        images: [],
        videos: [],
        locations: [],
        contacts: [],
        audio: [],
        files: []
    )

    let images: [ImageAttachment]
    let videos: [VideoAttachment]
    let locations: [LocationAttachment]
    let contacts: [ContactAttachment]
    let audio: [AudioAttachment]
    let files: [FileAttachment]
}

final class ChatLazyForwardDisplayModel {
    let signature: String
    private let lock = NSLock()
    private var resolvedAttachments: [MessageAttachment]?
    private var builder: (() -> [MessageAttachment])?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAttachments != nil
    }

    var attachments: [MessageAttachment] {
        lock.lock()
        if let resolvedAttachments {
            lock.unlock()
            return resolvedAttachments
        }
        guard let builder else {
            lock.unlock()
            return []
        }
        lock.unlock()

        let builtAttachments = builder()

        lock.lock()
        if let resolvedAttachments {
            lock.unlock()
            return resolvedAttachments
        }
        resolvedAttachments = builtAttachments
        self.builder = nil
        lock.unlock()
        return builtAttachments
    }

    init(signature: String, builder: @escaping () -> [MessageAttachment]) {
        self.signature = signature
        self.builder = builder
    }

    static func eager(_ attachments: [MessageAttachment], signature: String = "eager") -> ChatLazyForwardDisplayModel {
        let model = ChatLazyForwardDisplayModel(signature: signature) { attachments }
        model.resolvedAttachments = attachments
        model.builder = nil
        return model
    }
}

final class ChatCachedDisplayModel {
    let kind: MessageKind
    let mappedReferences: ChatMappedReferenceAttachments
    let lazyForwards: ChatLazyForwardDisplayModel
    let isDownloaded: Bool
    let timeMarkerText: NSAttributedString

    var forwards: [MessageAttachment] {
        lazyForwards.attachments
    }

    var bodyText: String {
        switch kind {
        case .attributedText(let text),
                .system(let text),
                .initial(let text),
                .skeleton(let text),
                .date(let text),
                .unread(let text):
            return text.string
        case .emoji(let text):
            return text
        case .sticker(let attachment):
            return attachment.primary
        case .call(let attachment):
            return attachment.primary
        }
    }

    var bodyFontPointSize: CGFloat? {
        switch kind {
        case .attributedText(let text),
                .system(let text),
                .initial(let text),
                .skeleton(let text),
                .date(let text),
                .unread(let text):
            guard text.length > 0 else { return nil }
            return (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
        case .emoji, .sticker, .call:
            return nil
        }
    }

    init(
        kind: MessageKind,
        mappedReferences: ChatMappedReferenceAttachments,
        lazyForwards: ChatLazyForwardDisplayModel,
        isDownloaded: Bool,
        timeMarkerText: NSAttributedString
    ) {
        self.kind = kind
        self.mappedReferences = mappedReferences
        self.lazyForwards = lazyForwards
        self.isDownloaded = isDownloaded
        self.timeMarkerText = timeMarkerText
    }
}

final class ChatDisplayModelCache {
    struct Statistics: Equatable {
        let hits: Int
        let misses: Int
        let stores: Int
        let evictions: Int
    }

    private let capacity: Int
    private let lock = NSLock()
    private var models: [ChatDisplayModelCacheKey: ChatCachedDisplayModel] = [:]
    private var keysByRecency: [ChatDisplayModelCacheKey] = []
    private var hitCount: Int = 0
    private var missCount: Int = 0
    private var storeCount: Int = 0
    private var evictionCount: Int = 0

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            hits: hitCount,
            misses: missCount,
            stores: storeCount,
            evictions: evictionCount
        )
    }

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func model(
        for key: ChatDisplayModelCacheKey,
        build: () -> ChatCachedDisplayModel
    ) -> ChatCachedDisplayModel {
        lock.lock()
        if let cached = models[key] {
            hitCount += 1
            markRecentlyUsed(key)
            lock.unlock()
            return cached
        }
        missCount += 1
        lock.unlock()

        let built = build()
        guard capacity > 0 else {
            return built
        }

        lock.lock()
        if let cached = models[key] {
            hitCount += 1
            markRecentlyUsed(key)
            lock.unlock()
            return cached
        }
        models[key] = built
        keysByRecency.append(key)
        storeCount += 1
        evictIfNeeded()
        lock.unlock()
        return built
    }

    func removeAll() {
        lock.lock()
        models.removeAll()
        keysByRecency.removeAll()
        lock.unlock()
    }

    private func markRecentlyUsed(_ key: ChatDisplayModelCacheKey) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private func evictIfNeeded() {
        while models.count > capacity,
              let oldest = keysByRecency.first {
            keysByRecency.removeFirst()
            if models.removeValue(forKey: oldest) != nil {
                evictionCount += 1
            }
        }
    }
}

private struct ChatDisplayModelRevisionHasher {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var value: UInt64 = ChatDisplayModelRevisionHasher.offsetBasis

    var revision: String {
        String(value, radix: 16)
    }

    mutating func combine(_ value: String?) {
        guard let value else {
            combineByte(0xff)
            return
        }
        for byte in value.utf8 {
            combineByte(byte)
        }
        combineByte(0xfe)
    }

    mutating func combine(_ value: Bool) {
        combineByte(value ? 1 : 0)
    }

    mutating func combine(_ value: Int) {
        combine(UInt64(bitPattern: Int64(value)))
    }

    mutating func combine(_ value: Double?) {
        guard let value else {
            combineByte(0xfd)
            return
        }
        combine(value.bitPattern)
    }

    mutating func combine(_ value: UInt64) {
        combineByte(UInt8(truncatingIfNeeded: value))
        combineByte(UInt8(truncatingIfNeeded: value >> 8))
        combineByte(UInt8(truncatingIfNeeded: value >> 16))
        combineByte(UInt8(truncatingIfNeeded: value >> 24))
        combineByte(UInt8(truncatingIfNeeded: value >> 32))
        combineByte(UInt8(truncatingIfNeeded: value >> 40))
        combineByte(UInt8(truncatingIfNeeded: value >> 48))
        combineByte(UInt8(truncatingIfNeeded: value >> 56))
    }

    private mutating func combineByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* ChatDisplayModelRevisionHasher.prime
    }
}

struct ChatDatasetWindow: Equatable {
    static let empty = ChatDatasetWindow(minIndex: 0, maxIndex: 0)

    let minIndex: Int
    let maxIndex: Int

    var isEmpty: Bool {
        maxIndex <= minIndex
    }

    var count: Int {
        max(0, maxIndex - minIndex)
    }
}

struct ChatTimelineBoundary: Equatable {
    let primary: String
    let archivedId: String?
    let messageId: String?
    let date: Date

    init(
        primary: String,
        archivedId: String?,
        messageId: String?,
        date: Date
    ) {
        self.primary = primary
        self.archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
        self.messageId = messageId?.isNotEmpty == true ? messageId : nil
        self.date = date
    }

    init(message: MessageStorageItem) {
        self.init(
            primary: message.primary,
            archivedId: message.archivedId,
            messageId: message.messageId,
            date: message.date
        )
    }
}

struct ChatTimelineAnchor: Equatable {
    let primary: String?
    let archivedId: String?
    let messageId: String?
    let date: Date?

    init(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        date: Date?
    ) {
        self.primary = primary?.isNotEmpty == true ? primary : nil
        self.archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
        self.messageId = messageId?.isNotEmpty == true ? messageId : nil
        self.date = date
    }
}

struct ChatTimelinePositionKey: Comparable, Equatable {
    let date: Date
    let cursorId: String
    let messageId: String
    let primary: String

    init(primary: String, archivedId: String?, messageId: String?, date: Date) {
        self.date = date
        self.cursorId = Self.normalized(archivedId) ?? Self.normalized(messageId) ?? primary
        self.messageId = Self.normalized(messageId) ?? ""
        self.primary = primary
    }

    init(message: MessageStorageItem) {
        self.init(
            primary: message.primary,
            archivedId: message.archivedId,
            messageId: message.messageId,
            date: message.date
        )
    }

    init(boundary: ChatTimelineBoundary) {
        self.init(
            primary: boundary.primary,
            archivedId: boundary.archivedId,
            messageId: boundary.messageId,
            date: boundary.date
        )
    }

    static func < (lhs: ChatTimelinePositionKey, rhs: ChatTimelinePositionKey) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }

        let cursorComparison = compareIdentifier(lhs.cursorId, rhs.cursorId)
        if cursorComparison != .orderedSame {
            return cursorComparison == .orderedAscending
        }

        let messageComparison = compareIdentifier(lhs.messageId, rhs.messageId)
        if messageComparison != .orderedSame {
            return messageComparison == .orderedAscending
        }

        return compareIdentifier(lhs.primary, rhs.primary) == .orderedAscending
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, value.isNotEmpty else {
            return nil
        }
        return value
    }

    private static func compareIdentifier(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }
}

enum ChatTimelineMessageIdentity {
    static func keys(for item: MessageStorageItem) -> [String] {
        var keys: [String] = []
        if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(item.archivedId) {
            keys.append("archive:\(archivedId)")
        }
        if item.messageId.isNotEmpty {
            keys.append("message:\(item.messageId)")
        }
        if item.primary.isNotEmpty {
            keys.append("primary:\(item.primary)")
        }
        return keys
    }
}

enum ChatTimelineOrdering {
    static func chronological(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        items.sorted {
            ChatTimelinePositionKey(message: $0) < ChatTimelinePositionKey(message: $1)
        }
    }

    static func deduplicatedChronological(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        var seen = Set<String>()
        return chronological(items).filter { item in
            let keys = ChatTimelineMessageIdentity.keys(for: item)
            guard keys.contains(where: { seen.contains($0) }) == false else {
                return false
            }
            seen.formUnion(keys)
            return true
        }
    }
}

struct ChatBoundedTimelineWindowState: Equatable {
    static let empty = ChatBoundedTimelineWindowState(
        oldest: nil,
        newest: nil,
        residentPrimaryKeys: [],
        residentArchivedIds: [],
        activePlaceholder: nil,
        isPagingLocked: false
    )

    let oldest: ChatTimelineBoundary?
    let newest: ChatTimelineBoundary?
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?
    let isPagingLocked: Bool

    var isEmpty: Bool {
        residentPrimaryKeys.isEmpty
    }

    init(
        oldest: ChatTimelineBoundary?,
        newest: ChatTimelineBoundary?,
        residentPrimaryKeys: [String],
        residentArchivedIds: [String],
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?,
        isPagingLocked: Bool
    ) {
        self.oldest = oldest
        self.newest = newest
        self.residentPrimaryKeys = residentPrimaryKeys
        self.residentArchivedIds = residentArchivedIds
        self.activePlaceholder = activePlaceholder
        self.isPagingLocked = isPagingLocked
    }

    init(
        items: [MessageStorageItem],
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition? = nil,
        isPagingLocked: Bool = false
    ) {
        let archiveIds = items.compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
        }
        self.init(
            oldest: items.first.map(ChatTimelineBoundary.init(message:)),
            newest: items.last.map(ChatTimelineBoundary.init(message:)),
            residentPrimaryKeys: items.map(\.primary),
            residentArchivedIds: archiveIds,
            activePlaceholder: activePlaceholder,
            isPagingLocked: isPagingLocked
        )
    }
}

protocol ChatTimelinePageProviding {
    func latest(limit: Int) -> [MessageStorageItem]
    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem]
    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem]
    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem]
    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem?
    func items(primaryKeys: [String]) -> [MessageStorageItem]
}

enum ChatBoundedTimelineWindowPolicy {
    static let targetPageMultiplier = 5
    static let hardPageMultiplier = 6

    static func targetLimit(pageSize: Int) -> Int {
        max(1, pageSize) * targetPageMultiplier
    }

    static func hardLimit(pageSize: Int) -> Int {
        max(1, pageSize) * hardPageMultiplier
    }

    static func trimmedItems<T>(
        _ items: [T],
        direction: ChatHistoryPageDirection?,
        pageSize: Int
    ) -> [T] {
        let limit = direction == nil ? targetLimit(pageSize: pageSize) : hardLimit(pageSize: pageSize)
        guard items.count > limit else {
            return items
        }

        switch direction {
        case .older:
            return Array(items.prefix(limit))
        case .newer, .none:
            return Array(items.suffix(limit))
        }
    }

    static func normalizedWindow(
        requestedWindow: ChatDatasetWindow,
        itemCount: Int,
        direction: ChatHistoryPageDirection?
    ) -> ChatDatasetWindow {
        guard itemCount > 0 else {
            return .empty
        }

        switch direction {
        case .older:
            return ChatDatasetWindow(
                minIndex: requestedWindow.minIndex,
                maxIndex: requestedWindow.minIndex + itemCount
            )
        case .newer, .none:
            return ChatDatasetWindow(
                minIndex: max(0, requestedWindow.maxIndex - itemCount),
                maxIndex: requestedWindow.maxIndex
            )
        }
    }
}

final class ChatLocalHistoryPageProvider: ChatTimelinePageProviding {
    private let realm: Realm
    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType

    init(
        realm: Realm,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        self.realm = realm
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
    }

    var totalCount: Int {
        baseQuery().count
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        return Array(scopedChronologicalItems().suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        let boundaryKey = ChatTimelinePositionKey(boundary: boundary)
        return Array(
            scopedChronologicalItems()
                .filter { ChatTimelinePositionKey(message: $0) < boundaryKey }
                .suffix(limit)
        )
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        let boundaryKey = ChatTimelinePositionKey(boundary: boundary)
        return Array(
            scopedChronologicalItems()
                .filter { ChatTimelinePositionKey(message: $0) > boundaryKey }
                .prefix(limit)
        )
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        let items = scopedChronologicalItems()
        guard let anchorIndex = items.firstIndex(where: { $0.primary == anchor.primary }) else {
            return []
        }

        let lowerBound = max(0, anchorIndex - max(0, before))
        let upperBound = min(items.count, anchorIndex + max(0, after) + 1)
        return Array(items[lowerBound..<upperBound])
    }

    func item(at index: Int) -> MessageStorageItem? {
        let results = scopedChronologicalItems()
        guard index >= 0, index < results.count else {
            return nil
        }
        return results[index]
    }

    func index(of message: MessageStorageItem) -> Int {
        index(of: ChatTimelineBoundary(message: message))
    }

    func index(of boundary: ChatTimelineBoundary) -> Int {
        let boundaryKey = ChatTimelinePositionKey(boundary: boundary)
        return scopedChronologicalItems()
            .filter { ChatTimelinePositionKey(message: $0) < boundaryKey }
            .count
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        if let primary,
           primary.isNotEmpty,
           let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
           item.owner == owner,
           item.opponent == jid,
           item.conversationType == conversationType,
           !item.isDeleted {
            return item
        }

        let scoped = baseQuery()
        if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId),
           let item = scoped.filter("archivedId == %@", archivedId).first {
            return item
        }

        if let messageId,
           messageId.isNotEmpty,
           let item = scoped.filter("messageId == %@", messageId).first {
            return item
        }

        return nil
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        guard let boundaryDate = ChatInitialPositionPolicy.archiveDate(from: boundaryArchivedId) else {
            return nil
        }

        let boundary = ChatTimelineBoundary(
            primary: boundaryArchivedId,
            archivedId: boundaryArchivedId,
            messageId: nil,
            date: boundaryDate
        )
        let boundaryKey = ChatTimelinePositionKey(boundary: boundary)
        return scopedChronologicalItems()
            .first {
                $0.outgoing == false &&
                    ChatTimelinePositionKey(message: $0) > boundaryKey
            }
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        guard primaryKeys.isNotEmpty else { return [] }
        let results = realm.objects(MessageStorageItem.self)
            .filter("primary IN %@", primaryKeys)
        let byPrimary = Dictionary(uniqueKeysWithValues: results.map { ($0.primary, $0) })
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    private func baseQuery() -> Results<MessageStorageItem> {
        realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@",
                owner,
                jid,
                conversationType.rawValue
            )
    }

    private func scopedChronologicalItems() -> [MessageStorageItem] {
        Self.deduplicatedChronologicalItems(Array(baseQuery()))
    }

    private static func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        ChatTimelineOrdering.deduplicatedChronological(items)
    }
}

enum ChatHistoryPageDirection: Equatable {
    case older
    case newer
}

enum ChatHistoryBoundaryPlaceholderPosition: Equatable {
    case top
    case bottom
}

enum ChatHistoryPagingLoadDecision: Equatable {
    case localOnly
    case remoteOlderPage
    case remoteNewerPage
    case remoteGapRepairOlder(RegularChatArchiveGap)
    case remoteGapRepairNewer(RegularChatArchiveGap)
    case endReached
}

enum ChatInteractiveHistoryPagingPlan: Equatable {
    case local
    case remote(ChatHistoryPagingLoadDecision)
    case endReached
    case noOp

    var shouldShowOverlay: Bool {
        if case .remote = self {
            return true
        }
        return false
    }

    var shouldShowBoundaryPlaceholder: Bool {
        shouldShowOverlay
    }

    var shouldCreateRemoteContext: Bool {
        shouldShowOverlay
    }
}

enum ChatInteractiveHistoryPagingPlanPolicy {
    static func plan(for decision: ChatHistoryPagingLoadDecision?) -> ChatInteractiveHistoryPagingPlan {
        guard let decision else {
            return .noOp
        }

        switch decision {
        case .localOnly:
            return .local
        case .remoteOlderPage,
             .remoteNewerPage,
             .remoteGapRepairOlder,
             .remoteGapRepairNewer:
            return .remote(decision)
        case .endReached:
            return .endReached
        }
    }
}

enum ChatScrollMotionState: String, Equatable {
    case resting
    case dragging
    case decelerating
    case tracking

    var isMoving: Bool {
        self != .resting
    }
}

enum ChatBoundaryPagingExecutionAction: Equatable {
    case applyNow(ChatHistoryPageDirection)
    case prepareLocal(ChatHistoryPageDirection)
    case deferRemote(ChatHistoryPageDirection)
    case none

    var diagnosticName: String {
        switch self {
        case .applyNow:
            return "applyNow"
        case .prepareLocal:
            return "prepareLocal"
        case .deferRemote:
            return "deferRemote"
        case .none:
            return "none"
        }
    }
}

enum ChatBoundaryPagingExecutionPolicy {
    static func action(
        direction: ChatHistoryPageDirection,
        pagingPlan: ChatInteractiveHistoryPagingPlan,
        motionState: ChatScrollMotionState
    ) -> ChatBoundaryPagingExecutionAction {
        switch pagingPlan {
        case .local:
            return motionState.isMoving ? .prepareLocal(direction) : .applyNow(direction)
        case .remote:
            return motionState.isMoving ? .deferRemote(direction) : .applyNow(direction)
        case .endReached, .noOp:
            return .none
        }
    }
}

struct ChatPreparedLocalHistoryPage {
    let id: String
    let direction: ChatHistoryPageDirection
    let conversationKey: ChatTimelineConversationKey
    let baseVirtualState: ChatVirtualTimelineState
    let baseWindow: ChatDatasetWindow
    let snapshot: ChatTimelineSnapshot
}

private struct ChatInteractiveHistoryPagingPreparation {
    let direction: ChatHistoryPageDirection
    let currentWindow: ChatDatasetWindow
    let requestedWindow: ChatDatasetWindow
    let archiveState: ChatArchiveStateSnapshot
    let virtualArchiveState: ChatArchiveStateSnapshot
    let snapshot: ChatTimelineSnapshot
    let pagingPlan: ChatInteractiveHistoryPagingPlan
}

private enum ChatPendingBoundaryPagingValidationPolicy {
    static func isBoundaryVisible(
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> Bool {
        switch direction {
        case .older:
            guard let firstRealSection = boundaryContext.firstRealSection else {
                return false
            }
            return boundaryContext.visibleRealSections.contains(firstRealSection)
        case .newer:
            guard let lastRealSection = boundaryContext.lastRealSection else {
                return false
            }
            return boundaryContext.visibleRealSections.contains(lastRealSection)
        }
    }
}

enum ChatShortLocalOlderRemainderPolicy {
    static func shouldRequestRemoteFirst(
        localOlderCount: Int,
        pageSize: Int,
        archiveEnded: Bool
    ) -> Bool {
        guard localOlderCount > 0,
              !archiveEnded else {
            return false
        }
        return localOlderCount < max(1, pageSize)
    }
}

enum ChatHistoryLoadingOverlayPolicy {
    static let isOverlayUserInteractionEnabled = false
    static let shouldDisableCollectionInteraction = false
}

enum ChatInteractiveRemoteArchiveTimeoutPolicy {
    static let requestStartTimeout: TimeInterval = 45
    static let timeout: TimeInterval = 45
}

struct ChatInteractiveRemoteArchiveDispatchRequest {
    let owner: String
    let queryId: String
    let direction: ChatHistoryPageDirection
    let cursorId: String?
    let pageSize: Int
    let priority: AccountXMPPTaskScheduler.Priority
    let resource: AccountXMPPTaskScheduler.Resource
    let deduplicationKey: String
    let shouldDispatch: () -> Bool
    let send: (_ account: Account, _ stream: XMPPStream, _ finish: @escaping () -> Void) -> String?
    let transportStarted: (_ sentQueryId: String, _ streamKind: MessageArchiveEndPageEvent.StreamKind, _ resource: String?) -> Void
    let dispatchUnavailable: (_ reason: String) -> Void
}

protocol ChatInteractiveRemoteArchiveRequestDispatching: AnyObject {
    func enqueue(_ request: ChatInteractiveRemoteArchiveDispatchRequest)
}

final class AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher: ChatInteractiveRemoteArchiveRequestDispatching {
    func enqueue(_ request: ChatInteractiveRemoteArchiveDispatchRequest) {
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestEnqueued", [
            ("owner", request.owner),
            ("queryId", request.queryId),
            ("direction", request.direction),
            ("cursor", request.cursorId ?? "-"),
            ("pageSize", request.pageSize),
            ("schedulerPriority", "\(request.priority)"),
            ("schedulerResource", "\(request.resource)"),
            ("deduplicationKey", request.deduplicationKey)
        ])

        guard let account = AccountManager.shared.find(for: request.owner) else {
            request.dispatchUnavailable("missingAccount")
            return
        }

        account.xmppTaskScheduler.enqueueAccountTask(
            priority: request.priority,
            resource: request.resource,
            deduplicationKey: request.deduplicationKey,
            requiresAuthenticatedStream: true
        ) { account, stream, finish in
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDequeued", [
                ("owner", request.owner),
                ("queryId", request.queryId),
                ("direction", request.direction),
                ("cursor", request.cursorId ?? "-"),
                ("schedulerPriority", "\(request.priority)"),
                ("schedulerResource", "\(request.resource)"),
                ("resource", stream.myJID?.resource ?? "-")
            ])

            guard request.shouldDispatch() else {
                finish()
                return
            }

            guard let sentQueryId = request.send(account, stream, finish) else {
                finish()
                return
            }

            request.transportStarted(
                sentQueryId,
                Self.remoteArchiveStreamKind(for: stream),
                stream.myJID?.resource
            )
        }
    }

    private static func remoteArchiveStreamKind(for stream: XMPPStream) -> MessageArchiveEndPageEvent.StreamKind {
        guard let resource = stream.myJID?.resource else {
            return .unknown
        }
        if resource.contains("_ui_upgrade_task") {
            return .uiAction
        }
        return .primary
    }
}

struct ChatTimelineConversationKey: Equatable {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType

    static let empty = ChatTimelineConversationKey(
        owner: "",
        jid: "",
        conversationType: .regular
    )
}

enum ChatVirtualSegment: Equatable {
    case unknownOlder
    case loadedRange(oldestArchiveId: String?, newestArchiveId: String?)
    case knownGap(RegularChatArchiveGap)
    case unknownNewer
    case liveTail
    case loadingPlaceholder(ChatHistoryBoundaryPlaceholderPosition)
}

enum ChatTimelineLoadingState: Equatable {
    case none
    case initialSkeleton
    case edge(ChatHistoryBoundaryPlaceholderPosition)
    case gap(ChatHistoryBoundaryPlaceholderPosition)
}

struct ChatTimelineRemoteLoad: Equatable {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let decision: ChatHistoryPagingLoadDecision
    let cursorId: String?
}

struct ChatTimelineAnchorRestoreCommand: Equatable {
    let primary: String
    let archivedId: String?
    let viewportOffset: CGFloat
}

struct ChatVirtualTimelineState: Equatable {
    static let empty = ChatVirtualTimelineState(
        conversationKey: .empty,
        segments: [],
        oldest: nil,
        newest: nil,
        residentPrimaryKeys: [],
        residentArchivedIds: [],
        activeRemoteLoad: nil,
        activePlaceholder: nil,
        isResidentAtLiveTail: true
    )

    let conversationKey: ChatTimelineConversationKey
    let segments: [ChatVirtualSegment]
    let oldest: ChatTimelineBoundary?
    let newest: ChatTimelineBoundary?
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let activeRemoteLoad: ChatTimelineRemoteLoad?
    let activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?
    let isResidentAtLiveTail: Bool

    var isEmpty: Bool {
        residentPrimaryKeys.isEmpty
    }

    static func empty(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatVirtualTimelineState {
        ChatVirtualTimelineState(
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            segments: [],
            oldest: nil,
            newest: nil,
            residentPrimaryKeys: [],
            residentArchivedIds: [],
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: true
        )
    }

    func normalized(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatVirtualTimelineState {
        let key = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        guard conversationKey == key else {
            return .empty(owner: owner, jid: jid, conversationType: conversationType)
        }
        return self
    }

    func withRuntimePlaceholder(
        _ placeholder: ChatHistoryBoundaryPlaceholderPosition?
    ) -> ChatVirtualTimelineState {
        let segmentsWithoutPlaceholder = segments.filter {
            if case .loadingPlaceholder = $0 {
                return false
            }
            return true
        }
        let nextSegments = placeholder.map {
            segmentsWithoutPlaceholder + [.loadingPlaceholder($0)]
        } ?? segmentsWithoutPlaceholder
        return ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: nextSegments,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: residentPrimaryKeys,
            residentArchivedIds: residentArchivedIds,
            activeRemoteLoad: activeRemoteLoad,
            activePlaceholder: placeholder,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
    }

    func abortingRemoteLoad(queryId: String) -> ChatVirtualTimelineState {
        guard activeRemoteLoad?.queryId == queryId else {
            return self
        }
        let segmentsWithoutPlaceholder = segments.filter {
            if case .loadingPlaceholder = $0 {
                return false
            }
            return true
        }
        return ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: segmentsWithoutPlaceholder,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: residentPrimaryKeys,
            residentArchivedIds: residentArchivedIds,
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
    }
}

struct ChatTimelineSnapshot {
    let items: [MessageStorageItem]
    let state: ChatVirtualTimelineState
    let loadingState: ChatTimelineLoadingState
    let loadDecision: ChatHistoryPagingLoadDecision?
    let anchorRestore: ChatTimelineAnchorRestoreCommand?
    let localOlderCandidateCount: Int?
    let pageSize: Int?
    let shortLocalRemainderRemoteFirst: Bool

    init(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        loadingState: ChatTimelineLoadingState,
        loadDecision: ChatHistoryPagingLoadDecision?,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) {
        self.items = items
        self.state = state
        self.loadingState = loadingState
        self.loadDecision = loadDecision
        self.anchorRestore = anchorRestore
        self.localOlderCandidateCount = localOlderCandidateCount
        self.pageSize = pageSize
        self.shortLocalRemainderRemoteFirst = shortLocalRemainderRemoteFirst
    }
}

extension ChatBoundedTimelineWindowState {
    init(virtualState: ChatVirtualTimelineState) {
        self.init(
            oldest: virtualState.oldest,
            newest: virtualState.newest,
            residentPrimaryKeys: virtualState.residentPrimaryKeys,
            residentArchivedIds: virtualState.residentArchivedIds,
            activePlaceholder: virtualState.activePlaceholder,
            isPagingLocked: virtualState.activeRemoteLoad != nil
        )
    }
}

struct ChatVirtualTimelineEngine {
    private let provider: ChatTimelinePageProviding
    private let pageSize: Int
    private let archiveState: ChatArchiveStateSnapshot
    private(set) var state: ChatVirtualTimelineState

    init(
        provider: ChatTimelinePageProviding,
        pageSize: Int,
        state: ChatVirtualTimelineState,
        archiveState: ChatArchiveStateSnapshot
    ) {
        self.provider = provider
        self.pageSize = max(1, pageSize)
        self.state = state
        self.archiveState = archiveState
    }

    mutating func openLatest(limit: Int? = nil) -> ChatTimelineSnapshot {
        let items = provider.latest(
            limit: limit ?? ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: pageSize)
        )
        return apply(
            items: items,
            direction: nil,
            isResidentAtLiveTail: true,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: nil
        )
    }

    mutating func scrollToLatest(limit: Int? = nil) -> ChatTimelineSnapshot {
        openLatest(limit: limit)
    }

    mutating func openAround(anchor: ChatTimelineAnchor) -> ChatTimelineSnapshot {
        guard let message = provider.message(
            primary: anchor.primary,
            archivedId: anchor.archivedId,
            messageId: anchor.messageId
        ) else {
            return openLatest()
        }

        let before = pageSize / 2
        let after = pageSize - before
        let items = provider.around(anchor: message, before: before, after: after)
        return apply(
            items: items,
            direction: nil,
            isResidentAtLiveTail: false,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: ChatTimelineAnchorRestoreCommand(
                primary: message.primary,
                archivedId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(message.archivedId),
                viewportOffset: 0
            )
        )
    }

    mutating func pageOlder(queryId: String? = nil) -> ChatTimelineSnapshot {
        guard state.activeRemoteLoad == nil else {
            return currentSnapshot()
        }

        guard let oldest = state.oldest else {
            return openLatest()
        }

        let olderItems = provider.older(before: oldest, limit: pageSize)
        guard olderItems.isNotEmpty else {
            if archiveState.fullArchiveLoaded {
                return currentSnapshot(
                    loadDecision: .endReached,
                    localOlderCandidateCount: 0,
                    shortLocalRemainderRemoteFirst: false
                )
            }
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: state.oldest?.archivedId,
                loadingState: .edge(.top),
                localOlderCandidateCount: 0,
                shortLocalRemainderRemoteFirst: false
            )
        }

        if let gapDecision = gapDecision(
            direction: .older,
            requestedItems: olderItems
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: gapDecision,
                cursorId: cursorId(for: gapDecision),
                loadingState: .gap(.top),
                localOlderCandidateCount: olderItems.count,
                shortLocalRemainderRemoteFirst: false
            )
        }

        if ChatShortLocalOlderRemainderPolicy.shouldRequestRemoteFirst(
            localOlderCount: olderItems.count,
            pageSize: pageSize,
            archiveEnded: archiveState.fullArchiveLoaded
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: state.oldest?.archivedId,
                loadingState: .edge(.top),
                localOlderCandidateCount: olderItems.count,
                shortLocalRemainderRemoteFirst: true
            )
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        let candidateItems = olderItems + currentItems
        let previousNewest = state.newest?.primary
        let wasLiveTail = state.isResidentAtLiveTail
        let trimmedItems = trimmed(candidateItems, direction: .older)
        let stillHasPreviousNewest = previousNewest.flatMap { newest in
            trimmedItems.contains(where: { $0.primary == newest })
        } ?? false

        return apply(
            items: trimmedItems,
            direction: .older,
            isResidentAtLiveTail: wasLiveTail && stillHasPreviousNewest,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil,
            localOlderCandidateCount: olderItems.count,
            shortLocalRemainderRemoteFirst: false
        )
    }

    mutating func pageNewer(queryId: String? = nil) -> ChatTimelineSnapshot {
        guard state.activeRemoteLoad == nil else {
            return currentSnapshot()
        }

        guard let newest = state.newest else {
            return openLatest()
        }

        let newerItems = provider.newer(after: newest, limit: pageSize)
        guard newerItems.isNotEmpty else {
            if archiveState.newerLiveEdgeReached || state.isResidentAtLiveTail {
                return currentSnapshot(loadDecision: .endReached)
            }
            return remoteSnapshot(
                queryId: queryId,
                direction: .newer,
                decision: .remoteNewerPage,
                cursorId: state.newest?.archivedId,
                loadingState: .edge(.bottom)
            )
        }

        if let gapDecision = gapDecision(
            direction: .newer,
            requestedItems: newerItems
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .newer,
                decision: gapDecision,
                cursorId: cursorId(for: gapDecision),
                loadingState: .gap(.bottom)
            )
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        let candidateItems = currentItems + newerItems
        let trimmedItems = trimmed(candidateItems, direction: .newer)
        let reachesKnownLiveTail = archiveState.newerLiveEdgeReached && (trimmedItems.last.map {
            provider.newer(after: ChatTimelineBoundary(message: $0), limit: 1).isEmpty
        } ?? false)

        return apply(
            items: trimmedItems,
            direction: .newer,
            isResidentAtLiveTail: reachesKnownLiveTail,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil
        )
    }

    mutating func appendLiveMessage(_ message: MessageStorageItem) -> ChatTimelineSnapshot {
        guard state.isResidentAtLiveTail else {
            return currentSnapshot()
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        return apply(
            items: currentItems + [message],
            direction: .newer,
            isResidentAtLiveTail: true,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil
        )
    }

    mutating func finishRemoteLoad(
        queryId: String,
        refetchDirection: ChatHistoryPageDirection? = nil
    ) -> ChatTimelineSnapshot {
        if let activeRemoteLoad = state.activeRemoteLoad,
           activeRemoteLoad.queryId != queryId {
            return currentSnapshot()
        }

        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: state.oldest,
                newest: state.newest,
                activePlaceholder: nil,
                isResidentAtLiveTail: state.isResidentAtLiveTail
            ),
            oldest: state.oldest,
            newest: state.newest,
            residentPrimaryKeys: state.residentPrimaryKeys,
            residentArchivedIds: state.residentArchivedIds,
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )

        guard let refetchDirection else {
            return currentSnapshot()
        }

        return refetchLocalAfterRemoteLoad(direction: refetchDirection)
    }

    mutating func abortRemoteLoad(queryId: String) -> ChatTimelineSnapshot {
        let nextState = state.abortingRemoteLoad(queryId: queryId)
        guard nextState != state else {
            return currentSnapshot()
        }
        state = nextState
        return currentSnapshot()
    }

    private mutating func refetchLocalAfterRemoteLoad(direction: ChatHistoryPageDirection) -> ChatTimelineSnapshot {
        switch direction {
        case .older:
            guard let oldest = state.oldest else {
                return openLatest()
            }

            let olderItems = provider.older(before: oldest, limit: pageSize)
            guard olderItems.isNotEmpty else {
                return currentSnapshot()
            }

            let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
            let previousNewest = state.newest?.primary
            let wasLiveTail = state.isResidentAtLiveTail
            let candidateItems = olderItems + currentItems
            let trimmedItems = trimmed(candidateItems, direction: .older)
            let stillHasPreviousNewest = previousNewest.flatMap { newest in
                trimmedItems.contains(where: { $0.primary == newest })
            } ?? false

            return apply(
                items: trimmedItems,
                direction: .older,
                isResidentAtLiveTail: wasLiveTail && stillHasPreviousNewest,
                loadingState: .none,
                loadDecision: .localOnly,
                anchorRestore: nil
            )
        case .newer:
            guard let newest = state.newest else {
                return openLatest()
            }

            let newerItems = provider.newer(after: newest, limit: pageSize)
            guard newerItems.isNotEmpty else {
                return currentSnapshot()
            }

            let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
            let candidateItems = currentItems + newerItems
            let trimmedItems = trimmed(candidateItems, direction: .newer)
            let reachesKnownLiveTail = archiveState.newerLiveEdgeReached && (trimmedItems.last.map {
                provider.newer(after: ChatTimelineBoundary(message: $0), limit: 1).isEmpty
            } ?? false)

            return apply(
                items: trimmedItems,
                direction: .newer,
                isResidentAtLiveTail: reachesKnownLiveTail,
                loadingState: .none,
                loadDecision: .localOnly,
                anchorRestore: nil
            )
        }
    }

    private mutating func apply(
        items: [MessageStorageItem],
        direction: ChatHistoryPageDirection?,
        isResidentAtLiveTail: Bool,
        loadingState: ChatTimelineLoadingState,
        loadDecision: ChatHistoryPagingLoadDecision?,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        let deduplicated = Self.deduplicatedChronologicalItems(items)
        let trimmedItems = trimmed(deduplicated, direction: direction)
        let archiveIds = trimmedItems.compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
        }
        let activePlaceholder = placeholder(for: loadingState)
        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: trimmedItems.first.map(ChatTimelineBoundary.init(message:)),
                newest: trimmedItems.last.map(ChatTimelineBoundary.init(message:)),
                activePlaceholder: activePlaceholder,
                isResidentAtLiveTail: isResidentAtLiveTail
            ),
            oldest: trimmedItems.first.map(ChatTimelineBoundary.init(message:)),
            newest: trimmedItems.last.map(ChatTimelineBoundary.init(message:)),
            residentPrimaryKeys: trimmedItems.map(\.primary),
            residentArchivedIds: archiveIds,
            activeRemoteLoad: nil,
            activePlaceholder: activePlaceholder,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
        return ChatTimelineSnapshot(
            items: trimmedItems,
            state: state,
            loadingState: loadingState,
            loadDecision: loadDecision,
            anchorRestore: anchorRestore,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    private mutating func remoteSnapshot(
        queryId: String?,
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        cursorId: String?,
        loadingState: ChatTimelineLoadingState,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        let activePlaceholder = placeholder(for: loadingState)
        let activeRemoteLoad = queryId.map {
            ChatTimelineRemoteLoad(
                queryId: $0,
                direction: direction,
                decision: decision,
                cursorId: cursorId
            )
        }
        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: state.oldest,
                newest: state.newest,
                activePlaceholder: activePlaceholder,
                isResidentAtLiveTail: state.isResidentAtLiveTail
            ),
            oldest: state.oldest,
            newest: state.newest,
            residentPrimaryKeys: state.residentPrimaryKeys,
            residentArchivedIds: state.residentArchivedIds,
            activeRemoteLoad: activeRemoteLoad,
            activePlaceholder: activePlaceholder,
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )
        return currentSnapshot(
            loadingState: loadingState,
            loadDecision: decision,
            localOlderCandidateCount: localOlderCandidateCount,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    func currentSnapshot(
        loadingState: ChatTimelineLoadingState = .none,
        loadDecision: ChatHistoryPagingLoadDecision? = nil,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: provider.items(primaryKeys: state.residentPrimaryKeys),
            state: state,
            loadingState: loadingState,
            loadDecision: loadDecision,
            anchorRestore: nil,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    private func trimmed(
        _ items: [MessageStorageItem],
        direction: ChatHistoryPageDirection?
    ) -> [MessageStorageItem] {
        ChatBoundedTimelineWindowPolicy.trimmedItems(
            items,
            direction: direction,
            pageSize: pageSize
        )
    }

    private func gapDecision(
        direction: ChatHistoryPageDirection,
        requestedItems: [MessageStorageItem]
    ) -> ChatHistoryPagingLoadDecision? {
        guard let currentOldest = state.oldest,
              let currentNewest = state.newest,
              let requestedOldest = requestedItems.first.map(ChatTimelineBoundary.init(message:)),
              let requestedNewest = requestedItems.last.map(ChatTimelineBoundary.init(message:)) else {
            return nil
        }

        return ChatArchiveBoundaryGapPagingPolicy.loadDecision(
            direction: direction,
            currentOldestArchiveId: currentOldest.archivedId,
            currentNewestArchiveId: currentNewest.archivedId,
            requestedOldestArchiveId: requestedOldest.archivedId,
            requestedNewestArchiveId: requestedNewest.archivedId,
            knownGaps: archiveState.knownGaps
        )
    }

    private func cursorId(for decision: ChatHistoryPagingLoadDecision) -> String? {
        switch decision {
        case .remoteOlderPage:
            return state.oldest?.archivedId
        case .remoteNewerPage:
            return state.newest?.archivedId
        case .remoteGapRepairOlder(let gap):
            return gap.newerRangeOldestArchiveId
        case .remoteGapRepairNewer(let gap):
            return gap.olderRangeNewestArchiveId
        case .localOnly, .endReached:
            return nil
        }
    }

    private func placeholder(for loadingState: ChatTimelineLoadingState) -> ChatHistoryBoundaryPlaceholderPosition? {
        switch loadingState {
        case .edge(let position), .gap(let position):
            return position
        case .none, .initialSkeleton:
            return nil
        }
    }

    private func segments(
        oldest: ChatTimelineBoundary?,
        newest: ChatTimelineBoundary?,
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?,
        isResidentAtLiveTail: Bool
    ) -> [ChatVirtualSegment] {
        var segments: [ChatVirtualSegment] = []
        if !archiveState.fullArchiveLoaded {
            segments.append(.unknownOlder)
        }
        if let oldestArchiveId = oldest?.archivedId,
           let newestArchiveId = newest?.archivedId {
            segments.append(.loadedRange(oldestArchiveId: oldestArchiveId, newestArchiveId: newestArchiveId))
        } else if oldest != nil || newest != nil {
            segments.append(.loadedRange(oldestArchiveId: oldest?.archivedId, newestArchiveId: newest?.archivedId))
        }
        segments.append(contentsOf: archiveState.knownGaps.map(ChatVirtualSegment.knownGap))
        if !archiveState.newerLiveEdgeReached || !isResidentAtLiveTail {
            segments.append(.unknownNewer)
        }
        if isResidentAtLiveTail {
            segments.append(.liveTail)
        }
        if let activePlaceholder {
            segments.append(.loadingPlaceholder(activePlaceholder))
        }
        return segments
    }

    private static func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        ChatTimelineOrdering.deduplicatedChronological(items)
    }
}

struct ChatInteractiveHistoryPageLoadContext {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let chatPrimaryKey: String
    let persistedCursorId: String?
    let persistedFullArchiveLoaded: Bool
    let requestedCursorId: String?
    let requestedWindow: ChatDatasetWindow
    let preLoadObserverCount: Int
    let preLoadOldestArchivedId: String?
    let preLoadNewestArchivedId: String?
    let preLoadFullArchiveLoaded: Bool
    let preLoadNewerLiveEdgeReached: Bool
    var remoteFetchStarted: Bool
    let isArchiveEndVerificationProbe: Bool
    let canMutateOlderArchiveEnd: Bool
    let expectedWindowMaxIndex: Int
    let coverageUpdateKind: RegularArchiveCoverageUpdateKind
    var didReceiveEndPage: Bool = false
    var queryExhausted: Bool = false
    var persistedMessageCount: Int? = nil
    var resultFirst: String = ""
    var resultLast: String = ""
    var resultCount: Int = 0
    var persistedRowsForQuery: Int = 0
    var visibleRowsForConversation: Int = 0
    var didEnterObserverSettlePhase: Bool = false
    var didObservePostIdleTick: Bool = false
    var isArchivePagePersisted: Bool = false
}

struct ChatHistoryPageAnchor: Equatable {
    let primary: String
    let offsetFromViewportTop: CGFloat
}

struct ChatHistoryPagingBoundaryContext: Equatable {
    let firstRealSection: Int?
    let lastRealSection: Int?
    let visibleRealSections: [Int]

    var isEntireRealRangeVisible: Bool {
        guard let firstRealSection,
              let lastRealSection else {
            return false
        }
        return visibleRealSections.contains(firstRealSection) &&
            visibleRealSections.contains(lastRealSection)
    }
}

enum ChatShortContentRemotePagingSuppressionPolicy {
    static let layoutTolerance: CGFloat = 8

    static func shouldSuppressRemoteBoundaryPaging(
        hasRealMessages: Bool,
        hasLocalOlderAvailable: Bool,
        hasLocalNewerAvailable: Bool,
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        tolerance: CGFloat = 8
    ) -> Bool {
        guard hasRealMessages,
              !hasLocalOlderAvailable,
              !hasLocalNewerAvailable,
              contentHeight > 0,
              visibleHeight > 0 else {
            return false
        }

        return contentHeight <= visibleHeight + tolerance
    }
}

enum ChatHistoryPageCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int?,
        isMessagePipelineIdle: Bool,
        isArchivePagePersisted: Bool = false,
        requiresObserverSettle: Bool = false,
        didObservePostIdleTick: Bool = true
    ) -> Bool {
        guard didReceiveEndPage, isMessagePipelineIdle || isArchivePagePersisted else {
            return false
        }

        if requiresObserverSettle && !isArchivePagePersisted && !didObservePostIdleTick {
            return false
        }

        if didAdvance {
            return true
        }

        if persistedMessageCount == 0 {
            return true
        }

        if isArchivePagePersisted {
            return true
        }

        return requiresObserverSettle && didObservePostIdleTick
    }

    static func didAdvance(
        previousObserverCount: Int,
        currentObserverCount: Int,
        previousOldestArchivedId: String?,
        currentOldestArchivedId: String?,
        previousArchiveEnded: Bool,
        currentArchiveEnded: Bool
    ) -> Bool {
        currentObserverCount > previousObserverCount ||
        previousOldestArchivedId != currentOldestArchivedId ||
        (!previousArchiveEnded && currentArchiveEnded)
    }

    static func didAdvance(
        direction: ChatHistoryPageDirection,
        previousObserverCount: Int,
        currentObserverCount: Int,
        previousOldestArchivedId: String?,
        currentOldestArchivedId: String?,
        previousNewestArchivedId: String?,
        currentNewestArchivedId: String?,
        previousArchiveEnded: Bool,
        currentArchiveEnded: Bool,
        previousNewerLiveEdgeReached: Bool,
        currentNewerLiveEdgeReached: Bool
    ) -> Bool {
        if currentObserverCount > previousObserverCount {
            return true
        }

        switch direction {
        case .older:
            return previousOldestArchivedId != currentOldestArchivedId ||
            (!previousArchiveEnded && currentArchiveEnded)
        case .newer:
            return previousNewestArchivedId != currentNewestArchivedId ||
            (!previousNewerLiveEdgeReached && currentNewerLiveEdgeReached)
        }
    }

    static func finalizedWindow(
        direction: ChatHistoryPageDirection,
        requestedWindow: ChatDatasetWindow,
        expectedWindowMaxIndex: Int,
        preLoadObserverCount: Int,
        currentObserverCount: Int,
        totalCount: Int
    ) -> ChatDatasetWindow {
        let observerCountDelta = max(0, currentObserverCount - preLoadObserverCount)
        let requestedMaxIndex = direction == .older
            ? expectedWindowMaxIndex + observerCountDelta
            : expectedWindowMaxIndex
        return ChatDatasetCoordinator(pageSize: max(1, requestedWindow.count)).clamp(
            ChatDatasetWindow(
                minIndex: requestedWindow.minIndex,
                maxIndex: requestedMaxIndex
            ),
            totalCount: totalCount
        )
    }
}

enum ChatInitialBootstrapCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        hasMessages: Bool,
        didConfirmEmpty: Bool,
        isMessagePipelineIdle: Bool,
        isArchivePagePersisted: Bool = false,
        requiresObserverSettle: Bool,
        didObservePostIdleTick: Bool
    ) -> Bool {
        guard didReceiveEndPage,
              isMessagePipelineIdle || isArchivePagePersisted,
              hasMessages || didConfirmEmpty else {
            return false
        }

        guard !requiresObserverSettle || isArchivePagePersisted || didObservePostIdleTick else {
            return false
        }

        return true
    }
}

enum ChatInitialBootstrapArchiveEndCommitPolicy {
    static func shouldCommitArchiveEnd(
        state: MessageArchivePageEndState?,
        resultCount: Int?,
        visibleRowsForLatestPage: Int,
        persistedRowsForQuery: Int = 0
    ) -> Bool {
        guard state?.archiveEnded == true,
              let resultCount else {
            return false
        }

        if resultCount == 0 {
            return true
        }

        return visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0
    }
}

struct ChatRemoteHistoryCompletionResult: Equatable {
    let state: MessageArchivePageEndState
    let flushedMessageCount: Int
    let persistenceSummary: MessageManager.ArchivePersistenceSummary
}

enum ChatRemoteHistoryCompletionCoordinator {
    private final class PersistenceSource {
        weak var manager: MessageManager?

        init(_ manager: MessageManager) {
            self.manager = manager
        }
    }

    private static let persistenceSourcesLock = NSLock()
    private static var persistenceSourcesByKey: [String: PersistenceSource] = [:]

    private static func persistenceSourceKey(owner: String, queryId: String) -> String {
        "\(owner)\u{1F}remote-history\u{1F}\(queryId)"
    }

    static func registerPersistenceSource(
        _ manager: MessageManager,
        owner: String,
        queryId: String
    ) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return
        }

        persistenceSourcesLock.lock()
        persistenceSourcesByKey[persistenceSourceKey(owner: owner, queryId: queryId)] = PersistenceSource(manager)
        persistenceSourcesLock.unlock()
        ChatArchiveDebugTrace.log("remoteCompletionSourceRegister", [
            ("owner", owner),
            ("queryId", queryId),
            ("manager", ObjectIdentifier(manager).hashValue)
        ])
    }

    static func unregisterPersistenceSource(owner: String, queryId: String) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return
        }

        persistenceSourcesLock.lock()
        let source = persistenceSourcesByKey.removeValue(forKey: persistenceSourceKey(owner: owner, queryId: queryId))?.manager
        persistenceSourcesLock.unlock()
        ChatArchiveDebugTrace.log("remoteCompletionSourceUnregister", [
            ("owner", owner),
            ("queryId", queryId),
            ("manager", source.map { ObjectIdentifier($0).hashValue } ?? 0)
        ])
        source?.clearArchivePersistenceSummary(forQueryId: queryId)
    }

    private static func registeredPersistenceSource(owner: String, queryId: String) -> MessageManager? {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return nil
        }

        persistenceSourcesLock.lock()
        let key = persistenceSourceKey(owner: owner, queryId: queryId)
        let manager = persistenceSourcesByKey[key]?.manager
        if manager == nil {
            persistenceSourcesByKey.removeValue(forKey: key)
        }
        persistenceSourcesLock.unlock()
        return manager
    }

    static func hasPendingMessages(owner: String, queryId: String) -> Bool {
        let sourceHasPendingMessages = registeredPersistenceSource(owner: owner, queryId: queryId)?
            .hasPendingMessages(forQueryId: queryId) ?? false
        let primaryHasPendingMessages = AccountManager.shared.find(for: owner)?
            .messages
            .hasPendingMessages(forQueryId: queryId) ?? false

        return sourceHasPendingMessages || primaryHasPendingMessages
    }

    static func flushQueryMessages(
        owner: String,
        queryId: String,
        state: MessageArchivePageEndState,
        conversationJid: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType? = nil
    ) -> ChatRemoteHistoryCompletionResult {
        let startedAt = Date()
        ChatArchiveDebugTrace.log("remoteCompletionFlushStart", [
            ("owner", owner),
            ("queryId", queryId),
            ("jid", conversationJid ?? "-"),
            ("conversationType", conversationType?.rawValue ?? "-"),
            ("statePersisted", state.persistedMessageCount)
        ])
        let source = registeredPersistenceSource(owner: owner, queryId: queryId)
        let fallbackSource = AccountManager.shared.find(for: owner)?.messages
        ChatArchiveDebugTrace.log("remoteCompletionSourceSelected", [
            ("owner", owner),
            ("queryId", queryId),
            ("sourcePresent", source != nil),
            ("fallbackPresent", fallbackSource != nil),
            ("sameSource", source != nil && source === fallbackSource),
            ("sourceManager", source.map { ObjectIdentifier($0).hashValue } ?? 0),
            ("fallbackManager", fallbackSource.map { ObjectIdentifier($0).hashValue } ?? 0)
        ])
        let sourceFlushStartedAt = Date()
        let sourceSummary = source?.storeMessagesNowSummary(forQueryId: queryId) ?? MessageManager.ArchivePersistenceSummary()
        ChatArchiveDebugTrace.log("remoteCompletionSourceFlushDone", [
            ("owner", owner),
            ("queryId", queryId),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: sourceFlushStartedAt)),
            ("received", sourceSummary.received),
            ("queued", sourceSummary.queued),
            ("savedNew", sourceSummary.savedNew),
            ("updatedExisting", sourceSummary.updatedExisting),
            ("skipped", sourceSummary.skipped),
            ("failed", sourceSummary.failed)
        ])
        let shouldFlushFallback = fallbackSource != nil && source !== fallbackSource
        let fallbackFlushStartedAt = Date()
        let fallbackSummary = shouldFlushFallback
            ? fallbackSource?.storeMessagesNowSummary(forQueryId: queryId) ?? MessageManager.ArchivePersistenceSummary()
            : MessageManager.ArchivePersistenceSummary()
        ChatArchiveDebugTrace.log("remoteCompletionFallbackFlushDone", [
            ("owner", owner),
            ("queryId", queryId),
            ("didFlush", shouldFlushFallback),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: fallbackFlushStartedAt)),
            ("received", fallbackSummary.received),
            ("queued", fallbackSummary.queued),
            ("savedNew", fallbackSummary.savedNew),
            ("updatedExisting", fallbackSummary.updatedExisting),
            ("skipped", fallbackSummary.skipped),
            ("failed", fallbackSummary.failed)
        ])
        var persistenceSummary = sourceSummary
        persistenceSummary.merge(fallbackSummary)
        if let conversationJid,
           let conversationType,
           persistenceSummary.persistedRows > 0,
           persistenceSummary.visibleRows(owner: owner, jid: conversationJid, conversationType: conversationType) == 0 {
            DDLogDebug("ChatRemoteHistoryCompletionCoordinator flushed non-visible rows queryId=\(queryId) persisted=\(persistenceSummary.persistedRows) jid=\(conversationJid) conversationType=\(conversationType.rawValue)")
        }

        let persistedMessageCount = max(state.persistedMessageCount, persistenceSummary.persistedRows)
        let effectiveState: MessageArchivePageEndState

        if persistedMessageCount != state.persistedMessageCount {
            effectiveState = MessageArchivePageEndState(
                queryExhausted: state.queryExhausted,
                archiveEnded: state.archiveEnded,
                persistedMessageCount: persistedMessageCount,
                requestCursorId: state.requestCursorId
            )
        } else {
            effectiveState = state
        }

        ChatArchiveDebugTrace.log("remoteCompletionFlushFinish", [
            ("owner", owner),
            ("queryId", queryId),
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
            ("persistedRows", persistenceSummary.persistedRows),
            ("processedRows", persistenceSummary.processedRows),
            ("effectivePersisted", effectiveState.persistedMessageCount)
        ])
        return ChatRemoteHistoryCompletionResult(
            state: effectiveState,
            flushedMessageCount: persistenceSummary.persistedRows,
            persistenceSummary: persistenceSummary
        )
    }
}

enum ChatDatasourceApplyCategory: String {
    case `default`
    case olderAnchorReload
    case tailAppendBottomPinned
}

enum ChatHistoryPageAnchorRestorePhase: String {
    case none
    case applyTransaction
    case completion
}

struct ChatHistoryPageApplyPlan: Equatable {
    let keepOffset: Bool
    let restorePhase: ChatHistoryPageAnchorRestorePhase
    let applyCategory: ChatDatasourceApplyCategory

    var shouldRestoreAnchor: Bool {
        restorePhase != .none
    }
}

enum ChatHistoryPageApplyPolicy {
    static func keepOffset(direction: ChatHistoryPageDirection) -> Bool {
        switch direction {
        case .older:
            return true
        case .newer:
            return false
        }
    }

    static func plan(
        direction: ChatHistoryPageDirection,
        hasCapturedAnchor: Bool
    ) -> ChatHistoryPageApplyPlan {
        switch direction {
        case .older where hasCapturedAnchor:
            return ChatHistoryPageApplyPlan(
                keepOffset: false,
                restorePhase: .applyTransaction,
                applyCategory: .olderAnchorReload
            )
        case .older:
            return ChatHistoryPageApplyPlan(
                keepOffset: true,
                restorePhase: .none,
                applyCategory: .default
            )
        case .newer:
            return ChatHistoryPageApplyPlan(
                keepOffset: false,
                restorePhase: hasCapturedAnchor ? .completion : .none,
                applyCategory: .default
            )
        }
    }
}

enum ChatTimelineObserverRefreshPolicy {
    static func shouldOpenLatest(
        isTimelineEmpty: Bool,
        isResidentAtLiveTail: Bool,
        isShowingBootstrapPlaceholder: Bool,
        hasActiveRemoteLoad: Bool,
        hasInteractiveRemoteContext: Bool
    ) -> Bool {
        guard !hasActiveRemoteLoad,
              !hasInteractiveRemoteContext else {
            return false
        }

        return isTimelineEmpty || isResidentAtLiveTail || isShowingBootstrapPlaceholder
    }
}

enum ChatHistoryPageAnchorRestorePolicy {
    static func targetContentOffsetY(
        anchorMinY: CGFloat,
        offsetFromViewportTop: CGFloat,
        minContentOffsetY: CGFloat,
        maxContentOffsetY: CGFloat
    ) -> CGFloat {
        min(max(anchorMinY - offsetFromViewportTop, minContentOffsetY), maxContentOffsetY)
    }
}

private struct ChatHistoryPageAnchorRestoreDiagnostics {
    var sectionFound = false
    var attributesFound = false
    var restored = false
    var targetOffsetY: CGFloat?
}

enum ChatHistoryLoadingTimeoutPolicy {
    static let checkInterval: TimeInterval = 5.0
    static let interactiveHardTimeout: TimeInterval = 180.0

    static func shouldAbortInteractivePageLoad(elapsed: TimeInterval) -> Bool {
        elapsed >= interactiveHardTimeout
    }
}

enum ChatDatasourceApplyGenerationPolicy {
    static func shouldApply(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }
}

enum ChatRemoteHistoryApplyGuardPolicy {
    static func shouldApply(
        requestConversationKey: ChatTimelineConversationKey,
        currentConversationKey: ChatTimelineConversationKey,
        requestQueryId: String,
        finishingQueryId: String?
    ) -> Bool {
        guard requestConversationKey == currentConversationKey else {
            return false
        }

        guard let finishingQueryId else {
            return false
        }

        return finishingQueryId == requestQueryId
    }
}

enum ChatRemoteHistoryApplyProofPolicy {
    static func didAdvance(
        direction: ChatHistoryPageDirection,
        visibleRows: Int,
        resultCount: Int,
        queryExhausted: Bool,
        previousOldestArchivedId: String?,
        previousNewestArchivedId: String?,
        newOldestArchivedId: String?,
        newNewestArchivedId: String?
    ) -> Bool {
        if resultCount == 0 && queryExhausted {
            return true
        }

        guard visibleRows > 0 else {
            return false
        }

        switch direction {
        case .older:
            return normalized(previousOldestArchivedId) != normalized(newOldestArchivedId)
        case .newer:
            return normalized(previousNewestArchivedId) != normalized(newNewestArchivedId)
        }
    }

    private static func normalized(_ archivedId: String?) -> String? {
        RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
    }
}

struct ChatRemoteHistoryApplyResult {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let visibleRows: Int
    let resultCount: Int
    let queryExhausted: Bool
    let previousOldestArchivedId: String?
    let previousNewestArchivedId: String?
    let newOldestArchivedId: String?
    let newNewestArchivedId: String?
    let itemCount: Int
    let queueWaitMs: Int
    let mapDurationMs: Int

    var didAdvance: Bool {
        ChatRemoteHistoryApplyProofPolicy.didAdvance(
            direction: direction,
            visibleRows: visibleRows,
            resultCount: resultCount,
            queryExhausted: queryExhausted,
            previousOldestArchivedId: previousOldestArchivedId,
            previousNewestArchivedId: previousNewestArchivedId,
            newOldestArchivedId: newOldestArchivedId,
            newNewestArchivedId: newNewestArchivedId
        )
    }
}

enum ChatHistoryPageOutcome: Equatable {
    case advanced(persistedCursorId: String?)
    case emptyExhausted(persistedCursorId: String?)
    case duplicateOrNoAdvance(persistedCursorId: String?)
}

enum ChatHistoryPageOutcomePolicy {
    static func resolve(
        queryExhausted: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int,
        requestedCursorId: String?,
        currentCursorId: String?
    ) -> ChatHistoryPageOutcome {
        if didAdvance {
            return .advanced(persistedCursorId: currentCursorId)
        }

        if queryExhausted && persistedMessageCount == 0 && requestedCursorId == currentCursorId {
            return .emptyExhausted(persistedCursorId: currentCursorId)
        }

        return .duplicateOrNoAdvance(persistedCursorId: currentCursorId)
    }
}

struct ChatArchiveCoverageCommitDecision: Equatable {
    let resolvedCursorId: String?
    let shouldCommitCoverage: Bool
    let shouldAdvanceOlderCursor: Bool
    let nextFullArchiveLoaded: Bool
    let shouldMarkNewerLiveEdgeReached: Bool
    let hasPersistenceProof: Bool
    let cursorRepeatedAfterCompletion: Bool
    let duplicateCursorSuppressed: Bool
}

enum ChatArchiveCoverageCommitPolicy {
    static func resolve(
        direction: ChatHistoryPageDirection,
        snapshot: ChatArchiveStateSnapshot,
        requestedCursorId: String?,
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        resultCount: Int,
        persistedRowsForQuery: Int,
        visibleRowsForConversation: Int,
        queryExhausted: Bool,
        canMutateOlderArchiveEnd: Bool,
        coverageUpdateKind: RegularArchiveCoverageUpdateKind
    ) -> ChatArchiveCoverageCommitDecision {
        let hasPersistenceProof = persistedRowsForQuery > 0 || visibleRowsForConversation > 0
        let hasTransportRange = resultCount > 0 && (transportFirst.isNotEmpty || transportLast.isNotEmpty)
        let hasTerminalProof = queryExhausted && (resultCount == 0 || hasPersistenceProof)
        let shouldCommitCoverage = coverageUpdateKind.shouldMutateCoverage &&
            hasTransportRange &&
            hasPersistenceProof
        let shouldAdvanceOlderCursor = shouldAdvanceOlderCursor(
            direction: direction,
            updateKind: coverageUpdateKind,
            hasPersistenceProof: hasPersistenceProof
        )
        let resolvedCursorId: String?

        if shouldAdvanceOlderCursor {
            resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
                direction: direction,
                observedCursorId: observedCursorId,
                transportFirst: transportFirst,
                transportLast: transportLast,
                currentPersistedCursorId: snapshot.persistedCursorId,
                hasPersistenceProof: hasPersistenceProof
            )
        } else {
            resolvedCursorId = snapshot.persistedCursorId
        }
        let requestedCursorId = requestedCursorId?.isNotEmpty == true ? requestedCursorId : nil
        let cursorRepeatedAfterCompletion = requestedCursorId != nil && requestedCursorId == resolvedCursorId
        let duplicateCursorSuppressed = cursorRepeatedAfterCompletion &&
            resultCount > 0 &&
            !queryExhausted

        let shouldMarkOlderArchiveEnd = direction == .older &&
            hasTerminalProof &&
            canMutateOlderArchiveEnd &&
            shouldMarkOlderArchiveEnd(updateKind: coverageUpdateKind)
        let shouldClearOlderArchiveEnd = direction == .older &&
            hasPersistenceProof &&
            shouldAdvanceOlderCursor
        let shouldMarkNewerLiveEdgeReached = direction == .newer &&
            hasTerminalProof &&
            shouldMarkNewerLiveEdgeReached(updateKind: coverageUpdateKind)

        return ChatArchiveCoverageCommitDecision(
            resolvedCursorId: resolvedCursorId,
            shouldCommitCoverage: shouldCommitCoverage,
            shouldAdvanceOlderCursor: shouldAdvanceOlderCursor,
            nextFullArchiveLoaded: shouldMarkOlderArchiveEnd ? true : (shouldClearOlderArchiveEnd ? false : snapshot.fullArchiveLoaded),
            shouldMarkNewerLiveEdgeReached: shouldMarkNewerLiveEdgeReached,
            hasPersistenceProof: hasPersistenceProof,
            cursorRepeatedAfterCompletion: cursorRepeatedAfterCompletion,
            duplicateCursorSuppressed: duplicateCursorSuppressed
        )
    }

    private static func shouldAdvanceOlderCursor(
        direction: ChatHistoryPageDirection,
        updateKind: RegularArchiveCoverageUpdateKind,
        hasPersistenceProof: Bool
    ) -> Bool {
        guard direction == .older,
              hasPersistenceProof else {
            return false
        }

        if case .pageOlder = updateKind {
            return true
        }
        return false
    }

    private static func shouldMarkNewerLiveEdgeReached(updateKind: RegularArchiveCoverageUpdateKind) -> Bool {
        if case .pageNewer = updateKind {
            return true
        }
        return false
    }

    private static func shouldMarkOlderArchiveEnd(updateKind: RegularArchiveCoverageUpdateKind) -> Bool {
        if case .pageOlder = updateKind {
            return true
        }
        return false
    }
}

struct ChatArchiveStateSnapshot: Equatable {
    let primaryKey: String
    let persistedCursorId: String?
    let fullArchiveLoaded: Bool
    let newestCursorId: String?
    let newerLiveEdgeReached: Bool
    let hasKnownNewerGap: Bool
    let knownGaps: [RegularChatArchiveGap]

    init(
        primaryKey: String,
        persistedCursorId: String?,
        fullArchiveLoaded: Bool,
        newestCursorId: String? = nil,
        newerLiveEdgeReached: Bool = true,
        hasKnownNewerGap: Bool = false,
        knownGaps: [RegularChatArchiveGap] = []
    ) {
        self.primaryKey = primaryKey
        self.persistedCursorId = persistedCursorId
        self.fullArchiveLoaded = fullArchiveLoaded
        self.newestCursorId = newestCursorId
        self.newerLiveEdgeReached = newerLiveEdgeReached
        self.hasKnownNewerGap = hasKnownNewerGap
        self.knownGaps = knownGaps
    }
}

struct ChatArchiveStateMutationPlan: Equatable {
    let resolvedCursorId: String?
    let fullArchiveLoaded: Bool
    let shouldWriteCursor: Bool
    let shouldWriteFullArchiveLoaded: Bool

    var needsWrite: Bool {
        shouldWriteCursor || shouldWriteFullArchiveLoaded
    }
}

struct ChatObserverLookupMaps: Equatable {
    let primaryIndex: [String: Int]
    let archivedIdIndex: [String: Int]
    let messageIdIndex: [String: Int]
    let oldestArchivedId: String?
    let newestArchivedId: String?
}

enum ChatObserverLookupPolicy {
    static func build<T: Sequence>(from items: T) -> ChatObserverLookupMaps where T.Element == MessageStorageItem {
        var primaryIndex: [String: Int] = [:]
        var archivedIdIndex: [String: Int] = [:]
        var messageIdIndex: [String: Int] = [:]
        var oldestArchivedId: String?
        var newestArchivedId: String?

        for (offset, item) in items.enumerated() {
            primaryIndex[item.primary] = offset
            if item.archivedId.isNotEmpty {
                let archivedId = item.archivedId
                archivedIdIndex[archivedId] = offset
                if oldestArchivedId == nil {
                    oldestArchivedId = archivedId
                }
                newestArchivedId = archivedId
            }
            if item.messageId.isNotEmpty {
                messageIdIndex[item.messageId] = offset
            }
        }

        return ChatObserverLookupMaps(
            primaryIndex: primaryIndex,
            archivedIdIndex: archivedIdIndex,
            messageIdIndex: messageIdIndex,
            oldestArchivedId: oldestArchivedId,
            newestArchivedId: newestArchivedId
        )
    }
}

enum ChatUnreadMentionNavigatorMode: Equatable {
    case hidden
    case indicator
}

struct ChatUnreadMentionItem: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let chatPrimary: String
    let authorId: String?
    let date: Date
    let targetMemberId: String?
    let groupchatJid: String
}

struct ChatUnreadMentionNavigationTarget: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let date: Date
    let observerIndex: Int?
}

struct ChatUnreadMentionNavigationRequest: Equatable {
    let target: ChatUnreadMentionNavigationTarget
    let direction: ChatViewController.ChatDirection
}

struct ChatUnreadMentionsState: Equatable {
    static let empty = ChatUnreadMentionsState(
        items: [],
        unreadCount: 0,
        visibleUnreadNotificationPrimaries: Set(),
        currentTarget: nil,
        jumpTarget: nil,
        mode: .hidden
    )

    let items: [ChatUnreadMentionItem]
    let unreadCount: Int
    let visibleUnreadNotificationPrimaries: Set<String>
    let currentTarget: ChatUnreadMentionNavigationTarget?
    let jumpTarget: ChatUnreadMentionNavigationTarget?
    let mode: ChatUnreadMentionNavigatorMode

    var hasUnreadMentions: Bool {
        unreadCount > 0
    }
}

enum ChatUnreadMentionMatcher {
    private static func resolveMessagePrimary(
        for notification: NotificationStorageItem,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm
    ) -> String? {
        if let archivedId = notification.sourceArchivedId,
           archivedId.isNotEmpty,
           let observerIndex = observerLookupMaps.archivedIdIndex[archivedId],
           observerIndex < messagesObserver.count {
            return messagesObserver[observerIndex].primary
        }

        if let messageId = notification.sourceMessageId,
           messageId.isNotEmpty,
           let observerIndex = observerLookupMaps.messageIdIndex[messageId],
           observerIndex < messagesObserver.count {
            return messagesObserver[observerIndex].primary
        }

        return MentionNotificationSync.matchingMessage(for: notification, in: realm)?.primary
    }

    static func unreadMentionItem(
        from notification: NotificationStorageItem,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> ChatUnreadMentionItem? {
        guard notification.isMentionNotification,
              !notification.isRead,
              notification.sourceChatJid == groupchatJid,
              notification.sourceConversationType == nil || notification.sourceConversationType == .group,
              notification.mentionLinkStatus != .invalidated,
              notification.mentionLinkStatus != .missing else {
            return nil
        }

        let archivedId = notification.sourceArchivedId?.isNotEmpty == true ? notification.sourceArchivedId : nil
        let messageId = notification.sourceMessageId?.isNotEmpty == true ? notification.sourceMessageId : nil

        guard archivedId != nil || messageId != nil else {
            return nil
        }

        let targetMemberId = notification.mentionTargetUserId ?? currentMemberId

        if let authorId = notification.sourceSenderId,
           authorId.isNotEmpty,
           let targetMemberId,
           targetMemberId.isNotEmpty,
           authorId == targetMemberId {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: notification.primary,
            messagePrimary: resolveMessagePrimary(
                for: notification,
                messagesObserver: messagesObserver,
                observerLookupMaps: observerLookupMaps,
                in: realm
            ),
            archivedId: archivedId,
            messageId: messageId,
            chatPrimary: chatPrimary,
            authorId: notification.sourceSenderId,
            date: notification.sourceMessageDate ?? notification.date,
            targetMemberId: targetMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionIndexPolicy {
    static func rebuild(
        from notifications: Results<NotificationStorageItem>,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> [ChatUnreadMentionItem] {
        var seenKeys: Set<String> = []
        return notifications.compactMap {
            ChatUnreadMentionMatcher.unreadMentionItem(
                from: $0,
                messagesObserver: messagesObserver,
                observerLookupMaps: observerLookupMaps,
                in: realm,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: groupchatJid
            )
        }.filter {
            let key = $0.archivedId ?? $0.messageId ?? $0.notificationPrimary ?? $0.chatPrimary
            return seenKeys.insert(key).inserted
        }
    }
}

enum ChatUnreadMentionFallbackPolicy {
    static func fallbackItem(
        mentionId: String?,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String,
        date: Date
    ) -> ChatUnreadMentionItem? {
        guard let mentionId,
              mentionId.isNotEmpty else {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: nil,
            messagePrimary: nil,
            archivedId: mentionId,
            messageId: nil,
            chatPrimary: chatPrimary,
            authorId: nil,
            date: date,
            targetMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionNavigationPolicy {
    private static func order(_ lhs: ChatUnreadMentionNavigationTarget, _ rhs: ChatUnreadMentionNavigationTarget) -> Bool {
        if let leftIndex = lhs.observerIndex,
           let rightIndex = rhs.observerIndex,
           leftIndex != rightIndex {
            return leftIndex > rightIndex
        }

        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }

        let leftKey = lhs.archivedId ?? lhs.messageId ?? lhs.notificationPrimary ?? ""
        let rightKey = rhs.archivedId ?? rhs.messageId ?? rhs.notificationPrimary ?? ""
        return leftKey < rightKey
    }

    static func resolveState(
        items: [ChatUnreadMentionItem],
        observerPrimaryIndexMap: [String: Int],
        visiblePrimaries: Set<String>,
        preferredArchivedId: String? = nil,
        selectedNotificationPrimary: String? = nil
    ) -> ChatUnreadMentionsState {
        let targets = items
            .compactMap { item -> ChatUnreadMentionNavigationTarget? in
                return ChatUnreadMentionNavigationTarget(
                    notificationPrimary: item.notificationPrimary,
                    messagePrimary: item.messagePrimary,
                    archivedId: item.archivedId,
                    messageId: item.messageId,
                    authorId: item.authorId,
                    date: item.date,
                    observerIndex: item.messagePrimary.flatMap { observerPrimaryIndexMap[$0] }
                )
            }
            .sorted(by: order)

        guard !targets.isEmpty else {
            return .empty
        }

        let visibleUnreadNotificationPrimaries = Set<String>(targets.compactMap { target in
            guard let messagePrimary = target.messagePrimary,
                  visiblePrimaries.contains(messagePrimary) else {
                return nil
            }
            return target.notificationPrimary
        })

        let preferredHintTarget = preferredArchivedId.flatMap { archivedId in
            targets.first(where: { $0.archivedId == archivedId })
        }

        let selectedTarget = selectedNotificationPrimary.flatMap { notificationPrimary in
            targets.first(where: { $0.notificationPrimary == notificationPrimary })
        }

        let visibleTarget = targets.first(where: { target in
            guard let messagePrimary = target.messagePrimary else {
                return false
            }
            return visiblePrimaries.contains(messagePrimary)
        })

        let currentTarget = selectedTarget ?? visibleTarget ?? preferredHintTarget ?? targets.first
        let jumpTarget: ChatUnreadMentionNavigationTarget?

        if let visibleTarget,
           let visibleIndex = targets.firstIndex(where: { $0.notificationPrimary == visibleTarget.notificationPrimary }),
           (visibleIndex + 1) < targets.count {
            jumpTarget = targets[visibleIndex + 1]
        } else {
            jumpTarget = currentTarget
        }

        let mode: ChatUnreadMentionNavigatorMode = .indicator

        return ChatUnreadMentionsState(
            items: items,
            unreadCount: targets.count,
            visibleUnreadNotificationPrimaries: visibleUnreadNotificationPrimaries,
            currentTarget: currentTarget,
            jumpTarget: jumpTarget,
            mode: mode
        )
    }
}

enum ChatUnreadMentionFloatingControlPolicy {
    static func shouldShowNavigator(
        conversationType: ClientSynchronizationManager.ConversationType,
        unreadCount: Int,
        isSearchMode: Bool
    ) -> Bool {
        conversationType == .group && unreadCount > 0 && !isSearchMode
    }

    static func shouldShowScrollDownButton(
        requested: Bool,
        navigatorVisible _: Bool
    ) -> Bool {
        requested
    }
}

enum ChatArchiveStateMutationPolicy {
    static func resolveCursorId(
        direction: ChatHistoryPageDirection,
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        currentPersistedCursorId: String?,
        hasPersistenceProof: Bool
    ) -> String? {
        let currentCursorId = currentPersistedCursorId?.isNotEmpty == true ? currentPersistedCursorId : nil
        let observedCursorId = observedCursorId?.isNotEmpty == true ? observedCursorId : nil
        if direction == .older,
           hasPersistenceProof {
            let transportCursorId = MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: transportFirst,
                last: transportLast,
                current: currentCursorId
            )
            if let transportCursorId, transportCursorId.isNotEmpty {
                return transportCursorId
            }
        }

        let resolvedCursorId = observedCursorId ?? currentCursorId
        guard let resolvedCursorId, resolvedCursorId.isNotEmpty else {
            return nil
        }
        return resolvedCursorId
    }

    static func resolveCursorId(
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        currentPersistedCursorId: String?
    ) -> String? {
        let currentCursorId = currentPersistedCursorId?.isNotEmpty == true ? currentPersistedCursorId : nil
        let observedCursorId = observedCursorId?.isNotEmpty == true ? observedCursorId : nil
        let fallbackCursorId = MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
            purpose: .pageOlder,
            first: transportFirst,
            last: transportLast,
            current: currentCursorId
        )
        let resolvedCursorId = observedCursorId ?? currentCursorId ?? fallbackCursorId
        guard let resolvedCursorId, resolvedCursorId.isNotEmpty else {
            return nil
        }
        return resolvedCursorId
    }

    static func resolvePlan(
        snapshot: ChatArchiveStateSnapshot,
        resolvedCursorId: String?,
        nextFullArchiveLoaded: Bool
    ) -> ChatArchiveStateMutationPlan {
        let currentCursorId = snapshot.persistedCursorId?.isNotEmpty == true ? snapshot.persistedCursorId : nil
        return ChatArchiveStateMutationPlan(
            resolvedCursorId: resolvedCursorId,
            fullArchiveLoaded: nextFullArchiveLoaded,
            shouldWriteCursor: resolvedCursorId != nil && resolvedCursorId != currentCursorId,
            shouldWriteFullArchiveLoaded: snapshot.fullArchiveLoaded != nextFullArchiveLoaded
        )
    }
}

enum ChatArchiveEndVerificationPolicy {
    static func shouldProbePersistedArchiveEnd(
        persistedArchiveEnded: Bool,
        hasConfirmedArchiveEndThisSession: Bool,
        hasUsedVerificationProbe: Bool
    ) -> Bool {
        persistedArchiveEnded &&
        !hasConfirmedArchiveEndThisSession &&
        !hasUsedVerificationProbe
    }

    static func effectiveArchiveEnded(
        persistedArchiveEnded: Bool,
        shouldProbePersistedArchiveEnd: Bool
    ) -> Bool {
        persistedArchiveEnded && !shouldProbePersistedArchiveEnd
    }
}

enum ChatHistoryCursorSelectionPolicy {
    static func oldestCursorId(
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> String? {
        if let observedCursorId = observedArchivedIds.first(where: { $0.isNotEmpty }) {
            return observedCursorId
        }

        guard let persistedCursorId, persistedCursorId.isNotEmpty else {
            return nil
        }
        return persistedCursorId
    }

    static func newestCursorId(
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> String? {
        if let observedCursorId = observedArchivedIds.reversed().first(where: { $0.isNotEmpty }) {
            return observedCursorId
        }

        guard let persistedCursorId, persistedCursorId.isNotEmpty else {
            return nil
        }
        return persistedCursorId
    }
}

enum ChatInteractiveOlderCursorSelectionSource: String {
    case virtualTimelineOldest
    case boundedTimelineOldest
    case observedOldest
    case persistedArchiveCursor
    case persistedFallback
    case none
}

struct ChatInteractiveOlderCursorSelection: Equatable {
    let cursorId: String?
    let source: ChatInteractiveOlderCursorSelectionSource
}

enum ChatInteractiveOlderCursorSelectionPolicy {
    static func select(
        timelineOldestArchivedId: String?,
        boundedOldestArchivedId: String?,
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> ChatInteractiveOlderCursorSelection {
        let persistedCursorId = persistedCursorId?.isNotEmpty == true ? persistedCursorId : nil
        let activeSelection: ChatInteractiveOlderCursorSelection?

        if let timelineOldestArchivedId,
           timelineOldestArchivedId.isNotEmpty {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: timelineOldestArchivedId,
                source: .virtualTimelineOldest
            )
        } else if let boundedOldestArchivedId,
                  boundedOldestArchivedId.isNotEmpty {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: boundedOldestArchivedId,
                source: .boundedTimelineOldest
            )
        } else if let observedOldestArchivedId = observedArchivedIds.first(where: { $0.isNotEmpty }) {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: observedOldestArchivedId,
                source: .observedOldest
            )
        } else {
            activeSelection = nil
        }

        if let persistedCursorId,
           let activeCursorId = activeSelection?.cursorId,
           compareArchiveIds(persistedCursorId, activeCursorId) == .orderedAscending {
            return ChatInteractiveOlderCursorSelection(
                cursorId: persistedCursorId,
                source: .persistedArchiveCursor
            )
        }

        if let activeSelection {
            return activeSelection
        }

        if let persistedCursorId {
            return ChatInteractiveOlderCursorSelection(
                cursorId: persistedCursorId,
                source: .persistedFallback
            )
        }

        return ChatInteractiveOlderCursorSelection(cursorId: nil, source: .none)
    }
}

enum ChatHistoryPagingPolicy {
    private static func boundaryAvailability(
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> (olderVisible: Bool, newerVisible: Bool) {
        let minVisibleSection = boundaryContext.visibleRealSections.min()
        let maxVisibleSection = boundaryContext.visibleRealSections.max()
        let hasLocalOlderPage = currentPageMinIndex > 0 || hasLocalOlderAvailable
        let hasLocalNewerPage = currentPageMaxIndex < totalCount || hasLocalNewerAvailable
        let allowsRemoteBoundaryPaging = !suppressRemoteBoundaryPaging && !boundaryContext.isEntireRealRangeVisible
        let hasOlderAvailable = hasLocalOlderPage || (allowsRemoteBoundaryPaging && hasRemoteOlderAvailable)
        let hasNewerAvailable = hasLocalNewerPage || (allowsRemoteBoundaryPaging && hasRemoteNewerAvailable)

        let olderVisible = hasOlderAvailable && (minVisibleSection.flatMap { visibleSection in
            boundaryContext.firstRealSection.map { visibleSection <= $0 }
        } ?? false)
        let newerVisible = hasNewerAvailable && (maxVisibleSection.flatMap { visibleSection in
            boundaryContext.lastRealSection.map { visibleSection >= $0 }
        } ?? false)

        return (olderVisible, newerVisible)
    }

    private static func directionForBoundaryDrag(
        gestureTranslationY: CGFloat,
        boundary: (olderVisible: Bool, newerVisible: Bool)
    ) -> ChatHistoryPageDirection? {
        switch boundary {
        case (true, false):
            return .older
        case (false, true):
            return .newer
        case (true, true):
            if gestureTranslationY > 0 {
                return .older
            }
            if gestureTranslationY < 0 {
                return .newer
            }
            return nil
        case (false, false):
            return nil
        }
    }

    static func triggerDirection(
        isUserScrolling: Bool,
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard isUserScrolling,
              canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasLocalOlderAvailable: hasLocalOlderAvailable,
            hasLocalNewerAvailable: hasLocalNewerAvailable,
            hasRemoteOlderAvailable: hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable,
            suppressRemoteBoundaryPaging: suppressRemoteBoundaryPaging
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }

    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow,
        requestedWindow: ChatDatasetWindow,
        localWindow: ChatDatasetWindow,
        totalCount: Int,
        isArchiveEnded: Bool,
        hasKnownNewerGap: Bool = false,
        newerLiveEdgeReached: Bool = true
    ) -> ChatHistoryPagingLoadDecision {
        switch direction {
        case .newer:
            guard requestedWindow.maxIndex > totalCount || localWindow.maxIndex < requestedWindow.maxIndex else {
                return .localOnly
            }
            return (hasKnownNewerGap || !newerLiveEdgeReached) ? .remoteNewerPage : .endReached
        case .older:
            if localWindow.minIndex < currentWindow.minIndex {
                let localOlderCount = currentWindow.minIndex - localWindow.minIndex
                let requestedOlderCount = currentWindow.minIndex - requestedWindow.minIndex
                if ChatShortLocalOlderRemainderPolicy.shouldRequestRemoteFirst(
                    localOlderCount: localOlderCount,
                    pageSize: requestedOlderCount,
                    archiveEnded: isArchiveEnded
                ) {
                    return .remoteOlderPage
                }
                return .localOnly
            }
            guard requestedWindow.minIndex < 0 else {
                return .localOnly
            }
            return isArchiveEnded ? .endReached : .remoteOlderPage
        }
    }

    static func fallbackDirectionForShortContentDrag(
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasLocalOlderAvailable: hasLocalOlderAvailable,
            hasLocalNewerAvailable: hasLocalNewerAvailable,
            hasRemoteOlderAvailable: hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable,
            suppressRemoteBoundaryPaging: suppressRemoteBoundaryPaging
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }
}

enum ChatArchiveGapPagingPolicy {
    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow,
        requestedWindow: ChatDatasetWindow,
        archivedIdsByIndex: [String?],
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatHistoryPagingLoadDecision? {
        guard knownGaps.isNotEmpty else {
            return nil
        }

        let currentArchiveIds = archiveIds(in: currentWindow, archivedIdsByIndex: archivedIdsByIndex)
        let requestedArchiveIds = archiveIds(in: requestedWindow, archivedIdsByIndex: archivedIdsByIndex)
        guard currentArchiveIds.isNotEmpty,
              requestedArchiveIds.isNotEmpty else {
            return nil
        }

        switch direction {
        case .older:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.newerRangeOldestArchiveId, $1.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedDescending
            }
            return sortedGaps.first(where: { gap in
                containsNewerSide(of: gap, in: currentArchiveIds) &&
                containsOlderSide(of: gap, in: requestedArchiveIds)
            }).map { .remoteGapRepairOlder($0) }
        case .newer:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.olderRangeNewestArchiveId, $1.olderRangeNewestArchiveId) ?? .orderedAscending) == .orderedAscending
            }
            return sortedGaps.first(where: { gap in
                containsOlderSide(of: gap, in: currentArchiveIds) &&
                containsNewerSide(of: gap, in: requestedArchiveIds)
            }).map { .remoteGapRepairNewer($0) }
        }
    }

    private static func archiveIds(
        in window: ChatDatasetWindow,
        archivedIdsByIndex: [String?]
    ) -> [String] {
        guard archivedIdsByIndex.isNotEmpty else {
            return []
        }
        let minIndex = max(0, window.minIndex)
        let maxIndex = min(archivedIdsByIndex.count, window.maxIndex)
        guard minIndex < maxIndex else {
            return []
        }
        return archivedIdsByIndex[minIndex..<maxIndex].compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0)
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        }
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        }
    }
}

enum ChatArchiveBoundaryGapPagingPolicy {
    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentOldestArchiveId: String?,
        currentNewestArchiveId: String?,
        requestedOldestArchiveId: String?,
        requestedNewestArchiveId: String?,
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatHistoryPagingLoadDecision? {
        guard knownGaps.isNotEmpty,
              let currentOldestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(currentOldestArchiveId),
              let currentNewestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(currentNewestArchiveId),
              let requestedOldestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(requestedOldestArchiveId),
              let requestedNewestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(requestedNewestArchiveId) else {
            return nil
        }

        switch direction {
        case .older:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.newerRangeOldestArchiveId, $1.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedDescending
            }
            return sortedGaps.first(where: { gap in
                containsNewerSide(of: gap, oldest: currentOldestArchiveId, newest: currentNewestArchiveId) &&
                crossesBelowNewerBoundary(of: gap, oldest: requestedOldestArchiveId, newest: requestedNewestArchiveId)
            }).map { .remoteGapRepairOlder($0) }
        case .newer:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.olderRangeNewestArchiveId, $1.olderRangeNewestArchiveId) ?? .orderedAscending) == .orderedAscending
            }
            return sortedGaps.first(where: { gap in
                containsOlderSide(of: gap, oldest: currentOldestArchiveId, newest: currentNewestArchiveId) &&
                crossesAboveOlderBoundary(of: gap, oldest: requestedOldestArchiveId, newest: requestedNewestArchiveId)
            }).map { .remoteGapRepairNewer($0) }
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let newestIsOlderSide = (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let spansOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsOlderSide || newestIsOlderSide || spansOlderSide
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let newestIsNewerSide = (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let spansNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsNewerSide || newestIsNewerSide || spansNewerSide
    }

    private static func crossesBelowNewerBoundary(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsBelowNewerBoundary = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedAscending
        let newestIsBelowNewerBoundary = (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedAscending
        let spansNewerBoundary = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsBelowNewerBoundary || newestIsBelowNewerBoundary || spansNewerBoundary
    }

    private static func crossesAboveOlderBoundary(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsAboveOlderBoundary = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) == .orderedDescending
        let newestIsAboveOlderBoundary = (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) == .orderedDescending
        let spansOlderBoundary = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsAboveOlderBoundary || newestIsAboveOlderBoundary || spansOlderBoundary
    }
}

enum ChatBootstrapViewState: Equatable {
    case skeleton
    case content
    case empty

    static func resolve(
        messageCount: Int,
        isSynced: Bool,
        isInitialArchiveLoaded: Bool = true,
        isInitialBootstrapInFlight: Bool,
        hasPendingInitialAnchorRequest: Bool,
        allowsStaleLocalHistory: Bool = false
    ) -> ChatBootstrapViewState {
        if hasPendingInitialAnchorRequest {
            return .skeleton
        }
        if isInitialBootstrapInFlight {
            return messageCount > 0 ? .content : .skeleton
        }
        if allowsStaleLocalHistory && messageCount > 0 {
            return .content
        }
        if !isSynced {
            return .skeleton
        }
        if !isInitialArchiveLoaded {
            return .skeleton
        }
        if messageCount > 0 {
            return .content
        }
        return .empty
    }
}

enum ChatInitialBootstrapContentRevealPolicy {
    static func shouldRevealContent(
        isShowingSkeleton: Bool,
        bootstrapState: ChatBootstrapViewState
    ) -> Bool {
        isShowingSkeleton && bootstrapState == .content
    }
}

enum ChatInitialBootstrapFailureRecoveryPolicy {
    static func shouldRevealLocalHistory(
        messageCount: Int,
        hasPendingInitialAnchorRequest: Bool
    ) -> Bool {
        messageCount > 0 && !hasPendingInitialAnchorRequest
    }
}

enum ChatBootstrapLocalHistoryFallbackPolicy {
    static let fallbackDelay: TimeInterval = 0.25

    static func shouldScheduleFallback(
        messageCount: Int,
        isShowingSkeleton: Bool,
        allowsStaleLocalHistory: Bool,
        hasPendingInitialAnchorRequest: Bool,
        isRequiredArchiveBootstrapInFlight: Bool = false
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !allowsStaleLocalHistory &&
        !hasPendingInitialAnchorRequest &&
        !isRequiredArchiveBootstrapInFlight
    }

    static func shouldRevealLocalHistory(
        messageCount: Int,
        isShowingSkeleton: Bool,
        hasPendingInitialAnchorRequest: Bool,
        isRequiredArchiveBootstrapInFlight: Bool = false
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !hasPendingInitialAnchorRequest &&
        !isRequiredArchiveBootstrapInFlight
    }
}

enum ChatBootstrapSkeletonRenderPolicy {
    static func shouldRenderSkeletonDatasource(
        forceRender: Bool,
        isDatasourceEmpty: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        forceRender || isDatasourceEmpty || !isShowingBootstrapPlaceholder
    }
}

enum ChatFirstFrameLocalHistoryPolicy {
    static func shouldApplySynchronously(
        bootstrapState: ChatBootstrapViewState,
        localMessageCount: Int,
        isShowingBootstrapPlaceholder: Bool,
        hasPendingOpenMessageRequest: Bool,
        hasPendingInitialAnchorRequest: Bool
    ) -> Bool {
        bootstrapState == .content &&
        localMessageCount > 0 &&
        isShowingBootstrapPlaceholder &&
        !hasPendingOpenMessageRequest &&
        !hasPendingInitialAnchorRequest
    }
}

enum ChatInitialLatestOpenStabilizationState: Equatable {
    case inactive
    case active
    case bottomAligned
}

enum ChatInitialLatestOpenStabilizationPolicy {
    enum ObserverRefreshAction: Equatable {
        case followDefault
        case keepCurrentNoScroll
        case openLatestNonAnimated
    }

    static func shouldStart(forceLatestOpen: Bool) -> Bool {
        forceLatestOpen
    }

    static func stateAfterBottomAlignment(
        current: ChatInitialLatestOpenStabilizationState,
        hasRealMessages: Bool
    ) -> ChatInitialLatestOpenStabilizationState {
        guard hasRealMessages else {
            return current
        }

        switch current {
        case .inactive:
            return .inactive
        case .active, .bottomAligned:
            return .bottomAligned
        }
    }

    static func shouldComplete(
        state: ChatInitialLatestOpenStabilizationState,
        hasViewAppeared: Bool
    ) -> Bool {
        state == .bottomAligned && hasViewAppeared
    }

    static func shouldSkipForcedContentRender(
        state: ChatInitialLatestOpenStabilizationState,
        forceRender: Bool,
        hasRealDatasource: Bool,
        newestLocalPrimary: String?,
        datasourceNewestPrimary: String?
    ) -> Bool {
        guard state != .inactive,
              forceRender,
              hasRealDatasource,
              let newestLocalPrimary,
              let datasourceNewestPrimary else {
            return false
        }

        return newestLocalPrimary == datasourceNewestPrimary
    }

    static func observerRefreshAction(
        state: ChatInitialLatestOpenStabilizationState,
        baseShouldOpenLatest: Bool,
        newestLocalPrimary: String?,
        datasourceNewestPrimary: String?
    ) -> ObserverRefreshAction {
        guard state != .inactive,
              baseShouldOpenLatest,
              let newestLocalPrimary,
              let datasourceNewestPrimary else {
            return .followDefault
        }

        return newestLocalPrimary == datasourceNewestPrimary ? .keepCurrentNoScroll : .openLatestNonAnimated
    }

    static func shouldAnimateAuxiliaryUpdate(
        state: ChatInitialLatestOpenStabilizationState,
        requestedAnimated: Bool
    ) -> Bool {
        requestedAnimated && state == .inactive
    }
}

enum ChatObserverRefreshBackpressureAction: Equatable {
    case applyImmediately
    case scheduleCoalesced
    case keepCoalesced
    case deferUntilScrollRest
}

enum ChatObserverRefreshFlushAction: Equatable {
    case none
    case keepPending
    case flush
}

enum ChatObserverRefreshBackpressurePolicy {
    static let coalescingDelay: TimeInterval = 0.18

    static func action(
        isShowingBootstrapPlaceholder: Bool,
        isHistoryPressureActive: Bool,
        motionState: ChatScrollMotionState,
        hasScheduledRefresh: Bool
    ) -> ChatObserverRefreshBackpressureAction {
        guard !isShowingBootstrapPlaceholder,
              isHistoryPressureActive else {
            return .applyImmediately
        }

        if motionState.isMoving {
            return .deferUntilScrollRest
        }

        return hasScheduledRefresh ? .keepCoalesced : .scheduleCoalesced
    }

    static func flushAction(
        hasPendingRefresh: Bool,
        motionState: ChatScrollMotionState
    ) -> ChatObserverRefreshFlushAction {
        guard hasPendingRefresh else {
            return .none
        }

        return motionState.isMoving ? .keepPending : .flush
    }
}

enum ChatInitialHistoryAppearancePolicy {
    static func shouldStart(isShowingBootstrapPlaceholder: Bool) -> Bool {
        isShowingBootstrapPlaceholder
    }

    static func shouldFinish(itemCount: Int, containsOnlyFakeMessages: Bool) -> Bool {
        itemCount == 0 || !containsOnlyFakeMessages
    }

    static func shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: Bool) -> Bool {
        !isInitialHistoryAppearancePending
    }

    static func shouldUseReloadFallbackForTargetedDiff(animated: Bool) -> Bool {
        !animated
    }

    static func shouldApplyFollowupChangesetAfterBootstrapReload(didReloadInitialWindow: Bool) -> Bool {
        !didReloadInitialWindow
    }

    static func shouldCompleteInitialAppearance(hasViewAppeared: Bool, hasRenderedStableHistory: Bool) -> Bool {
        hasViewAppeared && hasRenderedStableHistory
    }

    static func shouldForceNonAnimatedApplyForInitialPopulation(oldItemCount: Int, newItemCount: Int) -> Bool {
        oldItemCount == 0 && newItemCount > 0
    }
}

enum ChatFirstFrameAuxiliaryWorkDecision: Equatable {
    case runImmediately
    case deferUntilPostVisible
}

enum ChatFirstFrameAuxiliaryWorkPolicy {
    static func datasourceApplyDecision(
        isInitialHistoryAppearancePending: Bool,
        containsRealMessages: Bool,
        containsOnlyFakeMessages: Bool
    ) -> ChatFirstFrameAuxiliaryWorkDecision {
        guard isInitialHistoryAppearancePending,
              containsRealMessages,
              !containsOnlyFakeMessages else {
            return .runImmediately
        }

        return .deferUntilPostVisible
    }

    static func shouldRunDeferredFlush(
        hasPendingRefresh: Bool,
        hasViewAppeared: Bool,
        didLogFirstMessagesVisible: Bool
    ) -> Bool {
        hasPendingRefresh && (hasViewAppeared || didLogFirstMessagesVisible)
    }

    static func shouldScheduleDeferredFlush(
        hasPendingRefresh: Bool,
        isFlushScheduled: Bool,
        hasViewAppeared: Bool,
        didLogFirstMessagesVisible: Bool
    ) -> Bool {
        !isFlushScheduled && shouldRunDeferredFlush(
            hasPendingRefresh: hasPendingRefresh,
            hasViewAppeared: hasViewAppeared,
            didLogFirstMessagesVisible: didLogFirstMessagesVisible
        )
    }

    static func shouldCancelPendingRefreshOnDisappear(hasPendingRefresh: Bool) -> Bool {
        hasPendingRefresh
    }
}

enum ChatFirstFrameLatestWarmupState: Equatable {
    case inactive
    case armed
    case inFlight
    case completed
}

enum ChatFirstFrameLatestWarmupPolicy {
    static func shouldArm(
        appliedRealMessageCount: Int,
        availableLocalMessageCount: Int,
        initialLimit: Int,
        normalLimit: Int,
        isResidentAtLiveTail: Bool,
        hasPendingAnchorRequest: Bool,
        hasActiveAnchorExecution: Bool
    ) -> Bool {
        guard initialLimit > 0,
              initialLimit < normalLimit,
              appliedRealMessageCount > 0,
              isResidentAtLiveTail,
              !hasPendingAnchorRequest,
              !hasActiveAnchorExecution else {
            return false
        }

        let warmupTarget = min(availableLocalMessageCount, normalLimit)
        return appliedRealMessageCount < warmupTarget
    }

    static func shouldRun(
        state: ChatFirstFrameLatestWarmupState,
        currentRealMessageCount: Int,
        normalLimit: Int,
        isResidentAtLiveTail: Bool,
        hasPendingAnchorRequest: Bool,
        hasActiveAnchorExecution: Bool,
        hasViewAppeared: Bool,
        didLogFirstMessagesVisible: Bool
    ) -> Bool {
        guard state == .armed,
              currentRealMessageCount > 0,
              currentRealMessageCount < normalLimit,
              isResidentAtLiveTail,
              !hasPendingAnchorRequest,
              !hasActiveAnchorExecution else {
            return false
        }

        return hasViewAppeared || didLogFirstMessagesVisible
    }
}

enum ChatStackedNavigationPreparationPolicy {
    static func shouldLoadInitialDatasource(
        isDatasourceEmpty: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        isDatasourceEmpty || isShowingBootstrapPlaceholder
    }
}

enum ChatSavedPositionFirstFrameDecision: Equatable {
    case standardContent
    case savedPosition(anchorIndex: Int, window: ChatDatasetWindow)
}

enum ChatSavedPositionFirstFramePolicy {
    static func shouldApplySynchronously(
        bootstrapState: ChatBootstrapViewState,
        isShowingBootstrapPlaceholder: Bool,
        decision: ChatSavedPositionFirstFrameDecision
    ) -> Bool {
        guard bootstrapState == .content,
              isShowingBootstrapPlaceholder,
              case .savedPosition = decision else {
            return false
        }
        return true
    }

    static func decision(
        requestSource: ChatOpenMessageRequestSource?,
        isSynced: Bool,
        observerCount: Int,
        localAnchorIndex: Int?,
        pageSize: Int,
        isPageUnlocked: Bool = true,
        archivedIdsByIndex: [Int: String] = [:],
        knownGaps: [RegularChatArchiveGap] = []
    ) -> ChatSavedPositionFirstFrameDecision {
        guard requestSource == .savedVisiblePosition,
              isSynced,
              isPageUnlocked,
              observerCount > 0,
              let localAnchorIndex,
              localAnchorIndex >= 0,
              localAnchorIndex < observerCount else {
            return .standardContent
        }

        let window = ChatDatasetCoordinator(pageSize: pageSize)
            .replacementWindow(around: localAnchorIndex, totalCount: observerCount)
        guard !windowCrossesKnownGap(window, archivedIdsByIndex: archivedIdsByIndex, knownGaps: knownGaps) else {
            return .standardContent
        }
        return .savedPosition(anchorIndex: localAnchorIndex, window: window)
    }

    private static func windowCrossesKnownGap(
        _ window: ChatDatasetWindow,
        archivedIdsByIndex: [Int: String],
        knownGaps: [RegularChatArchiveGap]
    ) -> Bool {
        guard !archivedIdsByIndex.isEmpty,
              knownGaps.isNotEmpty else {
            return false
        }

        let archiveIds = archiveIds(in: window, archivedIdsByIndex: archivedIdsByIndex)
        guard archiveIds.isNotEmpty else {
            return false
        }

        return knownGaps.contains { gap in
            containsOlderSide(of: gap, in: archiveIds) &&
            containsNewerSide(of: gap, in: archiveIds)
        }
    }

    private static func archiveIds(
        in window: ChatDatasetWindow,
        archivedIdsByIndex: [Int: String]
    ) -> [String] {
        guard window.minIndex < window.maxIndex else {
            return []
        }

        return (window.minIndex..<window.maxIndex).compactMap { index in
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedIdsByIndex[index])
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        }
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        }
    }
}

enum ChatSavedPositionFirstFrameCompletionAction: Equatable {
    case finishRequest
    case recoverPendingRequest
}

enum ChatSavedPositionFirstFrameCompletionPolicy {
    static func mappingCancellationAction(
        requestSource: ChatOpenMessageRequestSource
    ) -> ChatSavedPositionFirstFrameCompletionAction {
        requestSource == .savedVisiblePosition ? .recoverPendingRequest : .finishRequest
    }

    static func renderedWindowAction(
        requestSource: ChatOpenMessageRequestSource,
        targetExistsInSnapshot: Bool
    ) -> ChatSavedPositionFirstFrameCompletionAction {
        guard requestSource == .savedVisiblePosition else {
            return .finishRequest
        }

        return targetExistsInSnapshot ? .finishRequest : .recoverPendingRequest
    }
}

enum ChatBootstrapContentRenderPolicy {
    static func shouldReloadInitialWindow(
        forceRender: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        forceRender || isShowingBootstrapPlaceholder
    }
}

enum ChatDatasourceApplyMode {
    case fullReload(keepOffset: Bool = false)
    case windowReload(keepOffset: Bool = false)
    case targetedDiff
}

enum ChatBottomAlignmentTarget: Equatable {
    case newestRealMessage
    case message(ChatMessageAnchorRef)
}

enum ChatBottomAlignmentTargetPolicy {
    static func indexPath(
        for target: ChatBottomAlignmentTarget,
        in items: [ChatViewController.Datasource]
    ) -> IndexPath? {
        guard let section = section(for: target, in: items) else {
            return nil
        }
        return IndexPath(item: 0, section: section)
    }

    static func section(
        for target: ChatBottomAlignmentTarget,
        in items: [ChatViewController.Datasource]
    ) -> Int? {
        switch target {
        case .newestRealMessage:
            return newestRealMessageSection(in: items)
        case .message(let anchor):
            return ChatLoadedMessageNavigationPolicy.index(in: items, for: anchor)
        }
    }

    private static func newestRealMessageSection(
        in items: [ChatViewController.Datasource]
    ) -> Int? {
        items
            .enumerated()
            .reversed()
            .first { _, item in
                isRealMessage(item)
            }?
            .offset
    }

    private static func isRealMessage(_ item: ChatViewController.Datasource) -> Bool {
        guard !item.isFakeMessage else {
            return false
        }

        switch item.kind {
        case .date(_), .unread(_), .initial(_), .skeleton(_):
            return false
        default:
            return true
        }
    }
}

struct ChatOutgoingAutoScrollRequest: Equatable {
    let previousNewestPrimary: String?
}

enum ChatOutgoingAutoScrollDecision: Equatable {
    case notHandled
    case useDefaultAndClear
    case handledNoScroll
    case scroll(IndexPath)

    var consumesPendingRequest: Bool {
        switch self {
        case .useDefaultAndClear, .handledNoScroll, .scroll:
            return true
        case .notHandled:
            return false
        }
    }
}

enum ChatOutgoingAutoScrollPolicy {
    static func newestRealMessage(
        in items: [ChatViewController.Datasource]
    ) -> (index: Int, item: ChatViewController.Datasource)? {
        items
            .enumerated()
            .reversed()
            .first { !$0.element.isFakeMessage }
            .map { (index: $0.offset, item: $0.element) }
    }

    static func didInsertLocalOutgoingRow(
        request: ChatOutgoingAutoScrollRequest?,
        items: [ChatViewController.Datasource]
    ) -> Bool {
        guard let request,
              let newest = newestRealMessage(in: items),
              newest.item.primary != request.previousNewestPrimary else {
            return false
        }

        return newest.item.isOutgoing
    }

    static func decision(
        request: ChatOutgoingAutoScrollRequest?,
        items: [ChatViewController.Datasource],
        isAnchorNavigationActive: Bool
    ) -> ChatOutgoingAutoScrollDecision {
        guard let request else {
            return .notHandled
        }
        guard !isAnchorNavigationActive else {
            return .handledNoScroll
        }
        guard let newest = newestRealMessage(in: items) else {
            return .notHandled
        }
        guard newest.item.primary != request.previousNewestPrimary else {
            return .notHandled
        }
        guard newest.item.isOutgoing else {
            return .useDefaultAndClear
        }

        let newestIndexPath = IndexPath(item: 0, section: newest.index)
        return .scroll(newestIndexPath)
    }
}

enum ChatOutgoingAutoScrollApplyPolicy {
    static func shouldUseImmediateReload(
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        switch outgoingAutoScrollDecision {
        case .scroll:
            return true
        case .notHandled, .useDefaultAndClear, .handledNoScroll:
            return false
        }
    }

    static func shouldAnimateStructuralApply(
        requestedAnimated: Bool,
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        guard requestedAnimated else {
            return false
        }

        switch outgoingAutoScrollDecision {
        case .scroll:
            return false
        case .notHandled, .useDefaultAndClear, .handledNoScroll:
            return true
        }
    }
}

enum ChatTailAppendBottomPinPolicy {
    static func isPureTailAppend(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot
    ) -> Bool {
        guard !old.items.isEmpty,
              new.items.count > old.items.count,
              !old.hasDuplicateKeys,
              !new.hasDuplicateKeys else {
            return false
        }

        for index in old.items.indices {
            let oldItem = old.items[index]
            let newItem = new.items[index]
            guard oldItem.primary == newItem.primary,
                  ChatViewController.Datasource.compareContent(oldItem, newItem) else {
                return false
            }
        }

        return new.items.dropFirst(old.items.count).contains { !$0.isFakeMessage }
    }

    static func shouldPinBottom(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot,
        wasNearBottom: Bool,
        isDefaultBottomScrollDeferred: Bool,
        suppressDefaultBottomScroll: Bool,
        containsOnlyFakeMessages: Bool,
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        guard wasNearBottom,
              !isDefaultBottomScrollDeferred,
              !suppressDefaultBottomScroll,
              !containsOnlyFakeMessages else {
            return false
        }

        switch outgoingAutoScrollDecision {
        case .notHandled, .useDefaultAndClear:
            return isPureTailAppend(old: old, new: new)
        case .scroll, .handledNoScroll:
            return false
        }
    }

    static func bottomDistance(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        contentInsets: UIEdgeInsets,
        contentOffsetY: CGFloat
    ) -> CGFloat {
        max(0, contentHeight + contentInsets.bottom - viewportHeight - contentOffsetY)
    }
}

struct ChatDatasetApplyPlan {
    let window: ChatDatasetWindow
    let mode: ChatDatasourceApplyMode
    let invalidateLayout: Bool
}

struct ChatMessageContentUpdate: Equatable {
    let primary: String
    let indexPath: IndexPath
}

enum ChatMessageUpdateClassification: Equatable {
    case contentOnly
    case layout
}

struct ChatMessageLayoutSignature: Equatable {
    enum CellKind: Equatable {
        case text
        case system
        case sticker
        case initial
    }

    enum MessageKindKey: Equatable {
        case attributedText
        case emoji
        case sticker(String)
        case call(String)
        case system
        case initial
        case skeleton
        case date
        case unread
    }

    let cellKind: CellKind
    let messageKindKey: MessageKindKey
    let isOutgoing: Bool
    let withAuthor: Bool
    let withAvatar: Bool
    let tailed: Bool
    let hasIndicator: Bool
    let messageWarningText: String?
    let images: [String]
    let videos: [String]
    let locations: [String]
    let contacts: [String]
    let files: [String]
    let audios: [String]
    let forwards: [ForwardSignature]

    struct ForwardSignature: Equatable {
        let primary: String
        let isOutgoing: Bool
        let images: [String]
        let videos: [String]
        let locations: [String]
        let contacts: [String]
        let files: [String]
        let audios: [String]
        let subforwards: [ForwardSignature]

        init(_ attachment: MessageAttachment) {
            self.primary = attachment.primary
            self.isOutgoing = attachment.outgoing
            self.images = attachment.images.map(\.primary)
            self.videos = attachment.videos.map(\.primary)
            self.locations = attachment.locations.map(\.primary)
            self.contacts = attachment.contacts.map(\.primary)
            self.files = attachment.files.map(\.primary)
            self.audios = attachment.audios.map(\.primary)
            self.subforwards = attachment.subforwards.map(ForwardSignature.init)
        }
    }

    init(_ message: ChatViewController.Datasource) {
        self.cellKind = Self.cellKind(for: message.kind)
        self.messageKindKey = Self.messageKindKey(for: message.kind)
        self.isOutgoing = message.isOutgoing
        self.withAuthor = message.withAuthor
        self.withAvatar = message.withAvatar
        self.tailed = message.tailed
        self.hasIndicator = message.indicator != .none
        self.messageWarningText = message.messageWarningText
        self.images = message.images.map(\.primary)
        self.videos = message.videos.map(\.primary)
        self.locations = message.locations.map(\.primary)
        self.contacts = message.contacts.map(\.primary)
        self.files = message.files.map(\.primary)
        self.audios = message.audios.map(\.primary)
        self.forwards = message.forwards.map(ForwardSignature.init)
    }

    private static func cellKind(for kind: MessageKind) -> CellKind {
        switch kind {
        case .attributedText, .emoji, .skeleton:
            return .text
        case .system, .date, .unread, .call:
            return .system
        case .sticker:
            return .sticker
        case .initial:
            return .initial
        }
    }

    private static func messageKindKey(for kind: MessageKind) -> MessageKindKey {
        switch kind {
        case .attributedText:
            return .attributedText
        case .emoji:
            return .emoji
        case .sticker(let attachment):
            return .sticker(attachment.primary)
        case .call(let attachment):
            return .call(attachment.primary)
        case .system:
            return .system
        case .initial:
            return .initial
        case .skeleton:
            return .skeleton
        case .date:
            return .date
        case .unread:
            return .unread
        }
    }
}

struct ChatDiffContentSignature: Equatable, CustomStringConvertible {
    let kind: ChatMessageKindContentSignature
    let timeMarkerText: String
    let attachments: ChatAttachmentContentSignature

    var description: String {
        "ChatDiffContentSignature(kind:\(kind),timeLength:\(timeMarkerText.count),attachments:\(attachments))"
    }
}

enum ChatMessageKindContentSignature: Equatable, CustomStringConvertible {
    case attributedText(String)
    case emoji(String)
    case sticker(ChatImageAttachmentSignature)
    case call(primary: String, incoming: Bool, missed: Bool)
    case system(String)
    case initial(String)
    case skeleton(String)
    case date(String)
    case unread(String)

    var description: String {
        switch self {
        case .attributedText(let text):
            return "attributedText(length:\(text.count))"
        case .emoji(let text):
            return "emoji(length:\(text.count))"
        case .sticker(let signature):
            return "sticker(\(signature))"
        case .call(let primary, let incoming, let missed):
            return "call(primary:\(primary),incoming:\(incoming),missed:\(missed))"
        case .system(let text):
            return "system(length:\(text.count))"
        case .initial(let text):
            return "initial(length:\(text.count))"
        case .skeleton(let text):
            return "skeleton(length:\(text.count))"
        case .date(let text):
            return "date(length:\(text.count))"
        case .unread(let text):
            return "unread(length:\(text.count))"
        }
    }
}

struct ChatAttachmentContentSignature: Equatable, CustomStringConvertible {
    let images: [ChatImageAttachmentSignature]
    let videos: [ChatVideoAttachmentSignature]
    let locations: [ChatLocationAttachmentSignature]
    let contacts: [ChatContactAttachmentSignature]
    let files: [ChatFileAttachmentSignature]
    let audios: [ChatAudioAttachmentSignature]
    let forwards: [ChatForwardAttachmentSignature]

    var description: String {
        [
            "images:\(images.count)",
            "videos:\(videos.count)",
            "locations:\(locations.count)",
            "contacts:\(contacts.count)",
            "files:\(files.count)",
            "audios:\(audios)",
            "forwards:\(forwards.count)"
        ].joined(separator: ",")
    }
}

struct ChatImageAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: CGSize
    let isSensitive: Bool
    let isSensitiveRevealed: Bool

    init(_ attachment: ImageAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.isSensitive = attachment.isSensitive
        self.isSensitiveRevealed = attachment.isSensitiveRevealed
    }

    var description: String {
        "image(primary:\(primary),url:\(url?.absoluteString ?? ""),size:\(size),sensitive:\(isSensitive),revealed:\(isSensitiveRevealed))"
    }
}

struct ChatVideoAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: CGSize
    let previewUrl: URL?
    let duration: Double
    let downloaded: Bool
    let isSensitive: Bool
    let isSensitiveRevealed: Bool

    init(_ attachment: VideoAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.previewUrl = attachment.previewUrl
        self.duration = attachment.duration
        self.downloaded = attachment.downloaded
        self.isSensitive = attachment.isSensitive
        self.isSensitiveRevealed = attachment.isSensitiveRevealed
    }

    var description: String {
        "video(primary:\(primary),duration:\(duration),downloaded:\(downloaded))"
    }
}

struct ChatLocationAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let address: String?
    let geoURI: String
    let snapshotURL: URL?

    init(_ attachment: LocationAttachment) {
        self.primary = attachment.primary
        self.latitude = attachment.coordinate.latitude
        self.longitude = attachment.coordinate.longitude
        self.address = attachment.address
        self.geoURI = attachment.geoURI
        self.snapshotURL = attachment.snapshotURL
    }

    var description: String {
        "location(primary:\(primary),lat:\(latitude),lon:\(longitude))"
    }
}

struct ChatContactAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let owner: String
    let jid: String
    let entity: MessageContactEntityKind
    let title: String
    let nickname: String?
    let given: String?
    let family: String?
    let avatarURL: String?
    let avatarMetadata: [String: String]

    init(_ attachment: ContactAttachment) {
        self.primary = attachment.primary
        self.owner = attachment.owner
        self.jid = attachment.jid
        self.entity = attachment.entity
        self.title = attachment.title
        self.nickname = attachment.nickname
        self.given = attachment.given
        self.family = attachment.family
        self.avatarURL = attachment.avatarURL
        self.avatarMetadata = attachment.avatarMetadata
    }

    var description: String {
        "contact(primary:\(primary),jid:\(jid),entity:\(entity.rawValue),metadata:\(avatarMetadata.count))"
    }
}

struct ChatFileAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: Double
    let name: String
    let downloaded: Bool

    init(_ attachment: FileAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.name = attachment.name
        self.downloaded = attachment.downloaded
    }

    var description: String {
        "file(primary:\(primary),name:\(name),size:\(size),downloaded:\(downloaded))"
    }
}

struct ChatAudioAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: Double
    let name: String
    let duration: Double
    let downloaded: Bool
    let pcm: ChatVoicePCMSignature

    init(_ attachment: AudioAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.name = attachment.name
        self.duration = attachment.duration
        self.downloaded = attachment.downloaded
        self.pcm = ChatVoicePCMSignature(attachment.pcm)
    }

    var description: String {
        "audio(primary:\(primary),duration:\(duration),downloaded:\(downloaded),pcm:\(pcm))"
    }
}

struct ChatForwardAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let author: String
    let jid: String
    let outgoing: Bool
    let textMessage: String
    let timeMarker: String
    let attachments: ChatAttachmentContentSignature

    var description: String {
        "forward(primary:\(primary),outgoing:\(outgoing),textLength:\(textMessage.count),attachments:\(attachments))"
    }
}

struct ChatVoicePCMSignature: Equatable, CustomStringConvertible {
    let count: Int
    let hash: UInt64

    init(_ pcm: [Float]) {
        var hasher = ChatStableSignatureHasher()
        for value in pcm {
            hasher.combine(value.bitPattern)
        }
        self.count = pcm.count
        self.hash = hasher.value
    }

    var description: String {
        "count:\(count),hash:\(String(hash, radix: 16))"
    }
}

private struct ChatStableSignatureHasher {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var value: UInt64 = ChatStableSignatureHasher.offsetBasis

    mutating func combine(_ value: UInt32) {
        combine(UInt8(truncatingIfNeeded: value))
        combine(UInt8(truncatingIfNeeded: value >> 8))
        combine(UInt8(truncatingIfNeeded: value >> 16))
        combine(UInt8(truncatingIfNeeded: value >> 24))
    }

    private mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* ChatStableSignatureHasher.prime
    }
}

private final class ChatDiffSignatureBuilder {
    private var textCache: [ObjectIdentifier: String] = [:]
    private var imageCache: [ObjectIdentifier: ChatImageAttachmentSignature] = [:]
    private var videoCache: [ObjectIdentifier: ChatVideoAttachmentSignature] = [:]
    private var locationCache: [ObjectIdentifier: ChatLocationAttachmentSignature] = [:]
    private var contactCache: [ObjectIdentifier: ChatContactAttachmentSignature] = [:]
    private var fileCache: [ObjectIdentifier: ChatFileAttachmentSignature] = [:]
    private var audioCache: [ObjectIdentifier: ChatAudioAttachmentSignature] = [:]
    private var forwardCache: [ObjectIdentifier: ChatForwardAttachmentSignature] = [:]

    func contentSignature(for message: ChatViewController.Datasource) -> ChatDiffContentSignature {
        ChatDiffContentSignature(
            kind: kindSignature(message.kind),
            timeMarkerText: textString(message.timeMarkerText),
            attachments: attachmentSignature(
                images: message.images,
                videos: message.videos,
                locations: message.locations,
                contacts: message.contacts,
                files: message.files,
                audios: message.audios,
                forwards: message.forwards
            )
        )
    }

    private func kindSignature(_ kind: MessageKind) -> ChatMessageKindContentSignature {
        switch kind {
        case .attributedText(let text):
            return .attributedText(textString(text))
        case .emoji(let text):
            return .emoji(text)
        case .sticker(let attachment):
            return .sticker(imageSignature(attachment))
        case .call(let attachment):
            return .call(
                primary: attachment.primary,
                incoming: attachment.incoming,
                missed: attachment.missed
            )
        case .system(let text):
            return .system(textString(text))
        case .initial(let text):
            return .initial(textString(text))
        case .skeleton(let text):
            return .skeleton(textString(text))
        case .date(let text):
            return .date(textString(text))
        case .unread(let text):
            return .unread(textString(text))
        }
    }

    private func attachmentSignature(
        images: [ImageAttachment],
        videos: [VideoAttachment],
        locations: [LocationAttachment],
        contacts: [ContactAttachment],
        files: [FileAttachment],
        audios: [AudioAttachment],
        forwards: [MessageAttachment]
    ) -> ChatAttachmentContentSignature {
        ChatAttachmentContentSignature(
            images: images.map(imageSignature(_:)),
            videos: videos.map(videoSignature(_:)),
            locations: locations.map(locationSignature(_:)),
            contacts: contacts.map(contactSignature(_:)),
            files: files.map(fileSignature(_:)),
            audios: audios.map(audioSignature(_:)),
            forwards: forwards.map(forwardSignature(_:))
        )
    }

    private func textString(_ text: NSAttributedString?) -> String {
        guard let text else { return "" }
        let key = ObjectIdentifier(text)
        if let cached = textCache[key] {
            return cached
        }
        let value = text.string
        textCache[key] = value
        return value
    }

    private func imageSignature(_ attachment: ImageAttachment) -> ChatImageAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = imageCache[key] {
            return cached
        }
        let signature = ChatImageAttachmentSignature(attachment)
        imageCache[key] = signature
        return signature
    }

    private func videoSignature(_ attachment: VideoAttachment) -> ChatVideoAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = videoCache[key] {
            return cached
        }
        let signature = ChatVideoAttachmentSignature(attachment)
        videoCache[key] = signature
        return signature
    }

    private func locationSignature(_ attachment: LocationAttachment) -> ChatLocationAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = locationCache[key] {
            return cached
        }
        let signature = ChatLocationAttachmentSignature(attachment)
        locationCache[key] = signature
        return signature
    }

    private func contactSignature(_ attachment: ContactAttachment) -> ChatContactAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = contactCache[key] {
            return cached
        }
        let signature = ChatContactAttachmentSignature(attachment)
        contactCache[key] = signature
        return signature
    }

    private func fileSignature(_ attachment: FileAttachment) -> ChatFileAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = fileCache[key] {
            return cached
        }
        let signature = ChatFileAttachmentSignature(attachment)
        fileCache[key] = signature
        return signature
    }

    private func audioSignature(_ attachment: AudioAttachment) -> ChatAudioAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = audioCache[key] {
            return cached
        }
        let signature = ChatAudioAttachmentSignature(attachment)
        audioCache[key] = signature
        return signature
    }

    private func forwardSignature(_ attachment: MessageAttachment) -> ChatForwardAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = forwardCache[key] {
            return cached
        }
        let signature = ChatForwardAttachmentSignature(
            primary: attachment.primary,
            author: attachment.author,
            jid: attachment.jid,
            outgoing: attachment.outgoing,
            textMessage: textString(attachment.textMessage),
            timeMarker: textString(attachment.timeMarker),
            attachments: attachmentSignature(
                images: attachment.images,
                videos: attachment.videos,
                locations: attachment.locations,
                contacts: attachment.contacts,
                files: attachment.files,
                audios: attachment.audios,
                forwards: attachment.subforwards
            )
        )
        forwardCache[key] = signature
        return signature
    }
}

enum ChatMessageUpdatePolicy {
    private static let sizeTolerance: CGFloat = 0.5

    static func shouldUseReloadFallback(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        old.hasDuplicateKeys || new.hasDuplicateKeys
    }

    static func classify(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource,
        oldSize: CGSize?,
        newSize: CGSize?
    ) -> ChatMessageUpdateClassification {
        guard oldMessage.primary == newMessage.primary else {
            return .layout
        }
        guard ChatMessageLayoutSignature(oldMessage) == ChatMessageLayoutSignature(newMessage) else {
            return .layout
        }
        guard let oldSize, let newSize, sizesAreEqual(oldSize, newSize) else {
            return .layout
        }
        return .contentOnly
    }

    static func shouldUpdateContent(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource
    ) -> Bool {
        let signatureBuilder = ChatDiffSignatureBuilder()
        return !ChatViewController.Datasource.compareContent(oldMessage, newMessage) ||
        signatureBuilder.contentSignature(for: oldMessage) != signatureBuilder.contentSignature(for: newMessage)
    }

    static func contentSignature(for message: ChatViewController.Datasource) -> ChatDiffContentSignature {
        ChatDiffSignatureBuilder().contentSignature(for: message)
    }

    private static func sizesAreEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= sizeTolerance &&
        abs(lhs.height - rhs.height) <= sizeTolerance
    }
}

struct ChatDatasourceCoordinator {
    struct DiffResult {
        let inserts: IndexSet
        let deletes: IndexSet
        let reloads: [IndexPath]
        let contentOnlyUpdates: [ChatMessageContentUpdate]
        let moves: [(from: IndexPath, to: IndexPath)]

        var isEmpty: Bool {
            inserts.isEmpty && deletes.isEmpty && reloads.isEmpty && contentOnlyUpdates.isEmpty && moves.isEmpty
        }

        var hasCollectionUpdates: Bool {
            !inserts.isEmpty || !deletes.isEmpty || !reloads.isEmpty || !moves.isEmpty
        }
    }

    static func makeSnapshot(items: [ChatViewController.Datasource]) -> ChatDatasourceSnapshot {
        ChatDatasourceSnapshot(items: items)
    }

    static func diff(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> DiffResult {
        diff(old: old, new: new, oldSizeProvider: nil, newSizeProvider: nil)
    }

    static func diff(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot,
        oldSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?,
        newSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?
    ) -> DiffResult {
        let changes = DeepDiff.diff(old: old.items, new: new.items)
        let inserts = IndexSet(changes.compactMap { $0.insert?.index })
        let deletes = IndexSet(changes.compactMap { $0.delete?.index })
        let moves = changes.compactMap { change -> (from: IndexPath, to: IndexPath)? in
            guard let move = change.move else { return nil }
            return (IndexPath(row: 0, section: move.fromIndex), IndexPath(row: 0, section: move.toIndex))
        }

        var contentOnlyUpdates: [ChatMessageContentUpdate] = []
        var reloads: [IndexPath] = []
        var handledSections = Set<Int>()

        changes.compactMap(\.replace).forEach { replace in
            handledSections.insert(replace.index)
        }

        let commonCount = min(old.items.count, new.items.count)
        for index in 0..<commonCount {
            guard !deletes.contains(index), !inserts.contains(index) else { continue }
            let oldItem = old.items[index]
            let newItem = new.items[index]
            guard oldItem.primary == newItem.primary else { continue }
            guard handledSections.contains(index) ||
                    ChatMessageUpdatePolicy.shouldUpdateContent(old: oldItem, new: newItem) else {
                continue
            }

            let indexPath = IndexPath(row: 0, section: index)
            let classification = ChatMessageUpdatePolicy.classify(
                old: oldItem,
                new: newItem,
                oldSize: oldSizeProvider?(oldItem),
                newSize: newSizeProvider?(newItem)
            )
            switch classification {
            case .contentOnly:
                contentOnlyUpdates.append(ChatMessageContentUpdate(primary: newItem.primary, indexPath: indexPath))
            case .layout:
                reloads.append(indexPath)
            }
        }

        return DiffResult(
            inserts: inserts,
            deletes: deletes,
            reloads: reloads,
            contentOnlyUpdates: contentOnlyUpdates,
            moves: moves
        )
    }

    static func compatibleForTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        guard !old.items.isEmpty else { return false }
        guard old.items.count == new.items.count else { return false }
        guard !old.hasDuplicateKeys, !new.hasDuplicateKeys else { return false }
        return zip(old.items, new.items).allSatisfy { $0.primary == $1.primary }
    }

    static func supportsTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        !old.items.isEmpty && !ChatMessageUpdatePolicy.shouldUseReloadFallback(old: old, new: new)
    }
}

struct ChatDatasetCoordinator {
    let pageSize: Int

    func clamp(_ window: ChatDatasetWindow, totalCount: Int) -> ChatDatasetWindow {
        guard totalCount > 0 else { return .empty }

        var minIndex = max(0, window.minIndex)
        var maxIndex = min(totalCount, max(minIndex, window.maxIndex))

        if maxIndex == minIndex {
            maxIndex = min(totalCount, minIndex + pageSize)
            minIndex = max(0, maxIndex - pageSize)
        }

        return ChatDatasetWindow(minIndex: minIndex, maxIndex: maxIndex)
    }

    func initialWindow(totalCount: Int) -> ChatDatasetWindow {
        clamp(ChatDatasetWindow(minIndex: totalCount - pageSize, maxIndex: totalCount), totalCount: totalCount)
    }

    func replacementWindow(around index: Int, totalCount: Int) -> ChatDatasetWindow {
        let halfPage = pageSize / 2
        return clamp(ChatDatasetWindow(minIndex: index - halfPage, maxIndex: index + halfPage), totalCount: totalCount)
    }

    func nextWindow(from current: ChatDatasetWindow, direction: ChatHistoryPageDirection) -> ChatDatasetWindow {
        switch direction {
        case .newer:
            return ChatDatasetWindow(minIndex: current.minIndex, maxIndex: current.maxIndex + pageSize)
        case .older:
            return ChatDatasetWindow(minIndex: current.minIndex - pageSize, maxIndex: current.maxIndex)
        }
    }

    func visibleWindow(currentPage: ChatViewController.ChatPage) -> ChatDatasetWindow {
        ChatDatasetWindow(minIndex: currentPage.minIndex, maxIndex: currentPage.maxIndex)
    }
}

extension ChatViewController {
    internal static let attachmentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    internal func requestOutgoingAutoScrollAfterDatasourceUpdate() {
        self.pendingOutgoingAutoScrollRequest = ChatOutgoingAutoScrollRequest(
            previousNewestPrimary: ChatOutgoingAutoScrollPolicy
                .newestRealMessage(in: self.datasource)?
                .item
                .primary
        )
    }

    private func consumePendingOutgoingAutoScrollDecision(
        items: [Datasource]
    ) -> ChatOutgoingAutoScrollDecision {
        let request = self.pendingOutgoingAutoScrollRequest
        let isAnchorNavigationActive = ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        )
        let decision = ChatOutgoingAutoScrollPolicy.decision(
            request: request,
            items: items,
            isAnchorNavigationActive: isAnchorNavigationActive
        )
        self.finishSendToLocalRowSignpostIfNeeded(request: request, items: items)
        if decision.consumesPendingRequest {
            self.pendingOutgoingAutoScrollRequest = nil
        }
        return decision
    }

    internal static func mapReferenceAttachments(
        _ references: [MessageReferenceStorageItem],
        revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    ) -> (images: [ImageAttachment], videos: [VideoAttachment], locations: [LocationAttachment], contacts: [ContactAttachment], audio: [AudioAttachment], files: [FileAttachment]) {
        var images: [ImageAttachment] = []
        var videos: [VideoAttachment] = []
        var locations: [LocationAttachment] = []
        var contacts: [ContactAttachment] = []
        var audio: [AudioAttachment] = []
        var files: [FileAttachment] = []

        references.filter { !$0.isLocallyHiddenByReport }.forEach { item in
            if item.kind == .geoloc {
                if let location = Self.locationAttachment(for: item) {
                    locations.append(location)
                }
                return
            }
            if item.kind == .contact {
                if let contact = Self.contactAttachment(for: item) {
                    contacts.append(contact)
                }
                return
            }

            let mediaType = SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(
                kind: item.kind,
                mimeType: item.mimeType,
                mediaType: item.metadata?["media-type"] as? String
            )
            switch mediaType {
            case .image:
                images.append(ImageAttachment(
                    primary: item.primary,
                    url: Self.imageDisplayURL(for: item),
                    size: item.sizeInPx ?? CGSize(square: 128),
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .video:
                videos.append(VideoAttachment(
                    primary: item.primary,
                    url: item.downloadUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    previewUrl: item.videoPreviewUrl,
                    duration: 0,
                    downloaded: item.isDownloaded,
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .unsupported:
                if item.kind_ == "voice" {
                    audio.append(AudioAttachment(primary: item.primary, url: item.decodedUrl, size: 10, name: "name", duration: Double(item.duration ?? 0), downloaded: item.isDownloaded, pcm: item.meteringLevels ?? []))
                } else if item.kind == .media && MimeIcon(item.mimeType).value != .audio && item.kind_ != "groupchat" {
                    files.append(FileAttachment(primary: item.primary, url: item.downloadUrl, size: Double(item.sizeInBytesRaw), name: item.filename ?? item.name ?? "file", downloaded: item.isDownloaded))
                }
            }
        }

        return (images, videos, locations, contacts, audio, files)
    }

    private static func imageDisplayURL(for reference: MessageReferenceStorageItem) -> URL? {
        if let downloadUrl = reference.downloadUrl {
            return downloadUrl
        }
        if let localFileUrl = reference.localFileUrl,
           localFileUrl.isFileURL {
            return localFileUrl
        }
        return reference.videoPreviewUrl
    }

    private static func locationAttachment(for reference: MessageReferenceStorageItem) -> LocationAttachment? {
        guard let metadata = reference.metadata,
              let latitude = geolocCoordinateValue(metadata["lat"]),
              let longitude = geolocCoordinateValue(metadata["lon"]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              latitude.isFinite,
              longitude.isFinite else {
            return nil
        }

        let snapshotURL = (metadata["local-snapshot-url"] as? String)
            .flatMap(URL.init(string:))
        let geoURI = metadata["uri"] as? String ?? reference.url ?? "geo:\(latitude),\(longitude)"

        return LocationAttachment(
            primary: reference.primary,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            address: metadata["text"] as? String,
            geoURI: geoURI,
            snapshotURL: snapshotURL
        )
    }

    private static func contactAttachment(for reference: MessageReferenceStorageItem) -> ContactAttachment? {
        guard let metadata = reference.metadata else {
            return nil
        }

        let jid = Self.contactNonEmpty(metadata["contact_jid"] as? String)
            ?? Self.contactNonEmpty(reference.url?.replacingOccurrences(of: "xmpp:", with: ""))
        guard let jid else {
            return nil
        }

        let nickname = Self.contactNonEmpty(metadata["nickname"] as? String)
        let given = Self.contactNonEmpty(metadata["given"] as? String)
        let family = Self.contactNonEmpty(metadata["family"] as? String)
        let entity = MessageContactEntityKind.resolved(
            metadata: metadata,
            owner: reference.owner,
            jid: jid
        )
        let title = contactDisplayTitle(
            displayTitle: Self.contactNonEmpty(metadata["display_title"] as? String),
            nickname: nickname,
            given: given,
            family: family,
            jid: jid
        )
        let avatarMetadata = metadata.compactMapValues { $0 as? String }
            .filter { $0.key.hasPrefix("avatar_") }

        return ContactAttachment(
            primary: reference.primary,
            owner: reference.owner,
            jid: jid,
            entity: entity,
            title: title,
            nickname: nickname,
            given: given,
            family: family,
            avatarURL: Self.contactNonEmpty(metadata["avatar_url"] as? String),
            avatarMetadata: avatarMetadata
        )
    }

    private static func contactDisplayTitle(
        displayTitle: String?,
        nickname: String?,
        given: String?,
        family: String?,
        jid: String
    ) -> String {
        if let displayTitle = Self.contactNonEmpty(displayTitle) {
            return displayTitle
        }
        if let nickname = Self.contactNonEmpty(nickname) {
            return nickname
        }
        let fullName = [Self.contactNonEmpty(given), Self.contactNonEmpty(family)]
            .compactMap { $0 }
            .joined(separator: " ")
        if let fullName = Self.contactNonEmpty(fullName) {
            return fullName
        }
        return jid
    }

    private static func contactNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }

    private static func geolocCoordinateValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func mappedReferenceAttachments(
        _ references: [MessageReferenceStorageItem],
        revealedSensitiveMediaPrimaries: Set<String>
    ) -> ChatMappedReferenceAttachments {
        let mapped = Self.mapReferenceAttachments(
            references,
            revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries
        )
        return ChatMappedReferenceAttachments(
            images: mapped.images,
            videos: mapped.videos,
            locations: mapped.locations,
            contacts: mapped.contacts,
            audio: mapped.audio,
            files: mapped.files
        )
    }

    private static func displayModelCacheKey(
        for item: MessageStorageItem,
        presentation: SavedMessageDisplayPolicy.Presentation,
        revealedSensitiveMediaPrimaries: Set<String>,
        context: ChatDisplayModelCacheContext
    ) -> ChatDisplayModelCacheKey {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(item.messageId)
        hasher.combine(item.archivedId)
        hasher.combine(item.queryIds)
        hasher.combine(item.displayAs.rawValue)
        hasher.combine(item.state.rawValue)
        hasher.combine(item.body)
        hasher.combine(item.legacyBody)
        hasher.combine(item.bodyForAttachmentRendering)
        hasher.combine(item.localReportPlaceholderText)
        hasher.combine(item.date.timeIntervalSinceReferenceDate)
        hasher.combine(item.sentDate.timeIntervalSinceReferenceDate)
        hasher.combine(item.editDate?.timeIntervalSinceReferenceDate)
        hasher.combine(item.afterburnInterval)
        hasher.combine(item.burnDate)
        hasher.combine(item.deleteState.rawValue)
        hasher.combine(item.isDeleted)
        hasher.combine(item.isLocallyHiddenByReport)
        hasher.combine(item.messageWarningText)
        hasher.combine(item.messageError)
        hasher.combine(item.groupchatAuthorId)
        hasher.combine(item.groupchatAuthorNickname)
        hasher.combine(item.groupchatAuthorBadge)
        combineMetadata(item.groupchatMetadata, into: &hasher)
        combineMetadata(item.errorMetadata, into: &hasher)

        hasher.combine(presentation.isSavedMessage)
        hasher.combine(presentation.isSavedForward)
        hasher.combine(presentation.isDirectSavedNote)
        hasher.combine(presentation.displayAuthorJid)
        hasher.combine(presentation.displayAuthorName)
        hasher.combine(presentation.displayAvatarSource)
        hasher.combine(presentation.displayOutgoing)
        hasher.combine(presentation.visibleBody)
        hasher.combine(presentation.visibleDate.timeIntervalSinceReferenceDate)
        hasher.combine(presentation.groupchatAuthorRole)
        hasher.combine(presentation.groupchatAuthorId)
        hasher.combine(presentation.groupchatAuthorNickname)
        hasher.combine(presentation.groupchatAuthorBadge)
        hasher.combine(presentation.isDeleted)
        hasher.combine(presentation.deleteState.rawValue)
        hasher.combine(presentation.authorColorKey)

        hasher.combine(presentation.visibleReferences.count)
        presentation.visibleReferences.forEach { combineReference($0, into: &hasher) }
        hasher.combine(presentation.visibleForwards.count)
        presentation.visibleForwards.forEach { combineForward($0, into: &hasher) }
        revealedSensitiveMediaPrimaries.sorted().forEach { hasher.combine($0) }

        return ChatDisplayModelCacheKey(
            messagePrimary: item.primary,
            displayRevision: hasher.revision,
            context: context
        )
    }

    private static func forwardDisplayRevision(
        _ forwards: [MessageForwardsInlineStorageItem],
        revealedSensitiveMediaPrimaries: Set<String>,
        context: ChatDisplayModelCacheContext
    ) -> String {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(forwards.count)
        forwards.forEach { combineForward($0, into: &hasher) }
        revealedSensitiveMediaPrimaries.sorted().forEach { hasher.combine($0) }
        hasher.combine(context.searchText)
        hasher.combine(context.localeIdentifier)
        hasher.combine(context.contentSizeCategory)
        hasher.combine(context.bodyFontName)
        hasher.combine(Double(context.bodyFontPointSize))
        hasher.combine(context.interfaceStyleRawValue)
        return hasher.revision
    }

    private static func combineReference(
        _ reference: MessageReferenceStorageItem,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        hasher.combine(reference.primary)
        hasher.combine(reference.owner)
        hasher.combine(reference.jid)
        hasher.combine(reference.kind_)
        hasher.combine(reference.mimeType)
        hasher.combine(reference.begin)
        hasher.combine(reference.end)
        hasher.combine(reference.url)
        hasher.combine(reference.downloadUrl?.absoluteString)
        hasher.combine(reference.localFileUrl?.absoluteString)
        hasher.combine(reference.decodedUrl?.absoluteString)
        hasher.combine(reference.videoPreviewUrl?.absoluteString)
        hasher.combine(reference.sizeInPx.map { Double($0.width) })
        hasher.combine(reference.sizeInPx.map { Double($0.height) })
        hasher.combine(reference.sizeInBytesRaw)
        hasher.combine(reference.filename)
        hasher.combine(reference.name)
        hasher.combine(String(describing: reference.duration))
        hasher.combine(reference.isDownloaded)
        hasher.combine(reference.isSensitive)
        hasher.combine(reference.isSensitiveChecked)
        hasher.combine(reference.isLocallyHiddenByReport)
        combineMetadata(reference.metadata, into: &hasher)
        let levels = reference.meteringLevels ?? []
        hasher.combine(levels.count)
        levels.forEach { hasher.combine(Double($0)) }
    }

    private static func combineForward(
        _ forward: MessageForwardsInlineStorageItem,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        hasher.combine(forward.primary)
        hasher.combine(forward.messageId)
        hasher.combine(forward.owner)
        hasher.combine(forward.opponent)
        hasher.combine(forward.jid)
        hasher.combine(forward.parentId)
        hasher.combine(forward.body)
        hasher.combine(forward.forwardJid)
        hasher.combine(forward.forwardNickname)
        hasher.combine(forward.isOutgoing)
        hasher.combine(forward.originalDate?.timeIntervalSinceReferenceDate)
        hasher.combine(forward.references.count)
        forward.references.forEach { combineReference($0, into: &hasher) }
        hasher.combine(forward.subforwards.count)
        forward.subforwards.forEach { combineForward($0, into: &hasher) }
    }

    private static func combineMetadata(
        _ metadata: [String: Any]?,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        guard let metadata else {
            hasher.combine("metadata:nil")
            return
        }
        hasher.combine(metadata.count)
        for key in metadata.keys.sorted() {
            hasher.combine(key)
            combineMetadataValue(metadata[key], into: &hasher)
        }
    }

    private static func combineMetadataValue(
        _ value: Any?,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        switch value {
        case let value as String:
            hasher.combine(value)
        case let value as Bool:
            hasher.combine(value)
        case let value as Int:
            hasher.combine(value)
        case let value as Int64:
            hasher.combine(UInt64(bitPattern: value))
        case let value as Double:
            hasher.combine(value)
        case let value as Float:
            hasher.combine(Double(value))
        case let value as [String]:
            hasher.combine(value.count)
            value.forEach { hasher.combine($0) }
        case let value as [String: String]:
            hasher.combine(value.count)
            for key in value.keys.sorted() {
                hasher.combine(key)
                hasher.combine(value[key])
            }
        case let value as [String: Any]:
            combineMetadata(value, into: &hasher)
        case let value as [Any]:
            hasher.combine(value.count)
            value.forEach { combineMetadataValue($0, into: &hasher) }
        case .none:
            hasher.combine("nil")
        default:
            hasher.combine(String(describing: value))
        }
    }
    
    internal func willUpdateFloatingDate() {
        self.updateFloatingDateObserverSignal.accept(true)
    }
    
    internal func updateFloatingDate() {
        guard let topVisibleReasonableMessageIndex = self.messagesCollectionView.indexPathsForVisibleItems.compactMap ({
            return $0.section
        }).min() else {
            return
        }
        let pinnOffset: CGFloat = 0//54
//        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
//            pinnOffset += topInset
//        }
        let frame = CGRect(
            origin: CGPoint(
                x: 0,
                y: pinnOffset
            ),
            size: CGSize(
                width: self.view.bounds.width,
                height: 34
            )
        )
        if self.datasource.count < 5 {
            self.pinnedDateView.isHidden = true
//            self.pinnedDateView.hide()
        } else {
            let index = [topVisibleReasonableMessageIndex, self.datasource.count - 1].min() ?? 0
            guard let item = self.datasourceItem(atSection: index) else {
                self.pinnedDateView.isHidden = true
                return
            }
//            self.pinnedDateView.show()
            self.pinnedDateView.isHidden = false
            let text = NSAttributedString(
                string: sectionsDateFormatter.string(from: item.sentDate),
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.white,
                ]
            )
            self.pinnedDateView.frame = frame
            self.pinnedDateView.configure(text)
        }
    }
    
    internal func mapAttachment(_ attachment: MessageForwardsInlineStorageItem) -> MessageAttachment {
        let references = attachment.references.toArray()
        let mappedReferences = Self.mapReferenceAttachments(references, revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries)
        let timeString = Self.attachmentTimeFormatter.string(from: attachment.originalDate ?? Date())
        let timeMarkerString = NSAttributedString(
            string: timeString,
            attributes: [
                NSAttributedString.Key.foregroundColor: UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1),
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10, weight: .regular)
            ]
        )
        return MessageAttachment(
            primary: attachment.primary,
            author: attachment.tryToLoadNickname(),
            jid: attachment.forwardJid,
            outgoing: attachment.isOutgoing,
            textMessage: attachment.createRefBody(
                [
                    NSAttributedString.Key.foregroundColor: UIColor.label,
                    NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)//UIFont.systemFont(ofSize: 16, weight: .regular),
                ],
                searchedText: self.searchTextObserver.value,
                searchedTextColor: .systemGreen
            ),
            images: mappedReferences.images,
            videos: mappedReferences.videos,
            locations: mappedReferences.locations,
            contacts: mappedReferences.contacts,
            files: mappedReferences.files,
            audios: mappedReferences.audio,
            timeMarker: timeMarkerString,
            subforwards: attachment.subforwards.toArray().compactMap({ return mapAttachment($0) })
        )
    }

    private func cachedDisplayModel(
        for item: MessageStorageItem,
        presentation: SavedMessageDisplayPolicy.Presentation,
        textAttributes: [NSAttributedString.Key: Any],
        context: ChatDisplayModelCacheContext
    ) -> ChatCachedDisplayModel {
        let key = Self.displayModelCacheKey(
            for: item,
            presentation: presentation,
            revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries,
            context: context
        )
        return displayModelCache.model(for: key) {
            let kind = self.displayKind(
                for: item,
                presentation: presentation,
                textAttributes: textAttributes
            )
            let mappedReferences = Self.mappedReferenceAttachments(
                presentation.visibleReferences,
                revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries
            )
            let forwardSignature = Self.forwardDisplayRevision(
                presentation.visibleForwards,
                revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries,
                context: context
            )
            let lazyForwards = ChatLazyForwardDisplayModel(signature: forwardSignature) { [weak self] in
                guard let self else { return [] }
                return presentation.visibleForwards.compactMap { self.mapAttachment($0) }
            }
            let timeMarkerString = self.timeMarkerText(for: item, presentation: presentation)
            return ChatCachedDisplayModel(
                kind: kind,
                mappedReferences: mappedReferences,
                lazyForwards: lazyForwards,
                isDownloaded: presentation.visibleReferences.contains(where: \.isDownloaded),
                timeMarkerText: timeMarkerString
            )
        }
    }

    private func displayKind(
        for item: MessageStorageItem,
        presentation: SavedMessageDisplayPolicy.Presentation,
        textAttributes: [NSAttributedString.Key: Any]
    ) -> MessageKind {
        switch item.displayAs {
        case .text:
            if presentation.isSavedMessage || presentation.visibleBody != item.body {
                return .attributedText(
                    SavedMessageDisplayPolicy.attributedBody(
                        for: presentation,
                        attributes: textAttributes,
                        searchedText: self.searchTextObserver.value,
                        searchedTextColor: .systemGreen
                    )
                )
            } else {
                return .attributedText(
                    item.createRefBody(
                        textAttributes,
                        searchedText: self.searchTextObserver.value,
                        searchedTextColor: .systemGreen
                    )
                )
            }
        case .call:
            return .call(CallAttachment(
                primary: item.primary,
                incoming: !presentation.displayOutgoing,
                missed: presentation.visibleReferences.first?.metadata?["callState"] as? String == "missed"
            ))
        case .system:
            return .system(
                NSAttributedString(
                    string: presentation.visibleBody,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption1).italic(),
                        .foregroundColor: UIColor.white,
                    ]
                )
            )
        case .sticker:
            return .attributedText(NSAttributedString())
        }
    }

    private func timeMarkerText(
        for item: MessageStorageItem,
        presentation: SavedMessageDisplayPolicy.Presentation
    ) -> NSAttributedString {
        var timeString = Self.attachmentTimeFormatter.string(from: presentation.visibleDate)
        if item.afterburnInterval > 0 {
            timeString = "\(timeString) ⦁ \(item.afterburnInterval.prettyMinuteFormatedString)"
        }
        if item.editDate != nil {
            timeString = "\(timeString) (edited)"
        }
        return NSAttributedString(
            string: timeString,
            attributes: [
                NSAttributedString.Key.foregroundColor: UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1),
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10, weight: .regular)
            ]
        )
    }

    internal func applyChatDatasource(
        _ items: [Datasource],
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        suppressDefaultBottomScroll: Bool = false,
        forceBottomAlignmentTarget: ChatBottomAlignmentTarget? = nil,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil
    ) {
        var datasourceApplySignpost = ChatPerformanceSignposts.begin(.datasourceApply)
        let applyStartedAt = Date()
        let modeDescription: String
        switch mode {
        case .fullReload(let keepOffset):
            modeDescription = "fullReload(keepOffset:\(keepOffset))"
        case .windowReload(let keepOffset):
            modeDescription = "windowReload(keepOffset:\(keepOffset))"
        case .targetedDiff:
            modeDescription = "targetedDiff"
        }
        let oldContentOffset = self.messagesCollectionView.contentOffset
        let oldContentSize = self.messagesCollectionView.contentSize
        let oldContentInsets = self.messagesCollectionView.contentInset
        let oldBottomDistance = ChatTailAppendBottomPinPolicy.bottomDistance(
            contentHeight: oldContentSize.height,
            viewportHeight: self.messagesCollectionView.bounds.height,
            contentInsets: oldContentInsets,
            contentOffsetY: oldContentOffset.y
        )
        let oldFirstArchivedId = self.datasource.first?.archivedId
        let oldLastArchivedId = self.datasource.last?.archivedId
        let newSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: items)
        let previousSnapshot = datasourceSnapshot
        let containsOnlyFakeMessages = !items.isEmpty && items.allSatisfy(\.isFakeMessage)
        let containsRealMessages = items.contains { !$0.isFakeMessage }
        let wasNearBottom = self.isNearBottom()
        let effectiveAnchorPrimary = anchorPrimary ?? restoreAnchor?.primary
        let shouldRestoreAnchorInApplyTransaction = anchorRestorePhase == .applyTransaction && restoreAnchor != nil
        let isDefaultBottomScrollDeferred = ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        )
        let shouldAutoScrollToBottom = !suppressDefaultBottomScroll
            && !shouldRestoreAnchorInApplyTransaction
            && forceBottomAlignmentTarget == nil
            && wasNearBottom
            && !isDefaultBottomScrollDeferred
            && !containsOnlyFakeMessages
        let requestedAnimatedApply = animated && !ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
            oldItemCount: previousSnapshot.items.count,
            newItemCount: newSnapshot.items.count
        )
        let requestedStructuralAnimation = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: requestedAnimatedApply,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )
        let outgoingAutoScrollDecision = self.consumePendingOutgoingAutoScrollDecision(items: items)
        let shouldTailAppendBottomPin = !shouldRestoreAnchorInApplyTransaction
            && ChatTailAppendBottomPinPolicy.shouldPinBottom(
                old: previousSnapshot,
                new: newSnapshot,
                wasNearBottom: wasNearBottom,
                isDefaultBottomScrollDeferred: isDefaultBottomScrollDeferred,
                suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                containsOnlyFakeMessages: containsOnlyFakeMessages,
                outgoingAutoScrollDecision: outgoingAutoScrollDecision
            )
        let effectiveApplyCategory: ChatDatasourceApplyCategory = shouldTailAppendBottomPin
            ? .tailAppendBottomPinned
            : applyCategory
        let shouldAnimateApply = !shouldTailAppendBottomPin && ChatOutgoingAutoScrollApplyPolicy.shouldAnimateStructuralApply(
            requestedAnimated: requestedStructuralAnimation,
            outgoingAutoScrollDecision: outgoingAutoScrollDecision
        )
        let forceBottomAlignmentDescription = forceBottomAlignmentTarget.map { String(describing: $0) } ?? "-"
        ChatArchiveDebugTrace.log("chatDatasourceApplyStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("mode", modeDescription),
            ("applyCategory", effectiveApplyCategory.rawValue),
            ("anchorRestorePhase", anchorRestorePhase.rawValue),
            ("anchorPrimary", effectiveAnchorPrimary ?? "-"),
            ("oldCount", self.datasource.count),
            ("newCount", items.count),
            ("oldFirstArchivedId", oldFirstArchivedId ?? "-"),
            ("newFirstArchivedId", items.first?.archivedId ?? "-"),
            ("oldLastArchivedId", oldLastArchivedId ?? "-"),
            ("newLastArchivedId", items.last?.archivedId ?? "-"),
            ("animated", animated),
            ("structuralAnimated", shouldAnimateApply),
            ("invalidateLayout", invalidateLayout),
            ("forceBottomAlignmentTarget", forceBottomAlignmentDescription),
            ("oldOffsetY", Int(oldContentOffset.y)),
            ("oldContentHeight", Int(oldContentSize.height)),
            ("oldBottomDistance", Int(oldBottomDistance))
        ])

        var didUpdateInsetsInApplyTransaction = false
        var anchorRestoreDiagnostics = ChatHistoryPageAnchorRestoreDiagnostics()
        var reloadedOffsetY: CGFloat?
        var reloadedContentHeight: CGFloat?
        var forcedBottomAlignmentApplied = false

        let restoreAnchorInApplyTransactionIfNeeded: () -> Void = {
            guard shouldRestoreAnchorInApplyTransaction,
                  let restoreAnchor else {
                return
            }

            self.messagesCollectionView.layoutIfNeeded()
            reloadedOffsetY = self.messagesCollectionView.contentOffset.y
            reloadedContentHeight = self.messagesCollectionView.contentSize.height
            self.updateChatCollectionInsets()
            didUpdateInsetsInApplyTransaction = true
            anchorRestoreDiagnostics = self.restorePagingAnchorAndCollectDiagnostics(restoreAnchor)
            self.messagesCollectionView.layoutIfNeeded()
            ChatArchiveDebugTrace.log("chatDatasourceAnchorRestore", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("phase", anchorRestorePhase.rawValue),
                ("anchorPrimary", restoreAnchor.primary),
                ("sectionFound", anchorRestoreDiagnostics.sectionFound),
                ("attributesFound", anchorRestoreDiagnostics.attributesFound),
                ("restored", anchorRestoreDiagnostics.restored),
                ("oldOffsetY", Int(oldContentOffset.y)),
                ("reloadedOffsetY", Int(reloadedOffsetY ?? self.messagesCollectionView.contentOffset.y)),
                ("targetOffsetY", Int(anchorRestoreDiagnostics.targetOffsetY ?? self.messagesCollectionView.contentOffset.y)),
                ("finalOffsetY", Int(self.messagesCollectionView.contentOffset.y)),
                ("oldContentHeight", Int(oldContentSize.height)),
                ("reloadedContentHeight", Int(reloadedContentHeight ?? self.messagesCollectionView.contentSize.height)),
                ("finalContentHeight", Int(self.messagesCollectionView.contentSize.height)),
                ("insetTop", Int(self.messagesCollectionView.adjustedContentInset.top)),
                ("insetBottom", Int(self.messagesCollectionView.adjustedContentInset.bottom))
            ])
        }

        let forceBottomAlignmentIfNeeded: () -> Void = {
            guard let forceBottomAlignmentTarget,
                  let targetIndexPath = ChatBottomAlignmentTargetPolicy.indexPath(
                    for: forceBottomAlignmentTarget,
                    in: self.datasource
                  ) else {
                return
            }

            UIView.performWithoutAnimation {
                self.scrollToBottomAligned(targetIndexPath: targetIndexPath, animated: false)
                self.messagesCollectionView.layoutIfNeeded()
            }
            forcedBottomAlignmentApplied = true
        }

        let finish: () -> Void = {
            let finishStartedAt = Date()
            let layoutStartedAt = Date()
            ChatPerformanceSignposts.measure(.layoutApply) {
                if invalidateLayout {
                    self.messagesCollectionView.collectionViewLayout.invalidateLayout()
                    self.messagesCollectionView.layoutIfNeeded()
                }
                self.messagesCollectionView.layoutIfNeeded()
            }
            let layoutMs = ChatArchiveDebugTrace.milliseconds(since: layoutStartedAt)
            let insetsStartedAt = Date()
            if !didUpdateInsetsInApplyTransaction {
                self.updateChatCollectionInsets()
            }
            let insetsMs = ChatArchiveDebugTrace.milliseconds(since: insetsStartedAt)
            if shouldRestoreAnchorInApplyTransaction,
               let restoreAnchor,
               !anchorRestoreDiagnostics.restored {
                UIView.performWithoutAnimation {
                    anchorRestoreDiagnostics = self.restorePagingAnchorAndCollectDiagnostics(restoreAnchor)
                    self.messagesCollectionView.layoutIfNeeded()
                }
                ChatArchiveDebugTrace.log("chatDatasourceAnchorRestore", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("phase", "\(anchorRestorePhase.rawValue)-fallback"),
                    ("anchorPrimary", restoreAnchor.primary),
                    ("sectionFound", anchorRestoreDiagnostics.sectionFound),
                    ("attributesFound", anchorRestoreDiagnostics.attributesFound),
                    ("restored", anchorRestoreDiagnostics.restored),
                    ("oldOffsetY", Int(oldContentOffset.y)),
                    ("reloadedOffsetY", Int(reloadedOffsetY ?? self.messagesCollectionView.contentOffset.y)),
                    ("targetOffsetY", Int(anchorRestoreDiagnostics.targetOffsetY ?? self.messagesCollectionView.contentOffset.y)),
                    ("finalOffsetY", Int(self.messagesCollectionView.contentOffset.y)),
                    ("oldContentHeight", Int(oldContentSize.height)),
                    ("reloadedContentHeight", Int(reloadedContentHeight ?? self.messagesCollectionView.contentSize.height)),
                    ("finalContentHeight", Int(self.messagesCollectionView.contentSize.height)),
                    ("insetTop", Int(self.messagesCollectionView.adjustedContentInset.top)),
                    ("insetBottom", Int(self.messagesCollectionView.adjustedContentInset.bottom))
                ])
            }
            if forceBottomAlignmentTarget != nil {
                forceBottomAlignmentIfNeeded()
            } else {
                switch outgoingAutoScrollDecision {
                case .scroll(let indexPath):
                    UIView.performWithoutAnimation {
                        self.scrollToBottomAligned(
                            targetIndexPath: indexPath,
                            animated: false
                        )
                    }
                    self.scheduleOutgoingBottomRealignment(targetIndexPath: indexPath)
                case .handledNoScroll:
                    break
                case .notHandled, .useDefaultAndClear:
                    if shouldTailAppendBottomPin {
                        UIView.performWithoutAnimation {
                            self.scrollToBottomAligned(targetIndexPath: nil, animated: false)
                        }
                    } else if shouldAutoScrollToBottom {
                        self.scrollToBottom(animated: shouldAnimateApply)
                    }
                }
            }
            let completionStartedAt = Date()
            completion?()
            let completionMs = ChatArchiveDebugTrace.milliseconds(since: completionStartedAt)
            self.handleChatDatasourceAuxiliaryRefreshAfterApply(
                containsRealMessages: containsRealMessages,
                containsOnlyFakeMessages: containsOnlyFakeMessages
            )
            if self.initialHistoryAppearancePending,
               ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: items.count, containsOnlyFakeMessages: containsOnlyFakeMessages) {
                self.hasRenderedStableInitialHistory = true
                self.finishInitialHistoryAppearanceIfPossible()
            }
            let applyDurationMs = ChatArchiveDebugTrace.milliseconds(since: applyStartedAt)
            let realMessageCount = self.chatOpenTimingRealMessageCount(in: items)
            self.recordChatOpenTimingFirstMessagesPreparedIfNeeded(
                reason: "chatDatasourceApplyFinish",
                modeDescription: modeDescription,
                appliedItemCount: items.count,
                realMessageCount: realMessageCount,
                applyStartedAt: applyStartedAt,
                applyDurationMs: applyDurationMs,
                layoutMs: layoutMs,
                animated: shouldAnimateApply,
                invalidateLayout: invalidateLayout
            )
            self.scheduleChatOpenTimingFirstMessagesVisibleCheck(
                reason: "chatDatasourceApplyFinish",
                modeDescription: modeDescription
            )
            let newContentOffset = self.messagesCollectionView.contentOffset
            let newContentSize = self.messagesCollectionView.contentSize
            let newContentInsets = self.messagesCollectionView.contentInset
            let newBottomDistance = ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: newContentSize.height,
                viewportHeight: self.messagesCollectionView.bounds.height,
                contentInsets: newContentInsets,
                contentOffsetY: newContentOffset.y
            )
            ChatArchiveDebugTrace.log("chatDatasourceApplyFinish", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("mode", modeDescription),
                ("applyCategory", effectiveApplyCategory.rawValue),
                ("anchorRestorePhase", anchorRestorePhase.rawValue),
                ("anchorPrimary", effectiveAnchorPrimary ?? "-"),
                ("anchorRestoredInTransaction", anchorRestoreDiagnostics.restored),
                ("anchorSectionFound", anchorRestoreDiagnostics.sectionFound),
                ("anchorAttributesFound", anchorRestoreDiagnostics.attributesFound),
                ("reloadedOffsetY", Int(reloadedOffsetY ?? newContentOffset.y)),
                ("count", self.datasource.count),
                ("firstArchivedId", self.datasource.first?.archivedId ?? "-"),
                ("lastArchivedId", self.datasource.last?.archivedId ?? "-"),
                ("layoutMs", layoutMs),
                ("insetsMs", insetsMs),
                ("completionMs", completionMs),
                ("finishMs", ChatArchiveDebugTrace.milliseconds(since: finishStartedAt)),
                ("durationMs", applyDurationMs),
                ("oldOffsetY", Int(oldContentOffset.y)),
                ("newOffsetY", Int(newContentOffset.y)),
                ("oldContentHeight", Int(oldContentSize.height)),
                ("newContentHeight", Int(newContentSize.height)),
                ("oldBottomDistance", Int(oldBottomDistance)),
                ("newBottomDistance", Int(newBottomDistance)),
                ("autoScrollToBottom", shouldAutoScrollToBottom),
                ("tailAppendBottomPinned", shouldTailAppendBottomPin),
                ("suppressDefaultBottomScroll", suppressDefaultBottomScroll),
                ("forceBottomAlignmentTarget", forceBottomAlignmentDescription),
                ("forcedBottomAlignmentApplied", forcedBottomAlignmentApplied),
                ("outgoingAutoScroll", "\(outgoingAutoScrollDecision)")
            ])
            datasourceApplySignpost.end()
        }

        let runWithoutAnimation: (@escaping () -> Void) -> Void = { updates in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let wereAnimationsEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            UIView.performWithoutAnimation {
                updates()
                self.messagesCollectionView.layoutIfNeeded()
                self.messagesCollectionView.layer.removeAllAnimations()
                self.messagesCollectionView.visibleCells.forEach {
                    $0.layer.removeAllAnimations()
                    $0.contentView.layer.removeAllAnimations()
                }
            }
            UIView.setAnimationsEnabled(wereAnimationsEnabled)
            CATransaction.commit()
        }

        switch mode {
        case .fullReload(let keepOffset):
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            let updates = {
                let reloadStartedAt = Date()
                if keepOffset {
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                } else {
                    self.messagesCollectionView.reloadData()
                }
                restoreAnchorInApplyTransactionIfNeeded()
                ChatArchiveDebugTrace.log("chatDatasourceReload", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("mode", modeDescription),
                    ("keepOffset", keepOffset),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                    ("count", items.count)
                ])
            }
            if shouldAnimateApply {
                updates()
            } else {
                runWithoutAnimation(updates)
            }
            finish()
        case .windowReload(let keepOffset):
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            let updates = {
                let reloadStartedAt = Date()
                if keepOffset {
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                } else {
                    self.messagesCollectionView.reloadData()
                }
                restoreAnchorInApplyTransactionIfNeeded()
                ChatArchiveDebugTrace.log("chatDatasourceReload", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("mode", modeDescription),
                    ("keepOffset", keepOffset),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                    ("count", items.count)
                ])
            }
            if shouldAnimateApply {
                updates()
            } else {
                runWithoutAnimation(updates)
            }
            finish()
        case .targetedDiff:
            if previousSnapshot.items.isEmpty {
                self.datasource = items
                self.datasourceSnapshot = newSnapshot
                runWithoutAnimation {
                    let reloadStartedAt = Date()
                    self.messagesCollectionView.reloadData()
                    ChatArchiveDebugTrace.log("chatDatasourceReload", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("mode", modeDescription),
                        ("keepOffset", false),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                        ("count", items.count)
                    ])
                }
                finish()
                return
            }

            guard ChatDatasourceCoordinator.supportsTargetedApply(old: previousSnapshot, new: newSnapshot) else {
                self.datasource = items
                self.datasourceSnapshot = newSnapshot
                if shouldAnimateApply {
                    let reloadStartedAt = Date()
                    self.messagesCollectionView.reloadData()
                    ChatArchiveDebugTrace.log("chatDatasourceReload", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("mode", modeDescription),
                        ("keepOffset", false),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                        ("count", items.count)
                    ])
                } else {
                    runWithoutAnimation {
                        let reloadStartedAt = Date()
                        self.messagesCollectionView.reloadData()
                        ChatArchiveDebugTrace.log("chatDatasourceReload", [
                            ("owner", self.owner),
                            ("jid", self.jid),
                            ("conversationType", self.conversationType.rawValue),
                            ("mode", modeDescription),
                            ("keepOffset", false),
                            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                            ("count", items.count)
                        ])
                    }
                }
                finish()
                return
            }

            let flowLayout = self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
            let diff = ChatPerformanceSignposts.measure(.datasourceDiff) {
                ChatDatasourceCoordinator.diff(
                    old: previousSnapshot,
                    new: newSnapshot,
                    oldSizeProvider: { flowLayout?.sizeForMessage($0) },
                    newSizeProvider: { flowLayout?.sizeForMessage($0) }
                )
            }
            self.datasource = items
            self.datasourceSnapshot = newSnapshot

            if ChatOutgoingAutoScrollApplyPolicy.shouldUseImmediateReload(outgoingAutoScrollDecision: outgoingAutoScrollDecision) {
                runWithoutAnimation {
                    let reloadStartedAt = Date()
                    self.messagesCollectionView.reloadData()
                    self.messagesCollectionView.layoutIfNeeded()
                    self.updateChatCollectionInsets()
                    if case .scroll(let indexPath) = outgoingAutoScrollDecision {
                        self.scrollToBottomAligned(targetIndexPath: indexPath, animated: false)
                    }
                    ChatArchiveDebugTrace.log("chatDatasourceOutgoingImmediateReload", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("mode", modeDescription),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                        ("count", items.count)
                    ])
                }
                finish()
                return
            }

            guard !diff.isEmpty else {
                ChatArchiveDebugTrace.log("chatDatasourceTargetedDiffEmpty", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("count", items.count)
                ])
                finish()
                return
            }

            let applyContentOnlyUpdates = {
                diff.contentOnlyUpdates.forEach { update in
                    self.updateVisibleMessageContent(primary: update.primary)
                }
            }

            let applyLayoutUpdates = {
                guard !diff.reloads.isEmpty else { return }
                diff.reloads.forEach { indexPath in
                    guard items.indices.contains(indexPath.section) else { return }
                    flowLayout?.invalidateLastMessageCachedSize(primary: items[indexPath.section].primary)
                }
                self.messagesCollectionView.reconfigureItems(at: diff.reloads)
            }

            let finishAfterNonStructuralUpdates = {
                runWithoutAnimation {
                    applyLayoutUpdates()
                    applyContentOnlyUpdates()
                }
                finish()
            }

            guard diff.hasCollectionUpdates else {
                ChatArchiveDebugTrace.log("chatDatasourceTargetedDiffContentOnly", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("reloads", diff.reloads.count),
                    ("contentOnly", diff.contentOnlyUpdates.count)
                ])
                finishAfterNonStructuralUpdates()
                return
            }

            let updates = {
                let batchStartedAt = Date()
                let batchUpdates = {
                    if !diff.deletes.isEmpty {
                        self.messagesCollectionView.deleteSections(diff.deletes)
                    }
                    if !diff.inserts.isEmpty {
                        self.messagesCollectionView.insertSections(diff.inserts)
                    }
                    diff.moves.forEach {
                        self.messagesCollectionView.moveSection($0.from.section, toSection: $0.to.section)
                    }
                }
                if shouldAnimateApply {
                    self.messagesCollectionView.performBatchUpdates(batchUpdates, completion: { _ in
                        ChatArchiveDebugTrace.log("chatDatasourceBatchUpdatesFinish", [
                            ("owner", self.owner),
                            ("jid", self.jid),
                            ("conversationType", self.conversationType.rawValue),
                            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: batchStartedAt)),
                            ("deletes", diff.deletes.count),
                            ("inserts", diff.inserts.count),
                            ("moves", diff.moves.count)
                        ])
                        finishAfterNonStructuralUpdates()
                    })
                } else {
                    runWithoutAnimation {
                        self.messagesCollectionView.performBatchUpdates(batchUpdates, completion: { _ in
                            ChatArchiveDebugTrace.log("chatDatasourceBatchUpdatesFinish", [
                                ("owner", self.owner),
                                ("jid", self.jid),
                                ("conversationType", self.conversationType.rawValue),
                                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: batchStartedAt)),
                                ("deletes", diff.deletes.count),
                                ("inserts", diff.inserts.count),
                                ("moves", diff.moves.count)
                            ])
                            finishAfterNonStructuralUpdates()
                        })
                    }
                }
            }
            updates()
        }
    }

    @discardableResult
    internal func updateVisibleMessageContent(primary: String) -> Bool {
        guard let section = datasourceSnapshot.primaryIndex[primary],
              let item = self.datasourceItem(atSection: section) else {
            return false
        }

        let indexPath = IndexPath(row: 0, section: section)
        guard let cell = messagesCollectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell else {
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        UIView.performWithoutAnimation {
            cell.reconfigureContent(with: item, at: indexPath, and: messagesCollectionView)
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
        }
        UIView.setAnimationsEnabled(wereAnimationsEnabled)
        CATransaction.commit()
        return true
    }

    internal var datasetCoordinator: ChatDatasetCoordinator {
        ChatDatasetCoordinator(pageSize: self.datasourcePageSize)
    }

    internal func syncCurrentPage(with window: ChatDatasetWindow) {
        self.currentPage.minIndex = window.minIndex
        self.currentPage.maxIndex = window.maxIndex
        self.refreshScrollBoundaryAvailabilityCache(reason: "syncCurrentPage")
    }

    internal func visibleWindow() -> ChatDatasetWindow {
        self.datasetCoordinator.visibleWindow(currentPage: self.currentPage)
    }

    private func messageWindowSliceForMapping(
        _ window: ChatDatasetWindow,
        currentWindow: ChatDatasetWindow,
        timelineState: ChatBoundedTimelineWindowState,
        virtualTimelineState: ChatVirtualTimelineState,
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?,
        isPagingLocked: Bool
    ) -> (window: ChatDatasetWindow, items: [MessageStorageItem], timelineState: ChatBoundedTimelineWindowState, virtualState: ChatVirtualTimelineState) {
        do {
            let realm = try WRealm.safe()
            let provider = ChatLocalHistoryPageProvider(
                realm: realm,
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            let archiveState = self.loadChatArchiveStateSnapshot()
            let normalizedVirtualState = virtualTimelineState.normalized(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            var engine = ChatVirtualTimelineEngine(
                provider: provider,
                pageSize: self.datasourcePageSize,
                state: normalizedVirtualState,
                archiveState: archiveState
            )
            let direction = self.localHistoryDirection(
                requestedWindow: window,
                currentWindow: currentWindow,
                timelineState: ChatBoundedTimelineWindowState(virtualState: normalizedVirtualState)
            )

            let snapshot: ChatTimelineSnapshot
            switch direction {
            case .older:
                snapshot = engine.pageOlder()
            case .newer:
                snapshot = engine.pageNewer()
            case .none:
                if !normalizedVirtualState.isEmpty && window == currentWindow {
                    snapshot = engine.currentSnapshot()
                } else if normalizedVirtualState.isEmpty || window.maxIndex >= currentWindow.maxIndex {
                    snapshot = engine.openLatest()
                } else if let anchor = provider.item(at: max(0, window.minIndex + window.count / 2)) {
                    snapshot = engine.openAround(
                        anchor: ChatTimelineAnchor(
                            primary: anchor.primary,
                            archivedId: anchor.archivedId,
                            messageId: anchor.messageId,
                            date: anchor.date
                        )
                    )
                } else {
                    snapshot = engine.openLatest()
                }
            }

            let frozenItems = snapshot.items.map { $0.freeze() }
            let nextVirtualState = snapshot.state.withRuntimePlaceholder(activePlaceholder)
            let outputWindow = ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count)

            return (
                outputWindow,
                frozenItems,
                ChatBoundedTimelineWindowState(virtualState: nextVirtualState),
                nextVirtualState
            )
        } catch {
            DDLogDebug("ChatViewController.messageWindowSliceForMapping: \(error.localizedDescription)")
            return (.empty, [], .empty, .empty)
        }
    }

    internal func sliceForWindow(_ window: ChatDatasetWindow) -> [MessageStorageItem] {
        let mapped = self.messageWindowSliceForMapping(
            window,
            currentWindow: self.visibleWindow(),
            timelineState: self.boundedTimelineWindowState,
            virtualTimelineState: self.virtualTimelineState,
            activePlaceholder: self.activeHistoryBoundaryPlaceholder,
            isPagingLocked: self.currentPage.locked
        )
        self.virtualTimelineState = mapped.virtualState
        self.boundedTimelineWindowState = mapped.timelineState
        return mapped.items
    }

    private func localHistoryDirection(
        requestedWindow: ChatDatasetWindow,
        currentWindow: ChatDatasetWindow,
        timelineState: ChatBoundedTimelineWindowState
    ) -> ChatHistoryPageDirection? {
        guard !timelineState.isEmpty,
              !currentWindow.isEmpty else {
            return nil
        }

        if requestedWindow.minIndex < currentWindow.minIndex {
            return .older
        }
        if requestedWindow.maxIndex > currentWindow.maxIndex {
            return .newer
        }
        return nil
    }

    private func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        var seen = Set<String>()
        return items
            .enumerated()
            .sorted {
                if $0.element.date == $1.element.date {
                    return $0.offset < $1.offset
                }
                return $0.element.date < $1.element.date
            }
            .map { $0.element }
            .filter { item in
                seen.insert(item.primary).inserted
            }
    }

    internal func ensureObserverLookupMaps(force: Bool = false) {
        guard self.messagesObserver != nil else {
            self.observerPrimaryIndexMap = [:]
            self.observerArchivedIdIndexMap = [:]
            self.observerMessageIdIndexMap = [:]
            self.observerOldestArchivedId = nil
            self.observerNewestArchivedId = nil
            self.observerLookupSignature = nil
            return
        }

        let signature = ObserverLookupSignature(
            count: self.messagesObserver.count,
            firstPrimary: self.messagesObserver.first?.primary,
            lastPrimary: self.messagesObserver.last?.primary
        )

        guard force || self.observerLookupSignature != signature else {
            return
        }

        let lookupMaps = ChatObserverLookupPolicy.build(from: self.messagesObserver)
        self.observerPrimaryIndexMap = lookupMaps.primaryIndex
        self.observerArchivedIdIndexMap = lookupMaps.archivedIdIndex
        self.observerMessageIdIndexMap = lookupMaps.messageIdIndex
        self.observerOldestArchivedId = lookupMaps.oldestArchivedId
        self.observerNewestArchivedId = lookupMaps.newestArchivedId
        self.observerLookupSignature = signature
    }

    internal func setArchiveLoading(_ isLoading: Bool) {
        DispatchQueue.main.async {
            self.messageLoadingActivityIndicator.isHidden = !isLoading
        }
    }

    internal func oldestObservedArchivedId(persistedCursorId: String? = nil) -> String? {
        if let residentOldest = self.virtualTimelineState.oldest?.archivedId {
            return residentOldest
        }
        if let residentOldest = self.boundedTimelineWindowState.oldest?.archivedId {
            return residentOldest
        }
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerOldestArchivedId ?? persistedCursorId ?? self.persistedHistoryCursorId()
    }

    internal func observedOldestArchivedId() -> String? {
        if let residentOldest = self.virtualTimelineState.oldest?.archivedId {
            return residentOldest
        }
        if let residentOldest = self.boundedTimelineWindowState.oldest?.archivedId {
            return residentOldest
        }
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerOldestArchivedId
    }

    internal func observedNewestArchivedId() -> String? {
        if let residentNewest = self.virtualTimelineState.newest?.archivedId {
            return residentNewest
        }
        if let residentNewest = self.boundedTimelineWindowState.newest?.archivedId {
            return residentNewest
        }
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerNewestArchivedId
    }

    internal func observedArchivedIds(in window: ChatDatasetWindow) -> [String] {
        if window == self.visibleWindow(),
           self.virtualTimelineState.residentArchivedIds.isNotEmpty {
            return self.virtualTimelineState.residentArchivedIds
        }
        if window == self.visibleWindow(),
           self.boundedTimelineWindowState.residentArchivedIds.isNotEmpty {
            return self.boundedTimelineWindowState.residentArchivedIds
        }
        guard self.messagesObserver != nil else { return [] }
        let normalized = self.datasetCoordinator.clamp(window, totalCount: self.messagesObserver.count)
        guard normalized.count > 0 else { return [] }
        return (normalized.minIndex..<normalized.maxIndex).compactMap { index in
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(self.messagesObserver[index].archivedId)
        }
    }

    internal func authoritativeOlderPagingCursorId(persistedCursorId: String? = nil) -> String? {
        if let persistedCursorId, persistedCursorId.isNotEmpty {
            return persistedCursorId
        }
        return self.observedOldestArchivedId()
    }

    internal func interactiveOlderPagingCursorSelection(
        in window: ChatDatasetWindow,
        persistedCursorId: String? = nil
    ) -> ChatInteractiveOlderCursorSelection {
        ChatInteractiveOlderCursorSelectionPolicy.select(
            timelineOldestArchivedId: self.virtualTimelineState.oldest?.archivedId,
            boundedOldestArchivedId: self.boundedTimelineWindowState.oldest?.archivedId,
            observedArchivedIds: self.observedArchivedIds(in: window),
            persistedCursorId: persistedCursorId
        )
    }

    internal func visibleNewerPagingCursorId(
        in window: ChatDatasetWindow,
        persistedCursorId: String? = nil
    ) -> String? {
        ChatHistoryCursorSelectionPolicy.newestCursorId(
            observedArchivedIds: self.observedArchivedIds(in: window),
            persistedCursorId: persistedCursorId
        )
    }

    internal func currentGroupchatMemberId(in realm: Realm? = nil) -> String? {
        let resolve: (Realm) -> String? = { realm in
            guard self.conversationType == .group else {
                return nil
            }

            return MentionNotificationSync.currentGroupMemberId(
                owner: self.owner,
                groupchatJid: self.jid,
                in: realm
            )
        }

        if let realm {
            return resolve(realm)
        }

        do {
            return resolve(try WRealm.safe())
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func unreadMentionHintArchivedId() -> String? {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.mentionId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func visibleRealMessagePrimaries() -> Set<String> {
        Set(
            self.messagesCollectionView.indexPathsForVisibleItems.compactMap {
                guard let item = self.datasourceItem(at: $0) else {
                    return nil
                }
                return item.isFakeMessage ? nil : item.primary
            }
        )
    }

    internal func rebuildUnreadMentionItems() {
        guard self.conversationType == .group,
              self.messagesObserver != nil else {
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            return
        }

        do {
            let realm = try WRealm.safe()
            self.ensureObserverLookupMaps()
            let currentMemberId = self.currentGroupchatMemberId(in: realm)
            let notifications = realm.objects(NotificationStorageItem.self)
                .filter("owner == %@ AND category_ == %@", self.owner, XMPPNotificationsManager.Category.mention.rawValue)

            let chatPrimary = LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
            let lookupMaps = ChatObserverLookupMaps(
                primaryIndex: self.observerPrimaryIndexMap,
                archivedIdIndex: self.observerArchivedIdIndexMap,
                messageIdIndex: self.observerMessageIdIndexMap,
                oldestArchivedId: self.observerOldestArchivedId,
                newestArchivedId: self.observerNewestArchivedId
            )
            let notificationBackedItems = ChatUnreadMentionIndexPolicy.rebuild(
                from: notifications,
                messagesObserver: self.messagesObserver,
                observerLookupMaps: lookupMaps,
                in: realm,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: self.jid
            )
            self.unreadMentionItems = notificationBackedItems
            if self.unreadMentionItems.isEmpty,
               let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: chatPrimary),
               let fallbackItem = ChatUnreadMentionFallbackPolicy.fallbackItem(
                mentionId: chat.mentionId,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: self.jid,
                date: chat.messageDate == Date(timeIntervalSince1970: 0) ? Date() : chat.messageDate
               ) {
                self.unreadMentionItems = [fallbackItem]
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
        }
    }

    internal func refreshUnreadMentionsNavigatorState(animated: Bool = false) {
        guard !self.showSkeletonObserver.value else {
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: [])
            if self.shouldShowUnreadMentionsNavigator.value {
                self.shouldShowUnreadMentionsNavigator.accept(false)
            } else {
                self.updateUnreadMentionsNavigatorFrame(animated: animated)
                self.updateScrollDownButtonFrame(animated: animated)
            }
            return
        }

        self.ensureObserverLookupMaps()
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: self.unreadMentionItems,
            observerPrimaryIndexMap: self.observerPrimaryIndexMap,
            visiblePrimaries: self.visibleRealMessagePrimaries(),
            preferredArchivedId: self.unreadMentionHintArchivedId(),
            selectedNotificationPrimary: self.currentUnreadMentionNotificationPrimary
        )
        self.unreadMentionsState = state
        self.currentUnreadMentionNotificationPrimary = state.currentTarget?.notificationPrimary
        self.unreadMentionsNavigatorView.update(
            mode: state.mode,
            unreadCount: state.unreadCount,
            accentColor: self.accountPallete.tint500
        )
        self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: state.visibleUnreadNotificationPrimaries)

        let shouldShowNavigator = ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
            conversationType: self.conversationType,
            unreadCount: state.unreadCount,
            isSearchMode: self.inSearchMode.value
        )

        if self.shouldShowUnreadMentionsNavigator.value != shouldShowNavigator {
            self.shouldShowUnreadMentionsNavigator.accept(shouldShowNavigator)
        } else {
            self.updateUnreadMentionsNavigatorFrame(animated: animated)
            self.updateScrollDownButtonFrame(animated: animated)
        }
    }

    internal func scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: Set<String>) {
        self.visibleUnreadMentionReconciliationWorkItem?.cancel()
        guard !notificationPrimaries.isEmpty else {
            self.visibleUnreadMentionReconciliationWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.markVisibleUnreadMentionNotificationsRead(Array(notificationPrimaries))
        }
        self.visibleUnreadMentionReconciliationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func markVisibleUnreadMentionNotificationsRead(_ notificationPrimaries: [String]) {
        guard notificationPrimaries.isNotEmpty else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let realm = try WRealm.safe()
                var messagePrimariesToMarkRead: Set<String> = []
                var didChangeReadState = false

                try realm.write {
                    notificationPrimaries.forEach { primary in
                        guard let notification = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary),
                              !notification.isRead,
                              notification.isMentionNotification,
                              notification.sourceChatJid == self.jid else {
                            return
                        }

                        notification.isRead = true
                        didChangeReadState = true
                        let result = MentionNotificationSync.reconcile(notification: notification, in: realm)
                        if let messagePrimary = result.linkedMessagePrimaryToMarkRead,
                           messagePrimary.isNotEmpty {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }
                    }

                    MentionNotificationSync.refreshLastChatMentionIds(
                        owner: self.owner,
                        groupchatJids: [self.jid],
                        in: realm
                    )
                }

                guard didChangeReadState else {
                    return
                }

                messagePrimariesToMarkRead.forEach {
                    AccountManager.shared.find(for: self.owner)?.messages.readMessage($0, last: false)
                }

                DispatchQueue.main.async {
                    self.rebuildUnreadMentionItems()
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    internal func loadChatArchiveStateSnapshot() -> ChatArchiveStateSnapshot {
        let primaryKey = LastChatsStorageItem.genPrimary(
            jid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType
        )
        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primaryKey
            )
            let conversationArchiveState = self.conversationType.supportsSnapshotArchiveRepair
                ? realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                )
                : nil
            let persistedCursorId = chat?.lastLoadedMessageHistoryId?.isNotEmpty == true ? chat?.lastLoadedMessageHistoryId : nil
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: conversationArchiveState?.oldestLoadedArchiveId ?? persistedCursorId,
                fullArchiveLoaded: conversationArchiveState?.olderArchiveEndReached ?? chat?.fullArchiveLoaded ?? false,
                newestCursorId: conversationArchiveState?.newestLoadedArchiveId,
                newerLiveEdgeReached: conversationArchiveState?.newerLiveEdgeReached ?? true,
                hasKnownNewerGap: conversationArchiveState?.knownGaps.isNotEmpty ?? false,
                knownGaps: conversationArchiveState?.knownGaps ?? []
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: nil,
                fullArchiveLoaded: false
            )
        }
    }

    internal func persistedHistoryCursorId() -> String? {
        self.loadChatArchiveStateSnapshot().persistedCursorId
    }

    @discardableResult
    internal func applyChatArchiveStateIfNeeded(
        snapshot: ChatArchiveStateSnapshot,
        plan: ChatArchiveStateMutationPlan,
        markNewerLiveEdgeReached: Bool = false
    ) -> ChatArchiveStateSnapshot {
        let updatedSnapshot = ChatArchiveStateSnapshot(
            primaryKey: snapshot.primaryKey,
            persistedCursorId: plan.resolvedCursorId,
            fullArchiveLoaded: plan.fullArchiveLoaded,
            newestCursorId: snapshot.newestCursorId,
            newerLiveEdgeReached: snapshot.newerLiveEdgeReached || markNewerLiveEdgeReached,
            hasKnownNewerGap: snapshot.hasKnownNewerGap,
            knownGaps: snapshot.knownGaps
        )

        guard plan.needsWrite || markNewerLiveEdgeReached else {
            return updatedSnapshot
        }

        do {
            let realm = try WRealm.safe()
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: snapshot.primaryKey
            ) else {
                return snapshot
            }
            try realm.write {
                if chat.isInvalidated { return }
                if plan.shouldWriteCursor {
                    chat.lastLoadedMessageHistoryId = plan.resolvedCursorId
                }
                if plan.shouldWriteFullArchiveLoaded {
                    chat.fullArchiveLoaded = plan.fullArchiveLoaded
                }
                if self.conversationType.supportsSnapshotArchiveRepair {
                    let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType,
                        in: realm
                    )
                    if plan.shouldWriteCursor {
                        archiveState.oldestLoadedArchiveId = plan.resolvedCursorId
                    }
                    if plan.shouldWriteFullArchiveLoaded {
                        archiveState.olderArchiveEndReached = plan.fullArchiveLoaded
                    }
                    if markNewerLiveEdgeReached {
                        archiveState.newerLiveEdgeReached = true
                    }
                    archiveState.updatedAt = Date()
                }
            }
            self.refreshScrollBoundaryAvailabilityCache(reason: "archiveStateChanged")
            return updatedSnapshot
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return snapshot
        }
    }

    internal func applyConversationArchiveLoadedRangeIfNeeded(
        first: String,
        last: String,
        updateKind: RegularArchiveCoverageUpdateKind
    ) {
        guard self.conversationType.supportsSnapshotArchiveRepair,
              first.isNotEmpty || last.isNotEmpty else {
            return
        }

        do {
            let realm = try WRealm.safe()
            try realm.write {
                let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    in: realm
                )
                archiveState.mergeLoadedRange(first: first, last: last, updateKind: updateKind)
                archiveState.updatedAt = Date()

                if let chat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                ) {
                    chat.lastLoadedMessageHistoryId = archiveState.oldestLoadedArchiveId ?? chat.lastLoadedMessageHistoryId
                    chat.fullArchiveLoaded = archiveState.olderArchiveEndReached
                }
            }
            self.refreshScrollBoundaryAvailabilityCache(reason: "archiveCoverageChanged")
        } catch {
            DDLogDebug("ChatViewController.applyConversationArchiveLoadedRangeIfNeeded error=\(error.localizedDescription)")
        }
    }

    internal func isFullArchiveLoaded() -> Bool {
        self.loadChatArchiveStateSnapshot().fullArchiveLoaded
    }

    internal func setFullArchiveLoaded(_ isLoaded: Bool) {
        do {
            let realm = try WRealm.safe()
            if let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            ) {
                guard chat.fullArchiveLoaded != isLoaded else { return }
                try realm.write {
                    if chat.isInvalidated { return }
                    chat.fullArchiveLoaded = isLoaded
                    if self.conversationType.supportsSnapshotArchiveRepair {
                        let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                            owner: self.owner,
                            jid: self.jid,
                            conversationType: self.conversationType,
                            in: realm
                        )
                        archiveState.olderArchiveEndReached = isLoaded
                        archiveState.updatedAt = Date()
                    }
                }
                self.refreshScrollBoundaryAvailabilityCache(reason: "fullArchiveLoadedChanged")
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    internal func pagingBoundaryContext(visibleSections: [Int]) -> ChatHistoryPagingBoundaryContext {
        let visibleRealSections = Array(Set(visibleSections.compactMap { section -> Int? in
            guard let item = self.datasourceItem(atSection: section),
                  !item.isFakeMessage else {
                return nil
            }
            return section
        })).sorted()

        return ChatHistoryPagingBoundaryContext(
            firstRealSection: self.datasource.firstIndex(where: { !$0.isFakeMessage }),
            lastRealSection: self.datasource.lastIndex(where: { !$0.isFakeMessage }),
            visibleRealSections: visibleRealSections
        )
    }

    internal func beginInitialBootstrapTracking(queryId: String) {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.cancelInitialBootstrapTimeout()
        self.initialBootstrapQueryId = queryId
        self.isInitialBootstrapInFlight = true
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapPageEndState = nil
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.initialBootstrapPersistedRowsForQuery = nil
        self.initialBootstrapVisibleRowsForConversation = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
        self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
        self.scheduleInitialBootstrapTimeout(queryId: queryId)
        self.beginChatHistoryLoadActivity(reason: "initial:\(queryId)")
    }

    internal func resetInitialBootstrapTracking() {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.cancelInitialBootstrapTimeout()
        if let initialBootstrapQueryId {
            self.endChatHistoryLoadActivity(reason: "initial:\(initialBootstrapQueryId)")
            self.unregisterRemoteHistoryPersistenceSource(queryId: initialBootstrapQueryId)
            self.unregisterRemoteHistoryFailureDispatcher(queryId: initialBootstrapQueryId)
            self.unregisterRemoteHistoryEndPageDispatcher(queryId: initialBootstrapQueryId)
        }
        self.initialBootstrapQueryId = nil
        self.isInitialBootstrapInFlight = false
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapPageEndState = nil
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.initialBootstrapPersistedRowsForQuery = nil
        self.initialBootstrapVisibleRowsForConversation = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
    }

    internal func scheduleInitialBootstrapTimeout(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        self.cancelInitialBootstrapTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleInitialBootstrapRemoteArchiveFailure(
                queryId: queryId,
                reason: .timeout,
                streamKind: .unknown,
                errorDescription: nil
            )
        }
        self.initialBootstrapTimeoutWorkItem = workItem
        ChatArchiveDebugTrace.log("initialBootstrapTimeoutScheduled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("timeoutMs", Int(ChatInteractiveRemoteArchiveTimeoutPolicy.timeout * 1000))
        ])
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            execute: workItem
        )
    }

    internal func cancelInitialBootstrapTimeout() {
        self.initialBootstrapTimeoutWorkItem?.cancel()
        self.initialBootstrapTimeoutWorkItem = nil
    }

    internal func localHistoryMessageCountForBootstrap() -> Int {
        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            return provider.latest(limit: 1).isEmpty ? 0 : 1
        } catch {
            DDLogDebug("ChatViewController.localHistoryMessageCountForBootstrap: \(error.localizedDescription)")
            return self.messagesObserver?.count ?? 0
        }
    }

    @discardableResult
    internal func completeInitialBootstrapIfNeeded() -> Bool {
        guard self.isInitialBootstrapInFlight else {
            return false
        }

        let queryId = self.initialBootstrapQueryId
        let localMessageCount = self.localHistoryMessageCountForBootstrap()
        let visibleRowsForLatestPage = self.initialBootstrapVisibleRowsForConversation ?? 0
        let persistedRowsForQuery = self.initialBootstrapPersistedRowsForQuery ?? 0
        let hasMessages = visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0
        let didConfirmEmpty = self.initialBootstrapResultCount == 0
        let isMessagePipelineIdle = queryId.flatMap {
            !ChatRemoteHistoryCompletionCoordinator.hasPendingMessages(owner: self.owner, queryId: $0)
        } ?? true
        let isArchivePagePersisted = visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0

        let requiresObserverSettle = visibleRowsForLatestPage > 0
        if self.didReceiveInitialBootstrapEndPage,
           isMessagePipelineIdle,
           requiresObserverSettle,
           !isArchivePagePersisted,
           !self.didEnterInitialBootstrapObserverSettlePhase {
            self.didEnterInitialBootstrapObserverSettlePhase = true
            DispatchQueue.main.async {
                self.didObserveInitialBootstrapPostIdleTick = true
                _ = self.completeInitialBootstrapIfNeeded()
            }
            return false
        }

        guard ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: self.didReceiveInitialBootstrapEndPage,
            hasMessages: hasMessages,
            didConfirmEmpty: didConfirmEmpty,
            isMessagePipelineIdle: isMessagePipelineIdle,
            isArchivePagePersisted: isArchivePagePersisted,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: self.didObserveInitialBootstrapPostIdleTick
        ) else {
            return false
        }

        let snapshot = self.loadChatArchiveStateSnapshot()
        let shouldCommitArchiveEnd = ChatInitialBootstrapArchiveEndCommitPolicy.shouldCommitArchiveEnd(
            state: self.initialBootstrapPageEndState,
            resultCount: self.initialBootstrapResultCount,
            visibleRowsForLatestPage: visibleRowsForLatestPage,
            persistedRowsForQuery: persistedRowsForQuery
        )
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: self.observedOldestArchivedId(),
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: snapshot.fullArchiveLoaded || shouldCommitArchiveEnd
        )
        _ = self.applyChatArchiveStateIfNeeded(
            snapshot: snapshot,
            plan: plan,
            markNewerLiveEdgeReached: true
        )
        self.rebuildUnreadMentionItems()
        let persistedMessageCount = self.initialBootstrapPersistedMessageCount ?? 0
        self.resetInitialBootstrapTracking()
        DDLogDebug("ChatViewController.initialBootstrap finished queryId=\(queryId ?? "-") persisted=\(persistedMessageCount) persistedRowsForQuery=\(persistedRowsForQuery) visibleRows=\(visibleRowsForLatestPage) localCount=\(localMessageCount)")
        self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
        self.flushPendingArchiveObserverRefreshIfPossible(reason: "initialBootstrapComplete")
        return true
    }

    internal func scheduleInitialBootstrapLocalHistoryFallbackIfNeeded() {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldScheduleFallback(
            messageCount: self.localHistoryMessageCountForBootstrap(),
            isShowingSkeleton: self.showSkeletonObserver.value,
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
            isRequiredArchiveBootstrapInFlight: self.isInitialBootstrapInFlight || self.currentBootstrapRequiresArchiveConfirmation()
        ) else {
            return
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.initialBootstrapLocalHistoryFallbackWorkItem = nil
            _ = self.revealStaleLocalHistoryIfNeeded()
        }
        self.initialBootstrapLocalHistoryFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatBootstrapLocalHistoryFallbackPolicy.fallbackDelay,
            execute: workItem
        )
    }

    internal func cancelInitialBootstrapLocalHistoryFallback() {
        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = false
    }

    @discardableResult
    internal func revealStaleLocalHistoryIfNeeded() -> Bool {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldRevealLocalHistory(
            messageCount: self.localHistoryMessageCountForBootstrap(),
            isShowingSkeleton: self.showSkeletonObserver.value,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
            isRequiredArchiveBootstrapInFlight: self.isInitialBootstrapInFlight || self.currentBootstrapRequiresArchiveConfirmation()
        ) else {
            return false
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = true
        self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
        return true
    }

    @discardableResult
    internal func revealInitialBootstrapContentIfAvailable() -> Bool {
        let state = self.currentBootstrapViewState()
        guard ChatInitialBootstrapContentRevealPolicy.shouldRevealContent(
            isShowingSkeleton: self.showSkeletonObserver.value,
            bootstrapState: state
        ) else {
            return false
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.applyBootstrapViewState(state, forceRender: true)
        return true
    }

    internal func handleInitialBootstrapRemoteArchiveFailure(
        queryId: String,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        self.performOnMain {
            guard self.isInitialBootstrapInFlight,
                  self.initialBootstrapQueryId == queryId else {
                ChatArchiveDebugTrace.log("initialBootstrapFailureSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("activeQueryId", self.initialBootstrapQueryId ?? "-"),
                    ("reason", reason.rawValue)
                ])
                return
            }

            let localMessageCount = self.localHistoryMessageCountForBootstrap()
            let shouldRevealLocalHistory = ChatInitialBootstrapFailureRecoveryPolicy.shouldRevealLocalHistory(
                messageCount: localMessageCount,
                hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest()
            )
            ChatArchiveDebugTrace.log("initialBootstrapFailure", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", reason.rawValue),
                ("streamKind", streamKind.rawValue),
                ("error", errorDescription ?? "none"),
                ("localCount", localMessageCount),
                ("revealLocalHistory", shouldRevealLocalHistory)
            ])

            self.resetInitialBootstrapTracking()
            if shouldRevealLocalHistory {
                self.allowsStaleLocalHistoryDuringInitialBootstrap = true
            }
            self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
            self.cancelPendingArchiveObserverRefresh(reason: "initialBootstrapFailure")
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
    }

    @discardableResult
    internal func handleInitialBootstrapEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        count: Int,
        persistedMessageCount: Int,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int
    ) -> Bool {
        guard queryId == self.initialBootstrapQueryId else {
            return false
        }

        self.didReceiveInitialBootstrapEndPage = true
        self.initialBootstrapPageEndState = state
        self.initialBootstrapResultCount = count
        self.initialBootstrapPersistedMessageCount = persistedMessageCount
        self.initialBootstrapPersistedRowsForQuery = persistedRowsForQuery
        self.initialBootstrapVisibleRowsForConversation = visibleRowsForConversation
        _ = self.completeInitialBootstrapIfNeeded()
        self.flushPendingArchiveObserverRefreshIfPossible(reason: "initialBootstrapEndPage")
        return true
    }

    internal func capturePagingAnchorIfNeeded(direction: ChatHistoryPageDirection) -> ChatHistoryPageAnchor? {
        let candidateSections = self.messagesCollectionView
            .indexPathsForVisibleItems
            .compactMap(\.section)
            .sorted()
            .filter {
                guard let item = self.datasourceItem(atSection: $0) else {
                    return false
                }
                return !item.isFakeMessage
            }

        let anchorSection: Int?
        switch direction {
        case .older:
            anchorSection = candidateSections.min()
        case .newer:
            anchorSection = self.isNearBottom() ? nil : candidateSections.max()
        }

        guard let section = anchorSection else {
            return nil
        }

        let indexPath = IndexPath(item: 0, section: section)
        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame

        guard let frame else {
            return nil
        }

        guard let item = self.datasourceItem(atSection: section) else {
            return nil
        }

        return ChatHistoryPageAnchor(
            primary: item.primary,
            offsetFromViewportTop: frame.minY - self.messagesCollectionView.contentOffset.y
        )
    }

    private func restorePagingAnchorAndCollectDiagnostics(_ anchor: ChatHistoryPageAnchor) -> ChatHistoryPageAnchorRestoreDiagnostics {
        var diagnostics = ChatHistoryPageAnchorRestoreDiagnostics()
        guard let section = self.datasourceSnapshot.primaryIndex[anchor.primary] else {
            return diagnostics
        }
        diagnostics.sectionFound = true

        let indexPath = IndexPath(item: 0, section: section)
        self.messagesCollectionView.layoutIfNeeded()

        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame
        diagnostics.attributesFound = frame != nil

        guard let frame else {
            return diagnostics
        }

        let minOffsetY = -self.messagesCollectionView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            self.messagesCollectionView.contentSize.height -
            self.messagesCollectionView.bounds.height +
            self.messagesCollectionView.adjustedContentInset.bottom
        )
        let targetY = ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
            anchorMinY: frame.minY,
            offsetFromViewportTop: anchor.offsetFromViewportTop,
            minContentOffsetY: minOffsetY,
            maxContentOffsetY: maxOffsetY
        )
        diagnostics.targetOffsetY = targetY

        self.messagesCollectionView.setContentOffset(
            CGPoint(
                x: self.messagesCollectionView.contentOffset.x,
                y: targetY
            ),
            animated: false
        )
        diagnostics.restored = true
        return diagnostics
    }

    internal func restorePagingAnchor(_ anchor: ChatHistoryPageAnchor) {
        let diagnostics = self.restorePagingAnchorAndCollectDiagnostics(anchor)
        ChatArchiveDebugTrace.log("chatDatasourceAnchorRestore", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("phase", ChatHistoryPageAnchorRestorePhase.completion.rawValue),
            ("anchorPrimary", anchor.primary),
            ("sectionFound", diagnostics.sectionFound),
            ("attributesFound", diagnostics.attributesFound),
            ("restored", diagnostics.restored),
            ("targetOffsetY", Int(diagnostics.targetOffsetY ?? self.messagesCollectionView.contentOffset.y)),
            ("finalOffsetY", Int(self.messagesCollectionView.contentOffset.y)),
            ("contentHeight", Int(self.messagesCollectionView.contentSize.height)),
            ("insetTop", Int(self.messagesCollectionView.adjustedContentInset.top)),
            ("insetBottom", Int(self.messagesCollectionView.adjustedContentInset.bottom))
        ])
    }

    internal func abortInteractiveHistoryPageLoad() {
        self.abortInteractiveHistoryPageLoad(
            queryId: self.interactiveHistoryPageLoadContext?.queryId,
            reason: .requestStartFailed,
            streamKind: .unknown,
            errorDescription: nil
        )
    }

    internal func handleInteractiveRemoteArchiveFailure(
        queryId: String,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        self.performOnMain {
            guard let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveAbortSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", reason.rawValue),
                    ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
                ])
                return
            }

            if reason == .timeout {
                let startedAt = self.remoteHistoryRequestStartedAtByQueryId[queryId]
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveTimeout", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("ageMs", startedAt.map { ChatArchiveDebugTrace.milliseconds(since: $0) } ?? -1),
                    ("direction", context.direction),
                    ("cursor", context.requestedCursorId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.currentPage.locked)
                ])
            } else if reason == .uiActionDisconnect {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveDisconnect", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("streamKind", streamKind.rawValue),
                    ("disconnectError", errorDescription ?? "none"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.currentPage.locked)
                ])
            }

            self.abortInteractiveHistoryPageLoad(
                queryId: queryId,
                reason: reason,
                streamKind: streamKind,
                errorDescription: errorDescription
            )
        }
    }

    internal func handleInteractiveRemoteArchiveRequestStartTimeout(queryId: String) {
        self.performOnMain {
            guard let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartTimeoutSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", "queryMismatch"),
                    ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
                ])
                return
            }

            guard !context.remoteFetchStarted else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartTimeoutSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", "alreadyStarted"),
                    ("direction", context.direction),
                    ("cursor", context.requestedCursorId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.currentPage.locked)
                ])
                return
            }

            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchTimeout", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("direction", context.direction),
                ("cursor", context.requestedCursorId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("pageLocked", self.currentPage.locked),
                ("remoteFetchStarted", context.remoteFetchStarted),
                ("visibleLoader", self.currentPage.isLoading),
                ("placeholderState", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count)
            ])
            self.abortInteractiveHistoryPageLoad(
                queryId: queryId,
                reason: .requestStartFailed,
                streamKind: .unknown,
                errorDescription: "request dispatch did not start"
            )
        }
    }

    private func abortInteractiveHistoryPageLoad(
        queryId: String?,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        let hadBoundaryPlaceholder = self.activeHistoryBoundaryPlaceholder != nil
        let hadVirtualPlaceholder = self.virtualTimelineState.activePlaceholder != nil
        if let queryId {
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
            self.abortedRemoteHistoryQueryIds.insert(queryId)
            self.virtualTimelineState = self.virtualTimelineState.abortingRemoteLoad(queryId: queryId)
            self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: self.virtualTimelineState)
            self.refreshScrollBoundaryAvailabilityCache(reason: "remoteLoadAbort")
        }
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        self.cancelInteractiveHistoryCompletionRetry()
        self.interactiveHistoryPageLoadContext = nil
        self.activeHistoryBoundaryPlaceholder = nil
        self.endHistoryLoadingUI(unlockPage: false)
        self.setArchiveLoading(false)
        self.currentPage.unlock()
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveAbort", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId ?? "-"),
            ("reason", reason.rawValue),
            ("streamKind", streamKind.rawValue),
            ("error", errorDescription ?? "none"),
            ("placeholderRemoved", hadBoundaryPlaceholder || hadVirtualPlaceholder),
            ("activeRemoteLoadCleared", self.virtualTimelineState.activeRemoteLoad == nil),
            ("coverageCommitted", false)
        ])
        if hadBoundaryPlaceholder || hadVirtualPlaceholder {
            self.mapAndApplyTimelineCurrent(
                mode: .windowReload(keepOffset: true),
                animated: false,
                invalidateLayout: false,
                preserveBoundaryPlaceholder: false
            )
        }
    }

    private func scheduleInteractiveHistoryCompletionRetry(queryId: String) {
        self.interactiveHistoryCompletionRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId,
                  context.didReceiveEndPage else {
                return
            }

            if self.tryFinishInteractiveHistoryPageLoadIfReady() {
                return
            }

            self.scheduleInteractiveHistoryCompletionRetry(queryId: queryId)
        }
        self.interactiveHistoryCompletionRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func cancelInteractiveHistoryCompletionRetry() {
        self.interactiveHistoryCompletionRetryWorkItem?.cancel()
        self.interactiveHistoryCompletionRetryWorkItem = nil
    }

    internal func finishPagingInteraction(
        window: ChatDatasetWindow,
        shouldApplyWindow: Bool,
        direction: ChatHistoryPageDirection,
        animated: Bool = true
    ) {
        let anchor = self.capturePagingAnchorIfNeeded(direction: direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let applyAnimated = applyPlan.applyCategory == .olderAnchorReload ? false : animated
        let hadBoundaryPlaceholder = self.activeHistoryBoundaryPlaceholder != nil
        self.activeHistoryBoundaryPlaceholder = nil

        guard shouldApplyWindow else {
            guard hadBoundaryPlaceholder else {
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
                return
            }

            self.mapAndApplyTimelineCurrent(
                mode: applyMode,
                animated: false,
                invalidateLayout: false,
                preserveBoundaryPlaceholder: false,
                applyCategory: applyPlan.applyCategory,
                anchorRestorePhase: applyPlan.restorePhase,
                anchorPrimary: anchor?.primary,
                restoreAnchor: anchor,
                completion: {
                    if applyPlan.restorePhase == .completion,
                       let anchor {
                        self.restorePagingAnchor(anchor)
                    }
                    self.endHistoryLoadingUI(unlockPage: false)
                    self.currentPage.unlock()
                },
                cancelledCompletion: {
                    self.endHistoryLoadingUI(unlockPage: false)
                    self.currentPage.unlock()
                }
            )
            return
        }

        self.mapAndApplyTimelineCurrent(
            mode: applyMode,
            animated: applyAnimated,
            invalidateLayout: false,
            preserveBoundaryPlaceholder: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: {
                if applyPlan.restorePhase == .completion,
                   let anchor {
                    self.restorePagingAnchor(anchor)
                }
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
            },
            cancelledCompletion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
            }
        )
    }

    internal func finishPagingInteraction(
        snapshot: ChatTimelineSnapshot,
        direction: ChatHistoryPageDirection,
        animated: Bool = true
    ) {
        let anchor = self.capturePagingAnchorIfNeeded(direction: direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let applyAnimated = applyPlan.applyCategory == .olderAnchorReload ? false : animated
        self.activeHistoryBoundaryPlaceholder = nil

        self.mapAndApplyTimelineSnapshot(
            snapshot,
            mode: applyMode,
            animated: applyAnimated,
            invalidateLayout: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: {
                if applyPlan.restorePhase == .completion,
                   let anchor {
                    self.restorePagingAnchor(anchor)
                }
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
            },
            cancelledCompletion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
            }
        )
    }

    @discardableResult
    internal func completeInteractiveHistoryPageLoadIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int = 0
    ) -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            return false
        }

        context.didReceiveEndPage = true
        context.queryExhausted = state.queryExhausted
        context.persistedMessageCount = max(
            state.persistedMessageCount,
            persistedRowsForQuery,
            visibleRowsForConversation
        )
        context.resultFirst = first
        context.resultLast = last
        context.resultCount = count
        context.persistedRowsForQuery = persistedRowsForQuery
        context.visibleRowsForConversation = visibleRowsForConversation
        context.isArchivePagePersisted = persistedRowsForQuery > 0 || visibleRowsForConversation > 0
        self.interactiveHistoryPageLoadContext = context
        if !self.tryFinishInteractiveHistoryPageLoadIfReady() {
            self.scheduleInteractiveHistoryCompletionRetry(queryId: queryId)
        }

        return true
    }

    @discardableResult
    internal func tryFinishInteractiveHistoryPageLoadIfReady() -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.didReceiveEndPage else {
            return false
        }

        let currentArchiveState = self.loadChatArchiveStateSnapshot()
        let currentCount = self.messagesObserver?.count ?? 0
        let currentOldestArchivedId = self.observedOldestArchivedId()
        let currentNewestArchivedId = self.observedNewestArchivedId()
        let didAdvance = ChatHistoryPageCompletionPolicy.didAdvance(
            direction: context.direction,
            previousObserverCount: context.preLoadObserverCount,
            currentObserverCount: currentCount,
            previousOldestArchivedId: context.preLoadOldestArchivedId,
            currentOldestArchivedId: currentOldestArchivedId,
            previousNewestArchivedId: context.preLoadNewestArchivedId,
            currentNewestArchivedId: currentNewestArchivedId,
            previousArchiveEnded: context.preLoadFullArchiveLoaded,
            currentArchiveEnded: currentArchiveState.fullArchiveLoaded,
            previousNewerLiveEdgeReached: context.preLoadNewerLiveEdgeReached,
            currentNewerLiveEdgeReached: currentArchiveState.newerLiveEdgeReached
        )
        let hasProviderVisibleRows = context.visibleRowsForConversation > 0
        let isMessagePipelineIdle = !ChatRemoteHistoryCompletionCoordinator.hasPendingMessages(
            owner: self.owner,
            queryId: context.queryId
        )
        let requiresObserverSettle = (context.persistedMessageCount ?? 0) > 0
        let persistenceReady = isMessagePipelineIdle || context.isArchivePagePersisted

        if requiresObserverSettle,
           persistenceReady,
           !context.isArchivePagePersisted,
           !context.didEnterObserverSettlePhase {
            context.didEnterObserverSettlePhase = true
            self.interactiveHistoryPageLoadContext = context

            DispatchQueue.main.async {
                guard var settleContext = self.interactiveHistoryPageLoadContext,
                      settleContext.queryId == context.queryId else {
                    return
                }
                settleContext.didObservePostIdleTick = true
                self.interactiveHistoryPageLoadContext = settleContext
                _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
            }
            return false
        }

        guard ChatHistoryPageCompletionPolicy.shouldFinish(
            didReceiveEndPage: context.didReceiveEndPage,
            didAdvance: didAdvance,
            persistedMessageCount: context.persistedMessageCount,
            isMessagePipelineIdle: isMessagePipelineIdle,
            isArchivePagePersisted: context.isArchivePagePersisted,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: context.didObservePostIdleTick
        ) else {
            return false
        }

        if !hasProviderVisibleRows,
           context.resultCount > 0 {
            let eventName = context.persistedRowsForQuery > 0
                ? "nonVisiblePersistedRows"
                : "persistenceMissing"
            DDLogDebug(
                "ChatViewController.interactivePaging \(eventName) queryId=\(context.queryId) count=\(context.resultCount) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) direction=\(context.direction)"
            )
        }

        let anchor = self.capturePagingAnchorIfNeeded(direction: context.direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: context.direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let remoteApplyConversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        self.cancelInteractiveHistoryCompletionRetry()
        self.interactiveHistoryPageLoadContext = nil
        self.remoteHistoryFinishingQueryId = context.queryId
        self.unregisterRemoteHistoryPersistenceSource(queryId: context.queryId)
        self.rebuildUnreadMentionItems()

        self.mapAndApplyFinishedVirtualTimelineRemoteLoad(
            queryId: context.queryId,
            archiveState: currentArchiveState,
            refetchDirection: context.direction,
            visibleRows: context.visibleRowsForConversation,
            resultCount: context.resultCount,
            queryExhausted: context.queryExhausted,
            mode: applyMode,
            animated: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: { applyResult in
                self.commitRemoteHistoryArchiveStateAfterApply(
                    context: context,
                    applyResult: applyResult,
                    baseArchiveState: currentArchiveState
                )

                if !applyResult.didAdvance,
                   context.resultCount > 0 {
                    DDLogDebug(
                        "ChatViewController.remoteHistoryApplyNoAdvance queryId=\(context.queryId) direction=\(context.direction) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) count=\(context.resultCount) oldOldest=\(applyResult.previousOldestArchivedId ?? "-") newOldest=\(applyResult.newOldestArchivedId ?? "-") oldNewest=\(applyResult.previousNewestArchivedId ?? "-") newNewest=\(applyResult.newNewestArchivedId ?? "-")"
                    )
                }

                if applyPlan.restorePhase == .completion,
                   let anchor {
                    self.restorePagingAnchor(anchor)
                }
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
                self.remoteHistoryFinishingQueryId = nil
                DDLogDebug(
                    "ChatViewController.remoteHistoryApplySuccess queryId=\(context.queryId) direction=\(context.direction) didAdvance=\(applyResult.didAdvance) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) persisted=\(context.persistedMessageCount ?? 0) items=\(applyResult.itemCount) oldOldest=\(applyResult.previousOldestArchivedId ?? "-") newOldest=\(applyResult.newOldestArchivedId ?? "-") oldNewest=\(applyResult.previousNewestArchivedId ?? "-") newNewest=\(applyResult.newNewestArchivedId ?? "-") queueWaitMs=\(applyResult.queueWaitMs) mapMs=\(applyResult.mapDurationMs)"
                )
            },
            cancelledCompletion: {
                self.clearFinishedRemoteLoadRuntimeStateIfNeeded(
                    queryId: context.queryId,
                    conversationKey: remoteApplyConversationKey
                )
                self.remoteHistoryFinishingQueryId = nil
                self.endHistoryLoadingUI(unlockPage: false)
                self.currentPage.unlock()
            }
        )

        return true
    }

    internal func mapAndApplyWindow(
        _ window: ChatDatasetWindow,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration
        let boundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
        let isPagingLocked = self.currentPage.locked
        let currentWindow = self.visibleWindow()
        let timelineState = self.boundedTimelineWindowState
        let virtualTimelineState = self.virtualTimelineState

        self.datasetMappingQueue.async {
            let mappedWindow = self.messageWindowSliceForMapping(
                window,
                currentWindow: currentWindow,
                timelineState: timelineState,
                virtualTimelineState: virtualTimelineState,
                activePlaceholder: boundaryPlaceholder,
                isPagingLocked: isPagingLocked
            )
            let normalizedWindow = mappedWindow.window
            let slice = mappedWindow.items
            let nextTimelineState = mappedWindow.timelineState
            let nextVirtualTimelineState = mappedWindow.virtualState
            var mappedDatasource = self.mapDataset(dataset: slice)
            if let boundaryPlaceholder {
                mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                    to: mappedDatasource,
                    position: boundaryPlaceholder
                )
            }

            DispatchQueue.main.async {
                guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }
                self.virtualTimelineState = nextVirtualTimelineState
                self.boundedTimelineWindowState = nextTimelineState
                self.syncCurrentPage(with: normalizedWindow)
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelineAnchor(
        _ anchor: ChatTimelineAnchor,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration
        let boundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
        let virtualTimelineState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )

        self.datasetMappingQueue.async {
            do {
                let provider = ChatLocalHistoryPageProvider(
                    realm: try WRealm.safe(),
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                )
                var engine = ChatVirtualTimelineEngine(
                    provider: provider,
                    pageSize: self.datasourcePageSize,
                    state: virtualTimelineState,
                    archiveState: self.loadChatArchiveStateSnapshot()
                )
                let snapshot = engine.openAround(anchor: anchor)
                let frozenItems = snapshot.items.map { $0.freeze() }
                let nextVirtualState = snapshot.state.withRuntimePlaceholder(boundaryPlaceholder)
                var mappedDatasource = self.mapDataset(dataset: frozenItems)
                if let boundaryPlaceholder {
                    mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                        to: mappedDatasource,
                        position: boundaryPlaceholder
                    )
                }

                DispatchQueue.main.async {
                    guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                        requestGeneration: generation,
                        currentGeneration: self.datasetMappingGeneration
                    ) else {
                        cancelledCompletion?()
                        return
                    }

                    self.virtualTimelineState = nextVirtualState
                    self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
                    self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                    self.applyChatDatasource(
                        mappedDatasource,
                        mode: mode,
                        animated: animated,
                        invalidateLayout: invalidateLayout,
                        completion: completion
                    )
                }
            } catch {
                DDLogDebug("ChatViewController.mapAndApplyTimelineAnchor: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    cancelledCompletion?()
                }
            }
        }
    }

    internal func mapAndApplyTimelineLatest(
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        limit: Int? = nil,
        suppressDefaultBottomScroll: Bool = false,
        forceBottomAlignmentTarget: ChatBottomAlignmentTarget? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration
        let virtualTimelineState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )

        self.datasetMappingQueue.async {
            do {
                let provider = ChatLocalHistoryPageProvider(
                    realm: try WRealm.safe(),
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                )
                var engine = ChatVirtualTimelineEngine(
                    provider: provider,
                    pageSize: self.datasourcePageSize,
                    state: virtualTimelineState,
                    archiveState: self.loadChatArchiveStateSnapshot()
                )
                let snapshot = engine.scrollToLatest(limit: limit)
                let frozenItems = snapshot.items.map { $0.freeze() }
                let nextVirtualState = snapshot.state
                let mappedDatasource = self.mapDataset(dataset: frozenItems)

                DispatchQueue.main.async {
                    guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                        requestGeneration: generation,
                        currentGeneration: self.datasetMappingGeneration
                    ) else {
                        cancelledCompletion?()
                        return
                    }

                    self.activeHistoryBoundaryPlaceholder = nil
                    self.virtualTimelineState = nextVirtualState
                    self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
                    self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                    if let limit,
                       limit == self.initialFirstFramePageSize {
                        self.armInitialFirstFrameLatestWarmupIfNeeded(
                            appliedRealMessageCount: frozenItems.count,
                            availableLocalMessageCount: self.messagesObserver?.count ?? frozenItems.count,
                            isResidentAtLiveTail: nextVirtualState.isResidentAtLiveTail
                        )
                    }
                    self.applyChatDatasource(
                        mappedDatasource,
                        mode: mode,
                        animated: animated,
                        invalidateLayout: invalidateLayout,
                        suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                        forceBottomAlignmentTarget: forceBottomAlignmentTarget,
                        completion: completion
                    )
                }
            } catch {
                DDLogDebug("ChatViewController.mapAndApplyTimelineLatest: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    cancelledCompletion?()
                }
            }
        }
    }

    internal func mapAndApplyTimelineCurrent(
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        preserveBoundaryPlaceholder: Bool = true,
        suppressDefaultBottomScroll: Bool = false,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration
        let boundaryPlaceholder = preserveBoundaryPlaceholder ? self.activeHistoryBoundaryPlaceholder : nil
        let virtualTimelineState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )

        self.datasetMappingQueue.async {
            do {
                let provider = ChatLocalHistoryPageProvider(
                    realm: try WRealm.safe(),
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                )
                let engine = ChatVirtualTimelineEngine(
                    provider: provider,
                    pageSize: self.datasourcePageSize,
                    state: virtualTimelineState,
                    archiveState: self.loadChatArchiveStateSnapshot()
                )
                let snapshot = engine.currentSnapshot()
                let frozenItems = snapshot.items.map { $0.freeze() }
                let nextVirtualState = snapshot.state.withRuntimePlaceholder(boundaryPlaceholder)
                var mappedDatasource = self.mapDataset(dataset: frozenItems)
                if let boundaryPlaceholder {
                    mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                        to: mappedDatasource,
                        position: boundaryPlaceholder
                    )
                }

                DispatchQueue.main.async {
                    guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                        requestGeneration: generation,
                        currentGeneration: self.datasetMappingGeneration
                    ) else {
                        cancelledCompletion?()
                        return
                    }

                    self.virtualTimelineState = nextVirtualState
                    self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
                    self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                    self.applyChatDatasource(
                        mappedDatasource,
                        mode: mode,
                        animated: animated,
                        invalidateLayout: invalidateLayout,
                        suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                        applyCategory: applyCategory,
                        anchorRestorePhase: anchorRestorePhase,
                        anchorPrimary: anchorPrimary,
                        restoreAnchor: restoreAnchor,
                        completion: completion
                    )
                }
            } catch {
                DDLogDebug("ChatViewController.mapAndApplyTimelineCurrent: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    cancelledCompletion?()
                }
            }
        }
    }

    internal func mapAndApplyTimelineSnapshot(
        _ snapshot: ChatTimelineSnapshot,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        suppressDefaultBottomScroll: Bool = false,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration
        let frozenItems = snapshot.items.map { $0.freeze() }
        let nextVirtualState = snapshot.state

        self.datasetMappingQueue.async {
            let mappedDatasource = self.mapDataset(dataset: frozenItems)

            DispatchQueue.main.async {
                guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }

                self.virtualTimelineState = nextVirtualState
                self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
                self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                    applyCategory: applyCategory,
                    anchorRestorePhase: anchorRestorePhase,
                    anchorPrimary: anchorPrimary,
                    restoreAnchor: restoreAnchor,
                    completion: completion
                )
            }
        }
    }

    internal func datasourceByAddingHistoryBoundaryPlaceholder(
        to datasource: [Datasource],
        position: ChatHistoryBoundaryPlaceholderPosition
    ) -> [Datasource] {
        guard !self.showSkeletonObserver.value else {
            return datasource
        }

        let placeholder = self.historyBoundaryPlaceholderDatasource(
            position: position,
            relativeTo: datasource
        )
        switch position {
        case .top:
            return [placeholder] + datasource
        case .bottom:
            return datasource + [placeholder]
        }
    }

    private func historyBoundaryPlaceholderDatasource(
        position: ChatHistoryBoundaryPlaceholderPosition,
        relativeTo datasource: [Datasource]
    ) -> Datasource {
        let primary = "history-boundary-placeholder-\(position)"
        let message = self.skeletonMessages.first ?? NSAttributedString(string: "")
        let neighborDate: Date? = {
            switch position {
            case .top:
                return datasource.first(where: { !$0.isFakeMessage })?.sentDate
            case .bottom:
                return datasource.last(where: { !$0.isFakeMessage })?.sentDate
            }
        }()
        let sentDate: Date
        switch position {
        case .top:
            sentDate = neighborDate?.addingTimeInterval(-1) ?? Date()
        case .bottom:
            sentDate = neighborDate?.addingTimeInterval(1) ?? Date()
        }

        return Datasource(
            primary: primary,
            jid: self.jid,
            owner: self.owner,
            outgoing: false,
            sender: self.opponentSender,
            messageId: primary,
            sentDate: sentDate,
            editDate: nil,
            kind: .skeleton(message),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .none,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: primary,
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: true,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(),
            indicator: .none,
            avatarUrl: nil
        )
    }

    internal func showHistoryBoundaryPlaceholder(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow
    ) {
        self.activeHistoryBoundaryPlaceholder = direction == .older ? .top : .bottom
        self.mapAndApplyTimelineCurrent(
            mode: .windowReload(keepOffset: ChatHistoryPageApplyPolicy.keepOffset(direction: direction)),
            animated: false,
            invalidateLayout: false
        )
    }

    internal var isShowingBootstrapPlaceholder: Bool {
        self.datasource.isEmpty || self.datasource.allSatisfy(\.isFakeMessage)
    }

    internal var shouldAnimateInitialHistoryAppearance: Bool {
        ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(
                isInitialHistoryAppearancePending: self.initialHistoryAppearancePending
            ),
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )
    }

    internal func armInitialFirstFrameLatestWarmupIfNeeded(
        appliedRealMessageCount: Int,
        availableLocalMessageCount: Int,
        isResidentAtLiveTail: Bool
    ) {
        guard self.initialFirstFrameLatestWarmupState == .inactive,
              ChatFirstFrameLatestWarmupPolicy.shouldArm(
                appliedRealMessageCount: appliedRealMessageCount,
                availableLocalMessageCount: availableLocalMessageCount,
                initialLimit: self.initialFirstFramePageSize,
                normalLimit: self.datasourcePageSize,
                isResidentAtLiveTail: isResidentAtLiveTail,
                hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
                hasActiveAnchorExecution: self.activeAnchorExecutionState != nil
              ) else {
            return
        }

        self.initialFirstFrameLatestWarmupState = .armed
        ChatArchiveDebugTrace.log("chatInitialFirstFrameLatestWarmupArmed", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("appliedRealMessageCount", appliedRealMessageCount),
            ("availableLocalMessageCount", availableLocalMessageCount),
            ("initialLimit", self.initialFirstFramePageSize),
            ("normalLimit", self.datasourcePageSize)
        ])
    }

    internal func performInitialFirstFrameLatestWarmupIfNeeded(trigger: String) {
        let currentRealMessageCount = self.chatOpenTimingRealMessageCount(in: self.datasource)
        guard ChatFirstFrameLatestWarmupPolicy.shouldRun(
            state: self.initialFirstFrameLatestWarmupState,
            currentRealMessageCount: currentRealMessageCount,
            normalLimit: self.datasourcePageSize,
            isResidentAtLiveTail: self.virtualTimelineState.isResidentAtLiveTail,
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            hasActiveAnchorExecution: self.activeAnchorExecutionState != nil,
            hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
            didLogFirstMessagesVisible: self.chatOpenTimingSession?.didLogFirstMessagesVisible == true
        ) else {
            return
        }

        self.initialFirstFrameLatestWarmupState = .inFlight
        ChatArchiveDebugTrace.log("chatInitialFirstFrameLatestWarmupStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("currentRealMessageCount", currentRealMessageCount),
            ("targetLimit", self.datasourcePageSize)
        ])
        self.mapAndApplyTimelineLatest(
            mode: .windowReload(),
            animated: false,
            invalidateLayout: true,
            limit: self.datasourcePageSize,
            suppressDefaultBottomScroll: true,
            forceBottomAlignmentTarget: .newestRealMessage,
            completion: { [weak self] in
                guard let self else {
                    return
                }
                self.initialFirstFrameLatestWarmupState = .completed
                self.finishLatestBottomScroll(animated: false, consumePendingForceLatest: false)
                ChatArchiveDebugTrace.log("chatInitialFirstFrameLatestWarmupFinish", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("realMessageCount", self.chatOpenTimingRealMessageCount(in: self.datasource)),
                    ("isResidentAtLiveTail", self.virtualTimelineState.isResidentAtLiveTail)
                ])
            },
            cancelledCompletion: { [weak self] in
                guard let self else {
                    return
                }
                if self.initialFirstFrameLatestWarmupState == .inFlight {
                    self.initialFirstFrameLatestWarmupState = .armed
                }
            }
        )
    }

    internal func handleChatDatasourceAuxiliaryRefreshAfterApply(
        containsRealMessages: Bool,
        containsOnlyFakeMessages: Bool
    ) {
        switch ChatFirstFrameAuxiliaryWorkPolicy.datasourceApplyDecision(
            isInitialHistoryAppearancePending: self.initialHistoryAppearancePending,
            containsRealMessages: containsRealMessages,
            containsOnlyFakeMessages: containsOnlyFakeMessages
        ) {
        case .runImmediately:
            self.performChatDatasourceAuxiliaryRefresh()
        case .deferUntilPostVisible:
            self.deferFirstFrameAuxiliaryRefreshIfNeeded(reason: "datasourceApply")
        }
    }

    internal func deferFirstFrameAuxiliaryRefreshIfNeeded(reason: String) {
        let wasPending = self.pendingFirstFrameAuxiliaryRefresh
        self.pendingFirstFrameAuxiliaryRefresh = true
        if !wasPending {
            ChatArchiveDebugTrace.log("chatFirstFrameAuxiliaryWorkDeferred", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("reason", reason)
            ])
        }
        self.schedulePendingFirstFrameAuxiliaryRefreshFlushIfNeeded(trigger: reason)
    }

    internal func schedulePendingFirstFrameAuxiliaryRefreshFlushIfNeeded(trigger: String) {
        guard ChatFirstFrameAuxiliaryWorkPolicy.shouldScheduleDeferredFlush(
            hasPendingRefresh: self.pendingFirstFrameAuxiliaryRefresh,
            isFlushScheduled: self.isFirstFrameAuxiliaryRefreshFlushScheduled,
            hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
            didLogFirstMessagesVisible: self.chatOpenTimingSession?.didLogFirstMessagesVisible == true
        ) else {
            return
        }

        self.isFirstFrameAuxiliaryRefreshFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isFirstFrameAuxiliaryRefreshFlushScheduled = false
            guard ChatFirstFrameAuxiliaryWorkPolicy.shouldRunDeferredFlush(
                hasPendingRefresh: self.pendingFirstFrameAuxiliaryRefresh,
                hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                didLogFirstMessagesVisible: self.chatOpenTimingSession?.didLogFirstMessagesVisible == true
            ) else {
                return
            }

            self.pendingFirstFrameAuxiliaryRefresh = false
            ChatArchiveDebugTrace.log("chatFirstFrameAuxiliaryWorkFlush", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger)
            ])
            self.performChatDatasourceAuxiliaryRefresh()
        }
    }

    internal func cancelPendingFirstFrameAuxiliaryRefresh(reason: String) {
        guard ChatFirstFrameAuxiliaryWorkPolicy.shouldCancelPendingRefreshOnDisappear(
            hasPendingRefresh: self.pendingFirstFrameAuxiliaryRefresh
        ) else {
            return
        }

        self.pendingFirstFrameAuxiliaryRefresh = false
        self.isFirstFrameAuxiliaryRefreshFlushScheduled = false
        ChatArchiveDebugTrace.log("chatFirstFrameAuxiliaryWorkCancel", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("reason", reason)
        ])
    }

    internal func performChatDatasourceAuxiliaryRefresh() {
        self.refreshUnreadMentionsNavigatorState()
        self.updateVisibleVoiceMessageQueue()
    }

    internal func finishInitialHistoryAppearanceIfPossible() {
        guard self.initialHistoryAppearancePending,
              ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                hasRenderedStableHistory: self.hasRenderedStableInitialHistory
              ) else { return }

        DispatchQueue.main.async {
            guard self.initialHistoryAppearancePending,
                  ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                    hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                    hasRenderedStableHistory: self.hasRenderedStableInitialHistory
                  ) else { return }

            self.initialHistoryAppearancePending = false
            self.hasRenderedStableInitialHistory = false
        }
    }

    internal func bootstrapViewState(chatInstance: LastChatsStorageItem?) -> ChatBootstrapViewState {
        ChatBootstrapViewState.resolve(
            messageCount: self.localHistoryMessageCountForBootstrap(),
            isSynced: chatInstance?.isSynced ?? false,
            isInitialArchiveLoaded: chatInstance?.isInitialArchiveLoaded ?? false,
            isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(chatInstance: chatInstance),
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap
        )
    }

    internal func currentBootstrapViewState() -> ChatBootstrapViewState {
        do {
            let realm = try WRealm.safe()
            let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )
            return self.bootstrapViewState(chatInstance: chatInstance)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return ChatBootstrapViewState.resolve(
                messageCount: self.localHistoryMessageCountForBootstrap(),
                isSynced: false,
                isInitialArchiveLoaded: false,
                isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
                hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(chatInstance: nil),
                allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap
            )
        }
    }

    internal func hasPendingInitialAnchorRequest(chatInstance: LastChatsStorageItem? = nil) -> Bool {
        if let executionState = self.activeAnchorExecutionState,
           executionState.request.owner == self.owner,
           executionState.request.chatJid == self.jid,
           executionState.request.conversationType == self.conversationType,
           executionState.usesBootstrapLoading,
           !executionState.isPositioning {
            return self.shouldBlockBootstrapForInitialAnchorRequest(
                executionState.request,
                chatInstance: chatInstance
            )
        }

        guard self.isShowingBootstrapPlaceholder,
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType else {
            return false
        }

        return self.shouldBlockBootstrapForInitialAnchorRequest(
            request,
            chatInstance: chatInstance
        )
    }

    private func shouldBlockBootstrapForInitialAnchorRequest(
        _ request: ChatOpenMessageRequest,
        chatInstance: LastChatsStorageItem?
    ) -> Bool {
        let hasLocalAnchor = ChatInitialAnchorBootstrapPolicy.needsLocalAnchorLookup(source: request.source)
            ? self.hasLocalAnchorForBootstrap(request)
            : false

        return ChatInitialAnchorBootstrapPolicy.shouldBlockBootstrap(
            source: request.source,
            isSynced: chatInstance?.isSynced ?? self.currentChatIsSyncedForBootstrap(),
            messageCount: self.localHistoryMessageCountForBootstrap(),
            hasLocalAnchor: hasLocalAnchor,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
    }

    private func currentChatIsSyncedForBootstrap() -> Bool {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.isSynced ?? false
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func currentBootstrapRequiresArchiveConfirmation() -> Bool {
        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )
            return MessageArchiveManager.ChatBootstrapRequestPolicy.shouldStartInitialBootstrap(
                isSynced: chat?.isSynced ?? false,
                isInitialArchiveLoaded: chat?.isInitialArchiveLoaded ?? false,
                localMessageCount: self.localHistoryMessageCountForBootstrap()
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return true
        }
    }

    @discardableResult
    internal func applyFirstFrameLocalHistoryIfNeeded(
        bootstrapState: ChatBootstrapViewState,
        chatInstance: LastChatsStorageItem? = nil,
        forceLatestBottom: Bool = false
    ) -> Bool {
        let localMessageCount = self.localHistoryMessageCountForBootstrap()
        guard ChatFirstFrameLocalHistoryPolicy.shouldApplySynchronously(
            bootstrapState: bootstrapState,
            localMessageCount: localMessageCount,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            hasPendingOpenMessageRequest: self.pendingOpenMessageRequest != nil,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(chatInstance: chatInstance)
        ) else {
            return false
        }

        do {
            self.datasetMappingGeneration += 1
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            var engine = ChatVirtualTimelineEngine(
                provider: provider,
                pageSize: self.datasourcePageSize,
                state: self.virtualTimelineState.normalized(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                ),
                archiveState: self.loadChatArchiveStateSnapshot()
            )
            let snapshot = engine.scrollToLatest(limit: self.initialFirstFramePageSize)
            let frozenItems = snapshot.items.map { $0.freeze() }
            guard !frozenItems.isEmpty else {
                return false
            }

            if forceLatestBottom {
                self.beginInitialLatestOpenStabilizationIfNeeded()
            }
            self.activeHistoryBoundaryPlaceholder = nil
            self.virtualTimelineState = snapshot.state
            self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: snapshot.state)
            self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
            self.armInitialFirstFrameLatestWarmupIfNeeded(
                appliedRealMessageCount: frozenItems.count,
                availableLocalMessageCount: self.messagesObserver?.count ?? frozenItems.count,
                isResidentAtLiveTail: snapshot.state.isResidentAtLiveTail
            )
            self.applyChatDatasource(
                self.mapDataset(dataset: frozenItems),
                mode: .fullReload(),
                animated: false,
                invalidateLayout: forceLatestBottom,
                suppressDefaultBottomScroll: forceLatestBottom,
                forceBottomAlignmentTarget: forceLatestBottom ? .newestRealMessage : nil,
                completion: forceLatestBottom ? {
                    self.finishLatestBottomScroll(animated: false, consumePendingForceLatest: true)
                } : nil
            )
            return true
        } catch {
            DDLogDebug("ChatViewController.applyFirstFrameLocalHistoryIfNeeded: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    internal func reloadInitialWindowAfterBootstrapIfNeeded(force: Bool = false) -> Bool {
        let state = self.currentBootstrapViewState()
        guard ChatBootstrapContentRenderPolicy.shouldReloadInitialWindow(
            forceRender: force,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        ) else { return false }

        switch state {
        case .skeleton:
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.syncCurrentPage(with: .empty)
            self.applyChatDatasource(self.mapDataset(dataset: []), mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            self.setShouldShowInitialMessage(false)
        case .content:
            self.rebuildUnreadMentionItems()
            let shouldForceLatestOpen = ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen()
                && (self.pendingForceLatestOpen || self.initialHistoryAppearancePending)
            if shouldForceLatestOpen {
                self.beginInitialLatestOpenStabilizationIfNeeded()
            }
            if !shouldForceLatestOpen,
               self.applySavedPositionFirstFrameWindowIfNeeded(isSynced: self.currentChatIsSyncedForBootstrap()) {
                return true
            }
            self.setShouldShowInitialMessage(false)
            if self.applyFirstFrameLocalHistoryIfNeeded(
                bootstrapState: state,
                forceLatestBottom: shouldForceLatestOpen
            ) {
                return true
            }
            if self.pendingOpenMessageRequest != nil || self.activeAnchorExecutionState != nil {
                return true
            }
            self.mapAndApplyTimelineLatest(
                mode: .fullReload(),
                animated: shouldForceLatestOpen ? false : self.shouldAnimateInitialHistoryAppearance,
                invalidateLayout: shouldForceLatestOpen,
                limit: shouldForceLatestOpen ? self.initialFirstFramePageSize : nil,
                suppressDefaultBottomScroll: shouldForceLatestOpen,
                forceBottomAlignmentTarget: shouldForceLatestOpen ? .newestRealMessage : nil,
                completion: shouldForceLatestOpen ? {
                    self.finishLatestBottomScroll(animated: false, consumePendingForceLatest: true)
                } : nil,
                cancelledCompletion: shouldForceLatestOpen ? {
                    self.finishLatestBottomScroll(animated: false, consumePendingForceLatest: true)
                } : nil
            )
        case .empty:
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.syncCurrentPage(with: .empty)
            self.applyChatDatasource([], mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            self.setShouldShowInitialMessage(true)
        }
        return true
    }

    internal func applyBootstrapViewState(_ state: ChatBootstrapViewState, forceRender: Bool = false) {
        switch state {
        case .skeleton:
            self.setDatasourceLoadingEnabled(false)
            self.setShouldShowInitialMessage(false)
            self.setSkeletonVisible(true)
            if ChatBootstrapSkeletonRenderPolicy.shouldRenderSkeletonDatasource(
                forceRender: forceRender,
                isDatasourceEmpty: self.datasource.isEmpty,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
            ) {
                self.applyChatDatasource(self.mapDataset(dataset: []), mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            }
        case .content, .empty:
            self.setDatasourceLoadingEnabled(true)
            self.setSkeletonVisible(false)
            if state == .content,
               self.shouldSkipInitialLatestForcedContentRender(forceRender: forceRender) {
                ChatArchiveDebugTrace.log("initialLatestStabilizationSkipBootstrapRender", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("state", "\(self.initialLatestOpenStabilizationState)"),
                    ("newest", self.newestRealDatasourcePrimary() ?? "-")
                ])
                return
            }
            self.reloadInitialWindowAfterBootstrapIfNeeded(force: forceRender)
        }
    }
    
    private static func messageIndicator(
        for state: MessageStorageItem.MessageSendingState,
        showsDeliveryIndicator: Bool
    ) -> IndicatorType {
        guard showsDeliveryIndicator else {
            return .none
        }

        switch state {
        case .sended:
            return .sended
        case .deliver:
            return .received
        case .read:
            return .read
        case .error:
            return .error
        case .none:
            return .none
        case .notSended:
            return .error
        case .sending, .uploading:
            return .sending
        }
    }

    internal final func mapDataset(dataset: Array<MessageStorageItem>) -> [Datasource] {
        var mapSignpost = ChatPerformanceSignposts.begin(.mapDataset)
        defer {
            mapSignpost.end()
        }
        if self.showSkeletonObserver.value {
            return skeletonMessages.enumerated().compactMap {
                (offset, item) in
                let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(((self.skeletonMessages.count - offset) * 1000)))
                return Datasource(
                    primary: UUID().uuidString,
                    jid: self.jid,
                    owner: self.owner,
                    outgoing: ((offset % 3) == 0),
                    sender: self.opponentSender,
                    messageId: UUID().uuidString,
                    sentDate: date,
                    editDate: nil,
                    kind: .skeleton(item),
                    withAuthor: false,
                    withAvatar: false,
                    error: false,
                    errorType: "",
                    canPinMessage: false,
                    canEditMessage: false,
                    canDeleteMessage: false,
                    forwards: [],
                    isOutgoing: ((offset % 3) == 0),
                    isEdited: false,
                    groupchatAuthorRole: "",
                    groupchatAuthorId: "",
                    groupchatAuthorNickname: "",
                    groupchatAuthorBadge: "",
                    isHasAttachedMessages: false,
                    isDownloaded: true,
                    state: .read,
                    searchString: nil,
                    errorMetadata: [:],
                    burnDate: -1,
                    afterburnInterval: -1,
                    isRead: true,
                    isFakeMessage: true,
                    images: [],
                    videos: [],
                    files: [],
                    audios: [],
                    timeMarkerText: NSAttributedString(),
                    indicator: .none
                )
            }
        }
        var out: [Datasource] = []
        var unreadId: String? = nil
        do {
            let realm = try WRealm.safe()
            let lastChatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))
            unreadId = lastChatInstance?.lastReadId
            unreadId = (lastChatInstance?.unread ?? 0) == 0 ? nil : unreadId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        func appendDateSeparatorIfNeeded(before item: MessageStorageItem, at offset: Int) {
            guard offset == 0 || self.isDateChange(from: dataset[offset - 1].sentDate, to: item.sentDate) else {
                return
            }
            let kind: MessageKind = .date(
                NSAttributedString(
                    string: sectionsDateFormatter.string(from: item.sentDate),
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption1),
                        .foregroundColor: UIColor.white,
                    ]
                )
            )
            out.append(Datasource(
                primary: "\(item.primary) date changed",
                jid: self.jid,
                owner: self.owner,
                outgoing: item.outgoing,
                sender: item.outgoing ? self.ownerSender : self.opponentSender,
                messageId: item.messageId,
                sentDate: item.date,
                editDate: nil,
                kind: kind,
                withAuthor: false,
                withAvatar: false,
                error: item.state == .error,
                errorType: "",
                canPinMessage: false,
                canEditMessage: false,
                canDeleteMessage: false,
                forwards: [],
                isOutgoing: item.outgoing,
                isEdited: false,
                groupchatAuthorRole: "",
                groupchatAuthorId: "",
                groupchatAuthorNickname: "",
                groupchatAuthorBadge: "",
                isHasAttachedMessages: false,
                isDownloaded: true,
                state: .none,
                searchString:  "",
                errorMetadata: nil,
                burnDate: 0,
                afterburnInterval: 0,
                archivedId: "\(item.archivedId) date changed",
                queryIds: "\(item.queryIds ?? "") date changed",
                isRead: item.isRead,
                selectedSearchResultId: nil,
                isHadHistoryGap: false,
                isFakeMessage: true,
                images: [],
                videos: [],
                files: [],
                audios: [],
                timeMarkerText: NSAttributedString(),
                indicator: .none,
                avatarUrl: nil
            ))
        }

        var displayPresentationCache: [String: SavedMessageDisplayPolicy.Presentation] = [:]
        func displayPresentation(for item: MessageStorageItem) -> SavedMessageDisplayPolicy.Presentation {
            if let cached = displayPresentationCache[item.primary] {
                return cached
            }
            let presentation = SavedMessageDisplayPolicy.presentation(
                for: item,
                currentUserJid: self.owner,
                currentUserName: self.ownerSender.displayName
            )
            displayPresentationCache[item.primary] = presentation
            return presentation
        }
        let displayContext = ChatDisplayModelCacheContext.current(
            searchText: self.searchTextObserver.value,
            traitCollection: self.traitCollection
        )
        let textAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label,
            .font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: self.traitCollection)
        ]
                
        dataset.enumerated().forEach {
            (offset, item) in
            appendDateSeparatorIfNeeded(before: item, at: offset)
//            let references = Array(item.references.toArray().compactMap { $0.loadModel() })
//            let inlineForwards = Array(item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true).toArray().compactMap { $0.loadModel() })
            
            let presentation = displayPresentation(for: item)
            let displaySender = presentation.isSavedMessage
                ? Sender(id: presentation.displayAuthorJid, displayName: presentation.displayAuthorName)
                : (item.outgoing ? self.ownerSender : self.opponentSender)
            let cachedDisplayModel = self.cachedDisplayModel(
                for: item,
                presentation: presentation,
                textAttributes: textAttributes,
                context: displayContext
            )
            let kind = cachedDisplayModel.kind
            let isDownloaded = cachedDisplayModel.isDownloaded
            
            var withAuthor: Bool = false
            var withAvatar: Bool = false
            var tailed: Bool = true
            let date = presentation.visibleDate
            let prevMessage = offset - 1
            let nextMessage = offset + 1
            
            if self.avatarVerticalPosition == "top" {
                if prevMessage >= 0 {
                    let prevItem = dataset[prevMessage]
                    let prevPresentation = displayPresentation(for: prevItem)
                    if self.conversationType == .group {
                        withAvatar = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        tailed = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        
                    } else {
                        tailed = !(presentation.displayOutgoing == prevPresentation.displayOutgoing)
                    }
                    if isDateChange(from: presentation.visibleDate, to: prevPresentation.visibleDate) {
                        tailed = true
                        if self.conversationType == .group {
                            withAvatar = true
                        }
                    }
                }
            }
            if prevMessage >= 0 {
                let prevItem = dataset[prevMessage]
                let prevPresentation = displayPresentation(for: prevItem)
                if self.conversationType == .group {
                    withAuthor = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                    if isDateChange(from: presentation.visibleDate, to: prevPresentation.visibleDate) {
                        withAuthor = true
                    }
                }
            } else if self.conversationType == .group {
                withAuthor = true
            }

            if nextMessage < dataset.count {
                let nextItem = dataset[nextMessage]
                let nextPresentation = displayPresentation(for: nextItem)
                
                if self.avatarVerticalPosition == "bottom" {
                    if self.conversationType == .group {
                        withAvatar = !(nextItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        tailed = !(nextItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        
                    } else {
                        tailed = !(presentation.displayOutgoing == nextPresentation.displayOutgoing)
                    }
                    if isDateChange(from: presentation.visibleDate, to: nextPresentation.visibleDate) {
                        tailed = true
                        if self.conversationType == .group {
                            withAvatar = true
                        }
                    }
                }
            }
            var attributedAuthor: NSAttributedString? = nil
            if presentation.isSavedForward {
                withAuthor = !presentation.displayOutgoing
                withAvatar = !presentation.displayOutgoing
                attributedAuthor = withAuthor ? SavedMessageDisplayPolicy.attributedAuthor(for: presentation) : nil
            } else if withAuthor && !presentation.displayOutgoing {
                attributedAuthor = SavedMessageDisplayPolicy.attributedAuthor(for: presentation)
            }
          
            if item.editDate != nil {
                let primary = item.primary
                DispatchQueue.main.async {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.invalidateLastMessageCachedSize(primary: primary)
                }
            }
            var searchString: String? = nil
            
            if self.inSearchMode.value,
               item.displayAs == .text,
               let str = self.searchTextObserver.value,
               str.isNotEmpty,
               presentation.visibleBody.contains(str) {
                searchString = str
            }
            
            
            let mappedReferences = cachedDisplayModel.mappedReferences
            let forwards = cachedDisplayModel.forwards
            let statePresentation = SavedMessageStatePolicy.presentation(
                for: item,
                displayAuthorJid: presentation.displayAuthorJid,
                isSavedForward: presentation.isSavedForward,
                isDirectSavedNote: presentation.isDirectSavedNote,
                currentUserJid: self.owner
            )
            let effectiveState = statePresentation.effectiveState
            let indicator = Self.messageIndicator(
                for: effectiveState,
                showsDeliveryIndicator: statePresentation.showsDeliveryIndicator
            )
            let timeMarkerString = cachedDisplayModel.timeMarkerText
            if presentation.displayOutgoing {
                withAuthor = false
                if presentation.isSavedMessage {
                    withAvatar = false
                }
            }
            let shouldShowAvatar = withAvatar || (self.conversationType == .group && !presentation.displayOutgoing)
//            if (dataset.count > 1 && (offset + 1) < dataset.count) || (offset + 1 == dataset.count) {
//                if item.archivedId == unreadId {
//                    let kind: MessageKind = .unread(
//                        NSAttributedString(
//                            string: "Unread messages",
//                            attributes: [
//                                .font: UIFont.preferredFont(forTextStyle: .caption1),
//                                .foregroundColor: UIColor.white,
//                            ]
//                        )
//                    )
//                    self.unreadMessagePositionId = offset
//                    out.append(Datasource(
//                        primary: "\(item.primary) unread",
//                        jid: self.jid,
//                        owner: self.owner,
//                        outgoing: item.outgoing,
//                        sender: item.outgoing ? self.ownerSender : self.opponentSender,
//                        messageId: item.messageId,
//                        sentDate: date,
//                        editDate: nil,
//                        kind: kind,
//                        withAuthor: false,
//                        withAvatar: false,//self.groupchat ? !item.outgoing : false,
//                        error: item.state == .error,
//                        errorType: "",
//                        canPinMessage: false,
//                        canEditMessage: false,
//                        canDeleteMessage: false,
//                        forwards: [],
//                        isOutgoing: item.outgoing,
//                        isEdited: false,
//                        groupchatAuthorRole: "",
//                        groupchatAuthorId: "",
//                        groupchatAuthorNickname: "",
//                        groupchatAuthorBadge: "",
//                        isHasAttachedMessages: false,
//                        isDownloaded: true,
//                        state: .none,
//                        searchString:  "",
//                        errorMetadata: nil,
//                        burnDate: 0,
//                        afterburnInterval: 0,
//                        archivedId: "\(item.archivedId) unread",
//                        queryIds: "\(item.queryIds ?? "") unread",
//                        isRead: item.isRead,
//                        selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
//                        isHadHistoryGap: false,
//                        isFakeMessage: true,
//                        images: [],
//                        videos: [],
//                        files: [],
//                        audios: [],
//                        timeMarkerText: NSAttributedString(),
//                        indicator: .none,
//                        avatarUrl: nil
//                    ))
//                }
//            }
            out.append(Datasource(
                primary: item.primary,
                jid: self.jid,
                owner: self.owner,
                outgoing: presentation.displayOutgoing,
                sender: displaySender,
                messageId: item.messageId,
                sentDate: date,
                editDate: item.editDate,
                kind: kind,
                withAuthor: withAuthor,
                withAvatar: shouldShowAvatar,
                error: effectiveState == .error,
                errorType: item.messageError ?? "",
                canPinMessage: [.system, .sticker].contains(item.displayAs) ? false : self.canUnpinMessage.value,
                canEditMessage: item.archivedId.isNotEmpty ? item.displayAs == .text && presentation.displayOutgoing : false,
                canDeleteMessage: [MessageStorageItem.MessageSendingState.deliver, MessageStorageItem.MessageSendingState.read].contains(effectiveState),
                forwards: forwards,
                isOutgoing: presentation.displayOutgoing,
                isEdited: item.editDate != nil,
                groupchatAuthorRole: presentation.groupchatAuthorRole,
                groupchatAuthorId: presentation.groupchatAuthorId,
                groupchatAuthorNickname: presentation.groupchatAuthorNickname,
                groupchatAuthorBadge: presentation.groupchatAuthorBadge,
                isHasAttachedMessages: item.isHasAttachedMessages,
                isDownloaded: isDownloaded,
                state: item.displayAs == .call ? .none : effectiveState,
                searchString:  searchString,
                errorMetadata: item.errorMetadata,
                messageWarningText: item.messageWarningText,
                burnDate: item.burnDate,
                afterburnInterval: item.afterburnInterval,
                archivedId: item.archivedId,
                queryIds: item.queryIds,
                isRead: item.isRead,
                selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                isHadHistoryGap: false,
                tailed: tailed,
                images: mappedReferences.images,
                videos: mappedReferences.videos,
                locations: mappedReferences.locations,
                contacts: mappedReferences.contacts,
                files: mappedReferences.files,
                audios: mappedReferences.audio,
                timeMarkerText: timeMarkerString,
                indicator: indicator,
                avatarUrl: shouldShowAvatar ? presentation.displayAvatarSource : nil,
                attributedAuthor: attributedAuthor
            ))
        }
        return out
    }
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexSet {
        let inserts = IndexSet(changes.compactMap({ return $0.insert?.index }))
        let deletes = IndexSet(changes.compactMap({ return $0.delete?.index }))
        let replaces = IndexSet(changes.compactMap({ return $0.replace?.index }))
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: 0, section: $0.fromIndex),
            to: IndexPath(item: 0, section: $0.toIndex)
          )
        })

        return ChangesWithIndexSet(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }

    internal final func performInteractiveHistoryPaging(direction: ChatHistoryPageDirection) {
        guard self.currentPage.isUnlocked else {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        self.setDatasourceLoadingEnabled(false)
        self.currentPage.locked = true
        self.loadDatasource(direction: direction) { snapshot in
            if let snapshot {
                self.finishPagingInteraction(
                    snapshot: snapshot,
                    direction: direction,
                    animated: false
                )
            } else {
                let window = self.visibleWindow()
                self.finishPagingInteraction(
                    window: window,
                    shouldApplyWindow: false,
                    direction: direction,
                    animated: false
                )
            }
        }
    }

    internal final func onTouchStartPage(direction: ChatHistoryPageDirection) {
        self.performInteractiveHistoryPaging(direction: direction)
    }

    internal final func onTouchEndPage(direction: ChatHistoryPageDirection) {
        self.performInteractiveHistoryPaging(direction: direction)
    }

    internal func currentScrollMotionState() -> ChatScrollMotionState {
        if self.messagesCollectionView.isDecelerating {
            return .decelerating
        }
        if self.messagesCollectionView.isDragging {
            return .dragging
        }
        if self.messagesCollectionView.isTracking {
            return .tracking
        }
        return .resting
    }

    internal var isArchiveObserverRefreshPressureActive: Bool {
        self.isInitialBootstrapInFlight ||
        self.currentPage.isLoading ||
        self.interactiveHistoryPageLoadContext != nil ||
        self.virtualTimelineState.activeRemoteLoad != nil ||
        self.activeChatHistoryLoadActivityKeys.isNotEmpty
    }

    internal func handleMessagesObserverRefresh() {
        self.refreshPinnedMessagePanelIfNeeded()
        if self.showSkeletonObserver.value {
            let didRevealBootstrapContent = self.revealInitialBootstrapContentIfAvailable()
            _ = self.completeInitialBootstrapIfNeeded()
            if !didRevealBootstrapContent {
                self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
            return
        }
        if self.currentPage.locked {
            _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
            return
        }
        if self.applyObserverRefreshBackpressureIfNeeded() {
            return
        }
        self.didReceiveChangeset()
    }

    @discardableResult
    internal func applyObserverRefreshBackpressureIfNeeded() -> Bool {
        let action = ChatObserverRefreshBackpressurePolicy.action(
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            isHistoryPressureActive: self.isArchiveObserverRefreshPressureActive,
            motionState: self.currentScrollMotionState(),
            hasScheduledRefresh: self.archiveObserverRefreshWorkItem != nil
        )

        switch action {
        case .applyImmediately:
            return false
        case .deferUntilScrollRest:
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.logArchiveObserverRefreshBackpressure(action: "deferUntilScrollRest")
            return true
        case .keepCoalesced:
            self.pendingArchiveObserverRefresh = true
            self.logArchiveObserverRefreshBackpressure(action: "keepCoalesced")
            return true
        case .scheduleCoalesced:
            self.pendingArchiveObserverRefresh = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.archiveObserverRefreshWorkItem = nil
                self.flushPendingArchiveObserverRefreshIfPossible(reason: "coalescedTimer")
            }
            self.archiveObserverRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ChatObserverRefreshBackpressurePolicy.coalescingDelay,
                execute: workItem
            )
            self.logArchiveObserverRefreshBackpressure(action: "scheduleCoalesced")
            return true
        }
    }

    @discardableResult
    internal func flushPendingArchiveObserverRefreshIfPossible(reason: String) -> Bool {
        let action = ChatObserverRefreshBackpressurePolicy.flushAction(
            hasPendingRefresh: self.pendingArchiveObserverRefresh,
            motionState: self.currentScrollMotionState()
        )

        switch action {
        case .none:
            return false
        case .keepPending:
            self.logArchiveObserverRefreshBackpressure(action: "flushDeferred:\(reason)")
            return false
        case .flush:
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.pendingArchiveObserverRefresh = false
            self.logArchiveObserverRefreshBackpressure(action: "flush:\(reason)")
            if self.currentPage.locked {
                _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
                return true
            }
            self.didReceiveChangeset()
            return true
        }
    }

    internal func cancelPendingArchiveObserverRefresh(reason: String) {
        guard self.pendingArchiveObserverRefresh || self.archiveObserverRefreshWorkItem != nil else {
            return
        }
        self.archiveObserverRefreshWorkItem?.cancel()
        self.archiveObserverRefreshWorkItem = nil
        self.pendingArchiveObserverRefresh = false
        self.logArchiveObserverRefreshBackpressure(action: "cancel:\(reason)")
    }

    private func logArchiveObserverRefreshBackpressure(action: String) {
        ChatArchiveDebugTrace.log("observerRefreshBackpressure", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("action", action),
            ("isInitialBootstrapInFlight", self.isInitialBootstrapInFlight),
            ("isPageLoading", self.currentPage.isLoading),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
            ("scrollMotionState", self.currentScrollMotionState().rawValue),
            ("pendingRefresh", self.pendingArchiveObserverRefresh),
            ("scheduledRefresh", self.archiveObserverRefreshWorkItem != nil),
            ("datasourceCount", self.datasource.count),
            ("observerCount", self.messagesObserver?.count ?? -1)
        ])
    }

    internal final func loadInitialDatasource(performPendingOpenMessageRequest: Bool = true) {
        self.recordChatOpenTimingInitialDatasourceLoadStarted(
            performPendingOpenMessageRequest: performPendingOpenMessageRequest
        )
        do {
            let realm = try WRealm.safe()
            let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid,
                                                               owner: self.owner,
                                                               conversationType: self.conversationType))
            self.rebuildUnreadMentionItems()
            let state = self.bootstrapViewState(chatInstance: chatInstance)
            let render = {
                self.applyBootstrapViewState(state, forceRender: true)
            }
            if self.isNavigationTransitionActive || self.isPreparingStackedNavigationPresentation {
                UIView.performWithoutAnimation(render)
            } else {
                render()
            }
            if performPendingOpenMessageRequest {
                self.performPendingOpenMessageRequestIfNeeded()
            }
            self.recordChatOpenTimingInitialDatasourceLoadFinished(
                bootstrapState: state,
                performPendingOpenMessageRequest: performPendingOpenMessageRequest
            )
        } catch {
            self.recordChatOpenTimingInitialDatasourceLoadFailed(error)
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    private func makeVirtualTimelineEngine(
        archiveState: ChatArchiveStateSnapshot
    ) throws -> ChatVirtualTimelineEngine {
        let provider = ChatLocalHistoryPageProvider(
            realm: try WRealm.safe(),
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        return ChatVirtualTimelineEngine(
            provider: provider,
            pageSize: self.datasourcePageSize,
            state: self.virtualTimelineState.normalized(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            ),
            archiveState: archiveState
        )
    }

    private func virtualTimelinePageSnapshot(
        direction: ChatHistoryPageDirection,
        queryId: String? = nil,
        archiveState: ChatArchiveStateSnapshot
    ) -> ChatTimelineSnapshot? {
        do {
            var engine = try self.makeVirtualTimelineEngine(archiveState: archiveState)
            switch direction {
            case .older:
                return engine.pageOlder(queryId: queryId)
            case .newer:
                return engine.pageNewer(queryId: queryId)
            }
        } catch {
            DDLogDebug("ChatViewController.virtualTimelinePageSnapshot: \(error.localizedDescription)")
            return nil
        }
    }

    private func frozenSnapshot(_ snapshot: ChatTimelineSnapshot) -> ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: snapshot.items.map { $0.freeze() },
            state: snapshot.state,
            loadingState: snapshot.loadingState,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst
        )
    }

    private func armedRemoteSnapshotWithoutVisiblePlaceholder(_ snapshot: ChatTimelineSnapshot) -> ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: snapshot.items,
            state: snapshot.state.withRuntimePlaceholder(nil),
            loadingState: .none,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst
        )
    }

    private func makeInteractiveHistoryPagingPreparation(
        direction: ChatHistoryPageDirection,
        first: Bool = false,
        samePage: Bool = false
    ) -> ChatInteractiveHistoryPagingPreparation? {
        func getWindow() -> ChatDatasetWindow {
            let currentWindow = self.visibleWindow()

            if samePage {
                return self.datasetCoordinator.clamp(currentWindow, totalCount: self.messagesObserver.count)
            }

            return self.datasetCoordinator.nextWindow(
                from: currentWindow,
                direction: direction
            )
        }

        guard self.messagesObserver != nil else {
            return nil
        }

        let currentWindow = self.visibleWindow()
        let requestedWindow = getWindow()
        guard !requestedWindow.isEmpty || first else {
            return nil
        }

        let chatArchiveState = self.loadChatArchiveStateSnapshot()
        let persistedArchiveEnded = chatArchiveState.fullArchiveLoaded
        let shouldProbePersistedArchiveEnd = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
            persistedArchiveEnded: persistedArchiveEnded,
            hasConfirmedArchiveEndThisSession: self.hasConfirmedArchiveEndThisSession,
            hasUsedVerificationProbe: self.hasUsedArchiveEndVerificationProbe
        )
        let effectiveArchiveEnded = ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
            persistedArchiveEnded: persistedArchiveEnded,
            shouldProbePersistedArchiveEnd: shouldProbePersistedArchiveEnd
        )
        let virtualArchiveState = ChatArchiveStateSnapshot(
            primaryKey: chatArchiveState.primaryKey,
            persistedCursorId: chatArchiveState.persistedCursorId,
            fullArchiveLoaded: effectiveArchiveEnded,
            newestCursorId: chatArchiveState.newestCursorId,
            newerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
            hasKnownNewerGap: chatArchiveState.hasKnownNewerGap,
            knownGaps: chatArchiveState.knownGaps
        )

        guard let virtualSnapshot = self.virtualTimelinePageSnapshot(
            direction: direction,
            archiveState: virtualArchiveState
        ) else {
            return nil
        }

        let decision = virtualSnapshot.loadDecision
        let pagingPlan = ChatInteractiveHistoryPagingPlanPolicy.plan(for: decision)
        ChatArchiveDebugTrace.log("timelinePagingDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", direction),
            ("decision", "\(decision)"),
            ("snapshotItems", virtualSnapshot.items.count),
            ("snapshotOldest", virtualSnapshot.state.oldest?.archivedId ?? "-"),
            ("snapshotNewest", virtualSnapshot.state.newest?.archivedId ?? "-"),
            ("snapshotResident", virtualSnapshot.state.residentPrimaryKeys.count),
            ("localOlderCandidateCount", virtualSnapshot.localOlderCandidateCount ?? -1),
            ("pageSize", virtualSnapshot.pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", virtualSnapshot.shortLocalRemainderRemoteFirst),
            ("currentOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
            ("currentNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
            ("currentResident", self.virtualTimelineState.residentPrimaryKeys.count),
            ("boundedOldest", self.boundedTimelineWindowState.oldest?.archivedId ?? "-"),
            ("boundedNewest", self.boundedTimelineWindowState.newest?.archivedId ?? "-"),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("observerCount", self.messagesObserver?.count ?? -1),
            ("scrollMotionState", self.currentScrollMotionState().rawValue),
            ("executionAction", "-"),
            ("preparedLocalPageId", self.pendingPreparedLocalHistoryPage?.id ?? "-"),
            ("pendingDirection", self.pendingDeferredRemoteHistoryDirection.map { "\($0)" } ?? "-"),
            ("discardReason", "-")
        ])

        if !pagingPlan.shouldShowOverlay {
            self.logInteractiveHistoryPagingPlan(
                direction: direction,
                plan: pagingPlan,
                localItemCount: virtualSnapshot.items.count,
                localOlderCandidateCount: virtualSnapshot.localOlderCandidateCount,
                pageSize: virtualSnapshot.pageSize,
                shortLocalRemainderRemoteFirst: virtualSnapshot.shortLocalRemainderRemoteFirst
            )
        }

        return ChatInteractiveHistoryPagingPreparation(
            direction: direction,
            currentWindow: currentWindow,
            requestedWindow: requestedWindow,
            archiveState: chatArchiveState,
            virtualArchiveState: virtualArchiveState,
            snapshot: virtualSnapshot,
            pagingPlan: pagingPlan
        )
    }

    @discardableResult
    internal func handleBoundaryPagingCandidate(
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        motionState: ChatScrollMotionState,
        trigger: String
    ) -> ChatBoundaryPagingExecutionAction {
        let currentConversationKey = self.chatTimelineConversationKey
        let currentVirtualState = self.virtualTimelineState.normalized(
            owner: currentConversationKey.owner,
            jid: currentConversationKey.jid,
            conversationType: currentConversationKey.conversationType
        )
        let currentWindow = self.visibleWindow()

        if motionState.isMoving,
           let pending = self.pendingPreparedLocalHistoryPage,
           pending.direction == direction,
           pending.conversationKey == currentConversationKey,
           pending.baseVirtualState == currentVirtualState,
           pending.baseWindow == currentWindow {
            ChatArchiveDebugTrace.log("boundaryPagingPrepareLocalFinish", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", direction),
                ("preparedLocalPageId", pending.id),
                ("duplicate", true),
                ("scrollMotionState", motionState.rawValue)
            ])
            return .prepareLocal(direction)
        }

        if motionState.isMoving,
           self.pendingDeferredRemoteHistoryDirection == direction {
            ChatArchiveDebugTrace.log("boundaryPagingDeferRemote", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", direction),
                ("duplicate", true),
                ("scrollMotionState", motionState.rawValue)
            ])
            return .deferRemote(direction)
        }

        guard let preparation = self.makeInteractiveHistoryPagingPreparation(direction: direction) else {
            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = nil
            self.logBoundaryPagingExecution(
                trigger: trigger,
                direction: direction,
                boundaryContext: boundaryContext,
                motionState: motionState,
                action: .none,
                discardReason: "planningFailed"
            )
            return .none
        }

        let action = ChatBoundaryPagingExecutionPolicy.action(
            direction: direction,
            pagingPlan: preparation.pagingPlan,
            motionState: motionState
        )
        self.logBoundaryPagingExecution(
            trigger: trigger,
            direction: direction,
            boundaryContext: boundaryContext,
            motionState: motionState,
            action: action,
            discardReason: nil
        )

        switch action {
        case .applyNow:
            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = nil
            self.performInteractiveHistoryPaging(direction: direction)
        case .prepareLocal:
            let preparedId = "local-page-\(NanoID.new(6))"
            ChatArchiveDebugTrace.log("boundaryPagingPrepareLocalStart", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", direction),
                ("preparedLocalPageId", preparedId),
                ("scrollMotionState", motionState.rawValue),
                ("baseOldest", currentVirtualState.oldest?.archivedId ?? "-"),
                ("baseNewest", currentVirtualState.newest?.archivedId ?? "-"),
                ("snapshotOldest", preparation.snapshot.state.oldest?.archivedId ?? "-"),
                ("snapshotNewest", preparation.snapshot.state.newest?.archivedId ?? "-"),
                ("snapshotItems", preparation.snapshot.items.count)
            ])
            self.pendingPreparedLocalHistoryPage = ChatPreparedLocalHistoryPage(
                id: preparedId,
                direction: direction,
                conversationKey: currentConversationKey,
                baseVirtualState: currentVirtualState,
                baseWindow: currentWindow,
                snapshot: self.frozenSnapshot(preparation.snapshot)
            )
            self.pendingDeferredRemoteHistoryDirection = nil
            ChatArchiveDebugTrace.log("boundaryPagingPrepareLocalFinish", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", direction),
                ("preparedLocalPageId", preparedId),
                ("duplicate", false),
                ("scrollMotionState", motionState.rawValue)
            ])
        case .deferRemote:
            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = direction
            ChatArchiveDebugTrace.log("boundaryPagingDeferRemote", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", direction),
                ("duplicate", false),
                ("scrollMotionState", motionState.rawValue)
            ])
        case .none:
            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = nil
        }

        return action
    }

    @discardableResult
    internal func applyPendingBoundaryPagingAfterScrollRest(trigger: String) -> Bool {
        let motionState = self.currentScrollMotionState()
        guard motionState == .resting else {
            return false
        }

        if let prepared = self.pendingPreparedLocalHistoryPage {
            if let discardReason = self.preparedLocalHistoryPageDiscardReason(prepared) {
                self.discardPreparedBoundaryPaging(reason: discardReason, trigger: trigger)
                return false
            }

            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = nil
            self.setDatasourceLoadingEnabled(false)
            self.currentPage.locked = true
            ChatArchiveDebugTrace.log("boundaryPagingApplyPreparedLocal", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", prepared.direction),
                ("preparedLocalPageId", prepared.id),
                ("snapshotItems", prepared.snapshot.items.count),
                ("snapshotOldest", prepared.snapshot.state.oldest?.archivedId ?? "-"),
                ("snapshotNewest", prepared.snapshot.state.newest?.archivedId ?? "-")
            ])
            self.finishPagingInteraction(
                snapshot: prepared.snapshot,
                direction: prepared.direction,
                animated: false
            )
            return true
        }

        if let direction = self.pendingDeferredRemoteHistoryDirection {
            let boundaryContext = self.pagingBoundaryContext(
                visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
            )
            guard ChatPendingBoundaryPagingValidationPolicy.isBoundaryVisible(
                direction: direction,
                boundaryContext: boundaryContext
            ) else {
                self.pendingDeferredRemoteHistoryDirection = nil
                ChatArchiveDebugTrace.log("boundaryPagingDiscardPrepared", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("trigger", trigger),
                    ("direction", direction),
                    ("discardReason", "remoteBoundaryNoLongerVisible")
                ])
                return false
            }

            self.pendingDeferredRemoteHistoryDirection = nil
            ChatArchiveDebugTrace.log("boundaryPagingDeferRemote", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", "\(trigger)-apply"),
                ("direction", direction),
                ("duplicate", false),
                ("scrollMotionState", motionState.rawValue)
            ])
            self.performInteractiveHistoryPaging(direction: direction)
            return true
        }

        return false
    }

    private func preparedLocalHistoryPageDiscardReason(_ prepared: ChatPreparedLocalHistoryPage) -> String? {
        let conversationKey = self.chatTimelineConversationKey
        guard prepared.conversationKey == conversationKey else {
            return "conversationChanged"
        }

        let normalizedState = self.virtualTimelineState.normalized(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )
        guard normalizedState == prepared.baseVirtualState else {
            return "virtualStateChanged"
        }
        guard normalizedState.activeRemoteLoad == nil else {
            return "remoteInFlight"
        }
        guard self.currentPage.isUnlocked else {
            return "pageLocked"
        }
        guard self.visibleWindow() == prepared.baseWindow else {
            return "windowChanged"
        }
        guard self.currentScrollMotionState() == .resting else {
            return "scrollMoving"
        }

        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
        )
        guard ChatPendingBoundaryPagingValidationPolicy.isBoundaryVisible(
            direction: prepared.direction,
            boundaryContext: boundaryContext
        ) else {
            return "boundaryNoLongerVisible"
        }
        return nil
    }

    private func discardPreparedBoundaryPaging(reason: String, trigger: String) {
        let preparedDirection = self.pendingPreparedLocalHistoryPage?.direction
        let preparedId = self.pendingPreparedLocalHistoryPage?.id
        self.pendingPreparedLocalHistoryPage = nil
        ChatArchiveDebugTrace.log("boundaryPagingDiscardPrepared", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", preparedDirection.map { "\($0)" } ?? "-"),
            ("preparedLocalPageId", preparedId ?? "-"),
            ("discardReason", reason)
        ])
    }

    private func logBoundaryPagingExecution(
        trigger: String,
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        motionState: ChatScrollMotionState,
        action: ChatBoundaryPagingExecutionAction,
        discardReason: String?
    ) {
        ChatArchiveDebugTrace.log("boundaryPagingExecutionDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", direction),
            ("firstRealSection", boundaryContext.firstRealSection ?? -1),
            ("lastRealSection", boundaryContext.lastRealSection ?? -1),
            ("visibleRealSections", boundaryContext.visibleRealSections.map(String.init).joined(separator: ",")),
            ("scrollMotionState", motionState.rawValue),
            ("executionAction", action.diagnosticName),
            ("preparedLocalPageId", self.pendingPreparedLocalHistoryPage?.id ?? "-"),
            ("pendingDirection", self.pendingDeferredRemoteHistoryDirection.map { "\($0)" } ?? "-"),
            ("discardReason", discardReason ?? "-")
        ])
    }

    private func applyVirtualTimelineSnapshotState(_ snapshot: ChatTimelineSnapshot) {
        let oldState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        ChatArchiveDebugTrace.log("virtualTimelineStateApply", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("oldOldest", oldState.oldest?.archivedId ?? "-"),
            ("newOldest", snapshot.state.oldest?.archivedId ?? "-"),
            ("oldNewest", oldState.newest?.archivedId ?? "-"),
            ("newNewest", snapshot.state.newest?.archivedId ?? "-"),
            ("oldResident", oldState.residentPrimaryKeys.count),
            ("newResident", snapshot.state.residentPrimaryKeys.count),
            ("oldActiveRemoteLoad", oldState.activeRemoteLoad?.queryId ?? "-"),
            ("newActiveRemoteLoad", snapshot.state.activeRemoteLoad?.queryId ?? "-"),
            ("itemCount", snapshot.items.count)
        ])
        self.virtualTimelineState = snapshot.state
        self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: snapshot.state)
        self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count))
    }

    internal func registerRemoteHistoryPersistenceSource(
        _ manager: MessageManager?,
        queryId: String
    ) {
        guard let manager,
              queryId.isNotEmpty else {
            return
        }

        ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
            manager,
            owner: self.owner,
            queryId: queryId
        )
    }

    internal func registerRemoteHistoryEndPageDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryEndPageDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
        self.completedRemoteHistoryEndPageQueryIds.remove(queryId)
        let token = MessageArchiveEndPageDispatcher.register(owner: self.owner, queryId: queryId) { [weak self] event in
            self?.didReceiveEndPage(
                queryId: event.queryId,
                state: event.state,
                first: event.first,
                last: event.last,
                count: event.count
            )
        }
        self.remoteHistoryEndPageDispatcherTokens[queryId] = token
    }

    internal func registerRemoteHistoryFailureDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryFailureDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        self.abortedRemoteHistoryQueryIds.remove(queryId)
        let token = MessageArchiveRequestFailureDispatcher.register(owner: self.owner, queryId: queryId) { [weak self] event in
            guard let self else {
                return
            }
            if self.initialBootstrapQueryId == event.queryId {
                self.handleInitialBootstrapRemoteArchiveFailure(
                    queryId: event.queryId,
                    reason: event.reason,
                    streamKind: event.streamKind,
                    errorDescription: event.errorDescription
                )
                return
            }
            self.handleInteractiveRemoteArchiveFailure(
                queryId: event.queryId,
                reason: event.reason,
                streamKind: event.streamKind,
                errorDescription: event.errorDescription
            )
        }
        self.remoteHistoryFailureDispatcherTokens[queryId] = token
    }

    internal func unregisterRemoteHistoryEndPageDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryEndPageDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
    }

    internal func unregisterRemoteHistoryFailureDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryFailureDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
    }

    internal func clearRemoteHistoryEndPageDispatchers() {
        self.remoteHistoryEndPageDispatcherTokens.values.forEach {
            MessageArchiveEndPageDispatcher.unregister($0)
        }
        self.remoteHistoryEndPageDispatcherTokens.removeAll()
        self.completedRemoteHistoryEndPageQueryIds.removeAll()
        self.remoteHistoryFailureDispatcherTokens.values.forEach {
            MessageArchiveRequestFailureDispatcher.unregister($0)
        }
        self.remoteHistoryFailureDispatcherTokens.removeAll()
        self.abortedRemoteHistoryQueryIds.removeAll()
        self.cancelInitialBootstrapTimeout()
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog()
        self.cancelInteractiveRemoteArchiveTimeout()
    }

    internal func markRemoteHistoryEndPageCompletionIfNeeded(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }

        if self.completedRemoteHistoryEndPageQueryIds.contains(queryId) {
            return false
        }

        self.completedRemoteHistoryEndPageQueryIds.insert(queryId)
        self.unregisterRemoteHistoryEndPageDispatcher(queryId: queryId)
        return true
    }

    internal func unregisterRemoteHistoryPersistenceSource(queryId: String) {
        self.unregisterRemoteHistoryEndPageDispatcher(queryId: queryId)
        self.unregisterRemoteHistoryFailureDispatcher(queryId: queryId)
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        self.cancelInteractiveRemoteArchiveTimeout(queryId: queryId)
        self.remoteHistoryRequestStartedAtByQueryId.removeValue(forKey: queryId)
        ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
            owner: self.owner,
            queryId: queryId
        )
    }

    internal func scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        self.cancelInteractiveRemoteArchiveRequestStartWatchdog()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleInteractiveRemoteArchiveRequestStartTimeout(queryId: queryId)
        }
        self.interactiveRemoteArchiveRequestStartWorkItem = workItem
        self.interactiveRemoteArchiveRequestStartQueryId = queryId
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogScheduled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("timeoutMs", Int(ChatInteractiveRemoteArchiveTimeoutPolicy.requestStartTimeout * 1000)),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
        ])
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatInteractiveRemoteArchiveTimeoutPolicy.requestStartTimeout,
            execute: workItem
        )
    }

    internal func cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: String? = nil) {
        guard let activeQueryId = self.interactiveRemoteArchiveRequestStartQueryId,
              self.interactiveRemoteArchiveRequestStartWorkItem != nil else {
            return
        }

        if let queryId = queryId,
           queryId != activeQueryId {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogCancelSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("activeStartQueryId", activeQueryId),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
            ])
            return
        }

        self.interactiveRemoteArchiveRequestStartWorkItem?.cancel()
        self.interactiveRemoteArchiveRequestStartWorkItem = nil
        self.interactiveRemoteArchiveRequestStartQueryId = nil
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogCancelled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId ?? activeQueryId),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
        ])
    }

    private func shouldDispatchInteractiveRemoteArchiveRequest(queryId: String) -> Bool {
        guard let context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "inactiveContext"),
                ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("aborted", self.abortedRemoteHistoryQueryIds.contains(queryId))
            ])
            return false
        }

        guard !context.remoteFetchStarted else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "alreadyStarted"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
            ])
            return false
        }

        return true
    }

    @discardableResult
    internal func markInteractiveRemoteArchiveRequestSent(
        queryId: String,
        direction: ChatHistoryPageDirection,
        cursorId: String?,
        pageSize: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        resource: String?,
        bootstrapActive: Bool,
        cursorSource: ChatInteractiveOlderCursorSelectionSource? = nil,
        timelineOldestCursorId: String? = nil,
        boundedOldestCursorId: String? = nil,
        persistedCursorId: String? = nil
    ) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }

        guard var context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "inactiveContext"),
                ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("streamKind", streamKind.rawValue)
            ])
            return false
        }

        context.remoteFetchStarted = true
        self.interactiveHistoryPageLoadContext = context
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        self.cancelInteractiveRemoteArchiveTimeout(queryId: queryId)
        let startedAt = Date()
        self.remoteHistoryRequestStartedAtByQueryId[queryId] = startedAt
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("direction", direction),
            ("cursor", cursorId ?? "-"),
            ("requestedCursor", cursorId ?? "-"),
            ("cursorSource", cursorSource?.rawValue ?? "-"),
            ("timelineOldest", timelineOldestCursorId ?? "-"),
            ("boundedOldest", boundedOldestCursorId ?? "-"),
            ("persistedCursor", persistedCursorId ?? "-"),
            ("cursorDiffersFromPersisted", cursorId != persistedCursorId),
            ("pageSize", pageSize),
            ("streamKind", streamKind.rawValue),
            ("resource", resource ?? "-"),
            ("bootstrapActive", bootstrapActive),
            ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count)
        ])
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleInteractiveRemoteArchiveFailure(
                queryId: queryId,
                reason: .timeout,
                streamKind: streamKind,
                errorDescription: nil
            )
        }
        self.interactiveRemoteArchiveTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            execute: workItem
        )
        return true
    }

    internal func remoteArchiveStreamKind(for stream: XMPPStream) -> MessageArchiveEndPageEvent.StreamKind {
        guard let resource = stream.myJID?.resource else {
            return .unknown
        }
        if resource.contains("_ui_upgrade_task") {
            return .uiAction
        }
        return .primary
    }

    internal func cancelInteractiveRemoteArchiveTimeout(queryId: String? = nil) {
        if let queryId {
            self.remoteHistoryRequestStartedAtByQueryId.removeValue(forKey: queryId)
        } else {
            self.remoteHistoryRequestStartedAtByQueryId.removeAll()
        }
        self.interactiveRemoteArchiveTimeoutWorkItem?.cancel()
        self.interactiveRemoteArchiveTimeoutWorkItem = nil
    }

    private func finishVirtualTimelineRemoteLoad(
        queryId: String,
        archiveState: ChatArchiveStateSnapshot,
        refetchDirection: ChatHistoryPageDirection? = nil
    ) {
        do {
            var engine = try self.makeVirtualTimelineEngine(archiveState: archiveState)
            let snapshot = engine.finishRemoteLoad(
                queryId: queryId,
                refetchDirection: refetchDirection
            )
            self.applyVirtualTimelineSnapshotState(snapshot)
        } catch {
            DDLogDebug("ChatViewController.finishVirtualTimelineRemoteLoad: \(error.localizedDescription)")
        }
    }

    private func commitRemoteHistoryArchiveStateAfterApply(
        context: ChatInteractiveHistoryPageLoadContext,
        applyResult: ChatRemoteHistoryApplyResult,
        baseArchiveState: ChatArchiveStateSnapshot
    ) {
        let coverageDecision = ChatArchiveCoverageCommitPolicy.resolve(
            direction: context.direction,
            snapshot: baseArchiveState,
            requestedCursorId: context.requestedCursorId,
            observedCursorId: applyResult.newOldestArchivedId,
            transportFirst: context.resultFirst,
            transportLast: context.resultLast,
            resultCount: context.resultCount,
            persistedRowsForQuery: context.persistedRowsForQuery,
            visibleRowsForConversation: context.visibleRowsForConversation,
            queryExhausted: context.queryExhausted,
            canMutateOlderArchiveEnd: context.canMutateOlderArchiveEnd,
            coverageUpdateKind: context.coverageUpdateKind
        )

        if coverageDecision.shouldCommitCoverage {
            self.applyConversationArchiveLoadedRangeIfNeeded(
                first: context.resultFirst,
                last: context.resultLast,
                updateKind: context.coverageUpdateKind
            )
        }

        let archiveStateForMutation = coverageDecision.shouldCommitCoverage
            ? self.loadChatArchiveStateSnapshot()
            : baseArchiveState
        let effectiveResolvedCursorId = coverageDecision.shouldAdvanceOlderCursor
            ? coverageDecision.resolvedCursorId
            : archiveStateForMutation.persistedCursorId

        if context.direction == .older,
           coverageDecision.nextFullArchiveLoaded,
           context.canMutateOlderArchiveEnd {
            self.hasConfirmedArchiveEndThisSession = true
        } else if context.direction == .older,
                  coverageDecision.hasPersistenceProof,
                  coverageDecision.shouldAdvanceOlderCursor {
            self.hasConfirmedArchiveEndThisSession = false
        }
        if context.isArchiveEndVerificationProbe {
            self.hasUsedArchiveEndVerificationProbe = true
        }

        let archiveStatePlan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: archiveStateForMutation,
            resolvedCursorId: effectiveResolvedCursorId,
            nextFullArchiveLoaded: coverageDecision.nextFullArchiveLoaded
        )
        ChatArchiveDebugTrace.log("remoteHistoryArchiveCommitDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", context.queryId),
            ("direction", context.direction),
            ("requestedCursor", context.requestedCursorId ?? "-"),
            ("observedCursor", applyResult.newOldestArchivedId ?? "-"),
            ("transportFirst", context.resultFirst),
            ("transportLast", context.resultLast),
            ("persistedRowsForQuery", context.persistedRowsForQuery),
            ("visibleRows", context.visibleRowsForConversation),
            ("resultCount", context.resultCount),
            ("queryExhausted", context.queryExhausted),
            ("hasPersistenceProof", coverageDecision.hasPersistenceProof),
            ("commitCoverage", coverageDecision.shouldCommitCoverage),
            ("advanceOlderCursor", coverageDecision.shouldAdvanceOlderCursor),
            ("resolvedCursor", effectiveResolvedCursorId ?? "-"),
            ("previousCursor", archiveStateForMutation.persistedCursorId ?? "-"),
            ("nextFullArchiveLoaded", coverageDecision.nextFullArchiveLoaded),
            ("markNewerLiveEdge", coverageDecision.shouldMarkNewerLiveEdgeReached),
            ("cursorRepeatedAfterCompletion", coverageDecision.cursorRepeatedAfterCompletion),
            ("duplicateCursorSuppressed", coverageDecision.duplicateCursorSuppressed)
        ])
        _ = self.applyChatArchiveStateIfNeeded(
            snapshot: archiveStateForMutation,
            plan: archiveStatePlan,
            markNewerLiveEdgeReached: coverageDecision.shouldMarkNewerLiveEdgeReached
        )
    }

    private func clearFinishedRemoteLoadRuntimeStateIfNeeded(
        queryId: String,
        conversationKey: ChatTimelineConversationKey
    ) {
        let currentConversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard currentConversationKey == conversationKey else {
            DDLogDebug(
                "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=conversationChanged requestJid=\(conversationKey.jid) currentJid=\(currentConversationKey.jid)"
            )
            return
        }

        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard normalizedState.activeRemoteLoad?.queryId == queryId ||
              self.remoteHistoryFinishingQueryId == queryId else {
            DDLogDebug(
                "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=queryMismatch active=\(normalizedState.activeRemoteLoad?.queryId ?? "-")"
            )
            return
        }

        let clearedState = ChatVirtualTimelineState(
            conversationKey: normalizedState.conversationKey,
            segments: normalizedState.segments.filter {
                if case .loadingPlaceholder = $0 {
                    return false
                }
                return true
            },
            oldest: normalizedState.oldest,
            newest: normalizedState.newest,
            residentPrimaryKeys: normalizedState.residentPrimaryKeys,
            residentArchivedIds: normalizedState.residentArchivedIds,
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: normalizedState.isResidentAtLiveTail
        )
        self.activeHistoryBoundaryPlaceholder = nil
        self.virtualTimelineState = clearedState
        self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: clearedState)
        self.refreshScrollBoundaryAvailabilityCache(reason: "remoteLoadCleared")
        DDLogDebug(
            "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=clearedRuntimeState oldest=\(clearedState.oldest?.archivedId ?? "-") newest=\(clearedState.newest?.archivedId ?? "-")"
        )
    }

    private func mapAndApplyFinishedVirtualTimelineRemoteLoad(
        queryId: String,
        archiveState: ChatArchiveStateSnapshot,
        refetchDirection: ChatHistoryPageDirection,
        visibleRows: Int,
        resultCount: Int,
        queryExhausted: Bool,
        mode: ChatDatasourceApplyMode,
        animated: Bool,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: ((ChatRemoteHistoryApplyResult) -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        let enqueuedAt = Date()
        let requestOwner = self.owner
        let requestJid = self.jid
        let requestConversationType = self.conversationType
        let requestConversationKey = ChatTimelineConversationKey(
            owner: requestOwner,
            jid: requestJid,
            conversationType: requestConversationType
        )
        let virtualTimelineState = self.virtualTimelineState.normalized(
            owner: requestOwner,
            jid: requestJid,
            conversationType: requestConversationType
        )
        let previousOldestArchivedId = virtualTimelineState.oldest?.archivedId
        let previousNewestArchivedId = virtualTimelineState.newest?.archivedId
        DDLogDebug(
            "ChatViewController.remoteHistoryApplyStart queryId=\(queryId) direction=\(refetchDirection) visibleRows=\(visibleRows) count=\(resultCount) oldest=\(previousOldestArchivedId ?? "-") newest=\(previousNewestArchivedId ?? "-")"
        )

        self.remoteHistoryApplyQueue.async {
            do {
                let startedAt = Date()
                let queueWaitMs = Int(startedAt.timeIntervalSince(enqueuedAt) * 1000)
                ChatArchiveDebugTrace.log("remoteHistoryApplyWorkerStart", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("queueWaitMs", queueWaitMs),
                    ("oldOldest", previousOldestArchivedId ?? "-"),
                    ("oldNewest", previousNewestArchivedId ?? "-")
                ])
                let refetchStartedAt = Date()
                let provider = ChatLocalHistoryPageProvider(
                    realm: try WRealm.safe(),
                    owner: requestOwner,
                    jid: requestJid,
                    conversationType: requestConversationType
                )
                var engine = ChatVirtualTimelineEngine(
                    provider: provider,
                    pageSize: self.datasourcePageSize,
                    state: virtualTimelineState,
                    archiveState: archiveState
                )
                let snapshot = engine.finishRemoteLoad(
                    queryId: queryId,
                    refetchDirection: refetchDirection
                )
                let refetchMs = ChatArchiveDebugTrace.milliseconds(since: refetchStartedAt)
                let frozenItems = snapshot.items.map { $0.freeze() }
                let nextVirtualState = snapshot.state
                ChatArchiveDebugTrace.log("remoteHistoryApplyRefetchDone", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("refetchMs", refetchMs),
                    ("items", frozenItems.count),
                    ("newOldest", nextVirtualState.oldest?.archivedId ?? "-"),
                    ("newNewest", nextVirtualState.newest?.archivedId ?? "-"),
                    ("activeRemoteLoad", nextVirtualState.activeRemoteLoad?.queryId ?? "-")
                ])
                let mapStartedAt = Date()
                let mappedDatasource = self.mapDataset(dataset: frozenItems)
                let mapDurationMs = ChatArchiveDebugTrace.milliseconds(since: mapStartedAt)
                let workerDurationMs = ChatArchiveDebugTrace.milliseconds(since: startedAt)
                let applyResult = ChatRemoteHistoryApplyResult(
                    queryId: queryId,
                    direction: refetchDirection,
                    visibleRows: visibleRows,
                    resultCount: resultCount,
                    queryExhausted: queryExhausted,
                    previousOldestArchivedId: previousOldestArchivedId,
                    previousNewestArchivedId: previousNewestArchivedId,
                    newOldestArchivedId: nextVirtualState.oldest?.archivedId,
                    newNewestArchivedId: nextVirtualState.newest?.archivedId,
                    itemCount: frozenItems.count,
                    queueWaitMs: queueWaitMs,
                    mapDurationMs: mapDurationMs
                )

                ChatArchiveDebugTrace.log("remoteHistoryApplyMapDone", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("mapMs", mapDurationMs),
                    ("workerDurationMs", workerDurationMs),
                    ("datasourceItems", mappedDatasource.count)
                ])
                let mainEnqueuedAt = Date()
                DispatchQueue.main.async {
                    ChatArchiveDebugTrace.log("remoteHistoryApplyMainStart", [
                        ("owner", requestOwner),
                        ("jid", requestJid),
                        ("conversationType", requestConversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", refetchDirection),
                        ("mainWaitMs", ChatArchiveDebugTrace.milliseconds(since: mainEnqueuedAt)),
                        ("currentOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                        ("currentNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                        ("currentResident", self.virtualTimelineState.residentPrimaryKeys.count),
                        ("datasourceCount", self.datasource.count)
                    ])
                    let currentConversationKey = ChatTimelineConversationKey(
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType
                    )
                    guard ChatRemoteHistoryApplyGuardPolicy.shouldApply(
                        requestConversationKey: requestConversationKey,
                        currentConversationKey: currentConversationKey,
                        requestQueryId: queryId,
                        finishingQueryId: self.remoteHistoryFinishingQueryId
                    ) else {
                        DDLogDebug(
                            "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=guard requestJid=\(requestJid) currentJid=\(currentConversationKey.jid) finishing=\(self.remoteHistoryFinishingQueryId ?? "-")"
                        )
                        cancelledCompletion?()
                        return
                    }

                    self.activeHistoryBoundaryPlaceholder = nil
                    self.virtualTimelineState = nextVirtualState
                    self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
                    self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                    ChatArchiveDebugTrace.log("remoteHistoryApplyStateAssigned", [
                        ("owner", requestOwner),
                        ("jid", requestJid),
                        ("conversationType", requestConversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", refetchDirection),
                        ("newOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                        ("newNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                        ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                        ("datasourceCount", self.datasource.count)
                    ])
                    DDLogDebug(
                        "ChatViewController.remoteHistoryApply queryId=\(queryId) direction=\(refetchDirection) items=\(frozenItems.count) oldOldest=\(previousOldestArchivedId ?? "-") newOldest=\(nextVirtualState.oldest?.archivedId ?? "-") oldNewest=\(previousNewestArchivedId ?? "-") newNewest=\(nextVirtualState.newest?.archivedId ?? "-") queueWaitMs=\(queueWaitMs) mapMs=\(mapDurationMs)"
                    )
                    self.applyChatDatasource(
                        mappedDatasource,
                        mode: mode,
                        animated: animated,
                        invalidateLayout: false,
                        applyCategory: applyCategory,
                        anchorRestorePhase: anchorRestorePhase,
                        anchorPrimary: anchorPrimary,
                        restoreAnchor: restoreAnchor,
                        completion: {
                            completion?(applyResult)
                        }
                    )
                }
            } catch {
                ChatArchiveDebugTrace.log("remoteHistoryApplyWorkerError", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("error", error.localizedDescription)
                ])
                DDLogDebug("ChatViewController.mapAndApplyFinishedVirtualTimelineRemoteLoad: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    cancelledCompletion?()
                }
            }
        }
    }

    private func logInteractiveHistoryPagingPlan(
        direction: ChatHistoryPageDirection,
        plan: ChatInteractiveHistoryPagingPlan,
        localItemCount: Int,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false,
        queryId: String? = nil
    ) {
        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let boundedState = self.boundedTimelineWindowState
        DDLogDebug(
            "ChatViewController.interactivePaging direction=\(direction) plan=\(plan) localItems=\(localItemCount) resident=\(self.virtualTimelineState.residentPrimaryKeys.count) oldest=\(self.virtualTimelineState.oldest?.archivedId ?? "-") newest=\(self.virtualTimelineState.newest?.archivedId ?? "-") queryId=\(queryId ?? "-")"
        )
        ChatArchiveDebugTrace.log("interactivePagingPlan", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", direction),
            ("plan", "\(plan)"),
            ("queryId", queryId ?? "-"),
            ("localItems", localItemCount),
            ("localOlderCandidateCount", localOlderCandidateCount ?? -1),
            ("pageSize", pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", shortLocalRemainderRemoteFirst),
            ("virtualOldest", normalizedState.oldest?.archivedId ?? "-"),
            ("virtualNewest", normalizedState.newest?.archivedId ?? "-"),
            ("virtualResident", normalizedState.residentPrimaryKeys.count),
            ("boundedOldest", boundedState.oldest?.archivedId ?? "-"),
            ("boundedNewest", boundedState.newest?.archivedId ?? "-"),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("datasourceCount", self.datasource.count),
            ("observerCount", self.messagesObserver?.count ?? -1),
            ("activeRemoteLoad", normalizedState.activeRemoteLoad?.queryId ?? "-"),
            ("activePlaceholder", self.activeHistoryBoundaryPlaceholder != nil),
            ("currentPageLocked", self.currentPage.locked),
            ("canLoadDatasource", self.canLoadDatasource)
        ])
    }

    private func armRemoteInteractiveHistoryRequest(
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        queryId: String,
        localItemCount: Int,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) {
        self.logInteractiveHistoryPagingPlan(
            direction: direction,
            plan: .remote(decision),
            localItemCount: localItemCount,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst,
            queryId: queryId
        )
        self.currentPage.locked = true
    }

    private func beginVisibleRemoteHistoryLoading(
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        queryId: String,
        currentWindow: ChatDatasetWindow
    ) {
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestSendStarted", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("direction", direction),
            ("decision", "\(decision)"),
            ("cursor", self.interactiveHistoryPageLoadContext?.requestedCursorId ?? "-"),
            ("visibleLoaderBefore", self.currentPage.isLoading),
            ("placeholderBefore", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil)
        ])
        self.beginHistoryLoadingUI(queryId: queryId)
        self.showHistoryBoundaryPlaceholder(direction: direction, currentWindow: currentWindow)
    }

    private func shouldDispatchInteractiveRemoteArchiveRequestOnMain(queryId: String) -> Bool {
        if Thread.isMainThread {
            return self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId)
        }
        return DispatchQueue.main.sync {
            self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId)
        }
    }

    private func enqueueInteractiveRemoteArchiveRequest(
        queryId: String,
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        cursorId: String?,
        pageSize: Int,
        currentWindow: ChatDatasetWindow,
        cursorSource: ChatInteractiveOlderCursorSelectionSource? = nil,
        timelineOldestCursorId: String? = nil,
        boundedOldestCursorId: String? = nil,
        persistedCursorId: String? = nil,
        send: @escaping (_ stream: XMPPStream, _ mam: MessageArchiveManager, _ finish: @escaping () -> Void) -> String
    ) {
        let request = ChatInteractiveRemoteArchiveDispatchRequest(
            owner: self.owner,
            queryId: queryId,
            direction: direction,
            cursorId: cursorId,
            pageSize: pageSize,
            priority: .interactive,
            resource: .mamArchive,
            deduplicationKey: "chat.interactive-history.\(queryId)",
            shouldDispatch: { [weak self] in
                self?.shouldDispatchInteractiveRemoteArchiveRequestOnMain(queryId: queryId) ?? false
            },
            send: { [weak self] account, stream, finish in
                guard let self else {
                    return nil
                }
                self.registerRemoteHistoryPersistenceSource(account.messages, queryId: queryId)
                return send(stream, account.mam, finish)
            },
            transportStarted: { [weak self] sentQueryId, streamKind, resource in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    guard self.markInteractiveRemoteArchiveRequestSent(
                        queryId: sentQueryId,
                        direction: direction,
                        cursorId: cursorId,
                        pageSize: pageSize,
                        streamKind: streamKind,
                        resource: resource,
                        bootstrapActive: self.isInitialBootstrapInFlight,
                        cursorSource: cursorSource,
                        timelineOldestCursorId: timelineOldestCursorId,
                        boundedOldestCursorId: boundedOldestCursorId,
                        persistedCursorId: persistedCursorId
                    ) else {
                        return
                    }
                    self.beginVisibleRemoteHistoryLoading(
                        direction: direction,
                        decision: decision,
                        queryId: sentQueryId,
                        currentWindow: currentWindow
                    )
                }
            },
            dispatchUnavailable: { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId) else {
                        return
                    }
                    ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchUnavailable", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", direction),
                        ("cursor", cursorId ?? "-"),
                        ("reason", reason),
                        ("visibleLoader", self.currentPage.isLoading),
                        ("placeholderState", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil)
                    ])
                    self.abortInteractiveHistoryPageLoad()
                }
            }
        )
        self.interactiveRemoteArchiveRequestDispatcher.enqueue(request)
    }
    
    internal final func loadDatasource(direction: ChatHistoryPageDirection, first: Bool = false, ignoreGaps: Bool = false, samePage: Bool = false, callback: @escaping ((ChatTimelineSnapshot?) -> Void)) {
        func getWindow() -> ChatDatasetWindow {
            let currentWindow = self.visibleWindow()

            if samePage {
                return self.datasetCoordinator.clamp(currentWindow, totalCount: self.messagesObserver.count)
            }

            return self.datasetCoordinator.nextWindow(
                from: currentWindow,
                direction: direction
            )
        }
        
        guard self.messagesObserver != nil else {
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback(nil)
            return
        }
        let currentWindow = self.visibleWindow()
        let requestedWindow = getWindow()
        if requestedWindow.isEmpty && !first {
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback(nil)
            return
        }
        let chatArchiveState = self.loadChatArchiveStateSnapshot()
        let persistedArchiveEnded = chatArchiveState.fullArchiveLoaded
        let shouldProbePersistedArchiveEnd = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
            persistedArchiveEnded: persistedArchiveEnded,
            hasConfirmedArchiveEndThisSession: self.hasConfirmedArchiveEndThisSession,
            hasUsedVerificationProbe: self.hasUsedArchiveEndVerificationProbe
        )
        let effectiveArchiveEnded = ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
            persistedArchiveEnded: persistedArchiveEnded,
            shouldProbePersistedArchiveEnd: shouldProbePersistedArchiveEnd
        )
        let virtualArchiveState = ChatArchiveStateSnapshot(
            primaryKey: chatArchiveState.primaryKey,
            persistedCursorId: chatArchiveState.persistedCursorId,
            fullArchiveLoaded: effectiveArchiveEnded,
            newestCursorId: chatArchiveState.newestCursorId,
            newerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
            hasKnownNewerGap: chatArchiveState.hasKnownNewerGap,
            knownGaps: chatArchiveState.knownGaps
        )
        let virtualSnapshot = self.virtualTimelinePageSnapshot(
            direction: direction,
            archiveState: virtualArchiveState
        )
        guard let virtualSnapshot else {
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback(nil)
            return
        }
        let decision = virtualSnapshot.loadDecision
        ChatArchiveDebugTrace.log("timelinePagingDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", direction),
            ("decision", "\(decision)"),
            ("snapshotItems", virtualSnapshot.items.count),
            ("snapshotOldest", virtualSnapshot.state.oldest?.archivedId ?? "-"),
            ("snapshotNewest", virtualSnapshot.state.newest?.archivedId ?? "-"),
            ("snapshotResident", virtualSnapshot.state.residentPrimaryKeys.count),
            ("localOlderCandidateCount", virtualSnapshot.localOlderCandidateCount ?? -1),
            ("pageSize", virtualSnapshot.pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", virtualSnapshot.shortLocalRemainderRemoteFirst),
            ("currentOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
            ("currentNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
            ("currentResident", self.virtualTimelineState.residentPrimaryKeys.count),
            ("boundedOldest", self.boundedTimelineWindowState.oldest?.archivedId ?? "-"),
            ("boundedNewest", self.boundedTimelineWindowState.newest?.archivedId ?? "-"),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("observerCount", self.messagesObserver?.count ?? -1)
        ])

        let pagingPlan = ChatInteractiveHistoryPagingPlanPolicy.plan(for: decision)
        if !pagingPlan.shouldShowOverlay {
            self.logInteractiveHistoryPagingPlan(
                direction: direction,
                plan: pagingPlan,
                localItemCount: virtualSnapshot.items.count,
                localOlderCandidateCount: virtualSnapshot.localOlderCandidateCount,
                pageSize: virtualSnapshot.pageSize,
                shortLocalRemainderRemoteFirst: virtualSnapshot.shortLocalRemainderRemoteFirst
            )
        }

        switch pagingPlan {
        case .local:
            callback(virtualSnapshot)
        case .remote(.remoteOlderPage):
            let cursorSelection = self.interactiveOlderPagingCursorSelection(
                in: currentWindow,
                persistedCursorId: chatArchiveState.persistedCursorId
            )
            let archivedId = cursorSelection.cursorId
            ChatArchiveDebugTrace.log("remoteOlderCursorSelection", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("requestedCursor", archivedId ?? "-"),
                ("cursorSource", cursorSelection.source.rawValue),
                ("timelineOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                ("boundedOldest", self.boundedTimelineWindowState.oldest?.archivedId ?? "-"),
                ("observedOldest", self.observedArchivedIds(in: currentWindow).first(where: { $0.isNotEmpty }) ?? "-"),
                ("persistedCursor", chatArchiveState.persistedCursorId ?? "-"),
                ("cursorDiffersFromPersisted", archivedId != chatArchiveState.persistedCursorId)
            ])
            let queryId = "MAM next history: \(NanoID.new(6))"
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let remoteSnapshot = self.virtualTimelinePageSnapshot(
                direction: direction,
                queryId: queryId,
                archiveState: virtualArchiveState
            )
            let armedSnapshot = remoteSnapshot.map(self.armedRemoteSnapshotWithoutVisiblePlaceholder)
            if let armedSnapshot {
                self.applyVirtualTimelineSnapshotState(armedSnapshot)
            }
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.persistedCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: shouldProbePersistedArchiveEnd ? false : persistedArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: shouldProbePersistedArchiveEnd,
                canMutateOlderArchiveEnd: true,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .pageOlder(cursorArchiveId: archivedId)
            )
            self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteOlderPage,
                queryId: queryId,
                localItemCount: armedSnapshot?.items.count ?? 0,
                localOlderCandidateCount: armedSnapshot?.localOlderCandidateCount,
                pageSize: armedSnapshot?.pageSize,
                shortLocalRemainderRemoteFirst: armedSnapshot?.shortLocalRemainderRemoteFirst ?? false
            )
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager, @escaping () -> Void) -> String = { stream, mam, finish in
                mam.getNextHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: finish,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteOlderPage,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                cursorSource: cursorSelection.source,
                timelineOldestCursorId: self.virtualTimelineState.oldest?.archivedId,
                boundedOldestCursorId: self.boundedTimelineWindowState.oldest?.archivedId,
                persistedCursorId: chatArchiveState.persistedCursorId,
                send: requestRemoteHistory
            )
        case .remote(.remoteNewerPage):
            guard let archivedId = self.visibleNewerPagingCursorId(in: currentWindow, persistedCursorId: chatArchiveState.newestCursorId),
                  archivedId.isNotEmpty else {
                self.setDatasourceLoadingEnabled(true)
                self.currentPage.unlock()
                callback(nil)
                return
            }
            let queryId = "MAM prev history: \(NanoID.new(6))"
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let remoteSnapshot = self.virtualTimelinePageSnapshot(
                direction: direction,
                queryId: queryId,
                archiveState: virtualArchiveState
            )
            let armedSnapshot = remoteSnapshot.map(self.armedRemoteSnapshotWithoutVisiblePlaceholder)
            if let armedSnapshot {
                self.applyVirtualTimelineSnapshotState(armedSnapshot)
            }
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.newestCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .pageNewer(cursorArchiveId: archivedId)
            )
            self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteNewerPage,
                queryId: queryId,
                localItemCount: armedSnapshot?.items.count ?? 0
            )
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager, @escaping () -> Void) -> String = { stream, mam, finish in
                mam.getPrevHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: finish,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteNewerPage,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .remote(.remoteGapRepairOlder(let gap)):
            let archivedId = gap.newerRangeOldestArchiveId
            let queryId = "MAM gap repair history: \(NanoID.new(6))"
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let remoteSnapshot = self.virtualTimelinePageSnapshot(
                direction: direction,
                queryId: queryId,
                archiveState: virtualArchiveState
            )
            let armedSnapshot = remoteSnapshot.map(self.armedRemoteSnapshotWithoutVisiblePlaceholder)
            if let armedSnapshot {
                self.applyVirtualTimelineSnapshotState(armedSnapshot)
            }
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.persistedCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .gapRepairOlder(cursorArchiveId: archivedId)
            )
            self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteGapRepairOlder(gap),
                queryId: queryId,
                localItemCount: armedSnapshot?.items.count ?? 0
            )
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager, @escaping () -> Void) -> String = { stream, mam, finish in
                mam.getGapRepairHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    gap: gap,
                    direction: .older,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: finish,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairOlder(gap),
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .remote(.remoteGapRepairNewer(let gap)):
            let archivedId = gap.olderRangeNewestArchiveId
            let queryId = "MAM gap repair history: \(NanoID.new(6))"
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let remoteSnapshot = self.virtualTimelinePageSnapshot(
                direction: direction,
                queryId: queryId,
                archiveState: virtualArchiveState
            )
            let armedSnapshot = remoteSnapshot.map(self.armedRemoteSnapshotWithoutVisiblePlaceholder)
            if let armedSnapshot {
                self.applyVirtualTimelineSnapshotState(armedSnapshot)
            }
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.newestCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .gapRepairNewer(cursorArchiveId: archivedId)
            )
            self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteGapRepairNewer(gap),
                queryId: queryId,
                localItemCount: armedSnapshot?.items.count ?? 0
            )
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager, @escaping () -> Void) -> String = { stream, mam, finish in
                mam.getGapRepairHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    gap: gap,
                    direction: .newer,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: finish,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairNewer(gap),
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .endReached, .noOp, .remote(.localOnly), .remote(.endReached):
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback(nil)
            return
        }
    }

    private func boundaryGapPagingDecision(
        direction: ChatHistoryPageDirection,
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatHistoryPagingLoadDecision? {
        guard self.conversationType == .regular,
              knownGaps.isNotEmpty,
              let currentOldest = self.boundedTimelineWindowState.oldest,
              let currentNewest = self.boundedTimelineWindowState.newest else {
            return nil
        }

        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            let requestedItems: [MessageStorageItem]
            switch direction {
            case .older:
                requestedItems = provider.older(before: currentOldest, limit: self.datasourcePageSize)
            case .newer:
                requestedItems = provider.newer(after: currentNewest, limit: self.datasourcePageSize)
            }
            guard let requestedOldest = requestedItems.first.map(ChatTimelineBoundary.init(message:)),
                  let requestedNewest = requestedItems.last.map(ChatTimelineBoundary.init(message:)) else {
                return nil
            }

            return ChatArchiveBoundaryGapPagingPolicy.loadDecision(
                direction: direction,
                currentOldestArchiveId: currentOldest.archivedId,
                currentNewestArchiveId: currentNewest.archivedId,
                requestedOldestArchiveId: requestedOldest.archivedId,
                requestedNewestArchiveId: requestedNewest.archivedId,
                knownGaps: knownGaps
            )
        } catch {
            DDLogDebug("ChatViewController.boundaryGapPagingDecision: \(error.localizedDescription)")
            return nil
        }
    }
    
    
    func didReceiveChangeset() {
        let startedAt = Date()
        if self.datasource.isNotEmpty {
            self.setShouldShowInitialMessage(false)
        }
        self.rebuildUnreadMentionItems()
        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let completion = {
            ChatArchiveDebugTrace.log("observerRefreshCompletion", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("oldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                ("newest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                ("datasourceCount", self.datasource.count)
            ])
            if self.pendingForceLatestOpen {
                self.finishLatestBottomScroll(
                    animated: self.pendingForceLatestOpenAnimated && !self.initialHistoryAppearancePending,
                    consumePendingForceLatest: true
                )
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
        let baseShouldOpenLatest = ChatTimelineObserverRefreshPolicy.shouldOpenLatest(
            isTimelineEmpty: normalizedState.isEmpty,
            isResidentAtLiveTail: normalizedState.isResidentAtLiveTail,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            hasActiveRemoteLoad: normalizedState.activeRemoteLoad != nil,
            hasInteractiveRemoteContext: self.interactiveHistoryPageLoadContext != nil
        ) || self.pendingForceLatestOpen
        let stabilizationAction = self.initialLatestObserverRefreshAction(baseShouldOpenLatest: baseShouldOpenLatest)
        let shouldOpenLatest = stabilizationAction == .openLatestNonAnimated ||
            (stabilizationAction == .followDefault && baseShouldOpenLatest)
        ChatArchiveDebugTrace.log("observerRefreshDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("action", shouldOpenLatest ? "openLatest" : "current"),
            ("stabilizationAction", "\(stabilizationAction)"),
            ("isTimelineEmpty", normalizedState.isEmpty),
            ("isResidentAtLiveTail", normalizedState.isResidentAtLiveTail),
            ("isShowingBootstrapPlaceholder", self.isShowingBootstrapPlaceholder),
            ("activeRemoteLoad", normalizedState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
            ("oldest", normalizedState.oldest?.archivedId ?? "-"),
            ("newest", normalizedState.newest?.archivedId ?? "-"),
            ("residentCount", normalizedState.residentPrimaryKeys.count),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("datasourceCount", self.datasource.count)
        ])
        switch stabilizationAction {
        case .keepCurrentNoScroll:
            self.mapAndApplyTimelineCurrent(
                mode: .targetedDiff,
                animated: false,
                invalidateLayout: false,
                suppressDefaultBottomScroll: true,
                completion: completion
            )
        case .openLatestNonAnimated:
            self.mapAndApplyTimelineLatest(
                mode: .targetedDiff,
                animated: false,
                invalidateLayout: false,
                limit: self.initialFirstFramePageSize,
                suppressDefaultBottomScroll: true,
                forceBottomAlignmentTarget: .newestRealMessage,
                completion: {
                    completion()
                    self.finishLatestBottomScroll(
                        animated: false,
                        consumePendingForceLatest: self.pendingForceLatestOpen
                    )
                }
            )
        case .followDefault where shouldOpenLatest:
            self.mapAndApplyTimelineLatest(
                mode: .targetedDiff,
                animated: self.shouldAnimateInitialHistoryAppearance,
                invalidateLayout: false,
                completion: completion
            )
        case .followDefault:
            self.mapAndApplyTimelineCurrent(
                mode: .targetedDiff,
                animated: self.shouldAnimateInitialHistoryAppearance,
                invalidateLayout: false,
                completion: completion
            )
        }
    }
    
    internal func scrollToLastOrUnreadItem() {
        if ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            self.requestForceLatestOpen(animated: !self.initialHistoryAppearancePending)
            return
        }

        if ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        ) {
            self.performPendingOpenMessageRequestIfNeeded()
            return
        }
        let shouldAnimateScroll = !self.initialHistoryAppearancePending

        if ChatOpenMessageRequestHandlingPolicy.shouldHonorDefaultUnreadPosition(),
           let index = self.unreadMessagePositionId {
            if Set(self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section })).contains(index) {
                self.scrollToBottom(animated: shouldAnimateScroll)
                self.scheduleSavedVisiblePositionFlushAfterBottomScroll(animated: shouldAnimateScroll)
            } else if self.datasourceItem(atSection: index) != nil {
                self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: shouldAnimateScroll)
            } else {
                self.scrollToLatestTimeline(animated: shouldAnimateScroll)
            }
            return
        }

        self.scrollToLatestTimeline(animated: shouldAnimateScroll)
    }
}
