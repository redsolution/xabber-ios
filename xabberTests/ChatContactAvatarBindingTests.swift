import XCTest
import MaterialComponents.MDCPalettes
@testable import xabber

@MainActor
final class ChatContactAvatarBindingTests: XCTestCase {
    func testAvatarRequestUsesOneRemoteThumbnailIdentityForVisibleAndPrefetch() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png"))
        let request = avatarRequest(url: url)

        XCTAssertEqual(request.thumbnailRequest?.url, url)
        XCTAssertEqual(request.thumbnailRequest?.displaySize, request.displaySize)
        XCTAssertEqual(request.thumbnailRequest?.scale, request.scale)
        XCTAssertEqual(request.thumbnailRequest?.traitStyle, request.traitStyle)
        XCTAssertEqual(request.thumbnailRequest?.pixelSize, ChatCollectionPrefetchSize(width: 108, height: 108))
    }

    func testContactAvatarResolverNeverInvokesRealmLookupOnMainThread() {
        var lookupCount = 0
        let resolver = ChatContactAvatarURLResolver { _, _ in
            lookupCount += 1
            return "https://cdn.example.com/avatar.png"
        }

        let result = resolver.resolve(owner: "owner@example.com", jid: "alice@example.com")

        XCTAssertNil(result)
        XCTAssertEqual(lookupCount, 0)
    }

    func testContactVisibleAndPrefetchUseExactlyTheSameAvatarRequest() throws {
        let pipeline = G14FakeAvatarServing()
        let attachment = contact(url: "https://cdn.example.com/avatar.png")
        _ = InlineContactsGridView.ContactView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44),
            contact: attachment,
            avatarPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light,
            representedBy: "message"
        )
        let visibleRequest = try XCTUnwrap(pipeline.requests.first)
        let item = ChatCollectionPrefetchItem(
            messagePrimary: "message",
            owner: "owner@example.com",
            jid: "chat@example.com",
            avatarURL: nil,
            images: [],
            videos: [],
            locations: [],
            contacts: [ChatCollectionPrefetchContactReference(
                primary: attachment.primary,
                owner: attachment.owner,
                jid: attachment.jid,
                avatarURL: attachment.avatarURL.flatMap(URL.init(string:)),
                displayName: attachment.title,
                colorKey: attachment.jid
            )]
        )
        let context = ChatCollectionPrefetchContext.empty(
            conversationKey: ChatCollectionPrefetchConversationKey(
                owner: "owner@example.com",
                jid: "chat@example.com",
                conversationType: "regular"
            ),
            screenScale: 3,
            traitStyle: .light
        )
        let resources = ChatCollectionPrefetchPlanner.resources(
            for: item,
            indexPath: IndexPath(item: 0, section: 0),
            context: context
        )
        let prefetchedRequest = try XCTUnwrap(resources.compactMap { resource -> ChatAvatarRequest? in
            guard case .avatar(let identity, let request) = resource,
                  identity.kind == .contactAvatar else { return nil }
            return request
        }.first)

        XCTAssertEqual(prefetchedRequest, visibleRequest)
        XCTAssertEqual(prefetchedRequest.displaySize, ChatCollectionPrefetchSize(width: 36, height: 36))
    }

    func testRemoteAvatarIsDeliveredExactlyOnceWithoutGeneratedFallback() {
        let thumbnail = G14FakeThumbnailServing()
        let renderer = G14FakeGeneratedAvatarRenderer()
        let pipeline = ChatAvatarPipeline(
            thumbnailPipeline: thumbnail,
            renderer: renderer,
            generatedCache: ChatGeneratedAvatarMemoryCache(capacity: 4)
        )
        let request = avatarRequest(url: URL(string: "https://cdn.example.com/avatar.png"))
        let expected = testImage(color: .blue)
        var deliveries: [ChatAvatarDelivery] = []

        let subscription = pipeline.acquire(request, consumer: avatarConsumer()) { result in
            if case .success(let delivery) = result {
                deliveries.append(delivery)
            }
        }
        thumbnail.complete(
            at: 0,
            with: .success(ChatThumbnailDelivery(
                image: expected,
                pixelSize: request.thumbnailRequest!.pixelSize,
                source: .processedMemoryCache
            ))
        )
        thumbnail.complete(
            at: 0,
            with: .failure(.loadFailed)
        )

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertTrue(deliveries.first?.image === expected)
        XCTAssertEqual(deliveries.first?.source, .remote)
        XCTAssertTrue(renderer.requests.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testGeneratedFallbackCoalescesCachesAndRendersOffMain() {
        let thumbnail = G14FakeThumbnailServing()
        let renderer = G14FakeGeneratedAvatarRenderer()
        let pipeline = ChatAvatarPipeline(
            thumbnailPipeline: thumbnail,
            renderer: renderer,
            generatedCache: ChatGeneratedAvatarMemoryCache(capacity: 4)
        )
        let request = avatarRequest(url: nil)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        let renderStarted = expectation(description: "render started")
        renderer.onRender = { renderStarted.fulfill() }

        let prefetchSubscription = pipeline.acquire(request, consumer: avatarConsumer(role: .prefetch)) { result in
            if case .success = result { first.fulfill() }
        }
        let visibleSubscription = pipeline.acquire(request, consumer: avatarConsumer()) { result in
            if case .success = result { second.fulfill() }
        }
        wait(for: [renderStarted], timeout: 2)
        renderer.complete(at: 0, image: testImage(color: .orange))
        wait(for: [first, second], timeout: 2)

        XCTAssertEqual(renderer.requests.count, 1)
        XCTAssertEqual(renderer.renderedOnMainThread, [false])
        XCTAssertEqual(pipeline.metrics.generatedRenderCount, 1)
        XCTAssertEqual(pipeline.metrics.deduplicatedGeneratedAcquireCount, 1)

        let cached = expectation(description: "cached")
        let cachedSubscription = pipeline.acquire(request, consumer: avatarConsumer()) { result in
            if case .success(let delivery) = result {
                XCTAssertEqual(delivery.source, .generatedMemoryCache)
                cached.fulfill()
            }
        }
        wait(for: [cached], timeout: 1)
        XCTAssertEqual(renderer.requests.count, 1)
        withExtendedLifetime((prefetchSubscription, visibleSubscription, cachedSubscription)) {}
    }

    func testRemoteFailureFallsBackOnceAndCancellationSuppressesDelivery() {
        let thumbnail = G14FakeThumbnailServing()
        let renderer = G14FakeGeneratedAvatarRenderer()
        let pipeline = ChatAvatarPipeline(
            thumbnailPipeline: thumbnail,
            renderer: renderer,
            generatedCache: ChatGeneratedAvatarMemoryCache(capacity: 4)
        )
        let request = avatarRequest(url: URL(string: "https://cdn.example.com/missing.png"))
        var callbackCount = 0
        let renderStarted = expectation(description: "render started")
        renderer.onRender = { renderStarted.fulfill() }

        let subscription = pipeline.acquire(request, consumer: avatarConsumer()) { _ in
            callbackCount += 1
        }
        thumbnail.complete(at: 0, with: .failure(.loadFailed))
        wait(for: [renderStarted], timeout: 2)
        XCTAssertEqual(renderer.requests.count, 1)
        subscription.cancel()
        renderer.complete(at: 0, image: testImage(color: .gray))

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(renderer.tasks[0].cancelCount, 1)
    }

    func testGeneratedCacheIsBounded() {
        let cache = ChatGeneratedAvatarMemoryCache(capacity: 2)
        let image = testImage(color: .purple)
        let first = avatarRequest(url: nil, entityIdentity: "first").generatedRequest
        let second = avatarRequest(url: nil, entityIdentity: "second").generatedRequest
        let third = avatarRequest(url: nil, entityIdentity: "third").generatedRequest

        cache.store(image, for: first)
        cache.store(image, for: second)
        _ = cache.image(for: first)
        cache.store(image, for: third)

        XCTAssertNotNil(cache.image(for: first))
        XCTAssertNil(cache.image(for: second))
        XCTAssertNotNil(cache.image(for: third))
        XCTAssertEqual(cache.count, 2)
    }

    func testContactViewKeepsDownloadedAvatarForUnchangedIdentityAndRejectsOldURL() {
        let pipeline = G14FakeAvatarServing()
        let firstContact = contact(url: "https://cdn.example.com/first.png")
        let view = InlineContactsGridView.ContactView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44),
            contact: firstContact,
            avatarPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )
        let firstImage = testImage(color: .red)
        let secondImage = testImage(color: .green)

        XCTAssertEqual(pipeline.requests.count, 1)
        pipeline.complete(at: 0, image: firstImage)
        XCTAssertTrue(view.avatarImageView.image === firstImage)

        view.configure(contact: firstContact, palette: .amber)
        XCTAssertEqual(pipeline.requests.count, 1)
        XCTAssertTrue(view.avatarImageView.image === firstImage)

        let secondContact = contact(url: "https://cdn.example.com/second.png")
        view.configure(contact: secondContact, palette: .amber)
        XCTAssertEqual(pipeline.requests.count, 2)
        XCTAssertEqual(pipeline.subscriptions[0].cancelCount, 0)
        XCTAssertTrue(view.avatarImageView.image === firstImage)

        pipeline.complete(at: 0, image: testImage(color: .yellow))
        XCTAssertTrue(view.avatarImageView.image === firstImage)
        pipeline.complete(at: 1, image: secondImage)
        XCTAssertTrue(view.avatarImageView.image === secondImage)

        view.updateRenderingEnvironment(screenScale: 3, traitStyle: .dark)
        XCTAssertEqual(pipeline.requests.count, 3)
        XCTAssertEqual(pipeline.requests[2].traitStyle, .dark)
        pipeline.complete(at: 1, image: firstImage)
        XCTAssertTrue(view.avatarImageView.image === secondImage)
        let darkImage = testImage(color: .purple)
        pipeline.complete(at: 2, image: darkImage)
        XCTAssertTrue(view.avatarImageView.image === darkImage)
    }

    func testContactViewResetCancelsAndClearsIdentity() {
        let pipeline = G14FakeAvatarServing()
        let view = InlineContactsGridView.ContactView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44),
            contact: contact(url: nil),
            avatarPipeline: pipeline,
            screenScale: 3,
            traitStyle: .dark
        )

        XCTAssertNotNil(view.representedAvatarRequest)
        view.resetState()

        XCTAssertNil(view.representedAvatarRequest)
        XCTAssertNil(view.avatarImageView.image)
        XCTAssertEqual(pipeline.subscriptions[0].cancelCount, 1)
    }

    func testContactViewCancelsOffscreenAndRejectsCancelledDeliveryAfterResume() {
        let pipeline = G14FakeAvatarServing()
        let view = InlineContactsGridView.ContactView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44),
            contact: contact(url: "https://cdn.example.com/avatar.png"),
            avatarPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )
        let staleImage = testImage(color: .red)
        let currentImage = testImage(color: .green)

        view.cancelOffscreenWork()
        XCTAssertEqual(pipeline.subscriptions[0].cancelCount, 1)
        view.resumeOnscreenWork()
        XCTAssertEqual(pipeline.requests.count, 2)

        pipeline.complete(at: 0, image: staleImage)
        XCTAssertFalse(view.avatarImageView.image === staleImage)
        pipeline.complete(at: 1, image: currentImage)
        XCTAssertTrue(view.avatarImageView.image === currentImage)
    }

    func testSynchronousAvatarCacheHitDoesNotLeaveRestartableVisibleSubscription() {
        let image = testImage(color: .blue)
        let pipeline = G14FakeAvatarServing(immediateImage: image)
        let view = InlineContactsGridView.ContactView(
            frame: CGRect(x: 0, y: 0, width: 220, height: 44),
            contact: contact(url: "https://cdn.example.com/avatar.png"),
            avatarPipeline: pipeline,
            screenScale: 3,
            traitStyle: .light
        )

        view.cancelOffscreenWork()
        view.resumeOnscreenWork()

        XCTAssertEqual(pipeline.requests.count, 1)
        XCTAssertTrue(view.avatarImageView.image === image)
    }

    private func avatarRequest(
        url: URL?,
        entityIdentity: String = "alice@example.com"
    ) -> ChatAvatarRequest {
        ChatAvatarRequest(
            entityIdentity: entityIdentity,
            remoteURL: url,
            displayName: "Alice",
            colorKey: "owner@example.com",
            displaySize: ChatCollectionPrefetchSize(width: 36, height: 36),
            scale: 3,
            traitStyle: .light
        )
    }

    private func avatarConsumer(
        role: ChatAvatarConsumer.Role = .visible(UUID())
    ) -> ChatAvatarConsumer {
        ChatAvatarConsumer(
            identity: ChatCollectionPrefetchIdentity(
                kind: .contactAvatar,
                messagePrimary: "message",
                referencePrimary: "contact"
            ),
            role: role
        )
    }

    private func contact(url: String?) -> ContactAttachment {
        ContactAttachment(
            primary: "contact",
            owner: "owner@example.com",
            jid: "alice@example.com",
            title: "Alice",
            nickname: "Alice",
            given: nil,
            family: nil,
            avatarURL: url,
            avatarMetadata: [:]
        )
    }

    private func testImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

private final class G14FakeThumbnailSubscription: ChatThumbnailSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class G14FakeThumbnailServing: ChatThumbnailServing {
    private(set) var requests: [ChatThumbnailRequest] = []
    private(set) var subscriptions: [G14FakeThumbnailSubscription] = []
    private var completions: [(Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void] = []

    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription {
        let subscription = G14FakeThumbnailSubscription()
        requests.append(request)
        subscriptions.append(subscription)
        completions.append(completion ?? { _ in })
        return subscription
    }

    func complete(
        at index: Int,
        with result: Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>
    ) {
        completions[index](result)
    }
}

private final class G14FakeGeneratedAvatarTask: ChatGeneratedAvatarTask {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class G14FakeGeneratedAvatarRenderer: ChatGeneratedAvatarRendering {
    private let lock = NSLock()
    private let autoCompleteImage: UIImage?
    private(set) var requests: [ChatGeneratedAvatarRequest] = []
    private(set) var renderedOnMainThread: [Bool] = []
    private(set) var tasks: [G14FakeGeneratedAvatarTask] = []
    private var completions: [(UIImage?) -> Void] = []
    var onRender: (() -> Void)?

    init(autoCompleteImage: UIImage? = nil) {
        self.autoCompleteImage = autoCompleteImage
    }

    func render(
        _ request: ChatGeneratedAvatarRequest,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatGeneratedAvatarTask {
        let task = G14FakeGeneratedAvatarTask()
        lock.lock()
        requests.append(request)
        renderedOnMainThread.append(Thread.isMainThread)
        tasks.append(task)
        completions.append(completion)
        lock.unlock()
        onRender?()
        if let autoCompleteImage {
            completion(autoCompleteImage)
        }
        return task
    }

    func complete(at index: Int, image: UIImage?) {
        lock.lock()
        let completion = completions[index]
        lock.unlock()
        completion(image)
    }
}

private final class G14FakeAvatarSubscription: ChatAvatarSubscription {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class G14FakeAvatarServing: ChatAvatarServing {
    private let immediateImage: UIImage?
    private(set) var requests: [ChatAvatarRequest] = []
    private(set) var subscriptions: [G14FakeAvatarSubscription] = []
    private var completions: [(Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void] = []

    init(immediateImage: UIImage? = nil) {
        self.immediateImage = immediateImage
    }

    func acquire(
        _ request: ChatAvatarRequest,
        consumer: ChatAvatarConsumer,
        completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?
    ) -> ChatAvatarSubscription {
        let subscription = G14FakeAvatarSubscription()
        requests.append(request)
        subscriptions.append(subscription)
        completions.append(completion ?? { _ in })
        if let immediateImage {
            completion?(.success(ChatAvatarDelivery(image: immediateImage, source: .remote)))
        }
        return subscription
    }

    func complete(at index: Int, image: UIImage) {
        completions[index](.success(ChatAvatarDelivery(image: image, source: .remote)))
    }
}
