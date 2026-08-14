import Foundation
import KissXML
import Darwin

enum PushNotificationUserInfoKey {
    static let routeKind = "route_kind"
    static let owner = "owner"
    static let routeJid = "route_jid"
    static let legacyJid = "jid"
    static let contactJid = "contact_jid"
    static let conversationType = "conversation_type"
    static let timestamp = "timestamp"
    static let stanzaId = "stanzaId"
    static let messageId = "message_id"
    static let stanza = "stanza"
    static let senderJid = "sender_jid"
    static let senderNickname = "sender_nickname"
    static let senderUserId = "sender_user_id"
    static let senderAvatarURL = "sender_avatar_url"
    static let groupchat = "groupchat"
    static let inviteKind = "invite_kind"
    static let inviterJid = "inviter_jid"
    static let inviterNickname = "inviter_nickname"
    static let sid = "sid"
}

enum PushNotificationCategory {
    static let message = "com.xabber.ios.message"
    static let pushMessage = "com.xabber.ios.message.push"
    static let subscription = "com.xabber.ios.subscribtion"
    static let invite = "com.xabber.ios.invite"
    static let verification = "com.xabber.ios.verification"
}

struct PushNotificationRoutePayload: Equatable {
    enum Kind: String {
        case message
        case subscriptionRequest
        case verificationRequest
        case groupInvite
    }

    let kind: Kind
    let owner: String
    let routeJid: String?
    let conversationType: String?
    let timestamp: TimeInterval?
    let stanzaId: String?
    let messageId: String?
    let stanza: String?
    let senderJid: String?
    let senderNickname: String?
    let senderUserId: String?
    let senderAvatarURL: String?
    let groupchat: String?
    let inviteKind: String?
    let inviterJid: String?
    let inviterNickname: String?
    let sid: String?

    init(
        kind: Kind,
        owner: String,
        routeJid: String?,
        conversationType: String? = nil,
        timestamp: TimeInterval? = nil,
        stanzaId: String? = nil,
        messageId: String? = nil,
        stanza: String? = nil,
        senderJid: String? = nil,
        senderNickname: String? = nil,
        senderUserId: String? = nil,
        senderAvatarURL: String? = nil,
        groupchat: String? = nil,
        inviteKind: String? = nil,
        inviterJid: String? = nil,
        inviterNickname: String? = nil,
        sid: String? = nil
    ) {
        self.kind = kind
        self.owner = owner
        self.routeJid = routeJid
        self.conversationType = conversationType
        self.timestamp = timestamp
        self.stanzaId = stanzaId
        self.messageId = messageId
        self.stanza = stanza
        self.senderJid = senderJid
        self.senderNickname = senderNickname
        self.senderUserId = senderUserId
        self.senderAvatarURL = senderAvatarURL
        self.groupchat = groupchat
        self.inviteKind = inviteKind
        self.inviterJid = inviterJid
        self.inviterNickname = inviterNickname
        self.sid = sid
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let owner = userInfo[PushNotificationUserInfoKey.owner] as? String,
              !owner.isEmpty else {
            return nil
        }

        let explicitKind = (userInfo[PushNotificationUserInfoKey.routeKind] as? String)
            .flatMap(Kind.init(rawValue:))
        let inferredKind: Kind?
        if let explicitKind {
            inferredKind = explicitKind
        } else if userInfo[PushNotificationUserInfoKey.sid] as? String != nil {
            inferredKind = .verificationRequest
        } else if userInfo[PushNotificationUserInfoKey.inviteKind] as? String != nil,
                  userInfo[PushNotificationUserInfoKey.groupchat] as? String != nil {
            inferredKind = .groupInvite
        } else if userInfo[PushNotificationUserInfoKey.contactJid] as? String != nil {
            inferredKind = .subscriptionRequest
        } else {
            inferredKind = .message
        }
        guard let kind = inferredKind else {
            return nil
        }

        let routeJid = PushNotificationRoutePayload.stringValue(
            userInfo[PushNotificationUserInfoKey.routeJid]
        )
        ?? PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.contactJid])
        ?? PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.groupchat])
        ?? PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.legacyJid])

        self.init(
            kind: kind,
            owner: owner,
            routeJid: routeJid,
            conversationType: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.conversationType]),
            timestamp: PushNotificationRoutePayload.timeIntervalValue(userInfo[PushNotificationUserInfoKey.timestamp]),
            stanzaId: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.stanzaId]),
            messageId: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.messageId]),
            stanza: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.stanza]),
            senderJid: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.senderJid]),
            senderNickname: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.senderNickname]),
            senderUserId: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.senderUserId]),
            senderAvatarURL: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.senderAvatarURL]),
            groupchat: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.groupchat]),
            inviteKind: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.inviteKind]),
            inviterJid: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.inviterJid]),
            inviterNickname: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.inviterNickname]),
            sid: PushNotificationRoutePayload.stringValue(userInfo[PushNotificationUserInfoKey.sid])
        )
    }

    static func message(
        owner: String,
        routeJid: String,
        conversationType: String,
        stanzaId: String?,
        messageId: String?,
        stanza: String?,
        senderJid: String?,
        senderNickname: String?,
        senderUserId: String? = nil,
        senderAvatarURL: String? = nil,
        groupchat: String?,
        timestamp: TimeInterval? = nil
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: routeJid,
            conversationType: conversationType,
            timestamp: timestamp,
            stanzaId: stanzaId,
            messageId: messageId,
            stanza: stanza,
            senderJid: senderJid,
            senderNickname: senderNickname,
            senderUserId: senderUserId,
            senderAvatarURL: senderAvatarURL,
            groupchat: groupchat
        )
    }

    static func subscriptionRequest(
        owner: String,
        contactJid: String,
        nickname: String? = nil
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .subscriptionRequest,
            owner: owner,
            routeJid: contactJid,
            conversationType: "regular",
            senderJid: contactJid,
            senderNickname: nickname
        )
    }

    static func verificationRequest(
        owner: String,
        senderJid: String?,
        sid: String?
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .verificationRequest,
            owner: owner,
            routeJid: nil,
            senderJid: senderJid,
            sid: sid
        )
    }

    static func groupInvite(
        owner: String,
        groupchat: String,
        inviteKind: String?,
        inviterJid: String?,
        inviterNickname: String?,
        inviterUserId: String? = nil,
        inviterAvatarURL: String? = nil
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .groupInvite,
            owner: owner,
            routeJid: groupchat,
            conversationType: "group",
            senderJid: inviterJid,
            senderNickname: inviterNickname,
            senderUserId: inviterUserId,
            senderAvatarURL: inviterAvatarURL,
            groupchat: groupchat,
            inviteKind: inviteKind,
            inviterJid: inviterJid,
            inviterNickname: inviterNickname
        )
    }

    func userInfo(timestamp: TimeInterval? = nil) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            PushNotificationUserInfoKey.routeKind: kind.rawValue,
            PushNotificationUserInfoKey.owner: owner
        ]
        if let routeJid {
            userInfo[PushNotificationUserInfoKey.routeJid] = routeJid
            userInfo[PushNotificationUserInfoKey.legacyJid] = routeJid
        }
        if let conversationType {
            userInfo[PushNotificationUserInfoKey.conversationType] = conversationType
        }
        if let timestamp = self.timestamp ?? timestamp {
            userInfo[PushNotificationUserInfoKey.timestamp] = timestamp
        }
        if let stanzaId {
            userInfo[PushNotificationUserInfoKey.stanzaId] = stanzaId
        }
        if let messageId {
            userInfo[PushNotificationUserInfoKey.messageId] = messageId
        }
        if let stanza {
            userInfo[PushNotificationUserInfoKey.stanza] = stanza
        }
        if let senderJid {
            userInfo[PushNotificationUserInfoKey.senderJid] = senderJid
        }
        if let senderNickname {
            userInfo[PushNotificationUserInfoKey.senderNickname] = senderNickname
        }
        if let senderUserId {
            userInfo[PushNotificationUserInfoKey.senderUserId] = senderUserId
        }
        if let senderAvatarURL {
            userInfo[PushNotificationUserInfoKey.senderAvatarURL] = senderAvatarURL
        }
        if let groupchat {
            userInfo[PushNotificationUserInfoKey.groupchat] = groupchat
        }
        if let inviteKind {
            userInfo[PushNotificationUserInfoKey.inviteKind] = inviteKind
        }
        if let inviterJid {
            userInfo[PushNotificationUserInfoKey.inviterJid] = inviterJid
        }
        if let inviterNickname {
            userInfo[PushNotificationUserInfoKey.inviterNickname] = inviterNickname
        }
        if let sid {
            userInfo[PushNotificationUserInfoKey.sid] = sid
        }
        if kind == .subscriptionRequest, let routeJid {
            userInfo[PushNotificationUserInfoKey.contactJid] = routeJid
        }
        return userInfo
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return TimeInterval(value)
        }
        return nil
    }
}

struct PushNotificationPreview: Equatable {
    let route: PushNotificationRoutePayload
    let body: String
    let groupName: String?
    let mediaItems: [PushNotificationMediaItem]

    var imageURLs: [String] {
        mediaItems
            .compactMap { item in
                switch item.kind {
                case .image, .sticker:
                    return item.thumbnailURL ?? item.url
                case .video:
                    return item.thumbnailURL
                case .file, .voice, .forward:
                    return nil
                }
            }
    }
}

struct PushNotificationMediaItem: Equatable {
    enum Kind {
        case image
        case video
        case sticker
        case file
        case voice
        case forward
    }

    let kind: Kind
    let filename: String?
    let mediaType: String?
    let size: Int64?
    let duration: Int?
    let url: String?
    let thumbnailURL: String?
}

enum PushNotificationMediaFormatter {
    static func fallbackText(for items: [PushNotificationMediaItem]) -> String? {
        guard !items.isEmpty else {
            return nil
        }

        let images = items.filter { $0.kind == .image }
        let videos = items.filter { $0.kind == .video }
        let forwards = items.filter { $0.kind == .forward }
        if items.count > 1 {
            if images.count == items.count {
                return PushNotificationLocalization.string(
                    "chat_message_attached_images",
                    fallback: "%@ attached images",
                    String(images.count)
                )
            }
            if videos.count == items.count {
                return PushNotificationLocalization.string(
                    "chat_messages_attached_videos",
                    fallback: "%@ attached videos",
                    String(videos.count)
                )
            }
            if forwards.count == items.count {
                return PushNotificationLocalization.string(
                    "chat_message_some_forwarded_messages",
                    fallback: "%@ forwarded messages",
                    String(forwards.count)
                )
            }
            return PushNotificationLocalization.string(
                "chat_message_attached_files",
                fallback: "%@ attached files",
                String(items.count)
            )
        }

        guard let item = items.first else {
            return nil
        }
        switch item.kind {
        case .voice:
            return PushNotificationLocalization.string(
                "chat_message_voice_duration",
                fallback: "Voice message, %@",
                formatDuration(item.duration ?? 0)
            )
        case .sticker:
            return PushNotificationLocalization.string(
                "chat_message_sticker",
                fallback: "Sticker"
            )
        case .video:
            if let duration = item.duration, duration > 0 {
                return PushNotificationLocalization.string(
                    "chat_message_video_count",
                    fallback: "Video, %@",
                    formatDuration(duration)
                )
            }
            return PushNotificationLocalization.string("chat_message_video", fallback: "Video")
        case .file:
            let filename = item.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeFilename = (filename?.isEmpty == false) ? filename! : "file"
            if let size = item.size, size > 0 {
                return "file: \(safeFilename), \(formatSize(size))"
            }
            return "file: \(safeFilename)"
        case .image:
            return PushNotificationLocalization.string("chat_message_image", fallback: "Image")
        case .forward:
            return PushNotificationLocalization.string(
                "chat_message_forwarded_message",
                fallback: "Forwarded message"
            )
        }
    }

    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        }
        if bytes < 1024 * 1024 {
            return "\(bytes / 1024)kB"
        }
        if bytes < 1024 * 1024 * 1024 {
            return "\(bytes / (1024 * 1024))MB"
        }
        return "\(bytes / (1024 * 1024 * 1024))GB"
    }

    static func formatDuration(_ duration: Int) -> String {
        let seconds = max(0, duration)
        return String(format: "%d:%02ds", seconds / 60, seconds % 60)
    }
}

/// Builds the immutable notification snapshot while the original stanza is
/// still available. Persistence identifiers win over values inferred from XML;
/// the parser remains the source of the user-visible body and media semantics.
enum LocalMessageNotificationPreviewFactory {
    static func make(
        originalStanzaXML: String?,
        owner: String,
        routeJid: String,
        conversationType: String,
        archivedId: String?,
        messageId: String?,
        sentAt: Date,
        fallbackBody: String,
        senderJid: String?,
        senderNickname: String?,
        senderUserId: String?
    ) -> PushNotificationPreview {
        let parsed = originalStanzaXML.flatMap {
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: $0,
                owner: owner
            )
        }
        let canonicalType = canonicalConversationType(
            conversationType,
            parsedType: parsed?.route.conversationType
        )
        let isGroup = canonicalType == "group"
        let route = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: trimmed(routeJid) ?? parsed?.route.routeJid ?? routeJid,
            conversationType: canonicalType,
            stanzaId: trimmed(archivedId) ?? parsed?.route.stanzaId,
            messageId: trimmed(messageId) ?? parsed?.route.messageId,
            stanza: originalStanzaXML ?? parsed?.route.stanza,
            senderJid: trimmed(senderJid) ?? parsed?.route.senderJid,
            senderNickname: trimmed(senderNickname) ?? parsed?.route.senderNickname,
            senderUserId: trimmed(senderUserId) ?? parsed?.route.senderUserId,
            senderAvatarURL: parsed?.route.senderAvatarURL,
            groupchat: isGroup
                ? (trimmed(routeJid) ?? parsed?.route.groupchat ?? parsed?.route.routeJid)
                : nil,
            timestamp: sentAt.timeIntervalSinceReferenceDate
        )
        let fallback = trimmed(fallbackBody) ?? PushNotificationLocalization.newMessage()
        return PushNotificationPreview(
            route: route,
            body: parsed?.body ?? fallback,
            groupName: parsed?.groupName,
            mediaItems: parsed?.mediaItems ?? []
        )
    }

    private static func canonicalConversationType(
        _ rawValue: String,
        parsedType: String?
    ) -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "group", "https://xabber.com/protocol/groups":
            return "group"
        case "channel", "https://xabber.com/protocol/channels":
            return "channel"
        case "saved", "urn:xabber:favorites:0":
            return "saved"
        case "notifications", "urn:xabber:xen:0":
            return "notifications"
        case "regular", "urn:xabber:chat":
            return "regular"
        case "omemo", "urn:xmpp:omemo:2":
            return "omemo"
        case "omemo1", "urn:xmpp:omemo:1":
            return "omemo1"
        case "axolotl", "eu.siacs.conversations.axolotl":
            return "axolotl"
        default:
            return parsedType == "group" ? "group" : "regular"
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum PushNotificationLocalization {
    static func string(
        _ key: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        string(
            key,
            fallback: fallback,
            bundle: .main,
            locale: .current,
            arguments: arguments
        )
    }

    static func newMessage(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        string(
            "plurals.new_chat_messages.item_0",
            fallback: "New message",
            bundle: bundle,
            locale: locale,
            arguments: [1]
        )
    }

    private static func string(
        _ key: String,
        fallback: String,
        bundle: Bundle,
        locale: Locale,
        arguments: [CVarArg]
    ) -> String {
        var format = bundle.localizedString(
            forKey: key,
            value: fallback,
            table: nil
        )
        guard !arguments.isEmpty else {
            return format
        }
        if arguments.allSatisfy({ $0 is String }) {
            format = format.replacingOccurrences(of: "%d", with: "%@")
        }
        return String(
            format: format,
            locale: locale,
            arguments: arguments
        )
    }
}

enum PushNotificationArchiveParser {
    private enum XMLNS {
        static let references = "https://xabber.com/protocol/references"
        static let files = "https://xabber.com/protocol/files"
        static let encryptedFileSharing = "urn:xmpp:esfs:0"
        static let voiceMessages = "https://xabber.com/protocol/voice-messages"
        static let groups = "https://xabber.com/protocol/groups"
        static let forward = "urn:xmpp:forward:0"
        static let delay = "urn:xmpp:delay"
        static let carbons = "urn:xmpp:carbons:2"
        static let trust = "urn:xmpp:trust:0"
        static let xen = "urn:xabber:xen:0"
        static let addresses = "http://jabber.org/protocol/address"
        static let markup = "https://xabber.com/protocol/markup"
        static let systemMessage = "https://xabber.com/protocol/system-message"
    }

    private struct MessageEnvelope {
        let message: DDXMLElement
        let timestamp: TimeInterval?
    }

    static func parseArchivedMessage(xmlString: String, owner: String) -> PushNotificationPreview? {
        guard let document = try? DDXMLDocument(xmlString: xmlString, options: 0),
              let root = document.rootElement() else {
            return nil
        }
        return parseArchivedMessage(root, owner: owner)
    }

    static func parseArchivedMessage(_ archiveMessage: DDXMLElement, owner: String) -> PushNotificationPreview? {
        guard let envelope = messageEnvelope(in: archiveMessage) else {
            return nil
        }
        let message = envelope.message
        if let verification = verificationRequestMessage(from: message) {
            return parseVerificationRequest(verification, owner: owner)
        }
        if let invite = parseInvite(message, owner: owner) {
            return invite
        }
        return parseVisibleMessage(
            message,
            archiveMessage: archiveMessage,
            owner: owner,
            timestamp: envelope.timestamp
        )
    }

    private static func messageEnvelope(in archiveMessage: DDXMLElement) -> MessageEnvelope? {
        var message = archiveMessage
        var timestamp: TimeInterval?

        if let result = archiveMessage.firstChild(named: "result"),
           let forwarded = forwardedElement(in: result) {
            guard let innerMessage = forwarded.firstChild(named: "message") else {
                return nil
            }
            message = innerMessage
            timestamp = forwardedTimestamp(in: forwarded)
        }

        let carbonWrappers = message.children(named: "sent", xmlns: XMLNS.carbons)
            + message.children(named: "received", xmlns: XMLNS.carbons)
        guard carbonWrappers.count <= 1 else {
            return nil
        }
        if let carbon = carbonWrappers.first {
            guard let forwarded = forwardedElement(in: carbon),
                  let innerMessage = forwarded.firstChild(named: "message") else {
                return nil
            }
            message = innerMessage
            timestamp = forwardedTimestamp(in: forwarded) ?? timestamp
        }

        return MessageEnvelope(message: message, timestamp: timestamp)
    }

    private static func forwardedElement(in parent: DDXMLElement) -> DDXMLElement? {
        parent.firstChild(named: "forwarded", xmlns: XMLNS.forward)
            ?? parent.children(named: "forwarded").first(where: { trimmed($0.xmlns()) == nil })
    }

    private static func forwardedTimestamp(in forwarded: DDXMLElement) -> TimeInterval? {
        let delay = forwarded.firstChild(named: "delay", xmlns: XMLNS.delay)
            ?? forwarded.children(named: "delay").first(where: { trimmed($0.xmlns()) == nil })
        guard let stamp = trimmed(delay?.attributeString("stamp")),
              let date = xmppDate(from: stamp) else {
            return nil
        }
        return date.timeIntervalSinceReferenceDate
    }

    private static func xmppDate(from stamp: String) -> Date? {
        let internetFormatter = ISO8601DateFormatter()
        internetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internetFormatter.date(from: stamp) {
            return date
        }
        internetFormatter.formatOptions = [.withInternetDateTime]
        if let date = internetFormatter.date(from: stamp) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: stamp) {
                return date
            }
        }
        return nil
    }

    private static func parseVisibleMessage(
        _ message: DDXMLElement,
        archiveMessage: DDXMLElement,
        owner: String,
        timestamp: TimeInterval?
    ) -> PushNotificationPreview? {
        let fromBare = bareJid(message.attributeString("from") ?? "")
        let toBare = bareJid(message.attributeString("to") ?? "")
        let groupUser = groupchatUserElement(from: message)
        let groupReference = groupchatReferenceElement(from: message)
        let isGroupMessage = message.attributeString("type") == "chat" && groupUser != nil
        let routeJid = isGroupMessage ? fromBare : (fromBare == owner ? toBare : fromBare)
        guard !routeJid.isEmpty else {
            return nil
        }

        let references = message.children(named: "reference")
        let mediaItems = mediaItems(from: references)
        let rawBody = message.firstChild(named: "body")?.stringValue ?? ""
        let displayBody = displayBody(from: rawBody, references: references, groupchatReference: groupReference)
        let body = displayBody.isEmpty
            ? (PushNotificationMediaFormatter.fallbackText(for: mediaItems)
                ?? PushNotificationLocalization.newMessage())
            : displayBody

        let senderJid: String?
        let senderNickname: String?
        if isGroupMessage {
            senderJid = trimmed(groupUser?.firstChild(named: "jid")?.stringValue)
            senderNickname = trimmed(groupUser?.firstChild(named: "nickname")?.stringValue)
        } else {
            senderJid = fromBare.isEmpty ? nil : fromBare
            senderNickname = nil
        }

        let stanzaId = preferredStanzaId(in: message, owner: owner, routeJid: routeJid)
            ?? trimmed(archiveMessage.firstChild(named: "result")?.attributeString("id"))
        let senderUserId: String?
        let senderAvatarURL: String?
        if isGroupMessage {
            senderUserId = trimmed(groupUser?.attributeString("id"))
            let avatarInfo = groupUser?.firstChild(named: "avatar")?.firstChild(named: "info")
                ?? groupUser?.firstChild(named: "metadata", xmlns: "urn:xmpp:avatar:metadata")?
                    .firstChild(named: "info")
            senderAvatarURL = trimmed(avatarInfo?.attributeString("url"))
                .flatMap { PushNotificationMediaURLPolicy.remoteURLString($0) }
        } else {
            senderUserId = nil
            senderAvatarURL = nil
        }
        let route = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: routeJid,
            conversationType: isGroupMessage ? "group" : "regular",
            stanzaId: stanzaId,
            messageId: trimmed(message.attributeString("id")),
            stanza: archiveMessage.xmlString,
            senderJid: senderJid,
            senderNickname: senderNickname,
            senderUserId: senderUserId,
            senderAvatarURL: senderAvatarURL,
            groupchat: isGroupMessage ? routeJid : nil,
            timestamp: timestamp
        )
        return PushNotificationPreview(
            route: route,
            body: body,
            groupName: nil,
            mediaItems: mediaItems
        )
    }

    private static func parseInvite(_ message: DDXMLElement, owner: String) -> PushNotificationPreview? {
        guard ["chat", "headline"].contains(message.attributeString("type") ?? ""),
              let payload = canonicalGroupInvite(in: message) else {
            return nil
        }

        let groupElement = payload.group
        let inviterUser = payload.inviter
        let inviteKind: String
        if groupElement?.attributeString("parent") != nil {
            inviteKind = "peer-to-peer"
        } else if payload.privacy == "incognito" {
            inviteKind = "incognito"
        } else {
            inviteKind = "group"
        }

        let info = groupElement.flatMap { uniqueCanonicalChild(named: "info", in: $0) }
        let groupName = info.flatMap { uniqueCanonicalChild(named: "name", in: $0) }.flatMap {
            trimmed($0.stringValue)
        }
        let inviterNickname = inviterUser
            .flatMap { uniqueCanonicalChild(named: "nickname", in: $0) }
            .flatMap { trimmed($0.stringValue) }
        let inviterUserId = trimmed(inviterUser?.attributeString("id"))
        let explicitInviterJid = inviterUser
            .flatMap { uniqueCanonicalChild(named: "jid", in: $0) }
            .flatMap { canonicalBareJID($0.stringValue) }
        let inviterJid: String?
        if inviteKind == "incognito" {
            inviterJid = nil
        } else {
            inviterJid = explicitInviterJid
        }
        let inviterAvatarInfo = inviterUser
            .flatMap { uniqueCanonicalChild(named: "avatar", in: $0) }
            .flatMap { avatarMetadataInfo(in: $0) }
        let inviterAvatarURL = trimmed(inviterAvatarInfo?.attributeString("url"))
            .flatMap { PushNotificationMediaURLPolicy.remoteURLString($0) }
        let route = PushNotificationRoutePayload.groupInvite(
            owner: owner,
            groupchat: payload.groupJID,
            inviteKind: inviteKind,
            inviterJid: inviterJid,
            inviterNickname: inviterNickname,
            inviterUserId: inviterUserId,
            inviterAvatarURL: inviterAvatarURL
        )
        let body: String
        switch inviteKind {
        case "incognito":
            body = PushNotificationLocalization.string(
                "chat_message_incognito_invitation",
                fallback: "Invitation to incognito group"
            )
        case "peer-to-peer":
            body = PushNotificationLocalization.string(
                "chat_message_private_invitation",
                fallback: "Invitation to private chat"
            )
        default:
            body = PushNotificationLocalization.string(
                "chat_message_public_invitation",
                fallback: "Invitation to public group"
            )
        }
        return PushNotificationPreview(route: route, body: body, groupName: groupName, mediaItems: [])
    }

    private struct CanonicalGroupInvitePayload {
        let groupJID: String
        let privacy: String?
        let inviter: DDXMLElement?
        let group: DDXMLElement?
    }

    /// PushNotificationRouting is shared with the notification-service target,
    /// which deliberately does not link XMPPFramework. Keep this small decoder
    /// strict and wire-equivalent to GroupProtocolCodec instead of retaining a
    /// permissive legacy invite parser in the extension.
    private static func canonicalGroupInvite(
        in message: DDXMLElement
    ) -> CanonicalGroupInvitePayload? {
        let inviteElements = directChildren(of: message).filter {
            $0.name == "invite" && effectiveNamespace(of: $0) == XMLNS.groups
        }
        let groupElements = directChildren(of: message).filter {
            $0.name == "group" && effectiveNamespace(of: $0) == XMLNS.groups
        }
        guard inviteElements.count == 1,
              groupElements.count <= 1,
              let invite = inviteElements.first,
              let groupJID = canonicalBareJID(invite.attributeString("jid")) else {
            return nil
        }

        let inviteChildren = directChildren(of: invite)
        guard canonicalChildren(
            inviteChildren,
            allowedNames: ["reason", "user"],
            uniqueNames: ["reason", "user"]
        ) else {
            return nil
        }
        let inviter = uniqueCanonicalChild(named: "user", in: invite)
        guard inviter.map(isCanonicalGroupMember) ?? true else {
            return nil
        }

        let group = groupElements.first
        guard group.map(isCanonicalGroupPreview) ?? true else {
            return nil
        }
        return CanonicalGroupInvitePayload(
            groupJID: groupJID,
            privacy: group?.attributeString("privacy"),
            inviter: inviter,
            group: group
        )
    }

    private static func isCanonicalGroupPreview(_ group: DDXMLElement) -> Bool {
        if let privacy = group.attributeString("privacy"),
           !["public", "incognito"].contains(privacy) {
            return false
        }
        if let jid = group.attributeString("jid"), canonicalBareJID(jid) == nil {
            return false
        }
        if let parent = group.attributeString("parent"), canonicalBareJID(parent) == nil {
            return false
        }
        if let members = group.attributeString("members"),
           Int(members).map({ $0 >= 0 }) != true {
            return false
        }

        let children = directChildren(of: group)
        guard canonicalChildren(
            children,
            allowedNames: ["localpart", "info", "settings", "pinned", "present"],
            uniqueNames: ["localpart", "info", "settings", "pinned", "present"]
        ) else {
            return false
        }
        if let info = uniqueCanonicalChild(named: "info", in: group),
           !isCanonicalGroupInfo(info) {
            return false
        }
        if let settings = uniqueCanonicalChild(named: "settings", in: group),
           !isCanonicalGroupSettings(settings) {
            return false
        }
        if let pinned = uniqueCanonicalChild(named: "pinned", in: group),
           !isCanonicalPinnedList(pinned) {
            return false
        }
        if let present = uniqueCanonicalChild(named: "present", in: group),
           Int(trimmed(present.stringValue) ?? "").map({ $0 >= 0 }) != true {
            return false
        }
        return true
    }

    private static func isCanonicalGroupInfo(_ info: DDXMLElement) -> Bool {
        let children = directChildren(of: info)
        guard canonicalChildren(
            children,
            allowedNames: ["name", "description", "avatar", "status"],
            uniqueNames: ["name", "description", "avatar", "status"]
        ) else {
            return false
        }
        return uniqueCanonicalChild(named: "avatar", in: info)
            .map(isCanonicalAvatar) ?? true
    }

    private static func isCanonicalGroupSettings(_ settings: DDXMLElement) -> Bool {
        let children = directChildren(of: settings)
        guard canonicalChildren(
            children,
            allowedNames: ["membership", "contacts", "domains", "index", "state"],
            uniqueNames: ["membership", "contacts", "domains", "index", "state"]
        ) else {
            return false
        }
        if let membership = uniqueCanonicalChild(named: "membership", in: settings),
           !["open", "private"].contains(trimmed(membership.stringValue) ?? "") {
            return false
        }
        if let index = uniqueCanonicalChild(named: "index", in: settings),
           !["none", "local", "global"].contains(trimmed(index.stringValue) ?? "") {
            return false
        }
        if let state = uniqueCanonicalChild(named: "state", in: settings),
           !["active", "inactive"].contains(trimmed(state.stringValue) ?? "") {
            return false
        }
        if let contacts = uniqueCanonicalChild(named: "contacts", in: settings) {
            let values = directChildren(of: contacts)
            guard canonicalChildren(values, allowedNames: ["contact"], uniqueNames: []),
                  values.allSatisfy({ canonicalBareJID($0.stringValue) != nil }) else {
                return false
            }
        }
        if let domains = uniqueCanonicalChild(named: "domains", in: settings) {
            let values = directChildren(of: domains)
            guard canonicalChildren(values, allowedNames: ["domain"], uniqueNames: []),
                  values.allSatisfy({ canonicalDomain($0.stringValue) != nil }) else {
                return false
            }
        }
        return true
    }

    private static func isCanonicalPinnedList(_ pinned: DDXMLElement) -> Bool {
        let messages = directChildren(of: pinned)
        return canonicalChildren(messages, allowedNames: ["pinned-message"], uniqueNames: [])
            && messages.allSatisfy { child in
                directChildren(of: child).isEmpty && trimmed(child.attributeString("id")) != nil
            }
    }

    private static func isCanonicalGroupMember(_ user: DDXMLElement) -> Bool {
        let attributes = user.attributes ?? []
        guard attributes.count == 1,
              attributes.first?.name == "id",
              let memberID = user.attributeString("id"),
              trimmed(memberID) == memberID,
              !memberID.contains(where: { $0.isWhitespace }) else {
            return false
        }
        let children = directChildren(of: user)
        guard canonicalChildren(
            children,
            allowedNames: ["jid", "role", "nickname", "badge", "avatar", "last", "allow-p2p"],
            uniqueNames: ["jid", "role", "nickname", "badge", "avatar", "last", "allow-p2p"]
        ) else {
            return false
        }
        if let jid = uniqueCanonicalChild(named: "jid", in: user),
           canonicalBareJID(jid.stringValue) == nil {
            return false
        }
        if let role = uniqueCanonicalChild(named: "role", in: user),
           !["owner", "admin", "member", "none"].contains(trimmed(role.stringValue) ?? "") {
            return false
        }
        if let avatar = uniqueCanonicalChild(named: "avatar", in: user),
           !isCanonicalAvatar(avatar) {
            return false
        }
        if let last = uniqueCanonicalChild(named: "last", in: user),
           xmppDate(from: trimmed(last.stringValue) ?? "") == nil {
            return false
        }
        return true
    }

    private static func isCanonicalAvatar(_ avatar: DDXMLElement) -> Bool {
        let children = directChildren(of: avatar)
        guard children.count <= 1 else { return false }
        guard let info = children.first else { return true }
        guard info.name == "info",
              effectiveNamespace(of: info) == "urn:xmpp:avatar:metadata",
              directChildren(of: info).isEmpty,
              trimmed(info.attributeString("id")) != nil,
              trimmed(info.attributeString("type")) != nil,
              Int(info.attributeString("bytes") ?? "").map({ $0 >= 0 }) == true else {
            return false
        }
        for name in ["width", "height"] {
            if let raw = info.attributeString(name), Int(raw).map({ $0 >= 0 }) != true {
                return false
            }
        }
        return true
    }

    private static func avatarMetadataInfo(in avatar: DDXMLElement) -> DDXMLElement? {
        let children = directChildren(of: avatar).filter {
            $0.name == "info" && effectiveNamespace(of: $0) == "urn:xmpp:avatar:metadata"
        }
        return children.count == 1 ? children[0] : nil
    }

    private static func canonicalChildren(
        _ children: [DDXMLElement],
        allowedNames: Set<String>,
        uniqueNames: Set<String>
    ) -> Bool {
        guard children.allSatisfy({ child in
            guard let name = child.name else { return false }
            return allowedNames.contains(name) && effectiveNamespace(of: child) == XMLNS.groups
        }) else {
            return false
        }
        return uniqueNames.allSatisfy { name in
            children.filter { $0.name == name }.count <= 1
        }
    }

    private static func uniqueCanonicalChild(
        named name: String,
        in parent: DDXMLElement
    ) -> DDXMLElement? {
        let matches = directChildren(of: parent).filter {
            $0.name == name && effectiveNamespace(of: $0) == XMLNS.groups
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func canonicalBareJID(_ raw: String?) -> String? {
        guard let rawValue = trimmed(raw)?.lowercased(),
              !rawValue.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let value = rawValue.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rawValue
        let components = value.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              canonicalDomain(String(components[1])) != nil else {
            return nil
        }
        return value
    }

    private static func canonicalDomain(_ raw: String?) -> String? {
        guard let value = trimmed(raw)?.lowercased(),
              !value.contains("@"),
              !value.contains("/"),
              !value.contains(where: { $0.isWhitespace }),
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return nil
        }
        return value
    }

    private static func parseVerificationRequest(
        _ message: DDXMLElement,
        owner: String
    ) -> PushNotificationPreview? {
        guard let trust = message.firstChild(named: "trust", xmlns: XMLNS.trust),
              trust.firstChild(named: "request") != nil else {
            return nil
        }

        let sender = bareJid(message.attributeString("from") ?? "")
        let route = PushNotificationRoutePayload.verificationRequest(
            owner: owner,
            senderJid: sender.isEmpty ? nil : sender,
            sid: trimmed(trust.attributeString("sid"))
        )
        let displaySender = sender.isEmpty ? "Somebody" : sender
        return PushNotificationPreview(
            route: route,
            body: "\(displaySender) asks you to verify yourself",
            groupName: nil,
            mediaItems: []
        )
    }

    private static func verificationRequestMessage(from message: DDXMLElement) -> DDXMLElement? {
        if containsTrustRequest(message) {
            return message
        }

        guard let notification = message.firstChild(named: "notification", xmlns: XMLNS.xen),
              let forwarded = notification.firstChild(named: "forwarded", xmlns: XMLNS.forward)
                ?? notification.firstChild(named: "forwarded"),
              let innerMessage = forwarded.firstChild(named: "message"),
              containsTrustRequest(innerMessage) else {
            return nil
        }

        if let originalFrom = originalFromAddress(in: message),
           let forwardedFrom = innerMessage.attributeString("from"),
           !jidMatches(originalFrom, forwardedFrom) {
            return nil
        }

        return innerMessage
    }

    private static func containsTrustRequest(_ message: DDXMLElement) -> Bool {
        guard let trust = message.firstChild(named: "trust", xmlns: XMLNS.trust) else {
            return false
        }
        return trust.firstChild(named: "request") != nil
    }

    private static func originalFromAddress(in message: DDXMLElement) -> String? {
        message
            .firstChild(named: "addresses", xmlns: XMLNS.addresses)?
            .children(named: "address")
            .first(where: { $0.attributeString("type") == "ofrom" })?
            .attributeString("jid")
    }

    private static func jidMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || bareJid(lhs) == bareJid(rhs)
    }

    private static func preferredStanzaId(in message: DDXMLElement, owner: String, routeJid: String) -> String? {
        let stanzaIds = message.children(named: "stanza-id")
        return stanzaIds.first(where: { $0.attributeString("by") == owner })?.attributeString("id")
            ?? stanzaIds.first(where: { $0.attributeString("by") == routeJid })?.attributeString("id")
            ?? stanzaIds.first?.attributeString("id")
    }

    private static func groupchatReferenceElement(from message: DDXMLElement) -> DDXMLElement? {
        guard let groupDecoration = directChildren(of: message).first(where: {
            $0.name == "x" && effectiveNamespace(of: $0) == XMLNS.groups
        }) else {
            return nil
        }
        return directChildren(of: groupDecoration).first {
            $0.name == "reference" && effectiveNamespace(of: $0) == XMLNS.references
        }
    }

    private static func groupchatUserElement(from message: DDXMLElement) -> DDXMLElement? {
        let groupDecorations = directChildren(of: message).filter {
            $0.name == "x" && effectiveNamespace(of: $0) == XMLNS.groups
        }
        guard message.attributeString("type") == "chat",
              groupDecorations.count == 1,
              let groupDecoration = groupDecorations.first,
              (groupDecoration.attributes ?? []).isEmpty else {
            return nil
        }
        let children = directChildren(of: groupDecoration)
        guard children.count == 1,
              let user = children.first,
              user.name == "user",
              effectiveNamespace(of: user) == XMLNS.groups,
              isCanonicalGroupMember(user) else {
            return nil
        }
        return user
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

    private static func mediaItems(from references: [DDXMLElement]) -> [PushNotificationMediaItem] {
        references.compactMap { reference -> PushNotificationMediaItem? in
            guard reference.xmlns() == XMLNS.references else {
                return nil
            }
            switch referenceKind(reference) {
            case "voice":
                guard let voice = reference.firstChild(named: "voice-message", xmlns: XMLNS.voiceMessages),
                      let fileSharing = voice.firstChild(named: "file-sharing", xmlns: XMLNS.files) else {
                    return nil
                }
                return mediaItem(from: fileSharing, forcedKind: .voice)
            case "media":
                guard let fileSharing = reference.firstChild(named: "file-sharing", xmlns: XMLNS.files) else {
                    return nil
                }
                return mediaItem(from: fileSharing, forcedKind: nil)
            case "forward":
                return PushNotificationMediaItem(
                    kind: .forward,
                    filename: nil,
                    mediaType: nil,
                    size: nil,
                    duration: nil,
                    url: nil,
                    thumbnailURL: nil
                )
            default:
                return nil
            }
        }
    }

    private static func mediaItem(
        from fileSharing: DDXMLElement,
        forcedKind: PushNotificationMediaItem.Kind?
    ) -> PushNotificationMediaItem? {
        guard let file = fileSharing.firstChild(named: "file") else {
            return nil
        }
        let isEncrypted = file.firstChild(
            named: "encrypted",
            xmlns: XMLNS.encryptedFileSharing
        ) != nil
        let uri = isEncrypted
            ? nil
            : fileSharing.firstChild(named: "sources")?
                .children(named: "uri")
                .compactMap({ trimmed($0.stringValue) })
                .compactMap({ PushNotificationMediaURLPolicy.remoteURLString($0) })
                .first
        let mediaType = trimmed(file.firstChild(named: "media-type")?.stringValue)
        let filename = trimmed(file.firstChild(named: "name")?.stringValue)
            ?? uri.flatMap { URL(string: $0)?.lastPathComponent }
        let size = trimmed(file.firstChild(named: "size")?.stringValue).flatMap(Int64.init)
        let duration = trimmed(file.firstChild(named: "duration")?.stringValue).flatMap(Int.init)
        let thumbnailURL = trimmed(file.firstChild(named: "thumbnail")?.attributeString("uri"))
            .flatMap { PushNotificationMediaURLPolicy.previewURLString($0) }
        let kind: PushNotificationMediaItem.Kind
        if let forcedKind {
            kind = forcedKind
        } else if isSticker(filename: filename, mediaType: mediaType) {
            kind = .sticker
        } else if isVideo(mediaType) {
            kind = .video
        } else if isImage(mediaType) {
            kind = .image
        } else {
            kind = .file
        }
        return PushNotificationMediaItem(
            kind: kind,
            filename: filename,
            mediaType: mediaType,
            size: size,
            duration: duration,
            url: uri,
            thumbnailURL: thumbnailURL
        )
    }

    private static func isSticker(filename: String?, mediaType: String?) -> Bool {
        if filename?.caseInsensitiveCompare("Memoji") == .orderedSame {
            return true
        }
        return mediaType?.caseInsensitiveCompare("image/sticker") == .orderedSame
    }

    private static func isVideo(_ mediaType: String?) -> Bool {
        guard let mediaType = mediaType?.lowercased() else {
            return false
        }
        return mediaType == "video" || mediaType.hasPrefix("video/")
    }

    private static func isImage(_ mediaType: String?) -> Bool {
        guard let mediaType = mediaType?.lowercased() else {
            return false
        }
        return mediaType == "image" || mediaType.hasPrefix("image/")
    }

    private static func referenceKind(_ reference: DDXMLElement) -> String? {
        if reference.firstChild(named: "voice-message", xmlns: XMLNS.voiceMessages) != nil {
            return "voice"
        }
        if reference.firstChild(named: "system-message", xmlns: XMLNS.systemMessage) != nil {
            return "system-message"
        }
        if reference.firstChild(named: "file-sharing", xmlns: XMLNS.files) != nil {
            return "media"
        }
        if reference.attributeString("type") == "decoration" {
            if reference.firstChild(named: "quote", xmlns: XMLNS.markup) != nil {
                return "quote"
            }
            if reference.firstChild(named: "mention", xmlns: XMLNS.markup) != nil {
                return "mention"
            }
            if let uri = reference.firstChild(named: "link", xmlns: XMLNS.markup)?.stringValue,
               uri.hasPrefix("xmpp:") {
                return "mention"
            }
            return "markup"
        }
        if reference.firstChild(named: "forwarded", xmlns: XMLNS.forward) != nil {
            return "forward"
        }
        return nil
    }

    private static func displayBody(
        from body: String,
        references: [DDXMLElement],
        groupchatReference: DDXMLElement?
    ) -> String {
        guard !body.isEmpty else {
            return body
        }
        let escapedBody = xmlEscaped(body, reverse: false)
        var out = escapedBody
        var mutatedReferences = references
        if let groupchatReference {
            mutatedReferences.append(groupchatReference)
        }

        for reference in mutatedReferences.sorted(by: { $0.integerAttribute("begin") < $1.integerAttribute("begin") }) {
            guard reference.xmlns() == XMLNS.references else {
                continue
            }
            let kind = referenceKind(reference)
            let shouldRemoveAnonymousMutable = reference.attributeString("type") == "mutable" && kind == nil
            let offset = escapedBody.count - out.count
            var begin = reference.integerAttribute("begin") - offset
            var end = reference.integerAttribute("end") - offset
            if end > out.count {
                end = out.count
            }
            if begin < 0 {
                begin = 0
            }
            guard begin < end,
                  let range = Range<String.Index>(NSRange(begin..<end), in: out) else {
                continue
            }
            switch kind {
            case "media", "voice", "forward":
                out.removeSubrange(range)
            case "quote":
                out = out.replacingOccurrences(of: ">", with: "", options: [], range: range)
            default:
                if shouldRemoveAnonymousMutable {
                    out.removeSubrange(range)
                }
            }
        }
        return xmlEscaped(out, reverse: true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlEscaped(_ string: String, reverse: Bool) -> String {
        var out = string
        let symbols: [String: String] = [
            "<": "&lt;",
            ">": "&gt;",
            "\"": "&quot;",
            "'": "&apos;"
        ]
        out = out.replacingOccurrences(of: reverse ? "&amp;" : "&", with: reverse ? "&" : "&amp;")
        symbols.forEach {
            out = out.replacingOccurrences(of: reverse ? $0.value : $0.key, with: reverse ? $0.key : $0.value)
        }
        return out
    }

    private static func bareJid(_ jid: String) -> String {
        jid.split(separator: "/").first.map(String.init) ?? jid
    }

    private static func trimmed(_ string: String?) -> String? {
        let value = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum PushNotificationMediaURLPolicy {
    static func remoteURLString(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host,
              !host.isEmpty,
              isPublicHost(host),
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url.absoluteString
    }

    static func previewURLString(_ value: String) -> String? {
        if let remote = remoteURLString(value) {
            return remote
        }
        guard value.hasPrefix("data:image/"),
              value.utf8.count <= 1_500_000,
              value.range(of: ";base64,") != nil else {
            return nil
        }
        return value
    }

    private static func isPublicHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local") else {
            return false
        }

        if host.contains(":") {
            return isPublicIPv6Literal(host)
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let looksNumeric = host.allSatisfy { $0.isNumber || $0 == "." }
            || host.hasPrefix("0x")
        if looksNumeric {
            guard octets.count == 4,
                  let values = ipv4Octets(octets) else {
                return false
            }
            return isPublicIPv4(values)
        }
        return true
    }

    private static func ipv4Octets(_ components: [Substring]) -> [UInt8]? {
        var result: [UInt8] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  let value = UInt8(component) else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    private static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 {
            return false
        }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 198, (18...19).contains(second) { return false }
        return true
    }

    private static func isPublicIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        let parsed = host.withCString {
            inet_pton(AF_INET6, $0, &address)
        }
        guard parsed == 1 else {
            return false
        }

        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16,
              bytes.contains(where: { $0 != 0 }) else {
            return false
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return false
        }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }

        let isIPv4Mapped = bytes.prefix(10).allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        let isIPv4Compatible = bytes.prefix(12).allSatisfy({ $0 == 0 })
        if isIPv4Mapped || isIPv4Compatible {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        return true
    }
}

private extension DDXMLElement {
    func firstChild(named name: String, xmlns namespace: String? = nil) -> DDXMLElement? {
        children(named: name, xmlns: namespace).first
    }

    func children(named name: String, xmlns namespace: String? = nil) -> [DDXMLElement] {
        elements(forName: name).filter { element in
            guard let namespace else {
                return true
            }
            return element.xmlns() == namespace
        }
    }

    func attributeString(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    func integerAttribute(_ name: String) -> Int {
        Int(attributeString(name) ?? "") ?? 0
    }
}
