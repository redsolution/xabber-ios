//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift
import CocoaLumberjack
import Kingfisher
import SensitiveContentAnalysis

enum SensitiveAnalyzableMediaType: Equatable {
    case image
    case video
    case unsupported
}

enum SensitiveMediaAnalysisPolicy: Equatable {
    case unavailable
    case disabled
    case enabled
}

enum SensitiveMediaAnalysisError: Error, LocalizedError {
    case unavailable
    case disabled
    case unsupportedMedia
    case missingMediaURL
    case encryptedRemoteVideoRequiresLocalFile
    case imageDecodeFailed
    case emptyAnalysisResult
    case unsupportedRemoteURL

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SensitiveContentAnalysis is unavailable."
        case .disabled:
            return "SensitiveContentAnalysis policy is disabled."
        case .unsupportedMedia:
            return "Unsupported media type for SensitiveContentAnalysis."
        case .missingMediaURL:
            return "Missing media URL for SensitiveContentAnalysis."
        case .encryptedRemoteVideoRequiresLocalFile:
            return "Encrypted remote video requires a local decrypted file before analysis."
        case .imageDecodeFailed:
            return "Image could not be decoded for SensitiveContentAnalysis."
        case .emptyAnalysisResult:
            return "SensitiveContentAnalysis returned no result."
        case .unsupportedRemoteURL:
            return "Unsupported remote media URL for SensitiveContentAnalysis."
        }
    }
}

@available(iOS 17.0, *)
private final class SensitiveMediaAnalysisSerialExecutor: SerialExecutor {
    private let queue = DispatchQueue(
        label: "com.xabber.sensitive-media.analysis",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }
}

@available(iOS 17.0, *)
@globalActor
actor SensitiveMediaAnalysisExecutionActor {
    static let shared = SensitiveMediaAnalysisExecutionActor()

    private struct WorkKey: Hashable {
        let serviceID: ObjectIdentifier
        let primaryKey: String
    }

    private struct PendingWork {
        let key: WorkKey
        let service: SensitiveMediaAnalysisService
    }

    private let executor = SensitiveMediaAnalysisSerialExecutor()
    private var pending: [PendingWork] = []
    private var scheduledKeys: Set<WorkKey> = []
    private var waitersByKey: [
        WorkKey: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var isDraining = false

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func submit(
        service: SensitiveMediaAnalysisService,
        primaryKeys: [String]
    ) async {
        for primaryKey in primaryKeys {
            await submitOne(service: service, primaryKey: primaryKey)
        }
    }

    private func submitOne(
        service: SensitiveMediaAnalysisService,
        primaryKey: String
    ) async {
        let key = WorkKey(
            serviceID: ObjectIdentifier(service),
            primaryKey: primaryKey
        )
        await withCheckedContinuation { continuation in
            waitersByKey[key, default: []].append(continuation)
            if scheduledKeys.insert(key).inserted {
                pending.append(PendingWork(key: key, service: service))
            }
            guard !isDraining else {
                return
            }
            isDraining = true
            Task { @SensitiveMediaAnalysisExecutionActor in
                await self.drain()
            }
        }
    }

    private func drain() async {
        // Actor reentrancy may append work while analysis awaits. Only this
        // drain owner invokes analyzers, so async suspension never opens a
        // second analysis slot.
        while pending.isNotEmpty {
            let work = pending.removeFirst()
            await work.service.analyzeMessageReferenceOnExecutor(
                primaryKey: work.key.primaryKey
            )
            scheduledKeys.remove(work.key)
            let waiters = waitersByKey.removeValue(forKey: work.key) ?? []
            waiters.forEach { $0.resume() }
        }
        isDraining = false
    }
}

protocol SensitiveMediaAnalyzing {
    var analysisPolicy: SensitiveMediaAnalysisPolicy { get }

    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    func analyzeImageFile(at url: URL) async throws -> Bool
    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    func analyzeImage(_ cgImage: CGImage) async throws -> Bool
    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    func analyzeVideoFile(at url: URL) async throws -> Bool
}

struct SensitiveMediaAnalysisLocalFile {
    let url: URL
    let shouldDeleteAfterUse: Bool
}

protocol SensitiveMediaFileProviding {
    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    func downloadImageCGImage(from url: URL) async throws -> CGImage
    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    func localVideoFile(from url: URL) async throws -> SensitiveMediaAnalysisLocalFile
}

final class SensitiveMediaAnalysisCoordinator {
    private let lock = NSLock()
    private var inProgress: Set<String> = []

    func begin(_ primaryKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inProgress.contains(primaryKey) else {
            return false
        }
        inProgress.insert(primaryKey)
        return true
    }

    func end(_ primaryKey: String) {
        lock.lock()
        inProgress.remove(primaryKey)
        lock.unlock()
    }
}

final class AppleSensitiveMediaAnalyzer: SensitiveMediaAnalyzing {
    var analysisPolicy: SensitiveMediaAnalysisPolicy {
        guard #available(iOS 17.0, *) else {
            return .unavailable
        }

        switch SCSensitivityAnalyzer().analysisPolicy {
        case .disabled:
            return .disabled
        default:
            return .enabled
        }
    }

    func analyzeImageFile(at url: URL) async throws -> Bool {
        guard #available(iOS 17.0, *) else {
            throw SensitiveMediaAnalysisError.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            SCSensitivityAnalyzer().analyzeImage(at: url) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let result = result {
                    continuation.resume(returning: result.isSensitive)
                } else {
                    continuation.resume(throwing: SensitiveMediaAnalysisError.emptyAnalysisResult)
                }
            }
        }
    }

    func analyzeImage(_ cgImage: CGImage) async throws -> Bool {
        guard #available(iOS 17.0, *) else {
            throw SensitiveMediaAnalysisError.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            SCSensitivityAnalyzer().analyzeImage(cgImage) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let result = result {
                    continuation.resume(returning: result.isSensitive)
                } else {
                    continuation.resume(throwing: SensitiveMediaAnalysisError.emptyAnalysisResult)
                }
            }
        }
    }

    func analyzeVideoFile(at url: URL) async throws -> Bool {
        guard #available(iOS 17.0, *) else {
            throw SensitiveMediaAnalysisError.unavailable
        }

        let handler = SCSensitivityAnalyzer().videoAnalysis(forFileAt: url)
        return try await handler.hasSensitiveContent().isSensitive
    }
}

final class DefaultSensitiveMediaFileProvider: SensitiveMediaFileProviding {
    func downloadImageCGImage(from url: URL) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            ImageDownloader.default.downloadImage(
                with: url,
                options: KingfisherParsedOptionsInfo([
                    .alsoPrefetchToMemory,
                    .cacheOriginalImage,
                    .backgroundDecode,
                    .waitForCache
                ])
            ) { result in
                switch result {
                case .success(let value):
                    if let cgImage = value.image.cgImage {
                        continuation.resume(returning: cgImage)
                    } else {
                        continuation.resume(throwing: SensitiveMediaAnalysisError.imageDecodeFailed)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func localVideoFile(from url: URL) async throws -> SensitiveMediaAnalysisLocalFile {
        if url.isFileURL {
            return SensitiveMediaAnalysisLocalFile(url: url, shouldDeleteAfterUse: false)
        }

        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw SensitiveMediaAnalysisError.unsupportedRemoteURL
        }

        let (downloadedURL, _) = try await URLSession.shared.download(from: url)
        let pathExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-sensitive-video-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try? FileManager.default.removeItem(at: targetURL)
        try FileManager.default.moveItem(at: downloadedURL, to: targetURL)
        return SensitiveMediaAnalysisLocalFile(url: targetURL, shouldDeleteAfterUse: true)
    }
}

struct SensitiveMediaAnalysisAccountTaskDescriptor: Equatable {
    let owner: String
    let primaryKey: String

    var priority: AccountXMPPTaskScheduler.Priority { .idle }
    var resource: AccountXMPPTaskScheduler.Resource { .other("sensitiveMedia") }
    var deduplicationKey: String {
        "sensitiveMedia.\(owner).\(primaryKey)"
    }
}

/// Converts detached reference identities into one account-scheduler task per
/// reference. The scheduler completion is deliberately owned by the analysis
/// callback, so the `.other("sensitiveMedia")` lane remains occupied across
/// every async download/analyzer/persistence suspension.
final class SensitiveMediaAnalysisAccountTaskScheduler {
    typealias ResolveOwners = ([String]) -> [String: String]
    typealias ScheduledWork = (@escaping () -> Void) -> Void
    typealias Enqueue = (
        SensitiveMediaAnalysisAccountTaskDescriptor,
        @escaping ScheduledWork
    ) -> Void
    typealias Analysis = (String, @escaping () -> Void) -> Void

    static let production = SensitiveMediaAnalysisAccountTaskScheduler(
        resolveOwners: { primaryKeys in
            do {
                let realm = try WRealm.safe()
                let references = realm.objects(MessageReferenceStorageItem.self)
                    .filter("primary IN %@", primaryKeys)
                return references.reduce(into: [String: String]()) {
                    result, reference in
                    let owner = reference.owner.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard owner.isNotEmpty else { return }
                    result[reference.primary] = owner
                }
            } catch {
                DDLogDebug(
                    "SensitiveMediaAnalysisAccountTaskScheduler: owner resolution failed. \(error.localizedDescription)"
                )
                return [:]
            }
        },
        enqueue: { task, work in
            guard let account = AccountManager.shared.find(for: task.owner) else {
                return
            }
            account.xmppTaskScheduler.enqueue(
                priority: task.priority,
                resource: task.resource,
                deduplicationKey: task.deduplicationKey,
                requiresAuthenticatedStream: false,
                work: work
            )
        }
    )

    private let resolveOwners: ResolveOwners
    private let enqueue: Enqueue

    init(
        resolveOwners: @escaping ResolveOwners,
        enqueue: @escaping Enqueue
    ) {
        self.resolveOwners = resolveOwners
        self.enqueue = enqueue
    }

    func schedule(
        primaryKeys: [String],
        analysis: @escaping Analysis
    ) {
        let uniquePrimaryKeys = Array(Set(
            primaryKeys.filter { $0.isNotEmpty }
        )).sorted()
        guard uniquePrimaryKeys.isNotEmpty else { return }
        let owners = resolveOwners(uniquePrimaryKeys)
        uniquePrimaryKeys.forEach { primaryKey in
            guard let owner = owners[primaryKey]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), owner.isNotEmpty else {
                return
            }
            let task = SensitiveMediaAnalysisAccountTaskDescriptor(
                owner: owner,
                primaryKey: primaryKey
            )
            enqueue(task) { finish in
                analysis(primaryKey, finish)
            }
        }
    }
}

final class SensitiveMediaAnalysisService {
    typealias AnalysisTaskScheduler = ([String]) -> Void

    static let shared = SensitiveMediaAnalysisService(
        accountTaskScheduler: .production
    )

    static let sourceAppleSCA = "apple_sca"

    private struct Snapshot {
        let primary: String
        let messageId: String
        let owner: String
        let jid: String
        let kind: MessageReferenceStorageItem.Kind
        let mimeType: String?
        let mediaType: String?
        let localFileURL: URL?
        let downloadURL: URL?
        let remoteURLIsEncrypted: Bool
        let failedAt: Date?
        let isSensitiveChecked: Bool
    }

    private let analyzer: SensitiveMediaAnalyzing
    private let fileProvider: SensitiveMediaFileProviding
    private let coordinator: SensitiveMediaAnalysisCoordinator
    private let dateProvider: () -> Date
    private let failureRetryInterval: TimeInterval
    private let analysisTaskScheduler: AnalysisTaskScheduler?
    private let accountTaskScheduler: SensitiveMediaAnalysisAccountTaskScheduler?

    var isAnalysisEnabled: Bool {
        analyzer.analysisPolicy == .enabled
    }

    init(
        analyzer: SensitiveMediaAnalyzing = AppleSensitiveMediaAnalyzer(),
        fileProvider: SensitiveMediaFileProviding = DefaultSensitiveMediaFileProvider(),
        coordinator: SensitiveMediaAnalysisCoordinator = SensitiveMediaAnalysisCoordinator(),
        dateProvider: @escaping () -> Date = Date.init,
        failureRetryInterval: TimeInterval = 6 * 60 * 60,
        analysisTaskScheduler: AnalysisTaskScheduler? = nil,
        accountTaskScheduler: SensitiveMediaAnalysisAccountTaskScheduler? = nil
    ) {
        self.analyzer = analyzer
        self.fileProvider = fileProvider
        self.coordinator = coordinator
        self.dateProvider = dateProvider
        self.failureRetryInterval = failureRetryInterval
        self.analysisTaskScheduler = analysisTaskScheduler
        self.accountTaskScheduler = accountTaskScheduler
    }

    func checkIsSensitive(messageReferencePrimaryKey primaryKey: String) {
        checkIsSensitive(messageReferencePrimaryKeys: [primaryKey])
    }

    func checkIsSensitive(messageReferencePrimaryKeys primaryKeys: [String]) {
        guard analyzer.analysisPolicy == .enabled else {
            return
        }
        let uniquePrimaryKeys = Array(Set(
            primaryKeys.filter { $0.isNotEmpty }
        )).sorted()
        guard uniquePrimaryKeys.isNotEmpty else {
            return
        }
        if let analysisTaskScheduler {
            analysisTaskScheduler(uniquePrimaryKeys)
            return
        }
        if let accountTaskScheduler {
            accountTaskScheduler.schedule(
                primaryKeys: uniquePrimaryKeys
            ) { [weak self] primaryKey, finish in
                guard let self else {
                    finish()
                    return
                }
                guard #available(iOS 17.0, *) else {
                    finish()
                    return
                }
                Task {
                    await self.analyzeMessageReference(primaryKey: primaryKey)
                    finish()
                }
            }
            return
        }
        guard #available(iOS 17.0, *) else {
            return
        }
        Task { @SensitiveMediaAnalysisExecutionActor in
            await SensitiveMediaAnalysisExecutionActor.shared.submit(
                service: self,
                primaryKeys: uniquePrimaryKeys
            )
        }
    }

    func analyzeMessageReference(primaryKey: String) async {
        guard analyzer.analysisPolicy == .enabled else {
            return
        }
        guard #available(iOS 17.0, *) else {
            return
        }
        await SensitiveMediaAnalysisExecutionActor.shared.submit(
            service: self,
            primaryKeys: [primaryKey]
        )
    }

    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    fileprivate func analyzeMessageReferenceOnExecutor(primaryKey: String) async {
        guard analyzer.analysisPolicy == .enabled else {
            return
        }
        guard coordinator.begin(primaryKey) else {
            return
        }
        defer { coordinator.end(primaryKey) }

        await analyzeStartedMessageReference(primaryKey: primaryKey)
    }

    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    private func analyzeStartedMessageReference(primaryKey: String) async {
        guard let snapshot = loadSnapshot(primaryKey: primaryKey) else {
            return
        }

        if snapshot.isSensitiveChecked {
            return
        }

        if let failedAt = snapshot.failedAt,
           dateProvider().timeIntervalSince(failedAt) < failureRetryInterval {
            return
        }

        let mediaType = Self.sensitiveAnalyzableMediaType(
            kind: snapshot.kind,
            mimeType: snapshot.mimeType,
            mediaType: snapshot.mediaType
        )

        guard mediaType != .unsupported else {
            return
        }

        switch analyzer.analysisPolicy {
        case .enabled:
            break
        case .disabled:
            DDLogDebug("SensitiveMediaAnalysisService: analysis policy disabled for \(primaryKey)")
            return
        case .unavailable:
            DDLogDebug("SensitiveMediaAnalysisService: analysis unavailable for \(primaryKey)")
            return
        }

        do {
            let isSensitive: Bool
            switch mediaType {
            case .image:
                isSensitive = try await analyzeImage(snapshot)
            case .video:
                isSensitive = try await analyzeVideo(snapshot)
            case .unsupported:
                return
            }
            persistSuccess(snapshot: snapshot, isSensitive: isSensitive)
        } catch {
            recordFailure(snapshot: snapshot, error: error)
        }
    }

    static func sensitiveAnalyzableMediaType(
        kind: MessageReferenceStorageItem.Kind,
        mimeType: String?,
        mediaType: String?
    ) -> SensitiveAnalyzableMediaType {
        guard kind == .media else {
            return .unsupported
        }

        for candidate in [mediaType, mimeType].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            if candidate == "image" ||
                candidate.hasPrefix("image/") ||
                ["image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/webp"].contains(candidate) {
                return .image
            }

            if candidate == "video" ||
                candidate.hasPrefix("video/") ||
                ["video/mp4", "video/quicktime", "video/mov", "video/x-m4v"].contains(candidate) {
                return .video
            }
        }

        return .unsupported
    }

    private func loadSnapshot(primaryKey: String) -> Snapshot? {
        do {
            let realm = try WRealm.safe()
            guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primaryKey) else {
                return nil
            }

            let metadata = reference.metadata
            return Snapshot(
                primary: reference.primary,
                messageId: reference.messageId,
                owner: reference.owner,
                jid: reference.jid,
                kind: reference.kind,
                mimeType: reference.mimeType,
                mediaType: metadata?["media-type"] as? String,
                localFileURL: reference.localFileUrl,
                downloadURL: reference.downloadUrl,
                remoteURLIsEncrypted: metadata?["encryption-key"] as? String != nil,
                failedAt: reference.sensitivityAnalysisFailedAt,
                isSensitiveChecked: reference.isSensitiveChecked
            )
        } catch {
            DDLogDebug("SensitiveMediaAnalysisService: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    private func analyzeImage(_ snapshot: Snapshot) async throws -> Bool {
        if let localFileURL = snapshot.localFileURL,
           FileManager.default.isReadableFile(atPath: localFileURL.path) {
            return try await analyzer.analyzeImageFile(at: localFileURL)
        }

        guard let downloadURL = snapshot.downloadURL else {
            throw SensitiveMediaAnalysisError.missingMediaURL
        }

        if downloadURL.isFileURL,
           FileManager.default.isReadableFile(atPath: downloadURL.path) {
            return try await analyzer.analyzeImageFile(at: downloadURL)
        }

        let cgImage = try await fileProvider.downloadImageCGImage(from: downloadURL)
        return try await analyzer.analyzeImage(cgImage)
    }

    @available(iOS 17.0, *)
    @SensitiveMediaAnalysisExecutionActor
    private func analyzeVideo(_ snapshot: Snapshot) async throws -> Bool {
        if let localFileURL = snapshot.localFileURL,
           FileManager.default.isReadableFile(atPath: localFileURL.path) {
            return try await analyzer.analyzeVideoFile(at: localFileURL)
        }

        guard let downloadURL = snapshot.downloadURL else {
            throw SensitiveMediaAnalysisError.missingMediaURL
        }

        if downloadURL.isFileURL,
           FileManager.default.isReadableFile(atPath: downloadURL.path) {
            return try await analyzer.analyzeVideoFile(at: downloadURL)
        }

        if snapshot.remoteURLIsEncrypted {
            throw SensitiveMediaAnalysisError.encryptedRemoteVideoRequiresLocalFile
        }

        let localFile = try await fileProvider.localVideoFile(from: downloadURL)
        defer {
            if localFile.shouldDeleteAfterUse {
                try? FileManager.default.removeItem(at: localFile.url)
            }
        }
        return try await analyzer.analyzeVideoFile(at: localFile.url)
    }

    private func persistSuccess(snapshot: Snapshot, isSensitive: Bool) {
        do {
            let realm = try WRealm.safe()
            guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: snapshot.primary) else {
                return
            }

            let now = dateProvider()
            try realm.write {
                reference.isSensitive = isSensitive
                reference.isSensitiveChecked = true
                reference.sensitivityCheckedAt = now
                reference.sensitivityAnalysisFailedAt = nil
                reference.sensitivityAnalysisError = nil
                reference.sensitivitySource = Self.sourceAppleSCA

                updateMediaAttachmentState(
                    in: realm,
                    reference: reference,
                    isSensitive: isSensitive,
                    isSensitiveChecked: true,
                    checkedAt: now,
                    failedAt: nil,
                    error: nil
                )
            }
        } catch {
            DDLogDebug("SensitiveMediaAnalysisService: \(#function). \(error.localizedDescription)")
        }
    }

    private func recordFailure(snapshot: Snapshot, error: Error) {
        do {
            let realm = try WRealm.safe()
            guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: snapshot.primary) else {
                return
            }

            let now = dateProvider()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try realm.write {
                reference.sensitivityAnalysisFailedAt = now
                reference.sensitivityAnalysisError = message

                updateMediaAttachmentState(
                    in: realm,
                    reference: reference,
                    isSensitive: reference.isSensitive,
                    isSensitiveChecked: reference.isSensitiveChecked,
                    checkedAt: reference.sensitivityCheckedAt,
                    failedAt: now,
                    error: message
                )
            }
        } catch {
            DDLogDebug("SensitiveMediaAnalysisService: \(#function). \(error.localizedDescription)")
        }
    }

    private func updateMediaAttachmentState(
        in realm: Realm,
        reference: MessageReferenceStorageItem,
        isSensitive: Bool,
        isSensitiveChecked: Bool,
        checkedAt: Date?,
        failedAt: Date?,
        error: String?
    ) {
        guard let url = reference.url ?? reference.downloadUrl?.absoluteString,
              url.isNotEmpty else {
            return
        }

        let attachments = realm.objects(MessageMediaAttachmentStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND messagePrimary == %@ AND url_ == %@",
                    reference.owner,
                    reference.jid,
                    reference.messageId,
                    url)

        attachments.forEach {
            $0.isSensitive = isSensitive
            $0.isSensitiveChecked = isSensitiveChecked
            $0.sensitivityCheckedAt = checkedAt
            $0.sensitivityAnalysisFailedAt = failedAt
            $0.sensitivityAnalysisError = error
            if isSensitiveChecked {
                $0.sensitivitySource = Self.sourceAppleSCA
            }
        }
    }
}

struct SensitiveMediaAnalysisStartupTaskDescriptor: Equatable {
    let owner: String

    var priority: AccountXMPPTaskScheduler.Priority { .idle }
    var resource: AccountXMPPTaskScheduler.Resource {
        .other("sensitiveMediaStartup")
    }
    var deduplicationKey: String {
        "sensitiveMediaStartup.\(owner)"
    }
}

final class SensitiveMediaAnalysisStartupScheduler {
    typealias AccountScanScheduler = (
        SensitiveMediaAnalysisStartupTaskDescriptor,
        @escaping () -> Void
    ) -> Void

    private static let productionScanQueue = DispatchQueue(
        label: "com.xabber.sensitive-media.startup-scan",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    static let shared = SensitiveMediaAnalysisStartupScheduler(
        scan: {
            MessageReferenceStorageItem.checkAllUndefinedForSensitive()
        },
        isAnalysisEnabled: {
            SensitiveMediaAnalysisService.shared.isAnalysisEnabled
        },
        accountScanScheduler: { task, scan in
            guard let account = AccountManager.shared.find(for: task.owner) else {
                return
            }
            account.xmppTaskScheduler.enqueue(
                priority: task.priority,
                resource: task.resource,
                deduplicationKey: task.deduplicationKey,
                requiresAuthenticatedStream: false
            ) { finish in
                SensitiveMediaAnalysisStartupScheduler.productionScanQueue.async {
                    scan()
                    finish()
                }
            }
        }
    )

    private let lock = NSLock()
    private let scan: () -> Void
    private let isAnalysisEnabled: () -> Bool
    private let accountScanScheduler: AccountScanScheduler
    private var preparedForLaunch = false
    private var onlineAccountJID: String?
    private var scanStarted = false

    init(scan: @escaping () -> Void) {
        self.scan = scan
        self.isAnalysisEnabled = { true }
        self.accountScanScheduler = { _, scan in scan() }
    }

    init(
        scan: @escaping () -> Void,
        isAnalysisEnabled: @escaping () -> Bool = { true },
        accountScanScheduler: @escaping AccountScanScheduler
    ) {
        self.scan = scan
        self.isAnalysisEnabled = isAnalysisEnabled
        self.accountScanScheduler = accountScanScheduler
    }

    func prepareForLaunch() {
        runScanIfNeeded {
            preparedForLaunch = true
        }
    }

    func accountDidReachOnline(jid: String) {
        runScanIfNeeded {
            let normalized = jid.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isNotEmpty {
                onlineAccountJID = normalized
            }
        }
    }

    private func runScanIfNeeded(_ mutation: () -> Void) {
        let analysisIsEnabled = isAnalysisEnabled()
        let accountJID: String?
        lock.lock()
        mutation()
        if analysisIsEnabled,
           preparedForLaunch,
           !scanStarted,
           let onlineAccountJID {
            scanStarted = true
            accountJID = onlineAccountJID
        } else {
            accountJID = nil
        }
        lock.unlock()

        if let accountJID {
            accountScanScheduler(
                SensitiveMediaAnalysisStartupTaskDescriptor(owner: accountJID),
                scan
            )
        }
    }
}
