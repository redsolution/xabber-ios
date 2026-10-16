import ImageIO
import Intents
import UIKit
import UserNotifications
import XCTest
@testable import xabber

/// An opt-in network smoke test for the already configured physical iPad.
/// It does not send a message, schedule a notification, or alter avatar storage.
final class PushNotificationAvatarDeviceTests: XCTestCase {
    func testLiveAvatarDownloadWithOfflineXMPPAndMissingSnapshot() async throws {
        guard ProcessInfo.processInfo.environment["XABBER_PUSH_AVATAR_LIVE"] == "1" else {
            throw XCTSkip("Requires an explicitly prepared live iPad avatar check")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This smoke test validates a signed physical-device HTTP request")
        #else
        let environment = ProcessInfo.processInfo.environment
        XCTAssertTrue(PushExtensionDiagnostics.isOfflineHostRun(environment: environment))
        XCTAssertFalse(AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(
            isPushKit: false,
            environment: environment
        ))
        XCTAssertTrue(HostedXCTestIsolationPolicy.isEnabled(environment: environment),
                      "The hosted probe must isolate Realm and the keychain service")
        XCTAssertEqual(CredentialsManager.uniqueAccessGroup(), "group.xabber.ios",
                       "Hosted isolation must retain the real shared metadata container")

        let owner = try XCTUnwrap(environment["XABBER_PUSH_AVATAR_OWNER"])
        let sender = try XCTUnwrap(environment["XABBER_PUSH_AVATAR_SENDER"])
        let identity = PushNotificationAvatarIdentity(owner: owner, contactJid: sender)
        XCTAssertNil(PushNotificationAvatarStore.shared.imageData(for: identity),
                     "This probe requires the observed real cache miss; never remove a snapshot to force it")

        let metadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: sender)
        let avatarURL = try XCTUnwrap(metadata.avatarUrl)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(avatarURL.isEmpty)
        XCTAssertEqual(URL(string: avatarURL)?.scheme?.lowercased(), "https")
        let displayName = metadata.username ?? sender
        let route = PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: sender,
            conversationType: "regular",
            senderJid: sender
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        PushExtensionDiagnostics.log(
            "event=avatar_device_probe_begin owner=\(owner) sender=\(sender) snapshot=missing metadataURL=\(avatarURL) xmppAutoconnect=false"
        )

        let resolver = PushNotificationAvatarResolver.live(
            diagnostics: PushExtensionDiagnostics.sink
        )
        let imageData = await resolver.imageData(
            for: route,
            displayName: displayName,
            fallbackJid: sender
        )
        let initialsData = PushNotificationInitialsRenderer.imageData(
            displayName: displayName,
            jid: sender
        )
        XCTAssertNotEqual(imageData, initialsData,
                          "A real remote photo must replace the deterministic initials")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThanOrEqual(max(width, height), 256)
        let image = try XCTUnwrap(UIImage(data: imageData))
        let attachment = XCTAttachment(image: image)
        attachment.name = "physical-device-downloaded-notification-avatar"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Exercise the same INImage/content conversion without donating an
        // interaction or publishing a synthetic user-visible notification.
        let person = INPerson(
            personHandle: INPersonHandle(value: sender, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: INImage(imageData: imageData),
            contactIdentifier: nil,
            customIdentifier: nil
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: "Avatar device probe",
            speakableGroupName: nil,
            conversationIdentifier: "avatar-device-probe",
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Avatar device probe"
        let updatedContent = try content.updating(from: intent)
        XCTAssertEqual(updatedContent.body, content.body)

        XCTAssertNil(PushNotificationAvatarStore.shared.imageData(for: identity),
                     "The read-only fallback must leave the live shared snapshot unchanged")
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        PushExtensionDiagnostics.log(
            "event=avatar_device_probe_result bytes=\(imageData.count) width=\(width) height=\(height) initials=false intentContentUpdated=true sharedSnapshot=missing elapsedMs=\(elapsedMilliseconds)"
        )
        #endif
    }
}
