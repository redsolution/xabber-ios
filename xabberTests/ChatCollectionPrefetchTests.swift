import XCTest
@testable import xabber

final class ChatCollectionPrefetchTests: XCTestCase {
    func testPrefetchGroupsSupportedResourcesByMessageAndReferenceIdentity() {
        let imageURL = URL(string: "https://cdn.example.com/shared.jpg")!
        let videoPreviewURL = URL(string: "https://cdn.example.com/video-preview.jpg")!
        let avatarURL = URL(string: "https://cdn.example.com/avatar.png")!
        let contactAvatarURL = URL(string: "https://cdn.example.com/contact-avatar.png")!
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                switch indexPath.section {
                case 0:
                    return self.item(
                        primary: "m1",
                        avatarURL: avatarURL,
                        images: [.init(primary: "img1", url: imageURL)],
                        videos: [.init(primary: "vid1", url: URL(string: "https://cdn.example.com/video.mov")!, previewURL: videoPreviewURL)],
                        locations: [.init(primary: "loc1", latitude: 51.5, longitude: -0.12, address: "London", geoURI: "geo:51.5,-0.12", snapshotURL: nil)],
                        contacts: [.init(primary: "contact1", owner: "owner@example.com", jid: "friend@example.com", avatarURL: contactAvatarURL)]
                    )
                case 1:
                    return self.item(
                        primary: "m2",
                        images: [.init(primary: "img2", url: imageURL)]
                    )
                default:
                    return nil
                }
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: false,
                        hasKnownArchiveGapAbove: false,
                        hasKnownArchiveGapBelow: false,
                        hasRemoteOlderPage: false,
                        hasRemoteNewerPage: false,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 1,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220)
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 0, section: 1)
        ])

        let resources = prefetcher.prefetchedResources()
        XCTAssertTrue(resources.contains(.image(identity: identity(.image, message: "m1", reference: "img1"), url: imageURL)))
        XCTAssertTrue(resources.contains(.image(identity: identity(.image, message: "m2", reference: "img2"), url: imageURL)))
        XCTAssertTrue(resources.contains(.videoPreview(identity: identity(.videoPreview, message: "m1", reference: "vid1"), url: videoPreviewURL)))
        XCTAssertTrue(resources.contains(.avatar(identity: identity(.avatar, message: "m1", reference: "m1"), url: avatarURL)))
        XCTAssertTrue(resources.contains(.avatar(identity: identity(.contactAvatar, message: "m1", reference: "contact1"), url: contactAvatarURL)))
        XCTAssertTrue(resources.contains(.locationSnapshot(
            identity: identity(.locationSnapshot, message: "m1", reference: "loc1"),
            location: ChatCollectionPrefetchLocation(latitude: 51.5, longitude: -0.12, address: "London", geoURI: "geo:51.5,-0.12"),
            size: ChatCollectionPrefetchSize(width: 220, height: 220)
        )))
        XCTAssertTrue(resources.contains(.pageWarmup(ChatCollectionPrefetchPageWarmup(
            direction: .older,
            conversationKey: key,
            boundary: oldest
        ))))
    }

    func testCancellationUsesStoredIdentitiesInsteadOfCurrentIndexPathItem() {
        let oldURL = URL(string: "https://cdn.example.com/old.jpg")!
        let newURL = URL(string: "https://cdn.example.com/new.jpg")!
        var currentItem = item(primary: "old-message", images: [.init(primary: "old-image", url: oldURL)])
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { _ in currentItem },
            contextProvider: { .empty(conversationKey: self.conversationKey()) },
            prefetcher: prefetcher
        )
        let indexPath = IndexPath(item: 0, section: 0)

        coordinator.prefetchItems(at: [indexPath])
        currentItem = item(primary: "new-message", images: [.init(primary: "new-image", url: newURL)])
        coordinator.cancelPrefetchingForItems(at: [indexPath])

        let cancelled = prefetcher.cancelledResources()
        XCTAssertTrue(cancelled.contains(.image(identity: identity(.image, message: "old-message", reference: "old-image"), url: oldURL)))
        XCTAssertFalse(cancelled.contains(.image(identity: identity(.image, message: "new-message", reference: "new-image"), url: newURL)))
    }

    func testStaleIndexPathsAfterDatasetShrinkDoNotPrefetchWrongContent() {
        let visibleURL = URL(string: "https://cdn.example.com/visible.jpg")!
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                indexPath.section == 0
                    ? self.item(primary: "visible", images: [.init(primary: "visible-image", url: visibleURL)])
                    : nil
            },
            contextProvider: { .empty(conversationKey: self.conversationKey()) },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [IndexPath(item: 0, section: 4)])

        XCTAssertTrue(prefetcher.prefetchedResources().isEmpty)
    }

    func testPageWarmupUsesOnlyCachedLocalBoundaryAvailability() {
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { indexPath in
                self.item(primary: "m\(indexPath.section)")
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: true,
                        hasKnownArchiveGapAbove: true,
                        hasKnownArchiveGapBelow: true,
                        hasRemoteOlderPage: true,
                        hasRemoteNewerPage: true,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 9,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
                    pageWarmupDistance: 1
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [
            IndexPath(item: 0, section: 0),
            IndexPath(item: 0, section: 9)
        ])

        let pageWarmups = prefetcher.prefetchedResources().compactMap { resource -> ChatCollectionPrefetchPageWarmup? in
            if case .pageWarmup(let warmup) = resource {
                return warmup
            }
            return nil
        }
        XCTAssertEqual(Set(pageWarmups.map(\.direction)), [.older, .newer])
        XCTAssertTrue(pageWarmups.allSatisfy { $0.conversationKey == key })
        XCTAssertTrue(pageWarmups.contains(ChatCollectionPrefetchPageWarmup(direction: .older, conversationKey: key, boundary: oldest)))
        XCTAssertTrue(pageWarmups.contains(ChatCollectionPrefetchPageWarmup(direction: .newer, conversationKey: key, boundary: newest)))
    }

    func testShortResidentRangeCanWarmBothLocalBoundariesFromSameIndexPath() {
        let key = conversationKey()
        let oldest = boundary(primary: "oldest", archivedId: "1")
        let newest = boundary(primary: "newest", archivedId: "10")
        let prefetcher = FakeChatCollectionContentPrefetcher()
        let coordinator = ChatCollectionPrefetchCoordinator(
            itemProvider: { _ in
                self.item(primary: "only-visible-message")
            },
            contextProvider: {
                ChatCollectionPrefetchContext(
                    conversationKey: key,
                    availability: ChatScrollBoundaryAvailability(
                        hasLocalOlderPage: true,
                        hasLocalNewerPage: true,
                        hasKnownArchiveGapAbove: false,
                        hasKnownArchiveGapBelow: false,
                        hasRemoteOlderPage: false,
                        hasRemoteNewerPage: false,
                        isRemotePageInFlight: false
                    ),
                    oldestBoundary: oldest,
                    newestBoundary: newest,
                    firstRealSection: 0,
                    lastRealSection: 0,
                    locationSnapshotSize: ChatCollectionPrefetchSize(width: 220, height: 220),
                    pageWarmupDistance: 0
                )
            },
            prefetcher: prefetcher
        )

        coordinator.prefetchItems(at: [IndexPath(item: 0, section: 0)])

        let pageWarmups = prefetcher.prefetchedResources().compactMap { resource -> ChatCollectionPrefetchPageWarmup? in
            if case .pageWarmup(let warmup) = resource {
                return warmup
            }
            return nil
        }
        XCTAssertEqual(Set(pageWarmups), [
            ChatCollectionPrefetchPageWarmup(direction: .older, conversationKey: key, boundary: oldest),
            ChatCollectionPrefetchPageWarmup(direction: .newer, conversationKey: key, boundary: newest)
        ])
    }

    private func item(
        primary: String,
        owner: String = "owner@example.com",
        jid: String = "chat@example.com",
        avatarURL: URL? = nil,
        images: [ChatCollectionPrefetchImageReference] = [],
        videos: [ChatCollectionPrefetchVideoReference] = [],
        locations: [ChatCollectionPrefetchLocationReference] = [],
        contacts: [ChatCollectionPrefetchContactReference] = []
    ) -> ChatCollectionPrefetchItem {
        ChatCollectionPrefetchItem(
            messagePrimary: primary,
            owner: owner,
            jid: jid,
            avatarURL: avatarURL,
            images: images,
            videos: videos,
            locations: locations,
            contacts: contacts
        )
    }

    private func identity(
        _ kind: ChatCollectionPrefetchIdentity.Kind,
        message: String,
        reference: String
    ) -> ChatCollectionPrefetchIdentity {
        ChatCollectionPrefetchIdentity(
            kind: kind,
            messagePrimary: message,
            referencePrimary: reference
        )
    }

    private func conversationKey() -> ChatCollectionPrefetchConversationKey {
        ChatCollectionPrefetchConversationKey(
            owner: "owner@example.com",
            jid: "chat@example.com",
            conversationType: "regular"
        )
    }

    private func boundary(primary: String, archivedId: String) -> ChatCollectionPrefetchBoundary {
        ChatCollectionPrefetchBoundary(
            primary: primary,
            archivedId: archivedId,
            messageId: "message-\(primary)",
            timestamp: 100
        )
    }
}

private final class FakeChatCollectionContentPrefetcher: ChatCollectionContentPrefetching {
    private var prefetched: [Set<ChatCollectionPrefetchResource>] = []
    private var cancelled: [Set<ChatCollectionPrefetchResource>] = []

    func prefetch(_ resources: Set<ChatCollectionPrefetchResource>) {
        prefetched.append(resources)
    }

    func cancelPrefetching(_ resources: Set<ChatCollectionPrefetchResource>) {
        cancelled.append(resources)
    }

    func prefetchedResources() -> Set<ChatCollectionPrefetchResource> {
        prefetched.reduce(into: Set<ChatCollectionPrefetchResource>()) { partialResult, resources in
            partialResult.formUnion(resources)
        }
    }

    func cancelledResources() -> Set<ChatCollectionPrefetchResource> {
        cancelled.reduce(into: Set<ChatCollectionPrefetchResource>()) { partialResult, resources in
            partialResult.formUnion(resources)
        }
    }
}
