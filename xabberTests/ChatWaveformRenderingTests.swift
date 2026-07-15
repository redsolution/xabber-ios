import XCTest
@testable import xabber

@MainActor
final class ChatWaveformRenderingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatWaveformRenderInstrumentation.resetForTests()
    }

    func testUnchangedRevisionAndWidthReuseStaticArtifact() {
        let view = makeWaveformView()

        view.configureStaticWaveform(levels: [0.1, 0.5, 0.9], revision: "voice-a-v1")
        view.layoutIfNeeded()
        view.configureStaticWaveform(levels: [0.1, 0.5, 0.9], revision: "voice-a-v1")
        view.layoutIfNeeded()

        let metrics = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(metrics.sampleNormalizationCount, 1)
        XCTAssertEqual(metrics.staticPathBuildCount, 1)
    }

    func testChangedRevisionAndWidthEachBuildOneNewStaticArtifact() {
        let view = makeWaveformView()
        view.configureStaticWaveform(levels: [0.1, 0.5], revision: "voice-a-v1")
        view.layoutIfNeeded()

        view.configureStaticWaveform(levels: [0.2, 0.8], revision: "voice-a-v2")
        view.layoutIfNeeded()
        view.frame.size.width = 260
        view.layoutIfNeeded()

        let metrics = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(metrics.sampleNormalizationCount, 3)
        XCTAssertEqual(metrics.staticPathBuildCount, 3)
    }

    func testProgressTicksMutateOnlyMaskWithoutStaticRebuild() {
        let view = makeWaveformView()
        view.configureStaticWaveform(levels: [0.1, 0.5, 0.9], revision: "voice-a-v1")
        view.layoutIfNeeded()
        let before = ChatWaveformRenderInstrumentation.snapshot

        view.setProgress(0.25)
        view.setProgress(0.5)
        view.setProgress(0.75)

        let after = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(after.sampleNormalizationCount, before.sampleNormalizationCount)
        XCTAssertEqual(after.staticPathBuildCount, before.staticPathBuildCount)
        XCTAssertEqual(after.progressMutationCount - before.progressMutationCount, 3)
        XCTAssertEqual(view.debugProgressMaskFrame.width, view.bounds.width * 0.75, accuracy: 0.001)
        XCTAssertEqual(view.activeClockCount, 0)
    }

    func testColorOnlyChangesDoNotRebuildStaticPath() {
        let view = makeWaveformView()
        view.configureStaticWaveform(levels: [0.2, 0.7], revision: "voice-a-v1")
        view.layoutIfNeeded()
        let before = ChatWaveformRenderInstrumentation.snapshot

        view.gradientStartColor = .systemRed
        view.gradientEndColor = .systemOrange
        view.barBackgroundFillColor = .systemGray
        view.layoutIfNeeded()

        let after = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(after.staticPathBuildCount, before.staticPathBuildCount)
        XCTAssertEqual(after.sampleNormalizationCount, before.sampleNormalizationCount)
    }

    func testMemoryWarningEvictsStaticArtifact() {
        let first = makeWaveformView()
        first.configureStaticWaveform(levels: [0.2, 0.7], revision: "voice-a-v1")
        first.layoutIfNeeded()
        let before = ChatWaveformRenderInstrumentation.snapshot

        ChatWaveformRenderInstrumentation.simulateMemoryWarningForTests()
        let second = makeWaveformView()
        second.configureStaticWaveform(levels: [0.2, 0.7], revision: "voice-a-v1")
        second.layoutIfNeeded()

        let after = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(after.sampleNormalizationCount, before.sampleNormalizationCount + 1)
        XCTAssertEqual(after.staticPathBuildCount, before.staticPathBuildCount + 1)
    }

    func testAudioViewRepeatedContentAndPlaybackTickOwnNoClock() {
        let view = makeAudioView(primary: "voice-a", pcm: [0.2, 0.6])
        let before = ChatWaveformRenderInstrumentation.snapshot

        view.updateContent(
            "voice-a",
            filename: "voice",
            size: "10 KB",
            duration: 12,
            pcm: [0.2, 0.6],
            state: .playing(currentTime: 3, duration: 12)
        )

        let after = ChatWaveformRenderInstrumentation.snapshot
        XCTAssertEqual(after.staticPathBuildCount, before.staticPathBuildCount)
        XCTAssertEqual(after.sampleNormalizationCount, before.sampleNormalizationCount)
        XCTAssertEqual(view.waveform.activeClockCount, 0)
        XCTAssertTrue(view.iconButton.isPulseActive)
    }

    func testGridRoutesStateOnlyToMatchingReference() throws {
        let grid = InlineAudiosGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 88))
        grid.configure(
            [
                attachment(primary: "voice-a", pcm: [0.2]),
                attachment(primary: "voice-b", pcm: [0.8])
            ],
            palette: .blue
        )

        XCTAssertTrue(grid.render(state: .playing(currentTime: 4, duration: 10), for: "voice-b"))
        XCTAssertFalse(grid.render(state: .playing(currentTime: 1, duration: 10), for: "missing"))

        let first = try XCTUnwrap(grid.views.first)
        let second = try XCTUnwrap(grid.views.last)
        XCTAssertEqual(first.renderedState, .downloaded)
        XCTAssertEqual(second.renderedState, .playing(currentTime: 4, duration: 10))
        XCTAssertEqual(first.waveform.currentGradientPercentage, 0)
        XCTAssertEqual(second.waveform.currentGradientPercentage, 0.4)
    }

    func testMessageCellRoutesTopLevelAndForwardedStateWithoutReconfigure() throws {
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        cell.audiosView.frame = CGRect(x: 0, y: 0, width: 280, height: 44)
        cell.audiosView.configure([attachment(primary: "top", pcm: [0.2])], palette: .blue)

        let forwarded = InlineMessageAttachmentView(frame: CGRect(x: 0, y: 44, width: 280, height: 44))
        forwarded.audiosView.frame = forwarded.bounds
        forwarded.audiosView.configure([attachment(primary: "forward", pcm: [0.7])], palette: .green)
        cell.forwardsContainer.inlineViews = [forwarded]

        XCTAssertTrue(cell.renderVoiceMessageState(
            referencePrimary: "top",
            state: .playing(currentTime: 2, duration: 10)
        ))
        XCTAssertTrue(cell.renderVoiceMessageState(
            referencePrimary: "forward",
            state: .paused(currentTime: 6, duration: 10)
        ))
        XCTAssertFalse(cell.renderVoiceMessageState(
            referencePrimary: "missing",
            state: .downloaded
        ))
        XCTAssertEqual(cell.audiosView.views.first?.renderedState, .playing(currentTime: 2, duration: 10))
        XCTAssertEqual(forwarded.audiosView.views.first?.renderedState, .paused(currentTime: 6, duration: 10))
    }

    func testCoordinatorIsTheOnlyPlaybackClock() {
        let player = ChatWaveformFakePlayer()
        let coordinator = VoiceMessagePlaybackCoordinator(
            downloader: ChatWaveformNoopDownloader(),
            player: player
        )
        let descriptor = VoiceMessageDescriptor(
            referencePrimary: "voice-a",
            containerMessagePrimary: "message-a",
            remoteURL: nil,
            decodedURL: URL(fileURLWithPath: "/tmp/voice-a.m4a"),
            duration: 12,
            downloaded: true,
            pcm: [0.2],
            sentDate: Date(timeIntervalSince1970: 1)
        )

        coordinator.handleTap(descriptor)
        XCTAssertEqual(coordinator.activePlaybackClockCount, 1)
        coordinator.handleTap(descriptor)
        XCTAssertEqual(coordinator.activePlaybackClockCount, 0)
        coordinator.handleTap(descriptor)
        XCTAssertEqual(coordinator.activePlaybackClockCount, 1)
        coordinator.stopPlayback()
        XCTAssertEqual(coordinator.activePlaybackClockCount, 0)
    }

    func testOffscreenAndReuseStopPulseAndClearRepresentation() {
        let view = makeAudioView(primary: "voice-a", pcm: [0.2, 0.6])
        view.render(state: .playing(currentTime: 3, duration: 12))
        XCTAssertTrue(view.iconButton.isPulseActive)

        view.cancelOffscreenWork()
        XCTAssertFalse(view.iconButton.isPulseActive)
        XCTAssertEqual(view.waveform.activeClockCount, 0)

        view.prepareForReuse()
        XCTAssertFalse(view.iconButton.isPulseActive)
        XCTAssertEqual(view.waveform.activeClockCount, 0)
        XCTAssertEqual(view.primary, "")
    }

    func testWaveformSourceHasNoPerDrawBitmapContext() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("xabber/controllers/chats/chat/Waveforms/AudioVisualizationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("UIGraphicsBeginImageContextWithOptions"))
        XCTAssertFalse(source.contains("override public func draw("))
    }

    func testChatPlaybackObserverRoutesDirectlyWithoutMessageCellReconfigure() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("xabber/controllers/chats/chat/ChatViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func handleVoiceMessageStateChange"))
        let end = try XCTUnwrap(
            source.range(
                of: "internal func updateVisibleVoiceMessageQueue",
                range: start.upperBound..<source.endIndex
            )
        )
        let handler = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(handler.contains("updateVisibleVoiceMessageState"))
        XCTAssertFalse(handler.contains("updateVisibleMessageContent"))
    }

    private func makeWaveformView() -> AudioVisualizationView {
        let view = AudioVisualizationView(frame: CGRect(x: 0, y: 0, width: 220, height: 26))
        view.audioVisualizationMode = .read
        view.audioVisualizationType = .both
        return view
    }

    private func makeAudioView(primary: String, pcm: [Float]) -> InlineAudiosGridView.AudioView {
        let view = InlineAudiosGridView.AudioView(
            frame: CGRect(x: 0, y: 0, width: 260, height: 44),
            url: URL(fileURLWithPath: "/tmp/\(primary).m4a")
        )
        view.configure(
            primary,
            filename: "voice",
            size: "10 KB",
            duration: 12,
            pcm: pcm
        )
        return view
    }

    private func attachment(primary: String, pcm: [Float]) -> AudioAttachment {
        AudioAttachment(
            primary: primary,
            url: URL(fileURLWithPath: "/tmp/\(primary).m4a"),
            size: 10,
            name: "voice",
            duration: 10,
            downloaded: true,
            pcm: pcm
        )
    }
}

private final class ChatWaveformNoopDownloadTask: VoiceMessageDownloadTask {
    func cancel() {}
}

private final class ChatWaveformNoopDownloader: VoiceMessageDownloading {
    func download(
        _ descriptor: VoiceMessageDescriptor,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<VoiceMessageDownloadedFile, Error>) -> Void
    ) -> VoiceMessageDownloadTask {
        ChatWaveformNoopDownloadTask()
    }
}

private final class ChatWaveformFakePlayer: VoiceMessagePlaying {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 12
    var isPlaying = false
    var onFinish: (() -> Void)?

    func start(url: URL, referencePrimary: String, at time: TimeInterval) throws -> TimeInterval {
        currentTime = time
        isPlaying = true
        return duration
    }

    func pause() {
        isPlaying = false
    }

    func resume() {
        isPlaying = true
    }

    func stop() {
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        currentTime = time
    }
}
