import Foundation
import CocoaLumberjack
import Intents
import UserNotifications

struct LocalRichNotificationRequest {
    let identifier: String
    let preview: PushNotificationPreview
    let names: RichNotificationNameOverrides
    let categoryIdentifier: String
    let sound: UNNotificationSound?
    let includePlayableMedia: Bool

    init(
        identifier: String,
        preview: PushNotificationPreview,
        names: RichNotificationNameOverrides = RichNotificationNameOverrides(),
        categoryIdentifier: String,
        sound: UNNotificationSound?,
        includePlayableMedia: Bool = true
    ) {
        self.identifier = identifier
        self.preview = preview
        self.names = names
        self.categoryIdentifier = categoryIdentifier
        self.sound = sound
        self.includePlayableMedia = includePlayableMedia
    }
}

protocol LocalNotificationCenterScheduling: AnyObject {
    func deliveredNotifications() async -> [UNNotification]
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
}

final class SystemLocalNotificationCenter: LocalNotificationCenterScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func deliveredNotifications() async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

final class LocalRichNotificationContentRenderer {
    private let avatarData: (PushNotificationAvatarIdentity) -> Data?
    private let donateInteractions: Bool

    init(
        avatarData: @escaping (PushNotificationAvatarIdentity) -> Data? = {
            PushNotificationAvatarStore.shared.imageData(for: $0)
        },
        donateInteractions: Bool = true
    ) {
        self.avatarData = avatarData
        self.donateInteractions = donateInteractions
    }

    func render(
        plan: RichNotificationPresentationPlan,
        categoryIdentifier: String,
        sound: UNNotificationSound?,
        attachments: [UNNotificationAttachment]
    ) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = plan.threadIdentifier
        content.sound = sound
        content.attachments = attachments
        content.userInfo = plan.route.userInfo(
            timestamp: plan.route.timestamp ?? Date().timeIntervalSinceReferenceDate
        )

        guard plan.route.kind != .verificationRequest else {
            return content
        }

        let sender = INPerson(
            personHandle: INPersonHandle(value: plan.senderHandle, type: .unknown),
            nameComponents: nil,
            displayName: plan.senderDisplayName,
            image: INImage(imageData: senderImageData(for: plan)),
            contactIdentifier: nil,
            customIdentifier: nil
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: plan.body,
            speakableGroupName: plan.speakableGroupName.map {
                INSpeakableString(spokenPhrase: $0)
            },
            conversationIdentifier: plan.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming

        do {
            if donateInteractions {
                try await interaction.donate()
            }
            let updated = try content.updating(from: intent)
            guard let merged = updated.mutableCopy() as? UNMutableNotificationContent else {
                return content
            }
            mergeAuthoritativeFields(from: content, into: merged)
            return merged
        } catch {
            return content
        }
    }

    private func senderImageData(for plan: RichNotificationPresentationPlan) -> Data {
        var identities: [PushNotificationAvatarIdentity] = []
        if let identity = plan.senderAvatarIdentity {
            identities.append(identity)
        }
        if let senderJid = plan.route.senderJid ?? plan.route.inviterJid {
            let contactIdentity = PushNotificationAvatarIdentity(
                owner: plan.route.owner,
                contactJid: senderJid
            )
            if !identities.contains(contactIdentity) {
                identities.append(contactIdentity)
            }
        }
        for identity in identities {
            if let data = avatarData(identity) {
                return data
            }
        }
        return PushNotificationInitialsRenderer.imageData(
            displayName: plan.senderDisplayName,
            jid: plan.senderHandle
        )
    }

    private func mergeAuthoritativeFields(
        from source: UNMutableNotificationContent,
        into destination: UNMutableNotificationContent
    ) {
        destination.title = source.title
        destination.subtitle = source.subtitle
        destination.body = source.body
        destination.categoryIdentifier = source.categoryIdentifier
        destination.threadIdentifier = source.threadIdentifier
        destination.sound = source.sound
        destination.attachments = source.attachments
        var userInfo = destination.userInfo
        source.userInfo.forEach { userInfo[$0.key] = $0.value }
        destination.userInfo = userInfo
    }
}

final class LocalRichNotificationScheduler {
    static let shared = LocalRichNotificationScheduler()

    private let center: LocalNotificationCenterScheduling
    private let attachmentLoader: RichNotificationAttachmentLoader
    private let renderer: LocalRichNotificationContentRenderer
    private let lock = NSLock()
    private var inFlightIdentifiers: Set<String> = []

    init(
        center: LocalNotificationCenterScheduling = SystemLocalNotificationCenter(),
        attachmentLoader: RichNotificationAttachmentLoader = RichNotificationAttachmentLoader(),
        renderer: LocalRichNotificationContentRenderer = LocalRichNotificationContentRenderer()
    ) {
        self.center = center
        self.attachmentLoader = attachmentLoader
        self.renderer = renderer
    }

    func schedule(_ request: LocalRichNotificationRequest) {
        let identifier = request.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, reserve(identifier) else {
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.release(identifier) }
            await self.perform(request, identifier: identifier)
        }
    }

    private func perform(_ request: LocalRichNotificationRequest, identifier: String) async {
        let plan = RichNotificationPresentationPolicy.plan(
            for: request.preview,
            overrides: request.names
        )
        let candidates = RichNotificationAttachmentPolicy.candidates(
            for: plan.mediaItems,
            includePlayableMedia: request.includePlayableMedia
        )
        let attachmentLease = await attachmentLoader.attachmentLease(for: candidates)
        defer { attachmentLease.release() }
        let attachments = attachmentLease.attachments
        guard !Task.isCancelled else { return }

        let content = await renderer.render(
            plan: plan,
            categoryIdentifier: request.categoryIdentifier,
            sound: request.sound,
            attachments: attachments
        )
        guard !Task.isCancelled,
              !(await isAlreadyScheduled(identifier: identifier, route: plan.route)) else {
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(notificationRequest)
        } catch {
            DDLogDebug("LocalRichNotificationScheduler: unable to schedule local notification")
        }
    }

    private func isAlreadyScheduled(
        identifier: String,
        route: PushNotificationRoutePayload
    ) async -> Bool {
        let delivered = await center.deliveredNotifications().map(\.request)
        let pending = await center.pendingNotificationRequests()
        return (delivered + pending).contains { existing in
            if existing.identifier == identifier {
                return true
            }
            guard let stanzaId = route.stanzaId else {
                return false
            }
            return existing.content.userInfo[PushNotificationUserInfoKey.stanzaId] as? String == stanzaId
        }
    }

    private func reserve(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlightIdentifiers.insert(identifier).inserted
    }

    private func release(_ identifier: String) {
        lock.lock()
        inFlightIdentifiers.remove(identifier)
        lock.unlock()
    }
}
