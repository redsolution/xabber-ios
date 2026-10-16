import UIKit
import XCTest
@testable import xabber

final class PushNotificationAvatarResolverTests: XCTestCase {
    private typealias Identity = PushNotificationAvatarIdentity

    private let owner = "romeo@example.com"
    private let contact = "juliet@example.com"
    private let displayName = "Juliet Capulet"
    private let avatarURL = "https://cdn.example.com/juliet.png"

    func testCachedContactAvatarWinsWithoutMetadataLookupOrDownload() async {
        let image = makeImageData(color: .systemPurple)
        var cacheLookups: [Identity] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { identity in
                cacheLookups.append(identity)
                return image
            },
            savedURL: { _ in
                XCTFail("A cache hit must not look up a remote URL")
                return nil
            },
            download: { _ in
                XCTFail("A cache hit must not download an avatar")
                return nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, image)
        XCTAssertEqual(cacheLookups, [contactIdentity()])
    }

    func testCacheMissDownloadsSavedContactURLAndKeepsOwnerScope() async {
        let image = makeImageData(color: .systemGreen)
        var metadataLookups: [Identity] = []
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { identity in
                metadataLookups.append(identity)
                return self.avatarURL
            },
            download: { url in
                requestedURLs.append(url)
                return image
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, image)
        XCTAssertEqual(requestedURLs, [avatarURL])
        XCTAssertGreaterThanOrEqual(metadataLookups.count, 2, "The saved URL must be checked again after download")
        XCTAssertTrue(metadataLookups.allSatisfy { $0 == contactIdentity() })
    }

    func testMissingSavedURLUsesInitialsWithoutNetwork() async {
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in nil },
            download: { _ in
                XCTFail("No remote request is possible without a saved URL")
                return nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, initialsData())
    }

    func testFailedDownloadUsesInitials() async {
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in self.avatarURL },
            download: { url in
                requestedURLs.append(url)
                return nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, initialsData())
        XCTAssertEqual(requestedURLs, [avatarURL])
    }

    func testChangedSavedURLRejectsDownloadThatWasAlreadyInFlight() async {
        let state = SavedURLState(avatarURL)
        let started = expectation(description: "avatar request started")
        let download = SuspendedDownload(started: started)
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in state.read() },
            download: { _ in await download.run() }
        )
        let route = makeContactRoute()
        let task = Task {
            await resolver.imageData(for: route, displayName: self.displayName, fallbackJid: self.contact)
        }

        await fulfillment(of: [started], timeout: 2)
        state.set("https://cdn.example.com/juliet-new.png")
        download.finish(with: makeImageData(color: .systemRed))
        let result = await task.value

        XCTAssertEqual(result, initialsData())
    }

    func testRemovedContactMetadataRejectsDownloadThatWasAlreadyInFlight() async {
        let state = SavedURLState(avatarURL)
        let started = expectation(description: "avatar request started")
        let download = SuspendedDownload(started: started)
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in state.read() },
            download: { _ in await download.run() }
        )
        let route = makeContactRoute()
        let task = Task {
            await resolver.imageData(for: route, displayName: self.displayName, fallbackJid: self.contact)
        }

        await fulfillment(of: [started], timeout: 2)
        state.set(nil)
        download.finish(with: makeImageData(color: .systemBlue))
        let result = await task.value

        XCTAssertEqual(result, initialsData())
    }

    func testCancellationRejectsDownloadedAvatarEvenWhenTransportCompletes() async {
        let started = expectation(description: "avatar request started")
        let download = SuspendedDownload(started: started)
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in self.avatarURL },
            download: { _ in await download.run() }
        )
        let route = makeContactRoute()
        let task = Task {
            await resolver.imageData(for: route, displayName: self.displayName, fallbackJid: self.contact)
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        download.finish(with: makeImageData(color: .systemYellow))
        let result = await task.value

        XCTAssertEqual(result, initialsData())
    }

    func testGroupParticipantSnapshotWinsOverContactSnapshotAndSavedURL() async {
        let groupImage = makeImageData(color: .systemOrange)
        let groupIdentity = Identity(owner: owner, groupchat: "stage@conference.example.com", participantId: "member-juliet")
        var cacheLookups: [Identity] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { identity in
                cacheLookups.append(identity)
                return identity == groupIdentity ? groupImage : self.makeImageData(color: .systemBlue)
            },
            savedURL: { _ in
                XCTFail("The group snapshot must win over remote contact metadata")
                return nil
            },
            download: { _ in
                XCTFail("A group cache hit must not start a download")
                return nil
            }
        )

        let result = await resolver.imageData(for: makeGroupRoute(), displayName: displayName, fallbackJid: contact)

        XCTAssertEqual(result, groupImage)
        XCTAssertEqual(cacheLookups, [groupIdentity])
    }

    func testContactSnapshotWinsBeforeRemoteFallbackAfterGroupCacheMiss() async {
        let contactImage = makeImageData(color: .systemTeal)
        let groupIdentity = Identity(owner: owner, groupchat: "stage@conference.example.com", participantId: "member-juliet")
        var cacheLookups: [Identity] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { identity in
                cacheLookups.append(identity)
                return identity == self.contactIdentity() ? contactImage : nil
            },
            savedURL: { _ in
                XCTFail("All cached identities must be tried before remote metadata")
                return nil
            },
            download: { _ in
                XCTFail("A contact snapshot makes the remote fallback unnecessary")
                return nil
            }
        )

        let result = await resolver.imageData(for: makeGroupRoute(), displayName: displayName, fallbackJid: contact)

        XCTAssertEqual(result, contactImage)
        XCTAssertEqual(cacheLookups, [groupIdentity, contactIdentity()])
    }

    func testGroupCacheMissDownloadsOnlyTheSavedContactAvatar() async {
        let image = makeImageData(color: .systemPink)
        var metadataLookups: [Identity] = []
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { identity in
                metadataLookups.append(identity)
                return self.avatarURL
            },
            download: { url in
                requestedURLs.append(url)
                return image
            }
        )

        let result = await resolver.imageData(for: makeGroupRoute(), displayName: displayName, fallbackJid: contact)

        XCTAssertEqual(result, image)
        XCTAssertEqual(requestedURLs, [avatarURL])
        XCTAssertFalse(metadataLookups.isEmpty)
        XCTAssertTrue(metadataLookups.allSatisfy { $0 == contactIdentity() })
    }

    func testAnonymousGroupParticipantDoesNotUseGroupIdentityAsSavedContact() async {
        let route = PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: "group",
            senderNickname: "Juliet",
            senderUserId: "member-juliet",
            groupchat: "stage@conference.example.com"
        )
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in
                XCTFail("Opaque group participants have no saved contact URL")
                return nil
            },
            download: { _ in
                XCTFail("No contact URL is available for this participant")
                return nil
            }
        )

        let result = await resolver.imageData(for: route, displayName: displayName, fallbackJid: contact)

        XCTAssertEqual(result, initialsData())
    }

    func testUnsafeSavedURLsAreRejectedBeforeDownload() async {
        let unsafeURLs = [
            "http://cdn.example.com/juliet.png",
            "https://127.0.0.1/juliet.png",
            "https://localhost/juliet.png",
            "https://10.0.0.1/juliet.png",
            "https://user:password@cdn.example.com/juliet.png",
            "file:///tmp/juliet.png",
            "data:image/png;base64,aW1hZ2U="
        ]
        for url in unsafeURLs {
            let resolver = PushNotificationAvatarResolver(
                cachedData: { _ in nil },
                savedURL: { _ in url },
                download: { _ in
                    XCTFail("An unsafe saved URL must not reach the downloader: \(url)")
                    return nil
                }
            )

            let result = await resolve(resolver)

            XCTAssertEqual(result, initialsData(), url)
        }
    }

    func testAvatarFromAnotherOwnerIsNeverLookedUpOrReused() async {
        let foreignIdentity = Identity(owner: "other@example.com", contactJid: contact)
        let foreignImage = makeImageData(color: .systemBrown)
        var lookups: [Identity] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { identity in
                lookups.append(identity)
                return identity == foreignIdentity ? foreignImage : nil
            },
            savedURL: { identity in
                lookups.append(identity)
                return identity == foreignIdentity ? self.avatarURL : nil
            },
            download: { _ in
                XCTFail("A different owner's metadata must not start a request")
                return nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, initialsData())
        XCTAssertFalse(lookups.isEmpty)
        XCTAssertTrue(lookups.allSatisfy { $0 == contactIdentity() })
    }

    func testFailedPreferredURLFallsBackToSavedOriginalURL() async {
        let originalURL = "https://cdn.example.com/pep-original.png"
        let image = makeImageData(color: .systemIndigo)
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in self.avatarURL },
            fallbackURLs: { identity in
                XCTAssertEqual(identity, self.contactIdentity())
                return [originalURL]
            },
            download: { url in
                requestedURLs.append(url)
                return url == originalURL ? image : nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, image)
        XCTAssertEqual(requestedURLs, [avatarURL, originalURL])
    }

    func testChangedMetadataURLsRejectOriginalDownloadThatWasAlreadyInFlight() async {
        let originalURL = "https://cdn.example.com/pep-original.png"
        let preferred = SavedURLState(avatarURL)
        let original = SavedURLState(originalURL)
        let started = expectation(description: "original avatar request started")
        let suspended = SuspendedDownload(started: started)
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in preferred.read() },
            fallbackURLs: { _ in original.read().map { [$0] } ?? [] },
            download: { url in
                requestedURLs.append(url)
                guard url == originalURL else { return nil }
                return await suspended.run()
            }
        )
        let route = makeContactRoute()
        let task = Task {
            await resolver.imageData(for: route, displayName: self.displayName, fallbackJid: self.contact)
        }

        await fulfillment(of: [started], timeout: 2)
        preferred.set("https://cdn.example.com/new-preview.png")
        original.set("https://cdn.example.com/new-original.png")
        suspended.finish(with: makeImageData(color: .systemMint))
        let result = await task.value

        XCTAssertEqual(result, initialsData())
        XCTAssertEqual(requestedURLs, [avatarURL, originalURL])
    }

    func testRemoteFallbackMakesAtMostTwoDistinctSafeRequests() async {
        let originalURL = "https://cdn.example.com/pep-original.png"
        let thirdURL = "https://cdn.example.com/third-must-not-load.png"
        var requestedURLs: [String] = []
        let resolver = PushNotificationAvatarResolver(
            cachedData: { _ in nil },
            savedURL: { _ in self.avatarURL },
            fallbackURLs: { _ in [
                self.avatarURL,
                "http://cdn.example.com/unsafe.png",
                originalURL,
                originalURL,
                thirdURL
            ] },
            download: { url in
                requestedURLs.append(url)
                return url == thirdURL ? self.makeImageData(color: .systemRed) : nil
            }
        )

        let result = await resolve(resolver)

        XCTAssertEqual(result, initialsData())
        XCTAssertEqual(requestedURLs, [avatarURL, originalURL])
    }

    func testContactMetadataRoundTripsExplicitOriginalAvatarURL() throws {
        let metadata = CommonContactsMetadataManager()
        let uniqueOwner = try metadataTestOwner()
        defer { removeMetadataTestKey(owner: uniqueOwner) }
        let originalURL = "https://cdn.example.com/original.png"

        metadata.update(
            owner: uniqueOwner,
            jid: contact,
            username: displayName,
            avatarUrl: avatarURL,
            avatarOriginalUrl: originalURL
        )
        let stored = metadata.getItem(owner: uniqueOwner, jid: contact)

        XCTAssertEqual(stored.avatarUrl, avatarURL)
        XCTAssertEqual(stored.avatarOriginalUrl, originalURL)
        XCTAssertEqual(stored.username, displayName)
    }

    func testNameUpdateWithSamePreferredURLPreservesOriginalAvatarURL() throws {
        let metadata = CommonContactsMetadataManager()
        let uniqueOwner = try metadataTestOwner()
        defer { removeMetadataTestKey(owner: uniqueOwner) }
        let originalURL = "https://cdn.example.com/original.png"
        metadata.update(
            owner: uniqueOwner,
            jid: contact,
            username: displayName,
            avatarUrl: avatarURL,
            avatarOriginalUrl: originalURL
        )

        metadata.update(owner: uniqueOwner, jid: contact, username: "New contact name", avatarUrl: avatarURL)
        let stored = metadata.getItem(owner: uniqueOwner, jid: contact)

        XCTAssertEqual(stored.username, "New contact name")
        XCTAssertEqual(stored.avatarUrl, avatarURL)
        XCTAssertEqual(stored.avatarOriginalUrl, originalURL)
    }

    func testChangedPreferredURLWithoutOriginalClearsPreviousOriginalURL() throws {
        let metadata = CommonContactsMetadataManager()
        let uniqueOwner = try metadataTestOwner()
        defer { removeMetadataTestKey(owner: uniqueOwner) }
        metadata.update(
            owner: uniqueOwner,
            jid: contact,
            username: displayName,
            avatarUrl: avatarURL,
            avatarOriginalUrl: "https://cdn.example.com/original.png"
        )
        let newPreferred = "https://cdn.example.com/new-avatar.png"

        metadata.update(owner: uniqueOwner, jid: contact, username: nil, avatarUrl: newPreferred)
        let stored = metadata.getItem(owner: uniqueOwner, jid: contact)

        XCTAssertEqual(stored.avatarUrl, newPreferred)
        XCTAssertNil(stored.avatarOriginalUrl)
    }

    private func metadataTestOwner() throws -> String {
        _ = try XCTUnwrap(UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()))
        return "avatar-resolver-test-\(UUID().uuidString.lowercased())@example.com"
    }

    private func removeMetadataTestKey(owner: String) {
        let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup())
        defaults?.removeObject(forKey: ["contacts_metadata", owner, contact].prp())
        // Metadata replacement invalidates snapshots. Remove only this unique
        // test identity's markers, never a shared account's markers.
        PushNotificationAvatarStore.shared.clearDeletionMarkers(
            for: Identity(owner: owner, contactJid: contact)
        )
        PushNotificationAvatarStore.shared.removeAll(owner: owner)
    }

    private func resolve(_ resolver: PushNotificationAvatarResolver) async -> Data {
        await resolver.imageData(for: makeContactRoute(), displayName: displayName, fallbackJid: contact)
    }

    private func makeContactRoute() -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: contact,
            conversationType: "regular",
            senderJid: contact
        )
    }

    private func makeGroupRoute() -> PushNotificationRoutePayload {
        PushNotificationRoutePayload(
            kind: .message,
            owner: owner,
            routeJid: "stage@conference.example.com",
            conversationType: "group",
            senderJid: contact,
            senderNickname: displayName,
            senderUserId: "member-juliet",
            groupchat: "stage@conference.example.com"
        )
    }

    private func contactIdentity() -> Identity {
        Identity(owner: owner, contactJid: contact)
    }

    private func initialsData() -> Data {
        PushNotificationInitialsRenderer.imageData(displayName: displayName, jid: contact)
    }

    private func makeImageData(color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private final class SavedURLState {
        private let lock = NSLock()
        private var value: String?

        init(_ value: String?) { self.value = value }

        func read() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: String?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private final class SuspendedDownload {
        private let lock = NSLock()
        private let started: XCTestExpectation
        private var continuation: CheckedContinuation<Data?, Never>?
        private var finished = false
        private var result: Data?

        init(started: XCTestExpectation) { self.started = started }

        func run() async -> Data? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished {
                    let result = result
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
                started.fulfill()
            }
        }

        func finish(with result: Data?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}
