import Foundation

/// Pure admission rules shared by live local-notification producers.
/// Persistence and unread reconciliation still run when an event is rejected;
/// only the user-visible notification side effect is gated here.
enum LocalNotificationAdmissionPolicy {
    static let freshnessWindow: TimeInterval = 10

    static func allowsMessage(
        countsAsRuntimeUnread: Bool,
        sentAt: Date,
        now: Date = Date()
    ) -> Bool {
        countsAsRuntimeUnread && isFresh(sentAt, relativeTo: now)
    }

    static func allowsSubscribePresence(
        receivedAt: Date,
        now: Date = Date()
    ) -> Bool {
        isFresh(receivedAt, relativeTo: now)
    }

    private static func isFresh(_ eventDate: Date, relativeTo now: Date) -> Bool {
        abs(now.timeIntervalSince(eventDate)) <= freshnessWindow
    }
}

struct RichNotificationNameOverrides: Equatable {
    let conversationName: String?
    let senderName: String?
    let editMark: String

    init(
        conversationName: String? = nil,
        senderName: String? = nil,
        editMark: String = ""
    ) {
        self.conversationName = conversationName
        self.senderName = senderName
        self.editMark = editMark
    }
}

struct RichNotificationPresentationPlan: Equatable {
    let title: String
    let subtitle: String
    let body: String
    let threadIdentifier: String
    let categoryIdentifier: String
    let senderDisplayName: String
    let senderHandle: String
    let senderAvatarIdentity: PushNotificationAvatarIdentity?
    let speakableGroupName: String?
    let mediaItems: [PushNotificationMediaItem]
    let route: PushNotificationRoutePayload
}

/// Shared presentation rules for local and remote notifications. Callers may
/// pass live app names as overrides; the app-group metadata mirror is only a
/// fallback and values carried by the stanza are used last.
enum RichNotificationPresentationPolicy {
    typealias MetadataNameLookup = (_ owner: String, _ jid: String) -> String?

    static func plan(
        for preview: PushNotificationPreview,
        overrides: RichNotificationNameOverrides,
        metadataName: MetadataNameLookup = { owner, jid in
            CommonContactsMetadataManager.shared.getItem(owner: owner, jid: jid).username
        }
    ) -> RichNotificationPresentationPlan {
        switch preview.route.kind {
        case .message:
            return messagePlan(
                preview: preview,
                overrides: overrides,
                metadataName: metadataName
            )
        case .subscriptionRequest:
            return subscriptionPlan(
                preview: preview,
                overrides: overrides,
                metadataName: metadataName
            )
        case .groupInvite:
            return invitePlan(
                preview: preview,
                overrides: overrides,
                metadataName: metadataName
            )
        case .verificationRequest:
            return verificationPlan(
                preview: preview,
                overrides: overrides,
                metadataName: metadataName
            )
        }
    }

    private static func messagePlan(
        preview: PushNotificationPreview,
        overrides: RichNotificationNameOverrides,
        metadataName: MetadataNameLookup
    ) -> RichNotificationPresentationPlan {
        let route = preview.route
        let routeJid = nonempty(route.routeJid) ?? route.owner
        let isGroup = route.groupchat != nil || route.conversationType == "group"
        let conversationName = firstNonempty(
            overrides.conversationName,
            metadataName(route.owner, routeJid),
            preview.groupName,
            routeJid
        ) ?? routeJid
        let senderMetadataName = (route.senderJid ?? route.inviterJid)
            .flatMap { metadataName(route.owner, $0) }
        let senderName: String
        if isGroup {
            senderName = firstNonempty(
                overrides.senderName,
                senderMetadataName,
                route.senderNickname,
                route.senderJid,
                PushNotificationLocalization.string(
                    "group_member",
                    fallback: "Group member"
                )
            ) ?? "Group member"
        } else {
            senderName = firstNonempty(
                overrides.senderName,
                overrides.conversationName,
                metadataName(route.owner, routeJid),
                route.senderNickname,
                route.senderJid,
                routeJid
            ) ?? routeJid
        }
        let editMark = nonempty(overrides.editMark)
        let subtitle = [editMark, isGroup ? senderName : nil]
            .compactMap { $0 }
            .joined(separator: " ")
        let threadIdentifier = conversationIdentifier(
            owner: route.owner,
            component: routeJid
        )
        return RichNotificationPresentationPlan(
            title: isGroup ? conversationName : senderName,
            subtitle: subtitle,
            body: preview.body,
            threadIdentifier: threadIdentifier,
            categoryIdentifier: PushNotificationCategory.pushMessage,
            senderDisplayName: senderName,
            senderHandle: route.stableSenderHandle(fallback: routeJid),
            senderAvatarIdentity: route.senderAvatarIdentity,
            speakableGroupName: isGroup ? conversationName : nil,
            mediaItems: preview.mediaItems,
            route: route
        )
    }

    private static func subscriptionPlan(
        preview: PushNotificationPreview,
        overrides: RichNotificationNameOverrides,
        metadataName: MetadataNameLookup
    ) -> RichNotificationPresentationPlan {
        let route = preview.route
        let jid = nonempty(route.routeJid ?? route.senderJid) ?? "Someone"
        let displayName = firstNonempty(
            overrides.senderName,
            overrides.conversationName,
            metadataName(route.owner, jid),
            route.senderNickname,
            jid
        ) ?? jid
        let body = PushNotificationLocalization.string(
            "desktop_notifications_add_you_to_contact",
            fallback: "Contact %@ wants to add you to contact list",
            displayName
        )
        return RichNotificationPresentationPlan(
            title: displayName,
            subtitle: displayName == jid ? "" : jid,
            body: body,
            threadIdentifier: conversationIdentifier(
                owner: route.owner,
                component: "contact-requests"
            ),
            categoryIdentifier: PushNotificationCategory.subscription,
            senderDisplayName: displayName,
            senderHandle: route.stableSenderHandle(fallback: jid),
            senderAvatarIdentity: route.senderAvatarIdentity,
            speakableGroupName: nil,
            mediaItems: [],
            route: route
        )
    }

    private static func invitePlan(
        preview: PushNotificationPreview,
        overrides: RichNotificationNameOverrides,
        metadataName: MetadataNameLookup
    ) -> RichNotificationPresentationPlan {
        let route = preview.route
        let groupchat = nonempty(route.groupchat ?? route.routeJid) ?? route.owner
        let groupName = firstNonempty(
            overrides.conversationName,
            metadataName(route.owner, groupchat),
            preview.groupName,
            groupchat
        ) ?? groupchat
        let inviterJid = route.inviterJid ?? route.senderJid
        let inviterMetadataName = inviterJid.flatMap {
            metadataName(route.owner, $0)
        }
        let inviterName = firstNonempty(
            overrides.senderName,
            inviterMetadataName,
            route.inviterNickname,
            route.senderNickname,
            inviterJid
        )
        let body = invitationBody(kind: route.inviteKind, inviterName: inviterName)
        let senderName = inviterName ?? PushNotificationLocalization.string(
            "somebody",
            fallback: "Someone"
        )
        return RichNotificationPresentationPlan(
            title: groupName,
            subtitle: inviterName ?? "",
            body: body,
            threadIdentifier: conversationIdentifier(
                owner: route.owner,
                component: "group-invitations"
            ),
            categoryIdentifier: PushNotificationCategory.invite,
            senderDisplayName: senderName,
            senderHandle: route.stableSenderHandle(fallback: inviterJid ?? groupchat),
            senderAvatarIdentity: route.senderAvatarIdentity,
            speakableGroupName: groupName,
            mediaItems: [],
            route: route
        )
    }

    private static func verificationPlan(
        preview: PushNotificationPreview,
        overrides: RichNotificationNameOverrides,
        metadataName: MetadataNameLookup
    ) -> RichNotificationPresentationPlan {
        let route = preview.route
        let senderJid = nonempty(route.senderJid)
        let senderName = firstNonempty(
            overrides.senderName,
            overrides.conversationName,
            senderJid.flatMap { metadataName(route.owner, $0) },
            route.senderNickname,
            senderJid,
            PushNotificationLocalization.string("somebody", fallback: "Somebody")
        ) ?? "Somebody"
        return RichNotificationPresentationPlan(
            title: PushNotificationLocalization.string(
                "new_verification_request",
                fallback: "New verification request"
            ),
            subtitle: "",
            body: PushNotificationLocalization.string(
                "verification_request_description",
                fallback: "%@ asks you to verify yourself",
                senderName
            ),
            threadIdentifier: "",
            categoryIdentifier: PushNotificationCategory.verification,
            senderDisplayName: senderName,
            senderHandle: route.stableSenderHandle(fallback: senderJid ?? route.owner),
            senderAvatarIdentity: route.senderAvatarIdentity,
            speakableGroupName: nil,
            mediaItems: [],
            route: route
        )
    }

    private static func invitationBody(kind: String?, inviterName: String?) -> String {
        if let inviterName {
            switch kind {
            case "incognito":
                return PushNotificationLocalization.string(
                    "chat_incognito_chat_invitation",
                    fallback: "%@ invited you to join this incognito group",
                    inviterName
                )
            case "peer-to-peer":
                return PushNotificationLocalization.string(
                    "chat_private_chat_invitation",
                    fallback: "%@ invited you to join private chat",
                    inviterName
                )
            default:
                return PushNotificationLocalization.string(
                    "chat_group_invitation",
                    fallback: "%@ invited you to join this group",
                    inviterName
                )
            }
        }

        switch kind {
        case "incognito":
            return PushNotificationLocalization.string(
                "incognito_group_invitation",
                fallback: "You are invited to join this incognito group"
            )
        case "peer-to-peer":
            return PushNotificationLocalization.string(
                "private_chat_invitation",
                fallback: "You are invited to join private chat"
            )
        default:
            return PushNotificationLocalization.string(
                "public_group_invitation",
                fallback: "You are invited to join this public group"
            )
        }
    }

    private static func conversationIdentifier(owner: String, component: String) -> String {
        "xabber:\(owner.lowercased()):\(component.lowercased())"
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy.compactMap(nonempty).first
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct RichNotificationAttachmentCandidate: Equatable {
    enum Kind: Equatable {
        case image
        case video
        case audio
    }

    let kind: Kind
    let sourceURL: String
    let fallbackImageURL: String?
    let filename: String?
    let mediaType: String?

    init(
        kind: Kind,
        sourceURL: String,
        fallbackImageURL: String? = nil,
        filename: String? = nil,
        mediaType: String? = nil
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.fallbackImageURL = fallbackImageURL
        self.filename = filename
        self.mediaType = mediaType
    }
}

/// Selects only attachment kinds that UserNotifications can present. Generic
/// files and forwarded-message markers remain represented by localized text.
enum RichNotificationAttachmentPolicy {
    static func candidates(
        for items: [PushNotificationMediaItem],
        includePlayableMedia: Bool
    ) -> [RichNotificationAttachmentCandidate] {
        items.compactMap { item in
            switch item.kind {
            case .image, .sticker:
                guard let source = previewURL(item.thumbnailURL)
                    ?? previewURL(item.url) else {
                    return nil
                }
                return RichNotificationAttachmentCandidate(
                    kind: .image,
                    sourceURL: source,
                    fallbackImageURL: nil,
                    filename: item.filename,
                    mediaType: item.mediaType
                )
            case .video:
                let fallbackImage = previewURL(item.thumbnailURL)
                if includePlayableMedia,
                   let source = remoteURL(item.url) {
                    return RichNotificationAttachmentCandidate(
                        kind: .video,
                        sourceURL: source,
                        fallbackImageURL: fallbackImage,
                        filename: item.filename,
                        mediaType: item.mediaType
                    )
                }
                guard let fallbackImage else {
                    return nil
                }
                return RichNotificationAttachmentCandidate(
                    kind: .image,
                    sourceURL: fallbackImage,
                    fallbackImageURL: nil,
                    filename: item.filename,
                    mediaType: "image/*"
                )
            case .voice:
                guard includePlayableMedia,
                      let source = remoteURL(item.url) else {
                    return nil
                }
                return RichNotificationAttachmentCandidate(
                    kind: .audio,
                    sourceURL: source,
                    fallbackImageURL: nil,
                    filename: item.filename,
                    mediaType: item.mediaType
                )
            case .file, .forward:
                return nil
            }
        }
    }

    private static func remoteURL(_ value: String?) -> String? {
        value.flatMap(PushNotificationMediaURLPolicy.remoteURLString)
    }

    private static func previewURL(_ value: String?) -> String? {
        value.flatMap(PushNotificationMediaURLPolicy.previewURLString)
    }
}
