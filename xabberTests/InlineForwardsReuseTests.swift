import CoreLocation
import MaterialComponents.MDCPalettes
import XCTest
@testable import xabber

@MainActor
final class InlineForwardsReuseTests: XCTestCase {
    func testConfigureCreatesCurrentChildrenWithoutPriorLayout() {
        let container = InlineForwardsContainerView(
            frame: CGRect(x: 0, y: 0, width: 224, height: 420)
        )

        container.configure(
            [makeMessage(primary: "forward-a")],
            palette: .blue,
            delegate: nil
        )

        XCTAssertEqual(container.inlineViews.map(\.messagePrimary), ["forward-a"])
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testResetRecursivelyClearsViewsIdentitiesDelegatesAndAudioClock() throws {
        let container = makeConfiguredContainer(message: makeMessage(primary: "forward-a", includeAllMedia: true))
        let forwardView = try XCTUnwrap(container.inlineViews.first)
        let audioView = try XCTUnwrap(forwardView.audiosView.views.first)
        audioView.play(for: 30)
        XCTAssertTrue(audioView.waveform.isPlayed)

        container.resetState()

        XCTAssertTrue(container.inlineViews.isEmpty)
        XCTAssertTrue(container.subviews.isEmpty)
        XCTAssertEqual(forwardView.messagePrimary, "")
        XCTAssertNil(forwardView.delegate)
        XCTAssertTrue(forwardView.imagesView.views.isEmpty)
        XCTAssertTrue(forwardView.videosView.views.isEmpty)
        XCTAssertTrue(forwardView.locationsView.views.isEmpty)
        XCTAssertTrue(forwardView.contactsView.views.isEmpty)
        XCTAssertTrue(forwardView.audiosView.views.isEmpty)
        XCTAssertTrue(forwardView.filesView.views.isEmpty)
        XCTAssertTrue(forwardView.imagesView.subviews.isEmpty)
        XCTAssertTrue(forwardView.videosView.subviews.isEmpty)
        XCTAssertTrue(forwardView.locationsView.subviews.isEmpty)
        XCTAssertTrue(forwardView.contactsView.subviews.isEmpty)
        XCTAssertTrue(forwardView.audiosView.subviews.isEmpty)
        XCTAssertTrue(forwardView.filesView.subviews.isEmpty)
        XCTAssertFalse(audioView.waveform.isPlayed)
        XCTAssertNil(audioView.delegate)
    }

    func testAllMediaMessageReusedAsEmptyMessageLeavesNoOldAttachmentPresentation() throws {
        let container = makeConfiguredContainer(message: makeMessage(primary: "forward-a", includeAllMedia: true))
        let reusedView = try XCTUnwrap(container.inlineViews.first)

        container.updateContent(
            [makeMessage(primary: "forward-b")],
            palette: .green,
            delegate: nil
        )

        XCTAssertEqual(container.inlineViews.map(\.messagePrimary), ["forward-b"])
        XCTAssertTrue(reusedView.imagesView.views.isEmpty)
        XCTAssertTrue(reusedView.videosView.views.isEmpty)
        XCTAssertTrue(reusedView.locationsView.views.isEmpty)
        XCTAssertTrue(reusedView.contactsView.views.isEmpty)
        XCTAssertTrue(reusedView.audiosView.views.isEmpty)
        XCTAssertTrue(reusedView.filesView.views.isEmpty)
        XCTAssertTrue(reusedView.imagesView.subviews.isEmpty)
        XCTAssertTrue(reusedView.videosView.subviews.isEmpty)
        XCTAssertTrue(reusedView.locationsView.subviews.isEmpty)
        XCTAssertTrue(reusedView.contactsView.subviews.isEmpty)
        XCTAssertTrue(reusedView.audiosView.subviews.isEmpty)
        XCTAssertTrue(reusedView.filesView.subviews.isEmpty)
    }

    func testSameCountDifferentIdentitiesStopsOldAudioAndRebindsEveryGrid() throws {
        let first = makeMessage(primary: "forward-a", referenceSuffix: "a", includeAllMedia: true)
        let second = makeMessage(primary: "forward-b", referenceSuffix: "b", includeAllMedia: true)
        let container = makeConfiguredContainer(message: first)
        let oldAudioView = try XCTUnwrap(container.inlineViews.first?.audiosView.views.first)
        oldAudioView.play(for: 30)

        container.updateContent([second], palette: .purple, delegate: nil)

        let current = try XCTUnwrap(container.inlineViews.first)
        XCTAssertEqual(current.messagePrimary, "forward-b")
        XCTAssertEqual(current.imagesView.views.map(\.primary), ["image-b"])
        XCTAssertEqual(current.videosView.views.map(\.primary), ["video-b"])
        XCTAssertEqual(current.locationsView.views.map(\.location.primary), ["location-b"])
        XCTAssertEqual(current.contactsView.views.map(\.primary), ["contact-b"])
        XCTAssertEqual(current.audiosView.views.map(\.primary), ["audio-b"])
        XCTAssertEqual(current.filesView.views.map(\.primary), ["file-b"])
        XCTAssertFalse(oldAudioView.waveform.isPlayed)
        XCTAssertNil(oldAudioView.delegate)
        XCTAssertNil(oldAudioView.superview)
    }

    func testDelayedLocationCompletionRequiresFullRepresentedRequest() throws {
        let provider = DelayedLocationSnapshotProvider()
        let grid = InlineLocationsGridView(snapshotProvider: provider)
        grid.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        let first = makeLocation(primary: "same-reference", latitude: 10, longitude: 20)
        let second = makeLocation(primary: "same-reference", latitude: 30, longitude: 40)
        let staleURL = try makeSnapshotFile(name: "stale")
        let currentURL = try makeSnapshotFile(name: "current")
        defer {
            try? FileManager.default.removeItem(at: staleURL)
            try? FileManager.default.removeItem(at: currentURL)
        }

        grid.configure([first])
        try XCTUnwrap(grid.views.first).layoutIfNeeded()
        grid.updateContent([second])
        try XCTUnwrap(grid.views.first).layoutIfNeeded()
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.tasks[0].cancelCount, 1)

        provider.complete(at: 0, with: .success(staleURL))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertNil(second.snapshotURL)

        provider.complete(at: 1, with: .success(currentURL))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(second.snapshotURL, currentURL)
    }

    func testResetCancelsActiveLocationSnapshotAndRejectsItsCompletion() throws {
        let provider = DelayedLocationSnapshotProvider()
        let grid = InlineLocationsGridView(snapshotProvider: provider)
        grid.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        let location = makeLocation(primary: "location", latitude: 10, longitude: 20)
        let staleURL = try makeSnapshotFile(name: "reset-stale")
        defer { try? FileManager.default.removeItem(at: staleURL) }

        grid.configure([location])
        try XCTUnwrap(grid.views.first).layoutIfNeeded()
        XCTAssertEqual(provider.requests.count, 1)

        grid.resetState()

        XCTAssertEqual(provider.tasks[0].cancelCount, 1)
        XCTAssertTrue(grid.views.isEmpty)
        XCTAssertTrue(grid.subviews.isEmpty)
        provider.complete(at: 0, with: .success(staleURL))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertNil(location.snapshotURL)
    }

    func testUnchangedLocationUpdateDoesNotRestartActiveSnapshotRequest() throws {
        let provider = DelayedLocationSnapshotProvider()
        let grid = InlineLocationsGridView(snapshotProvider: provider)
        grid.frame = CGRect(x: 0, y: 0, width: 180, height: 180)
        let original = makeLocation(primary: "location", latitude: 10, longitude: 20)
        let unchanged = makeLocation(primary: "location", latitude: 10, longitude: 20)

        grid.configure([original], representedBy: "forward")
        try XCTUnwrap(grid.views.first).layoutIfNeeded()
        grid.updateContent([unchanged], representedBy: "forward")
        try XCTUnwrap(grid.views.first).layoutIfNeeded()

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.tasks[0].cancelCount, 0)
    }

    func testConfigureApplyOrderingProducesSameCurrentTree() {
        let message = makeMessage(primary: "forward-a", includeAllMedia: true)
        let attributes = makeAttributes()
        let configureFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 420))
        configureFirst.configure([message], palette: .blue, delegate: nil)
        configureFirst.layout(with: attributes)

        let applyFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 420))
        applyFirst.layout(with: attributes)
        applyFirst.configure([message], palette: .blue, delegate: nil)

        XCTAssertEqual(treeSnapshot(configureFirst), treeSnapshot(applyFirst))
    }

    func testOneHundredReuseCyclesHaveZeroResetTreeAndNoConfiguredGrowth() {
        let container = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 420))
        let attributes = makeAttributes()
        var maximumConfiguredSubviewCount = 0

        for index in 0..<100 {
            container.layout(with: attributes)
            container.configure(
                [makeMessage(primary: "forward-\(index)", referenceSuffix: "\(index)", includeAllMedia: true)],
                palette: .blue,
                delegate: nil
            )
            maximumConfiguredSubviewCount = max(maximumConfiguredSubviewCount, container.subviews.count)
            XCTAssertEqual(container.inlineViews.count, 1)

            container.resetState()
            XCTAssertTrue(container.inlineViews.isEmpty)
            XCTAssertTrue(container.subviews.isEmpty)
        }

        XCTAssertEqual(maximumConfiguredSubviewCount, 1)
    }

    func testNestedDataDoesNotEagerlyBuildUnlaidOutAttachmentTrees() throws {
        let nested = makeMessage(primary: "nested", includeAllMedia: true)
        let root = makeMessage(primary: "root", subforwards: [nested])
        let container = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 420))

        container.configure([root], palette: .blue, delegate: nil)

        XCTAssertEqual(container.inlineViews.count, 1)
        XCTAssertEqual(try XCTUnwrap(container.inlineViews.first).messagePrimary, "root")
        XCTAssertEqual(container.subviews.count, 1)
    }

    private func makeConfiguredContainer(message: MessageAttachment) -> InlineForwardsContainerView {
        let container = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 420))
        container.layout(with: makeAttributes())
        container.configure([message], palette: .blue, delegate: nil)
        return container
    }

    private func makeMessage(
        primary: String,
        referenceSuffix: String = "a",
        includeAllMedia: Bool = false,
        subforwards: [MessageAttachment] = []
    ) -> MessageAttachment {
        let images = includeAllMedia ? [
            ImageAttachment(
                primary: "image-\(referenceSuffix)",
                url: URL(fileURLWithPath: "/tmp/image-\(referenceSuffix).jpg"),
                size: CGSize(width: 100, height: 100)
            )
        ] : []
        let videos = includeAllMedia ? [
            VideoAttachment(
                primary: "video-\(referenceSuffix)",
                url: URL(fileURLWithPath: "/tmp/video-\(referenceSuffix).mov"),
                size: CGSize(width: 100, height: 100),
                previewUrl: URL(fileURLWithPath: "/tmp/video-\(referenceSuffix).jpg"),
                duration: 2,
                downloaded: true
            )
        ] : []
        let locations = includeAllMedia ? [
            makeLocation(primary: "location-\(referenceSuffix)", latitude: 10, longitude: 20)
        ] : []
        let contacts = includeAllMedia ? [
            ContactAttachment(
                primary: "contact-\(referenceSuffix)",
                owner: "owner@example.com",
                jid: "contact-\(referenceSuffix)@example.com",
                title: "Contact \(referenceSuffix)",
                nickname: nil,
                given: nil,
                family: nil,
                avatarURL: nil,
                avatarMetadata: [:]
            )
        ] : []
        let files = includeAllMedia ? [
            FileAttachment(
                primary: "file-\(referenceSuffix)",
                url: URL(fileURLWithPath: "/tmp/file-\(referenceSuffix).pdf"),
                size: 1_024,
                name: "file.pdf",
                downloaded: true
            )
        ] : []
        let audios = includeAllMedia ? [
            AudioAttachment(
                primary: "audio-\(referenceSuffix)",
                url: URL(fileURLWithPath: "/tmp/audio-\(referenceSuffix).ogg"),
                size: 1_024,
                name: "audio.ogg",
                duration: 30,
                downloaded: true,
                pcm: [0.2, 0.4, 0.6]
            )
        ] : []
        return MessageAttachment(
            primary: primary,
            author: "Alexey",
            jid: "alexey@example.com",
            outgoing: false,
            textMessage: NSAttributedString(string: "Forward body"),
            images: images,
            videos: videos,
            locations: locations,
            contacts: contacts,
            files: files,
            audios: audios,
            timeMarker: NSAttributedString(string: "12:30"),
            subforwards: subforwards
        )
    }

    private func makeLocation(primary: String, latitude: Double, longitude: Double) -> LocationAttachment {
        LocationAttachment(
            primary: primary,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            address: "Location",
            geoURI: "geo:\(latitude),\(longitude)",
            snapshotURL: nil
        )
    }

    private func makeAttributes() -> MessagesCollectionViewLayoutAttributes {
        let attributes = MessagesCollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.side = .left
        attributes.cornerRadius = "12"
        attributes.messageLabelInsets = UIEdgeInsets(top: 3, left: 7, bottom: 5, right: 11)
        attributes.inlineContainerSizeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 2)
        attributes.inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 2, bottom: 0, right: 2)
        attributes.forwardsInlineViewSize = [MessageAttachmentSizes(
            textLabelSize: CGSize(width: 180, height: 30),
            imagesContainerSize: CGSize(width: 200, height: 80),
            videosContainerSize: CGSize(width: 200, height: 80),
            locationsContainerSize: CGSize(width: 200, height: 200),
            contactsContainerSize: CGSize(width: 200, height: 44),
            filesContainerSize: CGSize(width: 200, height: 44),
            audiosContainerSize: CGSize(width: 200, height: 44),
            containerSize: CGSize(width: 212, height: 540),
            authorSize: CGSize(width: 100, height: 18),
            messageContainer: CGSize(width: 216, height: 548),
            timeMarker: CGSize(width: 36, height: 14)
        )]
        return attributes
    }

    private func treeSnapshot(_ container: InlineForwardsContainerView) -> [String] {
        var result: [String] = []
        for view in container.inlineViews {
            result.append(view.messagePrimary)
            result.append(contentsOf: view.imagesView.views.map(\.primary))
            result.append(contentsOf: view.videosView.views.map(\.primary))
            result.append(contentsOf: view.locationsView.views.map(\.location.primary))
            result.append(contentsOf: view.contactsView.views.map(\.primary))
            result.append(contentsOf: view.audiosView.views.map(\.primary))
            result.append(contentsOf: view.filesView.views.map(\.primary))
        }
        return result
    }

    private func makeSnapshotFile(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-forward-\(name)-\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }
}

private final class DelayedLocationSnapshotProvider: ChatLocationSnapshotProviding {
    struct Request {
        let location: ChatAttachmentResolvedLocation
        let size: CGSize
        let completion: (Result<URL, Error>) -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var tasks: [DelayedLocationSnapshotTask] = []

    @discardableResult
    func makeSnapshot(
        for location: ChatAttachmentResolvedLocation,
        size: CGSize,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> ChatLocationSnapshotTask? {
        let task = DelayedLocationSnapshotTask()
        requests.append(Request(location: location, size: size, completion: completion))
        tasks.append(task)
        return task
    }

    func complete(at index: Int, with result: Result<URL, Error>) {
        requests[index].completion(result)
    }
}

private final class DelayedLocationSnapshotTask: ChatLocationSnapshotTask {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}
