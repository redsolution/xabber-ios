import Foundation
import AVFoundation
import CocoaLumberjack

enum VoiceMessagePlaybackState: Equatable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case downloaded
    case playing(currentTime: TimeInterval, duration: TimeInterval)
    case paused(currentTime: TimeInterval, duration: TimeInterval)
    case failed(error: String)

    var isActivePlayback: Bool {
        switch self {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    var playbackProgress: Double {
        switch self {
        case .playing(let currentTime, let duration),
             .paused(let currentTime, let duration):
            guard duration > 0 else { return 0 }
            return min(max(currentTime / duration, 0), 1)
        default:
            return 0
        }
    }
}

struct VoiceMessageDescriptor: Equatable {
    let referencePrimary: String
    let containerMessagePrimary: String
    let remoteURL: URL?
    let decodedURL: URL?
    let duration: TimeInterval
    let downloaded: Bool
    let pcm: [Float]
    let sentDate: Date

    init(
        referencePrimary: String,
        containerMessagePrimary: String,
        remoteURL: URL?,
        decodedURL: URL?,
        duration: TimeInterval,
        downloaded: Bool,
        pcm: [Float],
        sentDate: Date
    ) {
        self.referencePrimary = referencePrimary
        self.containerMessagePrimary = containerMessagePrimary
        self.remoteURL = remoteURL
        self.decodedURL = decodedURL
        self.duration = duration
        self.downloaded = downloaded
        self.pcm = pcm
        self.sentDate = sentDate
    }

    var isLocallyAvailable: Bool {
        downloaded || decodedURL != nil
    }
}

struct VoiceMessageStateChange {
    let referencePrimary: String
    let containerMessagePrimary: String
    let state: VoiceMessagePlaybackState
    let previousState: VoiceMessagePlaybackState?
}

struct VoiceMessagePlaybackRoute: Equatable {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let messagePrimary: String
    let archivedId: String?
    let sourceDate: Date
}

struct VoiceMessagePlaybackSnapshot {
    let referencePrimary: String
    let containerMessagePrimary: String
    let state: VoiceMessagePlaybackState
    let title: String?
    let subtitle: String?
    let route: VoiceMessagePlaybackRoute?
}

struct VoiceMessageDownloadedFile {
    let decodedURL: URL
    let duration: TimeInterval
    let pcm: [Float]
}

protocol VoiceMessageDownloadTask {
    func cancel()
}

protocol VoiceMessageDownloading {
    @discardableResult
    func download(
        _ descriptor: VoiceMessageDescriptor,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<VoiceMessageDownloadedFile, Error>) -> Void
    ) -> VoiceMessageDownloadTask
}

protocol VoiceMessagePlaying: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var onFinish: (() -> Void)? { get set }

    @discardableResult
    func start(url: URL, referencePrimary: String, at time: TimeInterval) throws -> TimeInterval
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)
}

final class VoiceMessagePlaybackCoordinator {
    static let shared = VoiceMessagePlaybackCoordinator(
        downloader: URLSessionVoiceMessageDownloader(),
        player: AudioManagerVoiceMessagePlayer()
    )

    private enum QueueSource {
        case visible
        case manual
    }

    private struct QueueItem {
        let descriptor: VoiceMessageDescriptor
        let source: QueueSource
    }

    private let downloader: VoiceMessageDownloading
    private let player: VoiceMessagePlaying
    private var descriptors: [String: VoiceMessageDescriptor] = [:]
    private var states: [String: VoiceMessagePlaybackState] = [:]
    private var observers: [UUID: (VoiceMessageStateChange) -> Void] = [:]
    private var downloadQueue: [QueueItem] = []
    private var activeDownloadPrimary: String?
    private var activeDownloadTask: VoiceMessageDownloadTask?
    private var activeDownloadGeneration: UUID?
    private var currentPlaybackPrimary: String?
    private var playbackPositions: [String: TimeInterval] = [:]
    private var visibleVoiceMessagesInPlaybackOrder: [VoiceMessageDescriptor] = []
    private var routes: [String: VoiceMessagePlaybackRoute] = [:]
    private var playbackTimer: Timer?

    init(downloader: VoiceMessageDownloading, player: VoiceMessagePlaying) {
        self.downloader = downloader
        self.player = player
        self.player.onFinish = { [weak self] in
            DispatchQueue.main.async {
                self?.handlePlaybackFinished()
            }
        }
    }

    deinit {
        playbackTimer?.invalidate()
    }

    @discardableResult
    func addObserver(_ observer: @escaping (VoiceMessageStateChange) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID?) {
        guard let token else { return }
        observers.removeValue(forKey: token)
    }

    func state(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackState {
        register(descriptor)
        return state(forReferencePrimary: descriptor.referencePrimary, downloaded: descriptor.downloaded)
    }

    func state(forReferencePrimary referencePrimary: String, downloaded: Bool = false) -> VoiceMessagePlaybackState {
        if let state = states[referencePrimary] {
            return state
        }
        return downloaded ? .downloaded : .notDownloaded
    }

    func handleTap(_ descriptor: VoiceMessageDescriptor) {
        register(descriptor)
        switch state(for: descriptor) {
        case .notDownloaded, .failed, .queued:
            enqueue(descriptor, source: .manual, front: true)
        case .downloading:
            cancelDownload(referencePrimary: descriptor.referencePrimary)
        case .downloaded:
            startPlayback(descriptor)
        case .playing:
            pausePlayback(referencePrimary: descriptor.referencePrimary)
        case .paused:
            resumePlayback(descriptor)
        }
    }

    func toggleCurrentPlayback() {
        guard let snapshot = currentPlaybackSnapshot,
              let descriptor = descriptors[snapshot.referencePrimary] else {
            return
        }
        handleTap(descriptor)
    }

    @discardableResult
    func seekCurrentPlayback(percentage: Float) -> TimeInterval {
        guard let primary = currentPlaybackPrimary else {
            return 0
        }
        return seek(referencePrimary: primary, percentage: percentage)
    }

    func setVisibleVoiceMessages(_ visibleDescriptors: [VoiceMessageDescriptor]) {
        let visibleUnique = uniqueOrderedDescriptors(visibleDescriptors)
        visibleVoiceMessagesInPlaybackOrder = visibleUnique
        visibleUnique.forEach(register(_:))
        let visiblePrimaries = Set(visibleUnique.map(\.referencePrimary))

        let removedQueuedVisibleItems = downloadQueue.filter {
            $0.source == .visible && !visiblePrimaries.contains($0.descriptor.referencePrimary)
        }
        downloadQueue.removeAll {
            $0.source == .visible && !visiblePrimaries.contains($0.descriptor.referencePrimary)
        }
        removedQueuedVisibleItems.forEach { item in
            if activeDownloadPrimary != item.descriptor.referencePrimary,
               case .queued = states[item.descriptor.referencePrimary] ?? .notDownloaded {
                setState(.notDownloaded, for: item.descriptor)
            }
        }

        let queuedPrimaries = Set(downloadQueue.map { $0.descriptor.referencePrimary })
        visibleUnique
            .reversed()
            .forEach { descriptor in
                guard descriptor.referencePrimary != activeDownloadPrimary,
                      !queuedPrimaries.contains(descriptor.referencePrimary),
                      case .notDownloaded = state(for: descriptor) else {
                    return
                }
                downloadQueue.append(QueueItem(descriptor: descriptor, source: .visible))
                setState(.queued, for: descriptor)
            }

        startNextDownloadIfNeeded()
    }

    func cancelDownload(referencePrimary: String) {
        if activeDownloadPrimary == referencePrimary {
            activeDownloadGeneration = nil
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            activeDownloadPrimary = nil
            if let descriptor = descriptors[referencePrimary] {
                setState(.notDownloaded, for: descriptor)
            }
            startNextDownloadIfNeeded()
            return
        }

        let removed = downloadQueue.filter { $0.descriptor.referencePrimary == referencePrimary }
        downloadQueue.removeAll { $0.descriptor.referencePrimary == referencePrimary }
        removed.forEach { setState(.notDownloaded, for: $0.descriptor) }
    }

    func retry(_ descriptor: VoiceMessageDescriptor) {
        register(descriptor)
        setState(.notDownloaded, for: descriptor)
        enqueue(descriptor, source: .manual, front: true)
    }

    func canSeek(referencePrimary: String) -> Bool {
        switch states[referencePrimary] {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func seek(referencePrimary: String, percentage: Float) -> TimeInterval {
        let clamped = min(max(Double(percentage), 0), 1)
        let duration: TimeInterval
        switch states[referencePrimary] {
        case .playing(_, let currentDuration),
             .paused(_, let currentDuration):
            duration = currentDuration
        default:
            return 0
        }
        let newTime = duration * clamped
        playbackPositions[referencePrimary] = newTime
        if currentPlaybackPrimary == referencePrimary {
            player.seek(to: newTime)
        }
        if let descriptor = descriptors[referencePrimary] {
            switch states[referencePrimary] {
            case .playing:
                setState(.playing(currentTime: newTime, duration: duration), for: descriptor)
            case .paused:
                setState(.paused(currentTime: newTime, duration: duration), for: descriptor)
            default:
                break
            }
        }
        return newTime
    }

    func stopPlayback() {
        guard let primary = currentPlaybackPrimary else { return }
        playbackTimer?.invalidate()
        playbackTimer = nil
        player.stop()
        playbackPositions[primary] = 0
        currentPlaybackPrimary = nil
        if let descriptor = descriptors[primary] {
            setState(.downloaded, for: descriptor)
        }
    }

    func tickPlaybackProgress() {
        guard let primary = currentPlaybackPrimary,
              case .playing = states[primary],
              let descriptor = descriptors[primary] else {
            return
        }
        let duration = player.duration > 0 ? player.duration : descriptor.duration
        let currentTime = min(max(player.currentTime, 0), max(duration, 0))
        playbackPositions[primary] = currentTime
        setState(.playing(currentTime: currentTime, duration: duration), for: descriptor)
    }

    var currentPlaybackSnapshot: VoiceMessagePlaybackSnapshot? {
        guard let primary = currentPlaybackPrimary,
              let descriptor = descriptors[primary],
              let state = states[primary] else {
            return nil
        }
        return VoiceMessagePlaybackSnapshot(
            referencePrimary: primary,
            containerMessagePrimary: descriptor.containerMessagePrimary,
            state: state,
            title: AudioManager.shared.currentPlayingTitle,
            subtitle: AudioManager.shared.currentPlayingSubtitle,
            route: route(for: descriptor)
        )
    }

    var hasActivePlayback: Bool {
        currentPlaybackSnapshot != nil
    }

    private func register(_ descriptor: VoiceMessageDescriptor) {
        descriptors[descriptor.referencePrimary] = descriptor
        _ = route(for: descriptor)
        if descriptor.isLocallyAvailable {
            switch states[descriptor.referencePrimary] {
            case nil, .notDownloaded, .queued, .failed:
                states[descriptor.referencePrimary] = .downloaded
            default:
                break
            }
        } else if states[descriptor.referencePrimary] == nil {
            states[descriptor.referencePrimary] = .notDownloaded
        }
    }

    private func enqueue(_ descriptor: VoiceMessageDescriptor, source: QueueSource, front: Bool) {
        downloadQueue.removeAll { $0.descriptor.referencePrimary == descriptor.referencePrimary }
        let item = QueueItem(descriptor: descriptor, source: source)
        if front {
            downloadQueue.insert(item, at: 0)
        } else {
            downloadQueue.append(item)
        }
        if activeDownloadPrimary != descriptor.referencePrimary {
            setState(.queued, for: descriptor)
        }
        startNextDownloadIfNeeded()
    }

    private func startNextDownloadIfNeeded() {
        guard activeDownloadPrimary == nil,
              let next = downloadQueue.first else {
            return
        }
        downloadQueue.removeFirst()
        let descriptor = next.descriptor
        let generation = UUID()
        activeDownloadGeneration = generation
        activeDownloadPrimary = descriptor.referencePrimary
        setState(.downloading(progress: 0), for: descriptor)
        activeDownloadTask = downloader.download(
            descriptor,
            progress: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.handleDownloadProgress(progress, descriptor: descriptor, generation: generation)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleDownloadCompletion(result, descriptor: descriptor, generation: generation)
                }
            }
        )
    }

    private func handleDownloadProgress(_ progress: Double, descriptor: VoiceMessageDescriptor, generation: UUID) {
        guard activeDownloadGeneration == generation,
              activeDownloadPrimary == descriptor.referencePrimary else {
            return
        }
        setState(.downloading(progress: min(max(progress, 0), 1)), for: descriptor)
    }

    private func handleDownloadCompletion(
        _ result: Result<VoiceMessageDownloadedFile, Error>,
        descriptor: VoiceMessageDescriptor,
        generation: UUID
    ) {
        guard activeDownloadGeneration == generation,
              activeDownloadPrimary == descriptor.referencePrimary else {
            return
        }
        activeDownloadGeneration = nil
        activeDownloadTask = nil
        activeDownloadPrimary = nil

        switch result {
        case .success(let file):
            let downloadedDescriptor = VoiceMessageDescriptor(
                referencePrimary: descriptor.referencePrimary,
                containerMessagePrimary: descriptor.containerMessagePrimary,
                remoteURL: descriptor.remoteURL,
                decodedURL: file.decodedURL,
                duration: file.duration,
                downloaded: true,
                pcm: file.pcm,
                sentDate: descriptor.sentDate
            )
            descriptors[descriptor.referencePrimary] = downloadedDescriptor
            setState(.downloaded, for: downloadedDescriptor)
        case .failure(let error):
            setState(.failed(error: error.localizedDescription), for: descriptor)
        }
        startNextDownloadIfNeeded()
    }

    private func startPlayback(_ descriptor: VoiceMessageDescriptor) {
        guard let url = descriptor.decodedURL ?? descriptor.remoteURL else {
            setState(.failed(error: "Audio file is unavailable"), for: descriptor)
            return
        }
        stopPreviousPlaybackIfNeeded(except: descriptor.referencePrimary)
        do {
            let startTime = playbackPositions[descriptor.referencePrimary] ?? 0
            let duration = try player.start(url: url, referencePrimary: descriptor.referencePrimary, at: startTime)
            currentPlaybackPrimary = descriptor.referencePrimary
            setState(.playing(currentTime: min(startTime, duration), duration: duration), for: descriptor)
            startPlaybackTimer()
        } catch {
            currentPlaybackPrimary = nil
            setState(.failed(error: error.localizedDescription), for: descriptor)
        }
    }

    private func pausePlayback(referencePrimary: String) {
        guard currentPlaybackPrimary == referencePrimary,
              let descriptor = descriptors[referencePrimary] else {
            return
        }
        player.pause()
        playbackTimer?.invalidate()
        playbackTimer = nil
        let duration = player.duration > 0 ? player.duration : descriptor.duration
        let currentTime = min(max(player.currentTime, 0), max(duration, 0))
        playbackPositions[referencePrimary] = currentTime
        setState(.paused(currentTime: currentTime, duration: duration), for: descriptor)
    }

    private func resumePlayback(_ descriptor: VoiceMessageDescriptor) {
        if currentPlaybackPrimary == descriptor.referencePrimary {
            player.resume()
            let duration = player.duration > 0 ? player.duration : descriptor.duration
            let currentTime = playbackPositions[descriptor.referencePrimary] ?? player.currentTime
            setState(.playing(currentTime: currentTime, duration: duration), for: descriptor)
            startPlaybackTimer()
        } else {
            startPlayback(descriptor)
        }
    }

    private func stopPreviousPlaybackIfNeeded(except primary: String) {
        guard let previousPrimary = currentPlaybackPrimary,
              previousPrimary != primary else {
            return
        }
        playbackTimer?.invalidate()
        playbackTimer = nil
        let currentTime = player.currentTime
        let duration = player.duration
        player.stop()
        playbackPositions[previousPrimary] = currentTime
        currentPlaybackPrimary = nil
        if let descriptor = descriptors[previousPrimary] {
            setState(.paused(currentTime: currentTime, duration: duration), for: descriptor)
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickPlaybackProgress()
        }
        if let playbackTimer {
            RunLoop.main.add(playbackTimer, forMode: .common)
        }
    }

    private func handlePlaybackFinished() {
        guard let primary = currentPlaybackPrimary else { return }
        let finishedDescriptor = descriptors[primary]
        let nextDescriptor = nextVisibleVoiceMessageAfter(primary)
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackPositions[primary] = 0
        player.stop()

        if let nextDescriptor, nextDescriptor.isLocallyAvailable {
            currentPlaybackPrimary = nil
            startPlayback(nextDescriptor)
            if let finishedDescriptor {
                setState(.downloaded, for: finishedDescriptor)
            }
            return
        }

        currentPlaybackPrimary = nil
        if let finishedDescriptor {
            setState(.downloaded, for: finishedDescriptor)
        }
    }

    private func setState(_ state: VoiceMessagePlaybackState, for descriptor: VoiceMessageDescriptor) {
        let previousState = states[descriptor.referencePrimary]
        states[descriptor.referencePrimary] = state
        let change = VoiceMessageStateChange(
            referencePrimary: descriptor.referencePrimary,
            containerMessagePrimary: descriptor.containerMessagePrimary,
            state: state,
            previousState: previousState
        )
        observers.values.forEach { $0(change) }
    }

    private func nextVisibleVoiceMessageAfter(_ referencePrimary: String) -> VoiceMessageDescriptor? {
        guard let index = visibleVoiceMessagesInPlaybackOrder.firstIndex(where: { $0.referencePrimary == referencePrimary }) else {
            return nil
        }
        let nextIndex = visibleVoiceMessagesInPlaybackOrder.index(after: index)
        guard visibleVoiceMessagesInPlaybackOrder.indices.contains(nextIndex) else {
            return nil
        }
        return descriptors[visibleVoiceMessagesInPlaybackOrder[nextIndex].referencePrimary] ?? visibleVoiceMessagesInPlaybackOrder[nextIndex]
    }

    private func route(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackRoute? {
        if let route = routes[descriptor.referencePrimary] {
            return route
        }

        guard let route = resolveRoute(for: descriptor) else {
            return nil
        }
        routes[descriptor.referencePrimary] = route
        return route
    }

    private func resolveRoute(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackRoute? {
        do {
            let realm = try WRealm.safe()
            let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: descriptor.referencePrimary)
            let messagePrimary = reference?.messageId.isEmpty == false
                ? reference?.messageId
                : descriptor.containerMessagePrimary
            guard let messagePrimary, messagePrimary.isNotEmpty else {
                return nil
            }

            let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messagePrimary)
            let owner = message?.owner.isEmpty == false ? message?.owner : reference?.owner
            let jid = message?.opponent.isEmpty == false ? message?.opponent : reference?.jid
            guard let owner, owner.isNotEmpty,
                  let jid, jid.isNotEmpty else {
                return nil
            }

            let archivedId = message?.archivedId.isEmpty == false ? message?.archivedId : nil
            return VoiceMessagePlaybackRoute(
                owner: owner,
                jid: jid,
                conversationType: message?.conversationType ?? reference?.conversationType ?? .regular,
                messagePrimary: messagePrimary,
                archivedId: archivedId,
                sourceDate: message?.date ?? reference?.sentDate ?? descriptor.sentDate
            )
        } catch {
            DDLogDebug("VoiceMessagePlaybackCoordinator: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func uniqueOrderedDescriptors(_ descriptors: [VoiceMessageDescriptor]) -> [VoiceMessageDescriptor] {
        var seen = Set<String>()
        var result: [VoiceMessageDescriptor] = []
        descriptors
            .forEach { descriptor in
                guard !seen.contains(descriptor.referencePrimary) else { return }
                seen.insert(descriptor.referencePrimary)
                result.append(descriptor)
            }
        return result
    }
}

private final class URLSessionVoiceDownloadTask: VoiceMessageDownloadTask {
    private let cancelHandler: () -> Void

    init(cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        cancelHandler()
    }
}

final class URLSessionVoiceMessageDownloader: NSObject, VoiceMessageDownloading {
    private struct Context {
        let descriptor: VoiceMessageDescriptor
        let progress: (Double) -> Void
        let completion: (Result<VoiceMessageDownloadedFile, Error>) -> Void
    }

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private var cancelledTaskIdentifiers = Set<Int>()

    @discardableResult
    func download(
        _ descriptor: VoiceMessageDescriptor,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<VoiceMessageDownloadedFile, Error>) -> Void
    ) -> VoiceMessageDownloadTask {
        guard let remoteURL = descriptor.remoteURL ?? remoteURLFromRealm(referencePrimary: descriptor.referencePrimary) else {
            completion(.failure(AudioMessageReceiverError.urlNotFound))
            return URLSessionVoiceDownloadTask(cancelHandler: {})
        }

        let task = session.downloadTask(with: remoteURL)
        lock.lock()
        contexts[task.taskIdentifier] = Context(descriptor: descriptor, progress: progress, completion: completion)
        lock.unlock()
        task.resume()
        return URLSessionVoiceDownloadTask { [weak self, weak task] in
            guard let self, let task else { return }
            self.lock.lock()
            self.cancelledTaskIdentifiers.insert(task.taskIdentifier)
            self.lock.unlock()
            task.cancel()
        }
    }

    private func remoteURLFromRealm(referencePrimary: String) -> URL? {
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary)?.downloadUrl
        } catch {
            DDLogDebug("URLSessionVoiceMessageDownloader: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func context(for taskIdentifier: Int, remove: Bool = false) -> Context? {
        lock.lock()
        defer { lock.unlock() }
        if remove {
            return contexts.removeValue(forKey: taskIdentifier)
        }
        return contexts[taskIdentifier]
    }

    private func isCancelled(_ taskIdentifier: Int, remove: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelledTaskIdentifiers.contains(taskIdentifier) {
            if remove {
                cancelledTaskIdentifiers.remove(taskIdentifier)
            }
            return true
        }
        return false
    }

    private func prepareDownloadedVoice(location: URL, descriptor: VoiceMessageDescriptor) throws -> VoiceMessageDownloadedFile {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw AudioMessageReceiverError.urlNotFound
        }
        let localOGG = cacheDirectory.appendingPathComponent("\(NanoID.new(10)).ogg")
        try? FileManager.default.removeItem(at: localOGG)
        try FileManager.default.moveItem(at: location, to: localOGG)
        let decodedURL = try AudioMessageReceiver.shared.decode(url: localOGG)
        let pcm = try AudioMessageReceiver.shared.getPCM(decoded: decodedURL)
        let duration = TimeInterval(try AudioMessageReceiver.shared.getDuration(decoded: decodedURL))

        do {
            let realm = try WRealm.safe()
            if let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: descriptor.referencePrimary) {
                try realm.write {
                    reference.decodedUrl = decodedURL
                    reference.meteringLevels = pcm
                    reference.duration = Int(duration)
                    reference.isDownloaded = true
                }
            }
        } catch {
            DDLogDebug("URLSessionVoiceMessageDownloader: \(#function). \(error.localizedDescription)")
            throw error
        }

        return VoiceMessageDownloadedFile(decodedURL: decodedURL, duration: duration, pcm: pcm)
    }
}

extension URLSessionVoiceMessageDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let context = context(for: downloadTask.taskIdentifier) else {
            return
        }
        context.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !isCancelled(downloadTask.taskIdentifier),
              let context = context(for: downloadTask.taskIdentifier, remove: true) else {
            return
        }
        do {
            context.completion(.success(try prepareDownloadedVoice(location: location, descriptor: context.descriptor)))
        } catch {
            context.completion(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let cancelled = isCancelled(task.taskIdentifier, remove: true)
        guard let context = context(for: task.taskIdentifier, remove: true),
              !cancelled else {
            return
        }
        context.completion(.failure(error))
    }
}

final class AudioManagerVoiceMessagePlayer: NSObject, VoiceMessagePlaying {
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        AudioManager.shared.addMulticastDelegate(self)
    }

    var currentTime: TimeInterval {
        AudioManager.shared.player?.currentTime ?? 0
    }

    var duration: TimeInterval {
        AudioManager.shared.player?.duration ?? 0
    }

    var isPlaying: Bool {
        AudioManager.shared.player?.isPlaying ?? false
    }

    @discardableResult
    func start(url: URL, referencePrimary: String, at time: TimeInterval) throws -> TimeInterval {
        let data = try AudioManager.shared.load(url) ?? Data(contentsOf: url)
        AudioManager.shared.player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.m4a.rawValue)
        AudioManager.shared.loadMetadata(reference: referencePrimary)
        let duration = AudioManager.shared.player?.duration ?? 0
        AudioManager.shared.player?.currentTime = min(max(time, 0), duration)
        AudioManager.shared.player?.play()
        return duration
    }

    func pause() {
        AudioManager.shared.player?.pause()
    }

    func resume() {
        AudioManager.shared.player?.play()
    }

    func stop() {
        AudioManager.shared.player?.stop()
        AudioManager.shared.player = nil
    }

    func seek(to time: TimeInterval) {
        AudioManager.shared.player?.currentTime = min(max(time, 0), AudioManager.shared.player?.duration ?? time)
    }
}

extension AudioManagerVoiceMessagePlayer: MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String {
        "voice_message_playback_coordinator_player"
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onFinish?()
    }

    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
    }

    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
    }
}
