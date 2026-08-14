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
//import RxSwift
import UIKit
import MaterialComponents.MDCPalettes
import CryptoSwift
import CryptoKit

enum GroupMessageMentionIntent: Equatable, Sendable {
    case absent
    case members([String])
    case all
    case invalid
}

enum GroupMessageMentionsCodec {
    private static let groupsNamespace = "https://xabber.com/protocol/groups"

    static func decode(from message: DDXMLElement) -> GroupMessageMentionIntent {
        let namedContainers = directChildren(of: message).filter { $0.name == "mentions" }
        let containers = namedContainers.filter { effectiveNamespace(of: $0) == groupsNamespace }
        guard namedContainers.count == containers.count else { return .invalid }
        guard !containers.isEmpty else { return .absent }
        guard message.attributeStringValue(forName: "type") == "chat",
              containers.count == 1,
              let mentions = containers.first,
              (mentions.attributes ?? []).isEmpty,
              normalizedText(mentions.stringValue) == nil else {
            return .invalid
        }

        let users = directChildren(of: mentions)
        guard users.allSatisfy({
            $0.name == "user" && effectiveNamespace(of: $0) == groupsNamespace
        }) else {
            return .invalid
        }
        if users.isEmpty {
            return .all
        }

        var memberIDs: [String] = []
        var seenMemberIDs: Set<String> = []
        for user in users {
            let attributes = user.attributes ?? []
            guard attributes.count == 1,
                  attributes.first?.name == "id",
                  directChildren(of: user).isEmpty,
                  normalizedText(user.stringValue) == nil,
                  let memberID = canonicalMemberID(user.attributeStringValue(forName: "id")),
                  seenMemberIDs.insert(memberID).inserted else {
                return .invalid
            }
            memberIDs.append(memberID)
        }
        return .members(memberIDs)
    }

    static func encode(
        _ intent: GroupMessageMentionIntent,
        capabilityGranted _: Bool,
        senderRole: GroupMemberRole?
    ) -> DDXMLElement? {
        switch intent {
        case .absent, .invalid:
            return nil
        case .all:
            guard senderRole == .admin || senderRole == .owner else {
                return nil
            }
            return DDXMLElement(name: "mentions", xmlns: groupsNamespace)
        case let .members(rawMemberIDs):
            var memberIDs: [String] = []
            var seenMemberIDs: Set<String> = []
            for rawMemberID in rawMemberIDs {
                guard let memberID = canonicalMemberID(rawMemberID) else { return nil }
                if seenMemberIDs.insert(memberID).inserted {
                    memberIDs.append(memberID)
                }
            }
            guard !memberIDs.isEmpty else { return nil }

            let mentions = DDXMLElement(name: "mentions", xmlns: groupsNamespace)
            memberIDs.forEach { memberID in
                let user = DDXMLElement(name: "user")
                user.addAttribute(withName: "id", stringValue: memberID)
                mentions.addChild(user)
            }
            return mentions
        }
    }

    static func storageValue(for intent: GroupMessageMentionIntent?) -> String? {
        guard let intent else { return nil }
        switch intent {
        case .absent:
            return "absent"
        case .all:
            return "all"
        case .invalid:
            return "invalid"
        case let .members(memberIDs):
            guard let data = try? JSONSerialization.data(withJSONObject: memberIDs),
                  let json = String(data: data, encoding: .utf8) else {
                return "invalid"
            }
            return "members:\(json)"
        }
    }

    static func intent(fromStorageValue value: String?) -> GroupMessageMentionIntent? {
        guard let value else { return nil }
        switch value {
        case "absent":
            return .absent
        case "all":
            return .all
        case "invalid":
            return .invalid
        default:
            let prefix = "members:"
            guard value.hasPrefix(prefix),
                  let data = String(value.dropFirst(prefix.count)).data(using: .utf8),
                  let memberIDs = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return .invalid
            }
            return .members(memberIDs)
        }
    }

    static func memberIDs<S: Sequence>(from references: S) -> [String]
    where S.Element == MessageReferenceStorageItem {
        var memberIDs: [String] = []
        var seenMemberIDs: Set<String> = []
        for reference in references where reference.kind == .mention {
            guard let memberID = memberID(from: reference),
                  seenMemberIDs.insert(memberID).inserted else {
                continue
            }
            memberIDs.append(memberID)
        }
        return memberIDs
    }

    static func memberID(from reference: MessageReferenceStorageItem) -> String? {
        let uri = reference.metadata?["uri"] as? String ?? reference.url
        let uriMemberID: String?
        if let uri {
            guard let canonicalURIValue = canonicalMentionMemberID(from: uri) else { return nil }
            uriMemberID = canonicalURIValue
        } else {
            uriMemberID = nil
        }
        if let rawMemberID = reference.metadata?["memberId"] as? String {
            guard let memberID = canonicalMemberID(rawMemberID) else { return nil }
            guard uriMemberID == nil || uriMemberID == memberID else { return nil }
            return memberID
        }
        return uriMemberID
    }

    private static func canonicalMentionMemberID(from uri: String) -> String? {
        guard uri.hasPrefix("xmpp:") else { return nil }
        let addressAndQuery = uri.dropFirst("xmpp:".count)
        let parts = addressAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let groupJID = parts.first.map(String.init) ?? ""
        guard parts.count == 2,
              !groupJID.isEmpty,
              !groupJID.contains(where: { $0.isWhitespace }),
              let parsedGroupJID = XMPPJID(string: groupJID),
              parsedGroupJID.resource == nil,
              parsedGroupJID.bare == groupJID else {
            return nil
        }
        let queryParts = parts[1].split(separator: ";", omittingEmptySubsequences: false)
        guard queryParts.count == 2,
              queryParts[0] == "members",
              queryParts[1].hasPrefix("id=") else {
            return nil
        }
        let memberID = String(queryParts[1].dropFirst("id=".count))
        guard !memberID.contains("&"),
              !memberID.contains("#") else {
            return nil
        }
        return canonicalMemberID(memberID)
    }

    private static func canonicalMemberID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == rawValue,
              !rawValue.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return rawValue
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func directChildren(of element: DDXMLElement) -> [DDXMLElement] {
        element.children?.compactMap { $0 as? DDXMLElement } ?? []
    }

    private static func effectiveNamespace(of element: DDXMLElement) -> String? {
        var current: DDXMLElement? = element
        while let candidate = current {
            if let namespace = candidate.xmlns() {
                return namespace
            }
            current = candidate.parent as? DDXMLElement
        }
        return nil
    }
}

struct MessageHistoryOrderKey: Comparable, Equatable {
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

    static func < (lhs: MessageHistoryOrderKey, rhs: MessageHistoryOrderKey) -> Bool {
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

        let primaryComparison = compareIdentifier(lhs.primary, rhs.primary)
        if primaryComparison != .orderedSame {
            return primaryComparison == .orderedAscending
        }
        return lhs.primary < rhs.primary
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

struct MessageHistoryPositionComponents: Comparable, Equatable {
    let ordinal: Int64
    let kind: Int
    let high: Int64
    let low: Int64
    let discriminator: Int64

    static func make(
        primary: String,
        archivedId: String?,
        messageId: String?,
        date: Date
    ) -> MessageHistoryPositionComponents {
        let archivedId = archivedId?.isNotEmpty == true ? archivedId! : ""
        let messageId = messageId?.isNotEmpty == true ? messageId! : ""
        let identity = archivedId + "\u{1F}" + messageId + "\u{1F}" + primary

        if let numericArchiveId = Int64(archivedId), archivedId.isNotEmpty {
            return MessageHistoryPositionComponents(
                ordinal: chronologicalOrdinal(date: date, numericArchiveId: numericArchiveId, cursor: archivedId),
                kind: 1,
                high: numericArchiveId,
                low: 0,
                discriminator: stableDiscriminator(identity)
            )
        }

        let cursor = archivedId.isNotEmpty ? archivedId : (messageId.isNotEmpty ? messageId : primary)
        let bytes = Array(cursor.utf8)
        return MessageHistoryPositionComponents(
            ordinal: chronologicalOrdinal(date: date, numericArchiveId: nil, cursor: cursor),
            kind: archivedId.isNotEmpty ? 2 : 0,
            high: lexicographicChunk(bytes, offset: 0),
            low: lexicographicChunk(bytes, offset: 7),
            discriminator: stableDiscriminator(identity)
        )
    }

    static func < (lhs: MessageHistoryPositionComponents, rhs: MessageHistoryPositionComponents) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.high != rhs.high { return lhs.high < rhs.high }
        if lhs.low != rhs.low { return lhs.low < rhs.low }
        return lhs.discriminator < rhs.discriminator
    }

    private static func lexicographicChunk(_ bytes: [UInt8], offset: Int) -> Int64 {
        var value: UInt64 = 0
        for index in 0..<7 {
            value <<= 8
            let sourceIndex = offset + index
            if sourceIndex < bytes.count {
                value |= UInt64(bytes[sourceIndex])
            }
        }
        return Int64(value)
    }

    private static func stableDiscriminator(_ identity: String) -> Int64 {
        let digest = CryptoKit.SHA256.hash(data: Data(identity.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(value & UInt64(Int64.max))
    }

    private static func chronologicalOrdinal(
        date: Date,
        numericArchiveId: Int64?,
        cursor: String
    ) -> Int64 {
        let millisecondsSinceUnixEpoch = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        let millisecondsAtReferenceEpoch: Int64 = 946_684_800_000 // 2000-01-01T00:00:00Z
        let timeComponent = millisecondsSinceUnixEpoch - millisecondsAtReferenceEpoch
        let scale: Int64 = 1_048_576
        let tieRange: Int64 = 1_000_000
        let tie: Int64
        if let numericArchiveId {
            tie = ((numericArchiveId % tieRange) + tieRange) % tieRange
        } else {
            var suffix: UInt64 = 0
            for byte in cursor.utf8.suffix(3) {
                suffix = (suffix << 8) | UInt64(byte)
            }
            tie = Int64(suffix % UInt64(tieRange))
        }
        let (scaled, overflow) = timeComponent.multipliedReportingOverflow(by: scale)
        guard !overflow else {
            return timeComponent >= 0 ? Int64.max - tieRange + tie : Int64.min + tie
        }
        return scaled + tie
    }
}

final class ChatLocalHistoryIndexStorageItem: Object {
    static let currentVersion = 1

    override static func primaryKey() -> String? { "primary" }
    override static func indexedProperties() -> [String] {
        ["owner", "jid", "conversationType_"]
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var oldestMessagePrimary: String? = nil
    @objc dynamic var newestMessagePrimary: String? = nil
    @objc dynamic var indexedVisibleCount: Int = 0
    @objc dynamic var version: Int = 0

    static func genPrimary(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> String {
        ["chat-local-history-index", owner, jid, conversationType.rawValue].prp()
    }
}


class MessageStorageItem: Object {
    
    static let addContactLocalArchivedId: String = "add-contact-local-archived-id"
    
    enum MessageDisplayType: String {
        case text = "text"
        case call = "call"
        case system = "system"
        case sticker = "sticker"
    }
    
    public enum MessageSendingState: Int {
        case sended
        case deliver
        case read
        case error
        case none
        case notSended
        case sending
        case uploading
    }

    enum DeleteState: String {
        case visible
        case autoDeleted
    }

    enum UnreadCounterBucket: String {
        case none
        case runtime
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    override static func indexedProperties() -> [String] {
        return [
            "opponent", "owner", "date", "conversationType_", "archivedId", "messageId",
            "isDeleted", "deleteState_", "historyPositionOrdinal", "historyPositionKind",
            "historyPositionHigh", "historyPositionLow", "historyPositionDiscriminator"
        ]
    }
    
    @objc dynamic var primary: String = "" {
        didSet { refreshHistoryPositionComponents() }
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var opponent: String = ""
    
    @objc dynamic var body: String = ""
    @objc dynamic var legacyBody: String = ""
    
    @objc dynamic var date: Date = Date() {
        didSet { refreshHistoryPositionComponents() }
    }
    @objc dynamic var sentDate: Date = Date()
    @objc dynamic var editDate: Date? = nil
    @objc dynamic var outgoing: Bool = false
    @objc dynamic var isRead: Bool = false
    
    @objc dynamic var messageType: String = MessageDisplayType.text.rawValue
    
    @objc dynamic var messageId: String = "" {
        didSet { refreshHistoryPositionComponents() }
    }
    
    @objc dynamic var trustedSource: Bool = false
    @objc dynamic var previousId: String? = nil
    @objc dynamic var queryIds: String? = nil
    
    @objc dynamic var archivedId: String = "" {
        didSet { refreshHistoryPositionComponents() }
    }

    @objc dynamic var historyPositionOrdinal: Int64 = 0
    @objc dynamic var historyPositionKind: Int = 0
    @objc dynamic var historyPositionHigh: Int64 = 0
    @objc dynamic var historyPositionLow: Int64 = 0
    @objc dynamic var historyPositionDiscriminator: Int64 = 0
    @objc dynamic var historyPreviousMessagePrimary: String? = nil
    @objc dynamic var historyNextMessagePrimary: String? = nil
    @objc dynamic var historyLinkedIndexVersion: Int = 0
    
    @objc dynamic var isDeleted: Bool = false
    @objc dynamic var state_: Int = 0
    
    /// Immutable saved-message envelope facts. Group authorship itself lives
    /// exclusively in the message's canonical group reference snapshot.
    @objc dynamic var isSavedForward: Bool = false
    @objc dynamic var savedForwardAuthorJid: String = ""
    
    @objc dynamic var envelopeContainer: String? = nil
    @objc dynamic var afterburnInterval: Double = -1
    @objc dynamic var burnDate: Double = -1
    @objc dynamic var readDate: Double = -1
    @objc dynamic var autoDeleteTTLSeconds: Double = -1
    @objc dynamic var autoDeleteExpiresAt: Double = -1
    @objc dynamic var autoDeletePolicyVersion: Int = 0
    @objc dynamic var deleteState_: String = DeleteState.visible.rawValue
    @objc dynamic var unreadCounterBucket_: String = UnreadCounterBucket.none.rawValue
    
    @objc dynamic var errorMetadata_: String? = nil
    @objc dynamic var systemMetadata_: String? = nil
    @objc dynamic var groupMentionIntent_: String? = nil
    @objc dynamic var groupMentionSenderRole_: String? = nil
    @objc dynamic var groupMentionAllCapabilityGranted: Bool = false
    @objc dynamic var isLocallyHiddenByReport: Bool = false
    @objc dynamic var localReportState: String? = nil
    @objc dynamic var lastReportedAt: Date? = nil
    @objc dynamic var lastReportReason: String? = nil
    @objc dynamic var reportCount: Int = 0
    
    var references: List<MessageReferenceStorageItem> = List<MessageReferenceStorageItem>()
    
    @objc dynamic var messageError: String? = nil
    @objc dynamic var messageErrorCode: String? = nil
    
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    
    var inlineForwards: List<MessageForwardsInlineStorageItem> = List<MessageForwardsInlineStorageItem>()

    func refreshHistoryPositionComponents() {
        let components = MessageHistoryPositionComponents.make(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId,
            date: date
        )
        guard historyPositionOrdinal != components.ordinal
                || historyPositionKind != components.kind
                || historyPositionHigh != components.high
                || historyPositionLow != components.low
                || historyPositionDiscriminator != components.discriminator else {
            return
        }
        historyPositionOrdinal = components.ordinal
        historyPositionKind = components.kind
        historyPositionHigh = components.high
        historyPositionLow = components.low
        historyPositionDiscriminator = components.discriminator
    }
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var isHasAttachedMessages: Bool {
        get {
            return false
        }
    }
    
    final var groupchatMetadata: [String: Any]? {
        get {
            return references.first(where: { $0.kind == .groupchat })?.metadata
        }
    }
    
    final var groupchatAuthorId: String? {
        get {
            if displayAs == .system { return nil }
            return Self.nonEmptyGroupAuthorValue(groupchatMetadata?["id"])
        }
    }
    
    final var groupchatAuthorNickname: String? {
        get {
            if displayAs == .system { return nil }
            return Self.nonEmptyGroupAuthorValue(groupchatMetadata?["nickname"])
                ?? Self.nonEmptyGroupAuthorValue(groupchatMetadata?["jid"])
        }
    }
    
    final var groupchatAuthorBadge: String? {
        get {
            let role = Self.nonEmptyGroupAuthorValue(groupchatMetadata?["role"])
            let badge = Self.nonEmptyGroupAuthorValue(groupchatMetadata?["badge"])
            if role?.lowercased() == "member" {
                return badge
            } else {
                return badge ?? role?.capitalized
            }
        }
    }

    final var groupchatAuthorAvatarURL: String? {
        Self.nonEmptyGroupAuthorValue(groupchatMetadata?["avatar_uri"])
    }
    
    final var groupchatDisplayedNickname: String? {
        get {
            if let nick = groupchatAuthorNickname,
                self.displayAs != .system {
                return outgoing ? "You:" : nick
            }
            return nil
        }
    }
    
    final var groupchatUserAvatarPath: String? {
        get {
            guard let avatarURL = groupchatAuthorAvatarURL else { return nil }
            return [avatarURL, opponent].prp()
        }
    }

    private static func nonEmptyGroupAuthorValue(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.isNotEmpty else {
            return nil
        }
        return value
    }
    
    var errorMetadata: [String: Any]? {
        get {
            if let metadata = errorMetadata_,
                let data = metadata.data(using: .utf8) {
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
                    errorMetadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode reference metadata with id: \(messageId)")
                }
            } else {
                errorMetadata_ = nil
            }
        }
    }
    
    var systemMetadata: [String: Any]? {
        get {
            if let metadata = systemMetadata_,
                let data = metadata.data(using: .utf8) {
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
                    systemMetadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode reference metadata with id: \(messageId)")
                }
            } else {
                systemMetadata_ = nil
            }
        }
    }
    
    var forceUnreadState: Bool? = nil
    var isInvite: Bool = false
    var shouldPersistArchiveQueryId: Bool = false
    var countsAsRuntimeUnread: Bool = false
    var groupMentionIntent: GroupMessageMentionIntent? {
        get { GroupMessageMentionsCodec.intent(fromStorageValue: groupMentionIntent_) }
        set { groupMentionIntent_ = GroupMessageMentionsCodec.storageValue(for: newValue) }
    }
    var groupMentionSenderRole: GroupMemberRole? {
        get { groupMentionSenderRole_.flatMap(GroupMemberRole.init(rawValue:)) }
        set { groupMentionSenderRole_ = newValue?.rawValue }
    }

    override static func ignoredProperties() -> [String] {
        return [
            "originalStanza",
            "forceUnreadState",
            "isInvite",
            "shouldPersistArchiveQueryId",
            "countsAsRuntimeUnread",
            "groupMentionIntent",
            "groupMentionSenderRole"
        ]
    }
    
    var originalStanza: XMPPMessage? = nil

    var unreadCounterBucket: UnreadCounterBucket {
        get {
            return UnreadCounterBucket(rawValue: unreadCounterBucket_) ?? .none
        } set {
            unreadCounterBucket_ = newValue.rawValue
        }
    }

    static let reportHiddenMessageText: String = "This message was hidden after your report."
        .localizeString(id: "report_hidden_message_placeholder", arguments: [])
    static let reportHiddenMediaText: String = "This media was hidden after your report."
        .localizeString(id: "report_hidden_media_placeholder", arguments: [])
    static let omemoUntrustedContactDevicesWarningText: String = "This message was not sent to one or more untrusted devices."
        .localizeString(id: "chat_omemo_untrusted_contact_devices_warning", arguments: [])
    static let messageWarningMetadataKey: String = "warning"
    static let omemoUntrustedContactDevicesWarningCode: String = "omemo_untrusted_contact_devices"

    var messageWarningText: String? {
        guard let warningCode = systemMetadata?[MessageStorageItem.messageWarningMetadataKey] as? String else {
            return nil
        }
        switch warningCode {
        case MessageStorageItem.omemoUntrustedContactDevicesWarningCode:
            return MessageStorageItem.omemoUntrustedContactDevicesWarningText
        default:
            return nil
        }
    }

    func markOmemoUntrustedContactDevicesWarning() {
        var metadata = systemMetadata ?? [:]
        metadata[MessageStorageItem.messageWarningMetadataKey] = MessageStorageItem.omemoUntrustedContactDevicesWarningCode
        systemMetadata = metadata
    }

    func clearOmemoUntrustedContactDevicesWarning() {
        guard var metadata = systemMetadata,
              metadata[MessageStorageItem.messageWarningMetadataKey] as? String == MessageStorageItem.omemoUntrustedContactDevicesWarningCode else {
            return
        }
        metadata.removeValue(forKey: MessageStorageItem.messageWarningMetadataKey)
        systemMetadata = metadata.isEmpty ? nil : metadata
    }

    var localReportPlaceholderText: String? {
        if isLocallyHiddenByReport {
            return MessageStorageItem.reportHiddenMessageText
        }
        let hiddenMedia = references.contains { reference in
            reference.isLocallyHiddenByReport && [.media, .voice].contains(reference.kind)
        }
        let visibleMedia = references.contains { reference in
            !reference.isLocallyHiddenByReport && [.media, .voice].contains(reference.kind)
        }
        if hiddenMedia && !visibleMedia && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MessageStorageItem.reportHiddenMediaText
        }
        return nil
    }
    
    var displayAs: MessageDisplayType {
        get {
            return MessageDisplayType(rawValue: self.messageType) ?? .text
        } set {
            messageType = newValue.rawValue
        }
    }
    
    var state: MessageSendingState {
        get {
            if displayAs == .system {
                return .none
            }
            return MessageSendingState(rawValue: self.state_) ?? .none
        } set {
            self.state_ = newValue.rawValue
        }
    }

    var deleteState: DeleteState {
        get {
            return DeleteState(rawValue: deleteState_) ?? .visible
        } set {
            deleteState_ = newValue.rawValue
        }
    }

    var effectiveAutoDeleteExpiresAt: Double {
        if autoDeleteExpiresAt > 0 {
            return autoDeleteExpiresAt
        }
        return burnDate
    }

    func applyAutoDeleteTTL(_ ttlSeconds: Double, startsAt date: Date, policyVersion: Int = 0) {
        guard ttlSeconds > 0 else {
            self.autoDeleteTTLSeconds = ttlSeconds
            self.autoDeleteExpiresAt = -1
            self.autoDeletePolicyVersion = policyVersion
            self.afterburnInterval = ttlSeconds
            self.burnDate = -1
            self.deleteState = .visible
            return
        }

        let expiresAt = date.timeIntervalSince1970 + ttlSeconds
        self.autoDeleteTTLSeconds = ttlSeconds
        self.autoDeleteExpiresAt = expiresAt
        self.autoDeletePolicyVersion = policyVersion
        self.afterburnInterval = ttlSeconds
        self.burnDate = expiresAt
        self.deleteState = .visible
    }

    func markAutoDeleted() {
        self.isDeleted = true
        self.body = ""
        self.legacyBody = ""
        self.deleteState = .autoDeleted
        synchronizeLocalHistoryIndexAfterVisibilityChange()
    }

    func markDeleted() {
        self.isDeleted = true
        synchronizeLocalHistoryIndexAfterVisibilityChange()
    }

    private func synchronizeLocalHistoryIndexAfterVisibilityChange() {
        guard let realm = self.realm,
              realm.isInWriteTransaction else {
            return
        }
        ChatLocalHistoryLinkedIndex.upsert(self, in: realm)
    }

    private var visibleGeolocReferences: [MessageReferenceStorageItem] {
        references.toArray().filter {
            !$0.isLocallyHiddenByReport && $0.kind == .geoloc
        }
    }

    private var visibleContactReferences: [MessageReferenceStorageItem] {
        references.toArray().filter {
            !$0.isLocallyHiddenByReport && $0.kind == .contact
        }
    }

    static var locationDisplayText: String {
        "Location".localizeString(id: "plurals.recent_chat__last_message__locations.item_0", arguments: [])
    }

    private static func nonEmptyContactText(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func contactDisplayTitle(for reference: MessageReferenceStorageItem) -> String? {
        guard let metadata = reference.metadata,
              let jid = nonEmptyContactText(metadata["contact_jid"]) else {
            return nil
        }

        if let displayTitle = nonEmptyContactText(metadata["display_title"]) {
            return displayTitle
        }

        if let nickname = nonEmptyContactText(metadata["nickname"]) {
            return nickname
        }

        let fullName = [
            nonEmptyContactText(metadata["given"]),
            nonEmptyContactText(metadata["family"])
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fullName.isNotEmpty {
            return fullName
        }

        return jid
    }

    private static func contactFallbackBody(for reference: MessageReferenceStorageItem) -> String? {
        guard let metadata = reference.metadata,
              let jid = nonEmptyContactText(metadata["contact_jid"]) else {
            return nil
        }

        let fullName = [
            nonEmptyContactText(metadata["given"]),
            nonEmptyContactText(metadata["family"])
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let display = fullName.isNotEmpty
            ? fullName
            : (nonEmptyContactText(metadata["display_title"]) ?? nonEmptyContactText(metadata["nickname"]) ?? jid)

        return display == jid ? jid : "\(display) (\(jid))"
    }

    private func bodyExcludingContactFallback(_ rawBody: String) -> String {
        var result = rawBody
        let sortedReferences = visibleContactReferences.sorted { $0.begin > $1.begin }
        for reference in sortedReferences {
            guard let fallback = Self.contactFallbackBody(for: reference),
                  reference.begin >= 0,
                  reference.end >= reference.begin,
                  reference.end <= (result as NSString).length else {
                continue
            }
            let range = NSRange(
                location: reference.begin,
                length: reference.end - reference.begin
            )
            let segment = (result as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment == fallback else {
                continue
            }
            result = (result as NSString).replacingCharacters(in: range, with: "")
        }
        return result
    }

    final var bodyForAttachmentRendering: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBody.isNotEmpty else { return body }
        let bodyMatchesLocationFallback = visibleGeolocReferences.contains { reference in
            let candidates = [
                reference.url,
                reference.metadata?["uri"] as? String
            ]
            return candidates.compactMap { $0 }.contains(trimmedBody)
        }
        if bodyMatchesLocationFallback {
            return ""
        }
        return bodyExcludingContactFallback(body)
    }

    final func copyableBodyText() -> String {
        let rawBody = legacyBody.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty ? legacyBody : body
        if rawBody.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
            return rawBody
        }
        return visibleGeolocReferences
            .compactMap { $0.url ?? $0.metadata?["uri"] as? String }
            .first ?? ""
    }
    
    public final func shouldShowAsSystemMessage() -> Bool {
        if localReportPlaceholderText != nil {
            return false
        }
        switch displayAs {
            case .text, .system:
                var resultBody: String = ""
	                let images: [ImageAttachment] = self.references.toArray().filter {
	                    item in
	                    !item.isLocallyHiddenByReport &&
	                    SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: item.kind, mimeType: item.mimeType, mediaType: item.metadata?["media-type"] as? String) == .image
                }.compactMap {
                    item in
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return ImageAttachment(primary: item.primary, url: url, size: item.sizeInPx ?? CGSize(square: 128), isSensitive: item.isSensitive)
                }
                
	                let videos: [VideoAttachment] = self.references.toArray().filter {
	                    !$0.isLocallyHiddenByReport && SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .video
                } .compactMap {
                    item in
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return VideoAttachment(primary: item.primary, url: url, size: item.sizeInPx ?? CGSize(square: 128), previewUrl: nil, duration: 0, downloaded: item.isDownloaded, isSensitive: item.isSensitive)
                }
                
                let audio: [AudioAttachment] = self.references.toArray().filter {
                    !$0.isLocallyHiddenByReport && $0.kind_ == "voice"
                } .compactMap {
                    item in
                    return AudioAttachment(primary: item.primary, url: item.decodedUrl, size: 10, name: "name", duration: Double(item.duration ?? 0), downloaded: item.isDownloaded, pcm: item.meteringLevels ?? [])
                }
                let contacts = visibleContactReferences
                
	                let files: [FileAttachment] = self.references.toArray().filter {
	                    return !$0.isLocallyHiddenByReport && $0.kind == .media && SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .unsupported && MimeIcon($0.mimeType).value != .audio
                } .compactMap {
                    item in
                    if item.kind_ == "groupchat" {
                        return nil
                    }
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return FileAttachment(primary: item.primary, url: url, size: Double(item.sizeInBytesRaw), name: item.filename ?? item.name ?? "file", mimeType: item.mimeType, downloaded: item.isDownloaded)
                }
                resultBody += body.trimmingCharacters(in: .whitespacesAndNewlines)
                if resultBody.isEmpty {
                    if images.count > 0 {
                        return true
                    }
                                    
                    if audio.count > 0 {
                        return true
                    }
                    
                    if videos.count > 0 {
                        return true
                    }
                    
                    if files.count > 0 {
                        return true
                    }
                    if contacts.count > 0 {
                        return true
                    }
                    if inlineForwards.count > 0 {
                        return true
                    }
                }
                
                return false
        case .call:
            return true
        case .sticker:
            return true
        }
    }
    
    public final func displayedBody() -> String {
        if let placeholder = localReportPlaceholderText {
            return placeholder
        }
        switch displayAs {
            case .text, .system:
                var resultBody: String = ""
	                let images: [ImageAttachment] = self.references.toArray().filter {
	                    item in
	                    !item.isLocallyHiddenByReport &&
	                    SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: item.kind, mimeType: item.mimeType, mediaType: item.metadata?["media-type"] as? String) == .image
                }.compactMap {
                    item in
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return ImageAttachment(primary: item.primary, url: url, size: item.sizeInPx ?? CGSize(square: 128), isSensitive: item.isSensitive)
                }
                
	                let videos: [VideoAttachment] = self.references.toArray().filter {
	                    !$0.isLocallyHiddenByReport && SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .video
                } .compactMap {
                    item in
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return VideoAttachment(primary: item.primary, url: url, size: item.sizeInPx ?? CGSize(square: 128), previewUrl: nil, duration: 0, downloaded: item.isDownloaded, isSensitive: item.isSensitive)
                }
                
                let audio: [AudioAttachment] = self.references.toArray().filter {
                    !$0.isLocallyHiddenByReport && $0.kind_ == "voice"
                } .compactMap {
                    item in
                    return AudioAttachment(primary: item.primary, url: item.decodedUrl, size: 10, name: "name", duration: Double(item.duration ?? 0), downloaded: item.isDownloaded, pcm: item.meteringLevels ?? [])
                }
                let contacts = visibleContactReferences
                
	                let files: [FileAttachment] = self.references.toArray().filter {
	                    return !$0.isLocallyHiddenByReport && $0.kind == .media && SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(kind: $0.kind, mimeType: $0.mimeType, mediaType: $0.metadata?["media-type"] as? String) == .unsupported && MimeIcon($0.mimeType).value != .audio
                } .compactMap {
                    item in
                    if item.kind_ == "groupchat" {
                        return nil
                    }
                    guard let url = item.downloadUrl else {
                        return nil
                    }
                    return FileAttachment(primary: item.primary, url: url, size: Double(item.sizeInBytesRaw), name: item.filename ?? item.name ?? "file", mimeType: item.mimeType, downloaded: item.isDownloaded)
                }
                let locations = visibleGeolocReferences
                resultBody += body.trimmingCharacters(in: .whitespacesAndNewlines)
                if resultBody.isEmpty {
                    
                    if images.count == 1 {
                        resultBody += "Image".localizeString(id: "chat_message_image", arguments: [])
                    } else if images.count > 1 {
                        resultBody += "Image, %@".localizeString(id: "chat_message_image_count", arguments: ["\(images.count)"])
                    }
                                    
                    if audio.count == 1 {
                        resultBody += "Voice message".localizeString(id: "chat_message_voice", arguments: [])
                    } else if audio.count > 1 {
                        resultBody += "Voice message, %@".localizeString(id: "chat_message_voice_duration", arguments: ["\(audio.count)"])
                    }
                    
                    if videos.count == 1 {
                        resultBody += "Video".localizeString(id: "chat_message_video", arguments: [])
                    } else if videos.count > 1 {
                        resultBody += "Video, %@".localizeString(id: "chat_message_video_count", arguments: ["\(videos.count)"])
                    }
                    
                    if files.count == 1 {
                        resultBody += "File".localizeString(id: "chat_message_file", arguments: [])
                    } else if files.count > 1 {
                        resultBody += "File, %@".localizeString(id: "chat_message_file_count", arguments: ["\(files.count)"])
                    }

                    if locations.isNotEmpty {
                        resultBody += Self.locationDisplayText
                    }

                    if contacts.count == 1,
                       let title = Self.contactDisplayTitle(for: contacts[0]) {
                        resultBody += title
                    } else if contacts.count > 1 {
                        resultBody += "Contact".localizeString(id: "chat_message_contact_count", arguments: ["\(contacts.count)"])
                    }
                    
                    if inlineForwards.count == 1 {
                        resultBody += "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])
                    } else if inlineForwards.count > 1 {
                        resultBody += "%@ forwarded messages".localizeString(id: "chat_message_some_forwarded_messages", arguments: ["\(files.count)"])
                    }
                }
                
                return resultBody
        case .call:
            return "Call".localizeString(id: "chat_message_call", arguments: []) // TODO change text
        case .sticker:
            return "Sticker".localizeString(id: "chat_message_sticker", arguments: []) // TODO: fix to sticker
        }
    }
    
    //TODO: foreignKey to CallStorageItem
    var callMetadata: [String: Any]? {
        get {
            return references.first(where: { $0.kind == .call })?.metadata
        }
    }
    
    public static func messageIdForAuthRequest(jid: String) -> String {
        return ["subscribtion", jid].prp()
    }
    
    
    public static func messageIdForContact(owner: String, jid: String, ts: String) -> String {
        return ["contact", ts, jid, owner].prp()
    }
    
    public static func messageIdForVoIPCall(owner: String, jid: String, callId: String) -> String {
        return ["voip", owner, jid, callId].prp()
    }
    
    public static func messageIdForInitial(jid: String, conversationType: ClientSynchronizationManager.ConversationType) -> String {
        return [jid, conversationType.rawValue, "initial_message"].prp()
    }
    
    public static func genPrimary(messageId: String, owner: String) -> String {
        var primary: String = ""
        primary = messageId
        primary += "_\(owner)"
        return primary
    }
    
    func updatePrimary(system: Bool = false, auth: Bool = false) {
        if self.primary.isNotEmpty { return }
        self.primary = MessageStorageItem.genPrimary(messageId: messageId,
                                                     owner: owner)
        if system {
            self.primary += "_sys"
        }
        if auth {
            self.primary += "_auth"
        }
        if isInvite {
            self.primary += "_invite"
        }
    }
    
    func storeStanza() {
        guard let stanza = originalStanza,
            primary.isNotEmpty else {
                return
        }
        let instance = MessageStanzaStorageItem()
        instance.set(messageId, for: owner, with: stanza.xmlString, at: date, primary: self.primary)
        do {
            let realm = try  WRealm.safe()
            if realm.isInWriteTransaction {
                realm.add(instance, update: .modified)
            } else {
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
        } catch {
            DDLogDebug("cant store stanza for message \(messageId)")
        }
    }

    func storeStanza(in realm: Realm) {
        guard let stanza = originalStanza,
            primary.isNotEmpty else {
                return
        }
        let instance = MessageStanzaStorageItem()
        instance.set(messageId, for: owner, with: stanza.xmlString, at: date, primary: self.primary)
        realm.add(instance, update: .modified)
    }
    
    func saveStanze(_ message: XMPPMessage, at date: Date) {
        if self.primary.isEmpty { return }
        let stanza = MessageStanzaStorageItem()
        stanza.set(messageId, for: owner, with: message.xmlString, at: date, primary: self.primary)
        do {
            let realm = try  WRealm.safe()
            if realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: stanza.primary) == nil {
                try realm.write {
                    realm.add(stanza, update: .modified)
                }
            }
        } catch {
            DDLogDebug("cant save message stanza for \(messageId)")
        }
    }
    
    internal func updateDisplayMode() {
        displayAs = .text
//        print(#function, self.references.toArray(), self.legacyBody, self.createReferences())
//        if !references.filter({ $0.kind == .call }).isEmpty {
//            displayAs = .call
//        } else if !references.filter({ $0.kind == .voice }).isEmpty {
//            if self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                if references.filter({ [.voice, .media].contains($0.kind) }).count == 1 {
//                    displayAs = .voice
//                } else {
//                    displayAs = .files
//                }
//            } else {
//                displayAs = .text
//            }
//            
//        } else if !references.filter({ [MimeIconTypes.file,
//                                        MimeIconTypes.archive,
//                                        MimeIconTypes.document,
//                                        MimeIconTypes.pdf,
//                                        MimeIconTypes.presentation,
//                                        MimeIconTypes.video,
//                                        MimeIconTypes.audio]
//            .map { return $0.rawValue}
//            .contains($0.mimeType) })
//            .isEmpty {
//            if self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                displayAs = .files
//            } else {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.mimeType == MimeIconTypes.image.rawValue }).isEmpty {
//            if references.filter({ $0.kind != .groupchat }).count == 1,
//                (references.filter({ $0.kind != .groupchat }).first?.metadata?["name"] as? String) == "Memoji" {
//                displayAs = .sticker
//            } else {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.mimeType == MimeIconTypes.file.rawValue }).isEmpty {
//            if references.filter({ $0.kind == .quote }).isEmpty {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.kind == .quote }).isEmpty {
//            displayAs = .quote
//        } else if !references.filter({ $0.kind == .systemMessage }).isEmpty {
//            displayAs = .system
//        }
    }

    
//    func configureInitialMessage(_ owner: String, opponent: String, conversationType: ClientSynchronizationManager.ConversationType, text: String?, date: Date, isRead: Bool) {
//        self.body = text ?? ""
//        self.owner = owner
//        self.opponent = opponent
//        self.date = date
//        self.isRead = isRead
//        self.outgoing = false
//        self.conversationType = conversationType
//        self.date = Date(timeIntervalSince1970: 0)
//        self.sentDate = date
//        self.messageId = MessageStorageItem.messageIdForInitial(jid: opponent, conversationType: conversationType)
//        self.displayAs = .initial
//        self.updatePrimary()
//    }
    
    func configureSystemMessage(
        _ messageContainer: XMPPMessage,
        owner: String,
        opponent: String,
        date: Date,
        source: GroupSystemMessageSource = .live
    ) {
        self.owner = owner
        self.opponent = opponent
        self.displayAs = .system
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        self.previousId = getPreviousId(messageContainer)
        self.updatePrimary()
        self.references.append(objectsIn: parseReferences(messageContainer, primary: self.primary, jid: opponent, owner: owner))
        self.legacyBody = messageContainer.body ?? ""
        self.body = messageContainer.body ?? ""
        self.systemMetadata = parseSystemMessageMetadata(messageContainer, source: source)
        self.date = date
        self.sentDate = date
        self.outgoing = false
        self.conversationType = .group
    }
    
    func editMessage(_ messageContainer: XMPPMessage, editDate: Date) {
        self.references.removeAll()
        self.references.append(objectsIn: parseReferences(messageContainer, primary: self.primary, jid: opponent, owner: owner))
        self.groupMentionIntent = GroupMessageMentionsCodec.decode(from: messageContainer)
        self.body = normalizedIncomingTextBody(from: messageContainer)
        if messageContainer.from == nil {
            messageContainer.addAttribute(withName: "from", stringValue: outgoing ? owner : opponent)
        }
        self.inlineForwards.removeAll()
        self.inlineForwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: primary, jid: opponent, owner: owner))
        self.updateDisplayMode()
        self.editDate = editDate
        self.messageError = "Edit"
        if self.archivedId.isEmpty {
            self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        }
        self.originalStanza = messageContainer
    }
    
    func configureIncomingMessage(_ messageContainer: XMPPMessage, owner: String, opponent: String, outgoing: Bool, isRead: Bool, date: Date, isEncrypted: Bool = false) {
        self.opponent = opponent
        self.owner = owner
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        self.previousId = getPreviousId(messageContainer)
        updatePrimary()
        self.references.append(objectsIn: parseReferences(messageContainer, primary: self.primary, jid: opponent, owner: owner))
        self.groupMentionIntent = GroupMessageMentionsCodec.decode(from: messageContainer)
        self.body = normalizedIncomingTextBody(from: messageContainer)
        if messageContainer.from == nil {
            messageContainer.addAttribute(withName: "from", stringValue: outgoing ? owner : opponent)
        }
        if let editDate = messageContainer.element(forName: "replaced")?.attributeStringValue(forName: "stamp")?.xmppDate {
            self.editDate = editDate
            self.messageError = "Edit"
        }
        self.legacyBody = messageContainer.body ?? ""
        self.outgoing = outgoing
        self.isRead = isRead
        self.date = date
        self.sentDate = date
        self.originalStanza = messageContainer
        
        self.conversationType = conversationTypeByMessage(messageContainer)
//        if isEncrypted {
//            self.conversationType = .omemo
//        }
        
//        if isEncrypted {
//            self.body = "Processing encrypted message..."
//            self.legacyBody = self.body
//            self.conversationType = .omemo
//        }
        
        self.inlineForwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: primary, jid: opponent, owner: owner))
        updateDisplayMode()
        self.references.forEach { $0.messageId = self.primary }
//        if self.displayAs == .text && self.createRefBody([:]).string.isEmpty {
//            self.isDeleted = true
//        }
    }
    
    func configureOutgoingMessage(_ body: String, legacy: String, messageId: String, owner: String, opponent: String, references: [MessageReferenceStorageItem], inlineForwards: [MessageForwardsInlineStorageItem]) {
        self.inlineForwards.append(objectsIn: inlineForwards)
        self.references.append(objectsIn: references)
        self.body = body
        self.legacyBody = legacy
        self.owner = owner
        self.opponent = opponent
        self.outgoing = true
        self.isRead = true
        self.messageId = messageId
        self.state = .notSended
        self.queryIds = "runtime_send"
        
        updatePrimary()
        updateDisplayMode()
        
        try? self.references.forEach {
            $0.messageId = self.primary
            $0.sentDate = Date()
            if CommonConfigManager.shared.config.use_file_enryption_by_default {
                
                if $0.conversationType.isEncrypted {
                    
                    var key = Data(count: 32)
                    
                    key.withUnsafeMutableBytes { (bytes) -> Void in
                        _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
                    }
                    
                    let salt = Array<UInt8>(repeating: 0, count: 32)
                    
                    let hkdf = try HKDF(
                        password: key.bytes,
                        salt: salt,
                        info: Array("Files encryption".data(using: .utf8)!),
                        keyLength: key.bytes.count,
                        variant: .sha256
                    ).calculate()
                    
                    let encryptionKey: Array<UInt8> = Array(hkdf.prefix(16))
                    let iv: Array<UInt8> = Array(hkdf.suffix(16))
                    
                    $0.metadata?["encryption-key"] = encryptionKey.toBase64()
                    $0.metadata?["iv"] = iv.toBase64()
                }
            }
        }
        
    }
    
    
    func genBody(_ count: Int, name: String, verbose: String) -> String {
        if count == 1 {
            return name
        } else {
            return "\(count) \(verbose)"
        }
    }
    
    func configureAuthRequestMessage(withBody body: String, opponent: String, owner: String) {
        self.body = body
        self.opponent = opponent
        self.owner = owner
        self.isRead = true
        self.date = Date()
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.messageId = MessageStorageItem.messageIdForAuthRequest(jid: opponent)
        self.displayAs = .system
        self.sentDate = date
        self.outgoing = false
        self.state = .none
        self.systemMetadata = ["auth_message": true]
        self.updatePrimary()
    }
    
    func configureContactMessage(withBody body: String, opponent: String, owner: String) {
        self.body = body
        self.opponent = opponent
        self.owner = owner
        self.isRead = true
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.date = Date()
        self.messageId = MessageStorageItem.messageIdForContact(owner: owner,
                                                                jid: opponent,
                                                                ts: "\(self.date.timeIntervalSinceReferenceDate)")
        self.displayAs = .system
        self.primary = self.messageId
//        self.archivedId = MessageStorageItem.addContactLocalArchivedId
        self.displayAs = .system
        self.sentDate = date
        self.outgoing = false
        self.state = .none
    }
    
    enum VoIPCallState: String {
        case missed = "missed"
        case noanswer = "noanswer"
        case made = "made"
        case busy = "busy"
        case received = "received"
        case none = "none"
    }
    
    public final func configureVoIPCallMessage(
        opponent: String,
        owner: String,
        date: Date,
        isRead: Bool,
        callId: String,
        archivedId: String?,
        outgoing: Bool,
        duration: TimeInterval,
        callState: VoIPCallState,
        terminationReason: String? = nil
    ) {
        self.opponent = opponent
        self.owner = owner
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.messageId = MessageStorageItem.messageIdForVoIPCall(
            owner: owner,
            jid: opponent,
            callId: callId
        )
        self.primary = self.messageId
        self.date = date
        self.sentDate = date
        self.state = .none
        self.isRead = isRead
        self.outgoing = outgoing
        self.displayAs = .call
        if let archivedId = archivedId {
            self.archivedId = archivedId
        }
        let reference = MessageReferenceStorageItem()
        reference.messageId = self.messageId
        reference.primary = [owner, callId].prp()
        reference.owner = owner
        reference.kind = .call
        reference.metadata = [
            "duration": duration,
            "outgoing": outgoing,
            "callState": callState.rawValue,
            "date": date.timeIntervalSince1970
        ]
        if let terminationReason {
            reference.metadata?["terminationReason"] = terminationReason
        }
        self.references.removeAll()
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: reference.primary) {
                self.references.append(instance)
            } else {
                self.references.append(reference)
            }
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
        self.trustedSource = true
    }
    
    func isInStorage() -> Bool {
        do {
            let realm = try  WRealm.safe()
            return realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.primary) != nil
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    struct SaveNotificationPayload {
        let message: String
        let messageId: String
        let username: String?
        let opponent: String
        let owner: String
        let date: Date
        let displayName: String
        let imageUrl: String?
        let conversationType: ClientSynchronizationManager.ConversationType
        let preview: PushNotificationPreview
    }

    struct SaveSideEffects {
        var shouldStoreStanza: Bool
        var notification: SaveNotificationPayload?
    }

    private func dispatch(sideEffects: SaveSideEffects?) {
        guard let notification = sideEffects?.notification else {
            return
        }
        NotifyManager.shared.update(
            withMessage: notification.message,
            messageId: notification.messageId,
            username: notification.username,
            opponent: notification.opponent,
            owner: notification.owner,
            date: notification.date,
            displayName: notification.displayName,
            imageUrl: notification.imageUrl,
            conversationType: notification.conversationType,
            preview: notification.preview
        )
    }

    @discardableResult
    internal func applyMessagePersistence(in realm: Realm, silentNotifications: Bool = false) -> SaveSideEffects? {
        if self.opponent.isEmpty {
            return nil
        }
        if CommonConfigManager.shared.config.auto_delete_messages_interval > 0 {
            if self.date < Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(CommonConfigManager.shared.config.auto_delete_messages_interval)) {
                return nil
            }
        }
        self.updatePrimary()

        if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.primary) {
            if self.trustedSource && !instance.trustedSource {
                if self.archivedId.isNotEmpty {
                    instance.archivedId = self.archivedId
                }
                instance.trustedSource = true
                instance.previousId = self.previousId
            }
            if shouldPersistArchiveQueryId,
               let newQueryIds = self.queryIds,
               newQueryIds.isNotEmpty {
                if let oldQueryIds = instance.queryIds,
                   oldQueryIds.isNotEmpty {
                    instance.queryIds = [oldQueryIds, newQueryIds].joined(separator: ",")
                } else {
                    instance.queryIds = newQueryIds
                }
            }
            ChatLocalHistoryLinkedIndex.upsert(instance, in: realm)
            return nil
        }

        var shouldNotify: Bool = false
        var displayNameForNotification: String?

        if let instance = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: self.opponent,
                owner: self.owner,
                conversationType: self.conversationType
            )
        ) {
            let previousReadBoundaryId = LastChatUnreadCounter.readBoundaryId(from: instance.lastMessage)
            if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int,
               instance.afterburnIntervalLastUpdate < self.date.timeIntervalSince1970 {
                instance.applyAutoDeleteTimer(Double(timer), updatedAt: self.date.timeIntervalSince1970, updatedBy: self.owner)
            }

            if instance.isFreshNotEmptyEncryptedChat {
                instance.isFreshNotEmptyEncryptedChat = false
            }

            displayNameForNotification = instance.rosterItem?.displayName

            if instance.lastMessage?.date ?? Date(timeIntervalSince1970: 1) > self.date {
                self.isRead = true
                if self.outgoing,
                    self.archivedId.isNotEmpty,
                    let timeInterval = TimeInterval(self.archivedId) {
                    if let delivered = instance.deliveredId,
                        let interval = TimeInterval(delivered),
                        interval > timeInterval {
                        self.state = .deliver
                    }
                    if let displayed = instance.displayedId,
                        let interval = TimeInterval(displayed),
                        interval > timeInterval {
                        self.state = .read
                    }
                }

                realm.add(self, update: .modified)

                if let rosterItem = realm.object(ofType: RosterStorageItem.self,
                                                 forPrimaryKey: [self.opponent, owner].prp()) {
                    instance.rosterItem = rosterItem
                }
            } else {
                shouldNotify = true

                if instance.isArchived && !instance.isMuted {
                    instance.isArchived = false
                }

                instance.messageDate = self.sentDate
                if !self.isDeleted {
                    instance.lastMessage = self
                } else {
                    realm.add(instance)
                }
                instance.lastMessageId = self.messageId
                clearSavedVisiblePosition(on: instance)

                if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int {
                    instance.applyAutoDeleteTimer(Double(timer), updatedAt: self.date.timeIntervalSince1970, updatedBy: self.owner)
                } else if self.afterburnInterval > -1 && instance.afterburnIntervalLastUpdate < self.date.timeIntervalSince1970 {
                    instance.applyAutoDeleteTimer(self.afterburnInterval, updatedAt: self.date.timeIntervalSince1970, updatedBy: self.owner)
                }

                if isInvite && !isRead {
                    if instance.rosterItem?.subscribtion != .both {
                        instance.rosterItem?.ask = .in
                    }
                }

                if self.outgoing {
                    LastChatUnreadCounter.clearAll(
                        to: instance,
                        boundaryId: previousReadBoundaryId ?? LastChatUnreadCounter.readBoundaryId(from: self),
                        realm: realm
                    )
                } else {
                    LastChatUnreadCounter.recordRuntimeUnread(for: self, in: instance)
                }
            }
        } else {
            let instance = LastChatsStorageItem()
            instance.jid = self.opponent
            instance.conversationType = self.conversationType
            instance.setPrimary(withOwner: owner)
            instance.messageDate = self.sentDate
            instance.lastMessage = self
            instance.isSynced = [.omemo, .omemo1, .axolotl].contains(self.conversationType)
            instance.lastMessageId = self.messageId

            if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int {
                instance.applyAutoDeleteTimer(Double(timer), updatedAt: self.date.timeIntervalSince1970, updatedBy: self.owner)
            } else {
                instance.applyAutoDeleteTimer(self.afterburnInterval, updatedAt: self.date.timeIntervalSince1970, updatedBy: self.owner)
            }

            if instance.isInvalidated {
                return nil
            }

            realm.add(instance, update: .modified)

            if let rosterItem = realm.object(ofType: RosterStorageItem.self,
                                             forPrimaryKey: [self.opponent, owner].prp()) {
                instance.rosterItem = rosterItem
            } else {
                let rosterItem = RosterStorageItem()
                rosterItem.owner = self.owner
                rosterItem.jid = self.opponent
                rosterItem.subscribtion = .undefined
                rosterItem.primary = RosterStorageItem.genPrimary(jid: self.opponent, owner: self.owner)

                if let group = realm.object(ofType: RosterGroupStorageItem.self,
                                            forPrimaryKey: [RosterGroupStorageItem.notInRosterGroupName, self.owner].prp()) {
                    if !group.contacts.contains(rosterItem) {
                        group.contacts.append(rosterItem)
                    }
                } else {
                    let group = RosterGroupStorageItem()
                    group.isSystemGroup = true
                    group.name = RosterGroupStorageItem.notInRosterGroupName
                    group.owner = owner
                    group.primary = RosterGroupStorageItem.genPrimary(name: RosterGroupStorageItem.notInRosterGroupName, owner: owner)
                    group.contacts.append(rosterItem)
                    realm.add(group, update: .modified)
                }

                rosterItem.associatedLastChat = instance
                realm.add(rosterItem, update: .modified)
                instance.rosterItem = rosterItem
            }

            displayNameForNotification = instance.rosterItem?.displayName
            shouldNotify = true

            if self.outgoing {
                LastChatUnreadCounter.clearAll(
                    to: instance,
                    boundaryId: LastChatUnreadCounter.readBoundaryId(from: self),
                    realm: realm
                )
            } else {
                LastChatUnreadCounter.recordRuntimeUnread(for: self, in: instance)
            }
        }

        if let storedMessage = realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: self.primary
        ) {
            ChatLocalHistoryLinkedIndex.upsert(storedMessage, in: realm)
        }

        let notification: SaveNotificationPayload?
        if !silentNotifications &&
            LocalNotificationAdmissionPolicy.allowsMessage(
                countsAsRuntimeUnread: self.countsAsRuntimeUnread,
                sentAt: self.date
            ) &&
            shouldNotify &&
            !self.isRead &&
            !self.outgoing &&
            self.archivedId.isNotEmpty &&
            self.displayAs != .system {
            let fallbackBody = self.displayedBody()
            let preview = LocalMessageNotificationPreviewFactory.make(
                originalStanzaXML: self.originalStanza?.xmlString,
                owner: self.owner,
                routeJid: self.opponent,
                conversationType: self.conversationType.rawValue,
                archivedId: self.archivedId,
                messageId: self.messageId,
                sentAt: self.date,
                fallbackBody: fallbackBody,
                senderJid: self.conversationType == .group
                    ? MessageStorageItem.groupchatMessageAuthorJid(self.references.toArray())
                    : self.opponent,
                senderNickname: self.conversationType == .group
                    ? self.groupchatAuthorNickname
                    : nil,
                senderUserId: self.conversationType == .group
                    ? self.groupchatAuthorId
                    : nil
            )
            notification = SaveNotificationPayload(
                message: preview.body,
                messageId: self.archivedId,
                username: self.groupchatAuthorNickname,
                opponent: self.opponent,
                owner: self.owner,
                date: self.date,
                displayName: displayNameForNotification ?? self.opponent,
                imageUrl: nil,
                conversationType: self.conversationType,
                preview: preview
            )
        } else {
            notification = nil
        }

        return SaveSideEffects(shouldStoreStanza: true, notification: notification)
    }

    private func clearSavedVisiblePosition(on chat: LastChatsStorageItem) {
        chat.lastVisibleMessagePrimary = nil
        chat.lastVisibleMessageArchivedId = nil
        chat.lastVisibleMessageId = nil
        chat.lastVisibleMessageDate = nil
    }

    private func normalizedIncomingTextBody(from messageContainer: XMPPMessage) -> String {
        let strippedBody = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(
                messageContainer.elements(forName: "reference"),
                groupchat: nil
            ) ?? ""

        guard conversationTypeByMessage(messageContainer) == .group else {
            return strippedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let authorName = resolvedGroupchatAuthorDisplayName(
            userElement: groupchatUserElement(from: messageContainer),
            references: references.toArray()
        ) else {
            return strippedBody
        }

        let prefix = "\(authorName):\n"
        guard strippedBody.hasPrefix(prefix) else {
            return strippedBody
        }

        return String(strippedBody.dropFirst(prefix.count))
    }

    public final func save(commitTransaction: Bool, silentNotifications: Bool = false) -> Bool {
        do {
            let realm = try  WRealm.safe()
            var sideEffects: SaveSideEffects?
            let shouldCommitHere = commitTransaction || !realm.isInWriteTransaction

            if shouldCommitHere {
                try realm.write {
                    sideEffects = self.applyMessagePersistence(in: realm, silentNotifications: silentNotifications)
                    if sideEffects?.shouldStoreStanza == true {
                        self.storeStanza(in: realm)
                    }
                }
                self.dispatch(sideEffects: sideEffects)
            } else {
                sideEffects = self.applyMessagePersistence(in: realm, silentNotifications: silentNotifications)
                if sideEffects?.shouldStoreStanza == true {
                    self.storeStanza(in: realm)
                }
            }

            return sideEffects?.shouldStoreStanza ?? false
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func createReferences() -> [DDXMLElement] {
        var out: [DDXMLElement] = []
        
        references.forEach {
            reference in
            let referenceElement = DDXMLElement(name: "reference",
                                                xmlns: "https://xabber.com/protocol/references")
            referenceElement.addAttribute(withName: "type", stringValue: reference.xmlType)
            referenceElement.addAttribute(withName: "begin", integerValue: reference.begin)
            referenceElement.addAttribute(withName: "end", integerValue: reference.end)
            switch reference.kind {
                case .media:
                    let fileSharing = DDXMLElement(name: "file-sharing",
                                                   xmlns: "https://xabber.com/protocol/files")
                    if let uri = reference.fileSharingURI {
                        let sources = DDXMLElement(name: "sources")
                        sources.addChild(DDXMLElement(name: "uri", stringValue: uri))
                        fileSharing.addChild(sources)
                    }
                    let file = DDXMLElement(name: "file")
                    reference.metadata?.forEach {
                        switch $0.key {
                            case "thumbnail-uri":
                                if let value = $0.value as? String {
                                    let thumb = DDXMLElement(name: "thumbnail", xmlns: "urn:xmpp:thumbs:1")
                                    thumb.addAttribute(withName: "width", integerValue: (reference.metadata?["thumbnail-width"] as? Int) ?? 24)
                                    thumb.addAttribute(withName: "height", integerValue: (reference.metadata?["thumbnail-height"] as? Int) ?? 24)
                                    thumb.addAttribute(withName: "media-type", stringValue: "image/jpeg")
                                    thumb.addAttribute(withName: "uri", stringValue: value)
                                    file.addChild(thumb)
                                }
                            case "media-type", "name", "height", "width", "size", "desc", "duration", "hash", "orientation", "video_duration":
                                if let value = $0.value as? String {
                                    file.addChild(DDXMLElement(name: $0.key, stringValue: value))
                                } else if let value = $0.value as? Int {
                                    file.addChild(DDXMLElement(name: $0.key, stringValue: "\(value)"))
                                }
                            default:
                                break
                        }
                    }
                    if let iv = reference.metadata?["iv"] as? String,
                       let encryptionKey = reference.metadata?["encryption-key"] as? String {
                        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: "urn:xmpp:esfs:0")
                        let keyElement = DDXMLElement(name: "key")
                        keyElement.stringValue = encryptionKey
                        let ivElement = DDXMLElement(name: "iv")
                        ivElement.stringValue = iv
                        encryptedElement.addChild(keyElement)
                        encryptedElement.addChild(ivElement)
                        file.addChild(encryptedElement)
                    }
                    
                    fileSharing.addChild(file)
                    referenceElement.addChild(fileSharing)
                case .geoloc:
                    let geoloc = DDXMLElement(
                        name: "geoloc",
                        xmlns: "http://jabber.org/protocol/geoloc"
                    )
                    func metadataString(for key: String) -> String? {
                        guard let value = reference.metadata?[key] else { return nil }
                        if let value = value as? String, value.isNotEmpty {
                            return value
                        }
                        if let value = value as? Int {
                            return "\(value)"
                        }
                        if let value = value as? Double, value.isFinite {
                            return "\(value)"
                        }
                        return nil
                    }
                    ["lat", "lon", "accuracy", "text", "timestamp", "uri"].forEach { key in
                        guard let value = metadataString(for: key) else { return }
                        geoloc.addChild(DDXMLElement(name: key, stringValue: value))
                    }
                    referenceElement.addChild(geoloc)
                case .contact:
                    func metadataString(for key: String) -> String? {
                        guard let value = reference.metadata?[key] else { return nil }
                        if let value = value as? String, value.isNotEmpty {
                            return value
                        }
                        if let value = value as? Int {
                            return "\(value)"
                        }
                        if let value = value as? Double, value.isFinite {
                            return "\(value)"
                        }
                        return nil
                    }
                    guard let contactJID = metadataString(for: "contact_jid")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          contactJID.isNotEmpty,
                          let contactJIDObject = XMPPJID(string: contactJID),
                          contactJIDObject.resource == nil,
                          contactJIDObject.bare == contactJID else {
                        return
                    }
                    let contact = DDXMLElement(
                        name: "contact",
                        xmlns: "https://xabber.com/protocol/contact-sharing"
                    )
                    contact.addAttribute(withName: "jid", stringValue: contactJID)
                    if let entityRaw = metadataString(for: "entity") {
                        guard let entity = MessageContactEntityKind(rawValue: entityRaw) else {
                            return
                        }
                        contact.addAttribute(withName: "entity", stringValue: entity.rawValue)
                    }
                    if let nickname = metadataString(for: "nickname") {
                        contact.addChild(DDXMLElement(name: "nickname", stringValue: nickname))
                    }
                    let name = DDXMLElement(name: "name")
                    if let given = metadataString(for: "given") {
                        name.addChild(DDXMLElement(name: "given", stringValue: given))
                    }
                    if let family = metadataString(for: "family") {
                        name.addChild(DDXMLElement(name: "family", stringValue: family))
                    }
                    if name.children?.isEmpty == false {
                        contact.addChild(name)
                    }
                    let avatarAttributes: [(metadataKey: String, xmlKey: String)] = [
                        ("avatar_id", "id"),
                        ("avatar_type", "type"),
                        ("avatar_bytes", "bytes"),
                        ("avatar_url", "url"),
                        ("avatar_width", "width"),
                        ("avatar_height", "height")
                    ]
                    let avatar = DDXMLElement(name: "avatar")
                    let info = DDXMLElement(name: "info", xmlns: "urn:xmpp:avatar:metadata")
                    var hasAvatarAttribute = false
                    avatarAttributes.forEach { metadataKey, xmlKey in
                        guard let value = metadataString(for: metadataKey) else { return }
                        info.addAttribute(withName: xmlKey, stringValue: value)
                        hasAvatarAttribute = true
                    }
                    if hasAvatarAttribute {
                        avatar.addChild(info)
                        contact.addChild(avatar)
                    }
                    referenceElement.addChild(contact)
                case .systemMessage:
                    let systemMessage = DDXMLElement(
                        name: "system-message",
                        xmlns: "https://xabber.com/protocol/system-message"
                    )
                    if let timer = reference.metadata?["ephemeral-timer"] as? Int {
                        let ephemeralElement = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
                        ephemeralElement.addAttribute(withName: "timer", doubleValue: Double(timer))
                        systemMessage.addChild(ephemeralElement)
                    }
                    referenceElement.addChild(systemMessage)
                case .voice:
                    let voiceMessage = DDXMLElement(name: "voice-message",
                                                    xmlns: "https://xabber.com/protocol/voice-messages")
                    let fileSharing = DDXMLElement(name: "file-sharing",
                                                   xmlns: "https://xabber.com/protocol/files")
                    
                    if let uri = reference.fileSharingURI {
                        let sources = DDXMLElement(name: "sources")
                        sources.addChild(DDXMLElement(name: "uri", stringValue: uri))
                        fileSharing.addChild(sources)
                    }
                    let file = DDXMLElement(name: "file")
                    
                    if let iv = reference.metadata?["iv"] as? String,
                       let encryptionKey = reference.metadata?["encryption-key"] as? String {
                        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: "urn:xmpp:esfs:0")
                        let keyElement = DDXMLElement(name: "key")
                        keyElement.stringValue = encryptionKey
                        let ivElement = DDXMLElement(name: "iv")
                        ivElement.stringValue = iv
                        encryptedElement.addChild(keyElement)
                        encryptedElement.addChild(ivElement)
                        file.addChild(encryptedElement)
                    }
                    
                    file.addChild(DDXMLElement(name: "media-type", stringValue: "audio/ogg"))
                    file.addChild(DDXMLElement(name: "name", stringValue: "Voice message"))
                    file.addChild(DDXMLElement(name: "desc", stringValue: "Voice message"))
                    file.addChild(DDXMLElement(name: "duration", stringValue: "\(reference.duration ?? 0)"))
                    
                    if let url = reference.localFileUrl,
                       let data = try? Data(contentsOf: url) {
                        file.addChild(DDXMLElement(name: "size", stringValue: "\(data.bytes.count)"))
                        let hashed = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                        let hash = DDXMLElement(name: "hash", stringValue: hashed)
                        hash.setXmlns("urn:xmpp:hashes:2")
                        hash.addAttribute(withName: "algo", stringValue: "sha-256")
                        file.addChild(hash)
                    }
                    
                    file.addChild(DDXMLElement(name: "meters", stringValue: (reference.meteringLevels ?? []).compactMap({String($0)}).joined(separator: " ")))
    //                reference.metadata?.forEach {
    //                    if ["uriEmbded"].contains($0.key) { return }
    //                    if let value = $0.value as? String {
    //                        file.addChild(DDXMLElement(name: $0.key, stringValue: value))
    //                    } else if let value = $0.value as? Int {
    //                        file.addChild(DDXMLElement(name: $0.key, stringValue: "\(value)"))
    //                    }
    //                }
                    
                    fileSharing.addChild(file)
                    voiceMessage.addChild(fileSharing)
                    referenceElement.addChild(voiceMessage)
                    
                case .forward:
                    break
                case .markup:
                    break
                case .mention:
                    if let uri = reference.metadata?["uri"] as? String ?? reference.url {
                        let memberId = GroupMessageMentionsCodec.memberID(from: reference)
                        let isGroupMention = memberId?.isNotEmpty ?? false

                        if isGroupMention {
                            let link = DDXMLElement(name: "link", xmlns: "https://xabber.com/protocol/markup")
                            link.stringValue = uri
                            referenceElement.addChild(link)
                        } else {
                            let mention = DDXMLElement(name: "mention", xmlns: "https://xabber.com/protocol/markup")
                            let node = reference.metadata?["node"] as? String
                            if let node, node.isNotEmpty {
                                mention.addAttribute(withName: "node", stringValue: node)
                            }
                            mention.stringValue = uri
                            referenceElement.addChild(mention)
                        }
                    }
                case .quote:
                    break
                case .groupchat:
                    break
                case .call:
                    break
                case .none:
                    break
            }
            out.append(referenceElement)
        }
        
        return out
    }

    func createMentionsElement() -> DDXMLElement? {
        let intent = groupMentionIntent ?? .members(
            GroupMessageMentionsCodec.memberIDs(from: references)
        )
        return GroupMessageMentionsCodec.encode(
            intent,
            capabilityGranted: groupMentionAllCapabilityGranted,
            senderRole: groupMentionSenderRole
        )
    }
    
    
    struct QuoteBodyItem {
        let body: NSAttributedString
        let isQuote: Bool
    }
    
    public final func createQuoteBody(_ attrs: [NSAttributedString.Key: Any]) -> [QuoteBodyItem] {
        let quoteRanges: [NSRange] = self.references
            .filter{ $0.kind == .quote }
            .compactMap { return $0.range }
            .sorted(by: { $0.lowerBound < $1.lowerBound })
        
        if quoteRanges.isEmpty {
            return []
        }
        
        let refBody = createRefBody(attrs)
        var ranges = quoteRanges
        if let first = quoteRanges.first?.lowerBound,
            first > 1 {
            ranges.append(NSRange(0..<first-1))
        }
        if let last = quoteRanges.last?.upperBound,
            last+1 < refBody.string.count {
            if refBody.string[String.Index(utf16Offset: last, in: refBody.string)] == "\n" {
                ranges.append(NSRange(last+1..<refBody.string.count))
            } else {
                ranges.append(NSRange(last..<refBody.string.count))
            }
        }
        
        if quoteRanges.count > 1 {
            quoteRanges.enumerated().forEach { (offset, element) in
                if offset >= quoteRanges.count - 1 { return }
                if quoteRanges[offset + 1].lowerBound != element.upperBound + 1,
                    element.upperBound+1 < quoteRanges[offset + 1].lowerBound-1 {
                    ranges.append(NSRange((element.upperBound+1)..<quoteRanges[offset + 1].lowerBound-1))
                }
            }
        }
        ranges = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        return ranges.compactMap { (range) -> QuoteBodyItem? in
            let bodyCopy = NSMutableAttributedString(attributedString: refBody)
            if range.lowerBound != 0 {
                bodyCopy.deleteCharacters(in: NSRange(0..<range.lowerBound))
            }
            if (range.upperBound+1) != bodyCopy.string.count {
                bodyCopy.deleteCharacters(in: NSRange((range.length)..<(bodyCopy.string.count)))
            }
            return QuoteBodyItem(body: bodyCopy, isQuote: quoteRanges.contains(range))
        }
    }
    
    public final func createRefBody(_ attrs: [NSAttributedString.Key: Any], searchedText: String? = nil, searchedTextColor: UIColor? = nil) -> NSAttributedString {
        if let placeholder = localReportPlaceholderText {
            let string = NSMutableAttributedString(string: placeholder)
            string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
            string.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: string.length))
            string.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body).italic(), range: NSRange(location: 0, length: string.length))
            return string
        }
        let mentionColor = AccountColorManager.shared.palette(for: owner).tint700
        let formattedReferences = Array(references).compactMap { reference -> ChatAttributedBodyReference? in
            guard !reference.isLocallyHiddenByReport,
                  reference.kind == .markup || reference.kind == .mention else {
                return nil
            }
            return ChatAttributedBodyReference(
                storageReference: reference,
                mentionColor: mentionColor
            )
        }
        return ChatAttributedBodyFormatter.format(
            body: body,
            references: formattedReferences,
            attributes: attrs,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor
        )
    }
    
    open func createLegacyBody() {
        var out: String = legacyBody//.xmlEscaping(reverse: false)
//        print(legacyBody)
        references.forEach {
            reference in
            
            reference.owner = self.owner
            reference.jid = self.opponent
            reference.messageId = self.primary
            
            let fallback: String?
            switch reference.kind {
            case .media:
                fallback = reference.fileSharingURI
            case .voice:
                guard let uri = reference.fileSharingURI else { return }
                fallback = "Voice message (duration \(TimeInterval(reference.metadata?["duration"] as? Double ?? 0).minuteFormatedString) sec)\n\(uri)"
            default:
                return
            }
            guard let fallback, fallback.isNotEmpty else { return }

            if out.isNotEmpty, !out.hasSuffix("\n") {
                out.append("\n")
            }
            reference.begin = out.xmlEscaping(reverse: false).unicodeScalars.count
            out += fallback
            reference.end = out.xmlEscaping(reverse: false).unicodeScalars.count
        }
//        out = [out, body].joined()
        references.forEach {
            reference in
            switch reference.kind {
            case .quote:
                out = body
                    .xmlEscaping(reverse: false)
                    .replacingOccurrences(of: "\n",
                                          with: "\n>".xmlEscaping(reverse: false),
                                          options: [],
                                          range: Range<String.Index>(NSRange(location: reference.begin,
                                                                             length: reference.end),
                                                                     in: body.xmlEscaping(reverse: false)))
            default: break
            }
        }
        legacyBody = out
    }
    
    
    public static func getGroupchatAuthorNickname(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return nonEmptyGroupAuthorValue(groupchatMetadata?["nickname"])
            ?? nonEmptyGroupAuthorValue(groupchatMetadata?["jid"])
    }
    
    public static func groupchatMessageAuthorJid(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return nonEmptyGroupAuthorValue(groupchatMetadata?["jid"])
    }
    
    public static func groupchatMessageAuthorId(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return nonEmptyGroupAuthorValue(groupchatMetadata?["id"])
    }
}

enum ChatLocalHistoryLinkedIndex {
    static func state(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) -> ChatLocalHistoryIndexStorageItem? {
        realm.object(
            ofType: ChatLocalHistoryIndexStorageItem.self,
            forPrimaryKey: ChatLocalHistoryIndexStorageItem.genPrimary(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            )
        )
    }

    static func upsert(_ message: MessageStorageItem, in realm: Realm) {
        precondition(realm.isInWriteTransaction, "History index updates must share the message write transaction")
        guard message.primary.isNotEmpty,
              message.owner.isNotEmpty,
              message.opponent.isNotEmpty else {
            return
        }

        if state(
            owner: message.owner,
            jid: message.opponent,
            conversationType: message.conversationType,
            in: realm
        ) == nil,
        scopedMessages(for: message, in: realm).first != nil {
            try? rebuildConversation(
                owner: message.owner,
                jid: message.opponent,
                conversationType: message.conversationType,
                in: realm
            )
            return
        }

        let state = ensureState(for: message, in: realm)
        if message.historyLinkedIndexVersion == ChatLocalHistoryIndexStorageItem.currentVersion {
            detach(message, state: state, in: realm)
        }
        guard !message.isDeleted else { return }

        guard let newestPrimary = state.newestMessagePrimary,
              let newest = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: newestPrimary) else {
            linkOnly(message, state: state)
            return
        }

        let messageOrder = MessageHistoryOrderKey(message: message)
        if !(messageOrder < MessageHistoryOrderKey(message: newest)) {
            newest.historyNextMessagePrimary = message.primary
            message.historyPreviousMessagePrimary = newest.primary
            message.historyNextMessagePrimary = nil
            message.historyLinkedIndexVersion = ChatLocalHistoryIndexStorageItem.currentVersion
            state.newestMessagePrimary = message.primary
            state.indexedVisibleCount += 1
            return
        }

        if let oldestPrimary = state.oldestMessagePrimary,
           let oldest = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: oldestPrimary),
           !(MessageHistoryOrderKey(message: oldest) < messageOrder) {
            oldest.historyPreviousMessagePrimary = message.primary
            message.historyPreviousMessagePrimary = nil
            message.historyNextMessagePrimary = oldest.primary
            message.historyLinkedIndexVersion = ChatLocalHistoryIndexStorageItem.currentVersion
            state.oldestMessagePrimary = message.primary
            state.indexedVisibleCount += 1
            return
        }

        let orderedCandidates = scopedMessages(for: message, in: realm).sorted {
            MessageHistoryOrderKey(message: $0) < MessageHistoryOrderKey(message: $1)
        }
        let insertionIndex = orderedCandidates.firstIndex {
            !(MessageHistoryOrderKey(message: $0) < messageOrder)
        } ?? orderedCandidates.endIndex
        let previous = insertionIndex > orderedCandidates.startIndex
            ? orderedCandidates[orderedCandidates.index(before: insertionIndex)]
            : nil
        let next = insertionIndex < orderedCandidates.endIndex
            ? orderedCandidates[insertionIndex]
            : nil

        message.historyPreviousMessagePrimary = previous?.primary
        message.historyNextMessagePrimary = next?.primary
        message.historyLinkedIndexVersion = ChatLocalHistoryIndexStorageItem.currentVersion
        previous?.historyNextMessagePrimary = message.primary
        next?.historyPreviousMessagePrimary = message.primary
        state.indexedVisibleCount += 1
    }

    static func rebuildConversation(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) throws {
        let all = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            owner,
            jid,
            conversationType.rawValue
        )
        let orderedVisible = all
            .filter("isDeleted == false")
            .sorted {
                MessageHistoryOrderKey(message: $0) < MessageHistoryOrderKey(message: $1)
            }
        let update = {
            for message in all {
                message.historyPreviousMessagePrimary = nil
                message.historyNextMessagePrimary = nil
                message.historyLinkedIndexVersion = 0
            }

            let state = ensureState(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
            for (index, message) in orderedVisible.enumerated() {
                message.historyPreviousMessagePrimary = index > 0 ? orderedVisible[index - 1].primary : nil
                message.historyNextMessagePrimary = index + 1 < orderedVisible.count ? orderedVisible[index + 1].primary : nil
                message.historyLinkedIndexVersion = ChatLocalHistoryIndexStorageItem.currentVersion
            }
            state.oldestMessagePrimary = orderedVisible.first?.primary
            state.newestMessagePrimary = orderedVisible.last?.primary
            state.indexedVisibleCount = orderedVisible.count
            state.version = ChatLocalHistoryIndexStorageItem.currentVersion
        }

        if realm.isInWriteTransaction {
            update()
        } else {
            try realm.write(update)
        }
    }

    private static func ensureState(
        for message: MessageStorageItem,
        in realm: Realm
    ) -> ChatLocalHistoryIndexStorageItem {
        ensureState(
            owner: message.owner,
            jid: message.opponent,
            conversationType: message.conversationType,
            in: realm
        )
    }

    private static func ensureState(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) -> ChatLocalHistoryIndexStorageItem {
        let primary = ChatLocalHistoryIndexStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        if let state = realm.object(ofType: ChatLocalHistoryIndexStorageItem.self, forPrimaryKey: primary) {
            state.version = ChatLocalHistoryIndexStorageItem.currentVersion
            return state
        }
        let state = ChatLocalHistoryIndexStorageItem()
        state.primary = primary
        state.owner = owner
        state.jid = jid
        state.conversationType_ = conversationType.rawValue
        state.version = ChatLocalHistoryIndexStorageItem.currentVersion
        realm.add(state, update: .modified)
        return state
    }

    private static func linkOnly(
        _ message: MessageStorageItem,
        state: ChatLocalHistoryIndexStorageItem
    ) {
        message.historyPreviousMessagePrimary = nil
        message.historyNextMessagePrimary = nil
        message.historyLinkedIndexVersion = ChatLocalHistoryIndexStorageItem.currentVersion
        state.oldestMessagePrimary = message.primary
        state.newestMessagePrimary = message.primary
        state.indexedVisibleCount = 1
    }

    private static func detach(
        _ message: MessageStorageItem,
        state: ChatLocalHistoryIndexStorageItem,
        in realm: Realm
    ) {
        let previous = message.historyPreviousMessagePrimary.flatMap {
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0)
        }
        let next = message.historyNextMessagePrimary.flatMap {
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0)
        }
        previous?.historyNextMessagePrimary = next?.primary
        next?.historyPreviousMessagePrimary = previous?.primary
        if state.oldestMessagePrimary == message.primary {
            state.oldestMessagePrimary = next?.primary
        }
        if state.newestMessagePrimary == message.primary {
            state.newestMessagePrimary = previous?.primary
        }
        state.indexedVisibleCount = max(0, state.indexedVisibleCount - 1)
        message.historyPreviousMessagePrimary = nil
        message.historyNextMessagePrimary = nil
        message.historyLinkedIndexVersion = 0
    }

    private static func scopedMessages(
        for message: MessageStorageItem,
        in realm: Realm
    ) -> Results<MessageStorageItem> {
        realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false AND primary != %@",
            message.owner,
            message.opponent,
            message.conversationType.rawValue,
            message.primary
        )
    }
}

extension UIFont {
    
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        let descriptor = self.fontDescriptor
            .withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits))
        return UIFont(descriptor: descriptor!, size: 0)
    }
    
    func boldItalic() -> UIFont {
        return withTraits(.traitBold, .traitItalic)
    }
    
    func bold() -> UIFont {
        return withTraits(.traitBold)
    }
    
    func italic() -> UIFont {
        return withTraits(.traitItalic)
    }
    
}
