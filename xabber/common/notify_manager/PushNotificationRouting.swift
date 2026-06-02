import Foundation
import KissXML

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
        groupchat: String?
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: routeJid,
            conversationType: conversationType,
            timestamp: nil,
            stanzaId: stanzaId,
            messageId: messageId,
            stanza: stanza,
            senderJid: senderJid,
            senderNickname: senderNickname,
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
        inviterNickname: String?
    ) -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .groupInvite,
            owner: owner,
            routeJid: groupchat,
            conversationType: "group",
            senderJid: inviterJid,
            senderNickname: inviterNickname,
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
        if let timestamp = timestamp ?? self.timestamp {
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
            .filter { $0.kind == .image }
            .compactMap { $0.url }
    }
}

struct PushNotificationMediaItem: Equatable {
    enum Kind {
        case image
        case file
        case voice
    }

    let kind: Kind
    let filename: String?
    let mediaType: String?
    let size: Int64?
    let duration: Int?
    let url: String?
}

enum PushNotificationMediaFormatter {
    static func fallbackText(for items: [PushNotificationMediaItem]) -> String? {
        if let voice = items.first(where: { $0.kind == .voice }) {
            return "Voice message, \(formatDuration(voice.duration ?? 0))"
        }
        let files = items.filter { $0.kind == .file }
        if files.count == 1, let file = files.first {
            let filename = file.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeFilename = (filename?.isEmpty == false) ? filename! : "file"
            if let size = file.size, size > 0 {
                return "file: \(safeFilename), \(formatSize(size))"
            }
            return "file: \(safeFilename)"
        }
        let imagesCount = items.filter { $0.kind == .image }.count
        if imagesCount > 0, files.isEmpty {
            return imagesCount == 1 ? "Image" : "\(imagesCount) images"
        }
        if files.count + imagesCount > 1 {
            return "\(files.count + imagesCount) files"
        }
        return nil
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

enum PushNotificationArchiveParser {
    private enum XMLNS {
        static let references = "https://xabber.com/protocol/references"
        static let files = "https://xabber.com/protocol/files"
        static let voiceMessages = "https://xabber.com/protocol/voice-messages"
        static let groups = "https://xabber.com/protocol/groups"
        static let forward = "urn:xmpp:forward:0"
        static let trust = "urn:xmpp:trust:0"
        static let xen = "urn:xabber:xen:0"
        static let addresses = "http://jabber.org/protocol/address"
        static let markup = "https://xabber.com/protocol/markup"
        static let systemMessage = "https://xabber.com/protocol/system-message"
    }

    static func parseArchivedMessage(xmlString: String, owner: String) -> PushNotificationPreview? {
        guard let document = try? DDXMLDocument(xmlString: xmlString, options: 0),
              let root = document.rootElement() else {
            return nil
        }
        return parseArchivedMessage(root, owner: owner)
    }

    static func parseArchivedMessage(_ archiveMessage: DDXMLElement, owner: String) -> PushNotificationPreview? {
        let message = forwardedMessage(in: archiveMessage) ?? archiveMessage
        if let verification = verificationRequestMessage(from: message) {
            return parseVerificationRequest(verification, owner: owner)
        }
        if let invite = parseInvite(message, owner: owner) {
            return invite
        }
        return parseVisibleMessage(message, archiveMessage: archiveMessage, owner: owner)
    }

    private static func forwardedMessage(in archiveMessage: DDXMLElement) -> DDXMLElement? {
        let result = archiveMessage.firstChild(named: "result")
        return result?.firstChild(named: "forwarded", xmlns: XMLNS.forward)?.firstChild(named: "message")
            ?? result?.firstChild(named: "forwarded")?.firstChild(named: "message")
    }

    private static func parseVisibleMessage(
        _ message: DDXMLElement,
        archiveMessage: DDXMLElement,
        owner: String
    ) -> PushNotificationPreview? {
        let fromBare = bareJid(message.attributeString("from") ?? "")
        let toBare = bareJid(message.attributeString("to") ?? "")
        let groupUser = groupchatUserElement(from: message)
        let groupReference = groupchatReferenceElement(from: message)
        let isGroupMessage = message.attributeString("type") == "groupchat" || groupUser != nil
        let routeJid = isGroupMessage ? fromBare : (fromBare == owner ? toBare : fromBare)
        guard !routeJid.isEmpty else {
            return nil
        }

        let references = message.children(named: "reference")
        let mediaItems = mediaItems(from: references)
        let rawBody = message.firstChild(named: "body")?.stringValue ?? ""
        let displayBody = displayBody(from: rawBody, references: references, groupchatReference: groupReference)
        let body = displayBody.isEmpty
            ? (PushNotificationMediaFormatter.fallbackText(for: mediaItems) ?? "New message")
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
        let route = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: routeJid,
            conversationType: isGroupMessage ? "group" : "regular",
            stanzaId: stanzaId,
            messageId: trimmed(message.attributeString("id")),
            stanza: archiveMessage.xmlString,
            senderJid: senderJid,
            senderNickname: senderNickname,
            groupchat: isGroupMessage ? routeJid : nil
        )
        return PushNotificationPreview(
            route: route,
            body: body,
            groupName: nil,
            mediaItems: mediaItems
        )
    }

    private static func parseInvite(_ message: DDXMLElement, owner: String) -> PushNotificationPreview? {
        guard let payload = GroupchatInviteV3Parser.parse(message, owner: owner, date: Date(), archiveId: nil) else {
            return nil
        }

        let groupElement = message.firstChild(named: "group", xmlns: XMLNS.groups)
        let inviteKind: String
        if groupElement?.firstChild(named: "parent-chat") != nil {
            inviteKind = "peer-to-peer"
        } else if payload.isAnonymous {
            inviteKind = "incognito"
        } else {
            inviteKind = "group"
        }

        let groupName = trimmed(groupElement?.firstChild(named: "info")?.firstChild(named: "name")?.stringValue)
            ?? trimmed(groupElement?.firstChild(named: "name")?.stringValue)
        let route = PushNotificationRoutePayload.groupInvite(
            owner: owner,
            groupchat: payload.groupchat,
            inviteKind: inviteKind,
            inviterJid: payload.sender.isEmpty ? nil : payload.sender,
            inviterNickname: nil
        )
        let body: String
        switch inviteKind {
        case "incognito":
            body = "Invitation to incognito group"
        case "peer-to-peer":
            body = "Invitation to private chat"
        default:
            body = "Invitation to public group"
        }
        return PushNotificationPreview(route: route, body: body, groupName: groupName, mediaItems: [])
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
        message
            .firstChild(named: "x", xmlns: XMLNS.groups)?
            .firstChild(named: "reference", xmlns: XMLNS.references)
    }

    private static func groupchatUserElement(from message: DDXMLElement) -> DDXMLElement? {
        if let directUser = message
            .firstChild(named: "x", xmlns: XMLNS.groups)?
            .firstChild(named: "user", xmlns: XMLNS.groups)
            ?? message.firstChild(named: "x", xmlns: XMLNS.groups)?.firstChild(named: "user") {
            return directUser
        }

        return groupchatReferenceElement(from: message)?
            .firstChild(named: "user", xmlns: XMLNS.groups)
            ?? groupchatReferenceElement(from: message)?.firstChild(named: "user")
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
            default:
                return nil
            }
        }
    }

    private static func mediaItem(
        from fileSharing: DDXMLElement,
        forcedKind: PushNotificationMediaItem.Kind?
    ) -> PushNotificationMediaItem? {
        guard let file = fileSharing.firstChild(named: "file"),
              let uri = fileSharing.firstChild(named: "sources")?
                .children(named: "uri")
                .compactMap({ trimmed($0.stringValue) })
                .first(where: { URL(string: $0) != nil }) else {
            return nil
        }
        let mediaType = trimmed(file.firstChild(named: "media-type")?.stringValue)
        let filename = trimmed(file.firstChild(named: "name")?.stringValue)
            ?? URL(string: uri)?.lastPathComponent
        let size = trimmed(file.firstChild(named: "size")?.stringValue).flatMap(Int64.init)
        let duration = trimmed(file.firstChild(named: "duration")?.stringValue).flatMap(Int.init)
        let kind: PushNotificationMediaItem.Kind
        if let forcedKind {
            kind = forcedKind
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
            url: uri
        )
    }

    private static func isImage(_ mediaType: String?) -> Bool {
        guard let mediaType else {
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
        if reference.firstChild(named: "user") != nil {
            return "groupchat"
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
            case "media", "voice", "forward", "groupchat":
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
