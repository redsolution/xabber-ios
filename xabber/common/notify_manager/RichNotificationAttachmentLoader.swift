//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
import UIKit

fileprivate final class RichNotificationAttachmentDirectoryRegistry {
    static let shared = RichNotificationAttachmentDirectoryRegistry()

    private struct Entry {
        var activeCount: Int
        var protectedUntil: Date?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func acquire(directory: URL) -> RichNotificationAttachmentDirectoryActivity {
        let path = canonicalPath(directory)
        lock.lock()
        var entry = entries[path] ?? Entry(activeCount: 0, protectedUntil: nil)
        entry.activeCount += 1
        entries[path] = entry
        lock.unlock()
        return RichNotificationAttachmentDirectoryActivity(
            registry: self,
            path: path
        )
    }

    func protectedPaths(at date: Date = Date()) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { _, entry in
            entry.activeCount > 0 || (entry.protectedUntil ?? .distantPast) > date
        }
        return Set(entries.compactMap { path, entry in
            guard entry.activeCount > 0 || (entry.protectedUntil ?? .distantPast) > date else {
                return nil
            }
            return path
        })
    }

    fileprivate func release(
        path: String,
        protectionInterval: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[path] else { return }
        entry.activeCount = max(0, entry.activeCount - 1)
        if protectionInterval > 0 {
            let candidate = Date().addingTimeInterval(protectionInterval)
            entry.protectedUntil = max(entry.protectedUntil ?? .distantPast, candidate)
        }
        if entry.activeCount == 0,
           (entry.protectedUntil ?? .distantPast) <= Date() {
            entries.removeValue(forKey: path)
        } else {
            entries[path] = entry
        }
    }

    private func canonicalPath(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

fileprivate final class RichNotificationAttachmentDirectoryActivity {
    private let registry: RichNotificationAttachmentDirectoryRegistry
    private let path: String
    private let lock = NSLock()
    private var isReleased = false

    init(
        registry: RichNotificationAttachmentDirectoryRegistry,
        path: String
    ) {
        self.registry = registry
        self.path = path
    }

    func release(protectionInterval: TimeInterval = 0) {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        registry.release(
            path: path,
            protectionInterval: protectionInterval
        )
    }

    deinit {
        release()
    }
}

/// Holds staged files active until the notification has been handed to the
/// system. `release()` is idempotent and also runs automatically on deinit.
final class RichNotificationAttachmentLease {
    let attachments: [UNNotificationAttachment]

    private let lock = NSLock()
    private var directoryActivity: RichNotificationAttachmentDirectoryActivity?

    fileprivate init(
        attachments: [UNNotificationAttachment],
        directoryActivity: RichNotificationAttachmentDirectoryActivity?
    ) {
        self.attachments = attachments
        self.directoryActivity = directoryActivity
    }

    func release() {
        release(protectionInterval: 0)
    }

    fileprivate func release(protectionInterval: TimeInterval) {
        lock.lock()
        let activity = directoryActivity
        directoryActivity = nil
        lock.unlock()
        activity?.release(protectionInterval: protectionInterval)
    }

    deinit {
        release()
    }
}

private struct RichNotificationDownloadedFile {
    let url: URL
    let contentType: UTType
    let size: Int64
}

/// Streams one response directly to a staged file. Headers are accepted before
/// the first body byte, and the transfer is cancelled on either byte overflow
/// or the absolute deadline shared by the whole attachment request.
private final class RichNotificationBoundedDownloader: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate {

    typealias ContentTypeValidator = (String) -> UTType?

    private let sourceURL: URL
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let requestDirectory: URL
    private let maximumBytes: Int64
    private let requestTimeout: TimeInterval
    private let deadline: Date
    private let contentTypeValidator: ContentTypeValidator

    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<RichNotificationDownloadedFile?, Never>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var timeoutWorkItem: DispatchWorkItem?
    private var fileHandle: FileHandle?
    private var destinationURL: URL?
    private var responseContentType: UTType?
    private var receivedBytes: Int64 = 0
    private var didComplete = false
    private var cancellationRequested = false

    init(
        sourceURL: URL,
        configuration: URLSessionConfiguration,
        fileManager: FileManager,
        requestDirectory: URL,
        maximumBytes: Int64,
        requestTimeout: TimeInterval,
        deadline: Date,
        contentTypeValidator: @escaping ContentTypeValidator
    ) {
        self.sourceURL = sourceURL
        self.configuration = (configuration.copy() as? URLSessionConfiguration)
            ?? configuration
        self.fileManager = fileManager
        self.requestDirectory = requestDirectory
        self.maximumBytes = maximumBytes
        self.requestTimeout = requestTimeout
        self.deadline = deadline
        self.contentTypeValidator = contentTypeValidator
    }

    func download() async -> RichNotificationDownloadedFile? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                start(continuation: continuation)
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func start(
        continuation: CheckedContinuation<RichNotificationDownloadedFile?, Never>
    ) {
        let remaining = deadline.timeIntervalSinceNow
        guard maximumBytes > 0, remaining > 0 else {
            continuation.resume(returning: nil)
            return
        }

        let configuration = (self.configuration.copy() as? URLSessionConfiguration)
            ?? self.configuration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let transferTimeout = max(0.1, min(requestTimeout, remaining))
        configuration.timeoutIntervalForRequest = transferTimeout
        configuration.timeoutIntervalForResource = transferTimeout
        configuration.waitsForConnectivity = false

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = transferTimeout
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let dataTask = session.dataTask(with: request)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(result: nil, cancelTask: true)
        }

        stateLock.lock()
        if cancellationRequested || didComplete {
            stateLock.unlock()
            session.invalidateAndCancel()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        self.session = session
        self.dataTask = dataTask
        self.timeoutWorkItem = timeoutWorkItem
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + remaining,
            execute: timeoutWorkItem
        )
        dataTask.resume()
    }

    private func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let hasContinuation = continuation != nil
        stateLock.unlock()
        if hasContinuation {
            finish(result: nil, cancelTask: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard deadline.timeIntervalSinceNow > 0,
              let url = request.url,
              PushNotificationMediaURLPolicy.remoteURLString(url.absoluteString) != nil else {
            completionHandler(nil)
            finish(result: nil, cancelTask: true)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard deadline.timeIntervalSinceNow > 0,
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url.flatMap({
                  PushNotificationMediaURLPolicy.remoteURLString($0.absoluteString)
              }) != nil,
              let mimeType = normalizedMIMEType(response.mimeType),
              let contentType = contentTypeValidator(mimeType),
              validExpectedLength(response.expectedContentLength),
              let fileExtension = contentType.preferredFilenameExtension else {
            completionHandler(.cancel)
            finish(result: nil, cancelTask: true)
            return
        }

        let destination = requestDirectory.appendingPathComponent(
            "remote-\(UUID().uuidString).\(fileExtension)"
        )
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            completionHandler(.cancel)
            finish(result: nil, cancelTask: true)
            return
        }

        stateLock.lock()
        guard !didComplete,
              !cancellationRequested,
              deadline.timeIntervalSinceNow > 0 else {
            stateLock.unlock()
            try? handle.close()
            try? fileManager.removeItem(at: destination)
            completionHandler(.cancel)
            finish(result: nil, cancelTask: true)
            return
        }
        fileHandle = handle
        destinationURL = destination
        responseContentType = contentType
        stateLock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        stateLock.lock()
        if didComplete || cancellationRequested || deadline.timeIntervalSinceNow <= 0 {
            shouldCancel = true
        } else {
            let addition = receivedBytes.addingReportingOverflow(Int64(data.count))
            if addition.overflow || addition.partialValue > maximumBytes {
                shouldCancel = true
            } else if let handle = fileHandle {
                do {
                    try handle.write(contentsOf: data)
                    receivedBytes = addition.partialValue
                } catch {
                    shouldCancel = true
                }
            } else {
                shouldCancel = true
            }
        }
        stateLock.unlock()
        if shouldCancel {
            finish(result: nil, cancelTask: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let result: RichNotificationDownloadedFile?
        if error == nil,
           !cancellationRequested,
           deadline.timeIntervalSinceNow > 0,
           receivedBytes > 0,
           receivedBytes <= maximumBytes,
           let destinationURL,
           let responseContentType {
            result = RichNotificationDownloadedFile(
                url: destinationURL,
                contentType: responseContentType,
                size: receivedBytes
            )
        } else {
            result = nil
        }
        stateLock.unlock()
        finish(result: result, cancelTask: result == nil)
    }

    private func validExpectedLength(_ length: Int64) -> Bool {
        length == NSURLSessionTransferSizeUnknown
            || (length > 0 && length <= maximumBytes)
    }

    private func normalizedMIMEType(_ value: String?) -> String? {
        let mimeType = value?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mimeType?.isEmpty == false ? mimeType : nil
    }

    private func finish(
        result: RichNotificationDownloadedFile?,
        cancelTask: Bool
    ) {
        var continuation: CheckedContinuation<RichNotificationDownloadedFile?, Never>?
        var handle: FileHandle?
        var destination: URL?
        var session: URLSession?
        var task: URLSessionDataTask?
        var timeoutWorkItem: DispatchWorkItem?

        stateLock.lock()
        guard !didComplete else {
            stateLock.unlock()
            return
        }
        didComplete = true
        continuation = self.continuation
        self.continuation = nil
        handle = fileHandle
        fileHandle = nil
        destination = destinationURL
        session = self.session
        self.session = nil
        task = dataTask
        dataTask = nil
        timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        stateLock.unlock()

        timeoutWorkItem?.cancel()
        try? handle?.close()
        if result == nil, let destination {
            try? fileManager.removeItem(at: destination)
        }
        if cancelTask {
            task?.cancel()
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(returning: result)
    }
}

/// Safely stages notification media into a request-owned temporary directory.
/// Source files are read or copied only; the loader never moves or deletes them.
final class RichNotificationAttachmentLoader {
    struct Limits: Equatable {
        static let standard = Limits()

        let maximumAttachmentCount: Int
        let maximumImageBytes: Int64
        let maximumVideoBytes: Int64
        let maximumAudioBytes: Int64
        let maximumTotalBytes: Int64
        let maximumImagePixels: Int
        let maximumImageDimension: Int
        let requestTimeout: TimeInterval
        let totalDeadline: TimeInterval
        let staleDirectoryAge: TimeInterval
        let compatibilityRetentionAfterReturn: TimeInterval
        let maximumDirectoryCount: Int
        let maximumAllocatedBytes: Int64

        init(
            maximumAttachmentCount: Int = 3,
            maximumImageBytes: Int64 = 8 * 1024 * 1024,
            maximumVideoBytes: Int64 = 20 * 1024 * 1024,
            maximumAudioBytes: Int64 = 8 * 1024 * 1024,
            maximumTotalBytes: Int64 = 28 * 1024 * 1024,
            maximumImagePixels: Int = 24_000_000,
            maximumImageDimension: Int = 1_600,
            requestTimeout: TimeInterval = 3,
            totalDeadline: TimeInterval = 3,
            staleDirectoryAge: TimeInterval = 24 * 60 * 60,
            compatibilityRetentionAfterReturn: TimeInterval = 5 * 60,
            maximumDirectoryCount: Int = 32,
            maximumAllocatedBytes: Int64 = 96 * 1024 * 1024
        ) {
            self.maximumAttachmentCount = max(0, maximumAttachmentCount)
            self.maximumImageBytes = max(0, maximumImageBytes)
            self.maximumVideoBytes = max(0, maximumVideoBytes)
            self.maximumAudioBytes = max(0, maximumAudioBytes)
            self.maximumTotalBytes = max(0, maximumTotalBytes)
            self.maximumImagePixels = max(0, maximumImagePixels)
            self.maximumImageDimension = max(1, maximumImageDimension)
            self.requestTimeout = max(0.1, requestTimeout)
            self.totalDeadline = max(0.1, totalDeadline)
            self.staleDirectoryAge = max(0, staleDirectoryAge)
            self.compatibilityRetentionAfterReturn = max(
                0,
                compatibilityRetentionAfterReturn
            )
            self.maximumDirectoryCount = max(0, maximumDirectoryCount)
            self.maximumAllocatedBytes = max(0, maximumAllocatedBytes)
        }
    }

    private struct StagedAttachment {
        let attachment: UNNotificationAttachment
        let size: Int64
    }

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let limits: Limits
    private let sessionConfiguration: URLSessionConfiguration
    private let localFileURLsBySource: [String: URL]
    private let directoryRegistry = RichNotificationAttachmentDirectoryRegistry.shared

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        limits: Limits = .standard,
        localFileURLsBySource: [String: URL] = [:]
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "xabber-rich-notification-media",
                isDirectory: true
            )
        self.limits = limits
        self.sessionConfiguration = (configuration.copy() as? URLSessionConfiguration)
            ?? configuration
        self.localFileURLsBySource = localFileURLsBySource
    }

    /// Compatibility API for callers that do not need explicit ownership. The
    /// directory remains protected for a grace period after this method returns.
    func attachments(
        for candidates: [RichNotificationAttachmentCandidate]
    ) async -> [UNNotificationAttachment] {
        let lease = await attachmentLease(for: candidates)
        let attachments = lease.attachments
        lease.release(protectionInterval: limits.compatibilityRetentionAfterReturn)
        return attachments
    }

    /// Preferred API. Keep the lease alive through `UNUserNotificationCenter.add`
    /// or notification-service content completion, then call `release()`.
    func attachmentLease(
        for candidates: [RichNotificationAttachmentCandidate]
    ) async -> RichNotificationAttachmentLease {
        guard limits.maximumAttachmentCount > 0,
              limits.maximumTotalBytes > 0,
              !candidates.isEmpty,
              !Task.isCancelled else {
            return RichNotificationAttachmentLease(
                attachments: [],
                directoryActivity: nil
            )
        }

        let deadline = Date().addingTimeInterval(limits.totalDeadline)
        sweepStaleAttachmentDirectories(reservingBytes: limits.maximumTotalBytes)
        guard deadline.timeIntervalSinceNow > 0, !Task.isCancelled else {
            return RichNotificationAttachmentLease(
                attachments: [],
                directoryActivity: nil
            )
        }

        let requestDirectory = rootDirectory.appendingPathComponent(
            "request-\(UUID().uuidString)",
            isDirectory: true
        )
        let directoryActivity = directoryRegistry.acquire(directory: requestDirectory)
        do {
            try fileManager.createDirectory(
                at: requestDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            directoryActivity.release(protectionInterval: 0)
            return RichNotificationAttachmentLease(
                attachments: [],
                directoryActivity: nil
            )
        }

        var result: [UNNotificationAttachment] = []
        var consumedBytes: Int64 = 0
        for candidate in candidates {
            guard result.count < limits.maximumAttachmentCount,
                  !Task.isCancelled,
                  deadline.timeIntervalSinceNow > 0 else {
                break
            }
            let remainingBytes = max(0, limits.maximumTotalBytes - consumedBytes)
            guard remainingBytes > 0 else { break }

            if let staged = await stagedAttachment(
                for: candidate,
                requestDirectory: requestDirectory,
                deadline: deadline,
                remainingBytes: remainingBytes
            ) {
                result.append(staged.attachment)
                let addition = consumedBytes.addingReportingOverflow(staged.size)
                consumedBytes = addition.overflow ? Int64.max : addition.partialValue
            }
        }

        if result.isEmpty || Task.isCancelled {
            try? fileManager.removeItem(at: requestDirectory)
            directoryActivity.release(protectionInterval: 0)
            return RichNotificationAttachmentLease(
                attachments: [],
                directoryActivity: nil
            )
        }
        return RichNotificationAttachmentLease(
            attachments: result,
            directoryActivity: directoryActivity
        )
    }

    private func stagedAttachment(
        for candidate: RichNotificationAttachmentCandidate,
        requestDirectory: URL,
        deadline: Date,
        remainingBytes: Int64
    ) async -> StagedAttachment? {
        if let attachment = await stagedAttachment(
            kind: candidate.kind,
            source: candidate.sourceURL,
            filename: candidate.filename,
            mediaType: candidate.mediaType,
            requestDirectory: requestDirectory,
            deadline: deadline,
            remainingBytes: remainingBytes
        ) {
            return attachment
        }

        guard candidate.kind == .video,
              let fallback = nonempty(candidate.fallbackImageURL),
              deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled else {
            return nil
        }
        return await stagedAttachment(
            kind: .image,
            source: fallback,
            filename: candidate.filename,
            mediaType: nil,
            requestDirectory: requestDirectory,
            deadline: deadline,
            remainingBytes: remainingBytes
        )
    }

    private func stagedAttachment(
        kind: RichNotificationAttachmentCandidate.Kind,
        source: String,
        filename: String?,
        mediaType: String?,
        requestDirectory: URL,
        deadline: Date,
        remainingBytes: Int64
    ) async -> StagedAttachment? {
        guard !Task.isCancelled,
              deadline.timeIntervalSinceNow > 0 else {
            return nil
        }

        if let localURL = localFileURLsBySource[source] {
            return stagedLocalAttachment(
                kind: kind,
                sourceURL: localURL,
                filename: filename,
                mediaType: mediaType,
                requestDirectory: requestDirectory,
                deadline: deadline,
                remainingBytes: remainingBytes
            )
        }

        if kind == .image, source.hasPrefix("data:image/") {
            guard let data = inlineImageData(from: source, deadline: deadline) else {
                return nil
            }
            return normalizedImageAttachment(
                from: data,
                requestDirectory: requestDirectory,
                deadline: deadline,
                remainingBytes: remainingBytes
            )
        }

        guard let safeURLString = PushNotificationMediaURLPolicy.remoteURLString(source),
              let url = URL(string: safeURLString) else {
            return nil
        }
        let maximumTransferBytes = min(maximumBytes(for: kind), remainingBytes)
        let downloader = RichNotificationBoundedDownloader(
            sourceURL: url,
            configuration: sessionConfiguration,
            fileManager: fileManager,
            requestDirectory: requestDirectory,
            maximumBytes: maximumTransferBytes,
            requestTimeout: limits.requestTimeout,
            deadline: deadline,
            contentTypeValidator: { [weak self] mimeType in
                self?.contentType(for: kind, mimeType: mimeType)
            }
        )
        guard let downloaded = await downloader.download() else {
            return nil
        }

        if kind == .image {
            defer { try? fileManager.removeItem(at: downloaded.url) }
            return normalizedImageAttachment(
                from: downloaded.url,
                requestDirectory: requestDirectory,
                deadline: deadline,
                remainingBytes: remainingBytes
            )
        }
        return makeAttachment(
            at: downloaded.url,
            contentType: downloaded.contentType,
            size: downloaded.size,
            deadline: deadline
        )
    }

    private func stagedLocalAttachment(
        kind: RichNotificationAttachmentCandidate.Kind,
        sourceURL: URL,
        filename: String?,
        mediaType: String?,
        requestDirectory: URL,
        deadline: Date,
        remainingBytes: Int64
    ) -> StagedAttachment? {
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              sourceURL.isFileURL,
              let actualSize = regularFileSize(at: sourceURL),
              validActualSize(
                actualSize,
                kind: kind,
                remainingBytes: remainingBytes
              ) else {
            return nil
        }

        if kind == .image {
            return normalizedImageAttachment(
                from: sourceURL,
                requestDirectory: requestDirectory,
                deadline: deadline,
                remainingBytes: remainingBytes
            )
        }

        guard let contentType = localContentType(
            for: kind,
            sourceURL: sourceURL,
            filename: filename,
            mediaType: mediaType
        ) else {
            return nil
        }
        return copiedMediaAttachment(
            from: sourceURL,
            contentType: contentType,
            size: actualSize,
            requestDirectory: requestDirectory,
            deadline: deadline
        )
    }

    private func inlineImageData(from source: String, deadline: Date) -> Data? {
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              source.utf8.count <= 1_500_000,
              let marker = source.range(of: ";base64,"),
              source[..<marker.lowerBound].hasPrefix("data:image/") else {
            return nil
        }
        let encoded = String(source[marker.upperBound...])
        guard let data = Data(base64Encoded: encoded, options: []),
              deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              !data.isEmpty,
              data.count <= limits.maximumImageBytes else {
            return nil
        }
        return data
    }

    private func normalizedImageAttachment(
        from sourceURL: URL,
        requestDirectory: URL,
        deadline: Date,
        remainingBytes: Int64
    ) -> StagedAttachment? {
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
              deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled else {
            return nil
        }
        return normalizedImageAttachment(
            from: data,
            requestDirectory: requestDirectory,
            deadline: deadline,
            remainingBytes: remainingBytes
        )
    }

    private func normalizedImageAttachment(
        from data: Data,
        requestDirectory: URL,
        deadline: Date,
        remainingBytes: Int64
    ) -> StagedAttachment? {
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              !data.isEmpty,
              data.count <= limits.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled else {
            return nil
        }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow,
              pixelCount.partialValue <= limits.maximumImagePixels else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumImageDimension
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
        deadline.timeIntervalSinceNow > 0,
        !Task.isCancelled else {
            return nil
        }

        let image = UIImage(cgImage: thumbnail)
        let encodings: [(data: Data?, type: UTType)]
        if hasAlpha(thumbnail) {
            encodings = [
                (image.pngData(), .png),
                (image.jpegData(compressionQuality: 0.82), .jpeg)
            ]
        } else {
            encodings = [
                (image.jpegData(compressionQuality: 0.82), .jpeg),
                (image.pngData(), .png)
            ]
        }

        let maximumOutputBytes = min(limits.maximumImageBytes, remainingBytes)
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              let encoding = encodings.first(where: {
                guard let data = $0.data else { return false }
                return !data.isEmpty && Int64(data.count) <= maximumOutputBytes
              }),
              let normalizedData = encoding.data,
              let fileExtension = encoding.type.preferredFilenameExtension else {
            return nil
        }

        let destination = requestDirectory.appendingPathComponent(
            "image-\(UUID().uuidString).\(fileExtension)"
        )
        do {
            try normalizedData.write(to: destination, options: .atomic)
            guard deadline.timeIntervalSinceNow > 0, !Task.isCancelled else {
                try? fileManager.removeItem(at: destination)
                return nil
            }
            return makeAttachment(
                at: destination,
                contentType: encoding.type,
                size: Int64(normalizedData.count),
                deadline: deadline
            )
        } catch {
            return nil
        }
    }

    private func copiedMediaAttachment(
        from sourceURL: URL,
        contentType: UTType,
        size: Int64,
        requestDirectory: URL,
        deadline: Date
    ) -> StagedAttachment? {
        guard deadline.timeIntervalSinceNow > 0,
              !Task.isCancelled,
              let fileExtension = contentType.preferredFilenameExtension else {
            return nil
        }
        let destination = requestDirectory.appendingPathComponent(
            "media-\(UUID().uuidString).\(fileExtension)"
        )
        guard copyFile(
            from: sourceURL,
            to: destination,
            maximumBytes: size,
            deadline: deadline
        ) else {
            return nil
        }
        return makeAttachment(
            at: destination,
            contentType: contentType,
            size: size,
            deadline: deadline
        )
    }

    private func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64,
        deadline: Date
    ) -> Bool {
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil),
              let reader = try? FileHandle(forReadingFrom: sourceURL),
              let writer = try? FileHandle(forWritingTo: destinationURL) else {
            return false
        }
        defer {
            try? reader.close()
            try? writer.close()
        }

        var copiedBytes: Int64 = 0
        do {
            while deadline.timeIntervalSinceNow > 0, !Task.isCancelled {
                guard let data = try reader.read(upToCount: 256 * 1024),
                      !data.isEmpty else {
                    return copiedBytes > 0 && copiedBytes <= maximumBytes
                }
                let addition = copiedBytes.addingReportingOverflow(Int64(data.count))
                guard !addition.overflow,
                      addition.partialValue <= maximumBytes else {
                    break
                }
                try writer.write(contentsOf: data)
                copiedBytes = addition.partialValue
            }
        } catch {
            // The partially copied destination is removed below.
        }
        try? fileManager.removeItem(at: destinationURL)
        return false
    }

    private func makeAttachment(
        at url: URL,
        contentType: UTType,
        size: Int64,
        deadline: Date
    ) -> StagedAttachment? {
        guard deadline.timeIntervalSinceNow > 0, !Task.isCancelled else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        do {
            let options: [AnyHashable: Any] = [
                UNNotificationAttachmentOptionsTypeHintKey: contentType.identifier
            ]
            let attachment = try UNNotificationAttachment(
                identifier: url.lastPathComponent,
                url: url,
                options: options
            )
            guard deadline.timeIntervalSinceNow > 0, !Task.isCancelled else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            return StagedAttachment(attachment: attachment, size: size)
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func localContentType(
        for kind: RichNotificationAttachmentCandidate.Kind,
        sourceURL: URL,
        filename: String?,
        mediaType: String?
    ) -> UTType? {
        if let mediaType = normalizedMIMEType(mediaType),
           let contentType = contentType(for: kind, mimeType: mediaType) {
            return contentType
        }
        if let values = try? sourceURL.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = values.contentType,
           contentTypeMatches(contentType, kind: kind) {
            return contentType
        }
        let extensions = [
            URL(fileURLWithPath: filename ?? "").pathExtension,
            sourceURL.pathExtension
        ]
        for fileExtension in extensions where !fileExtension.isEmpty {
            if let contentType = UTType(filenameExtension: fileExtension),
               contentTypeMatches(contentType, kind: kind) {
                return contentType
            }
        }
        return nil
    }

    private func contentType(
        for kind: RichNotificationAttachmentCandidate.Kind,
        mimeType: String
    ) -> UTType? {
        guard let contentType = UTType(mimeType: mimeType),
              contentTypeMatches(contentType, kind: kind) else {
            return nil
        }
        return contentType
    }

    private func contentTypeMatches(
        _ contentType: UTType,
        kind: RichNotificationAttachmentCandidate.Kind
    ) -> Bool {
        switch kind {
        case .image:
            return contentType.conforms(to: .image)
        case .video:
            return contentType.conforms(to: .movie)
        case .audio:
            return contentType.conforms(to: .audio)
        }
    }

    private func normalizedMIMEType(_ value: String?) -> String? {
        let mimeType = value?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mimeType?.isEmpty == false ? mimeType : nil
    }

    private func validActualSize(
        _ size: Int64,
        kind: RichNotificationAttachmentCandidate.Kind,
        remainingBytes: Int64
    ) -> Bool {
        size > 0
            && size <= maximumBytes(for: kind)
            && size <= remainingBytes
    }

    private func maximumBytes(
        for kind: RichNotificationAttachmentCandidate.Kind
    ) -> Int64 {
        switch kind {
        case .image:
            return limits.maximumImageBytes
        case .video:
            return limits.maximumVideoBytes
        case .audio:
            return limits.maximumAudioBytes
        }
    }

    private func regularFileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ]),
        values.isRegularFile == true,
        let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    private func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func sweepStaleAttachmentDirectories(reservingBytes: Int64) {
        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return
        }

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey
        ]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct DirectoryInfo {
            let url: URL
            let modified: Date
            let allocatedSize: Int64
            let isProtected: Bool
        }

        let now = Date()
        let protectedPaths = directoryRegistry.protectedPaths(at: now)
        let cutoff = now.addingTimeInterval(-limits.staleDirectoryAge)
        var retained: [DirectoryInfo] = []
        for directory in directories where directory.lastPathComponent.hasPrefix("request-") {
            guard let values = try? directory.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true else {
                continue
            }
            let isProtected = protectedPaths.contains(
                directory.standardizedFileURL.resolvingSymlinksInPath().path
            )
            let modified = values.contentModificationDate ?? .distantPast
            if !isProtected,
               modified < cutoff,
               (try? fileManager.removeItem(at: directory)) != nil {
                continue
            }
            retained.append(
                DirectoryInfo(
                    url: directory,
                    modified: modified,
                    allocatedSize: allocatedSize(of: directory),
                    isProtected: isProtected
                )
            )
        }

        retained.sort { $0.modified < $1.modified }
        var totalAllocatedBytes = retained.reduce(Int64(0)) { partial, item in
            let addition = partial.addingReportingOverflow(item.allocatedSize)
            return addition.overflow ? Int64.max : addition.partialValue
        }
        let retainedByteLimit = max(
            0,
            limits.maximumAllocatedBytes - min(
                limits.maximumAllocatedBytes,
                max(0, reservingBytes)
            )
        )
        while retained.count >= limits.maximumDirectoryCount
                || totalAllocatedBytes > retainedByteLimit {
            guard let removableIndex = retained.firstIndex(where: { !$0.isProtected }) else {
                break
            }
            let oldest = retained.remove(at: removableIndex)
            guard (try? fileManager.removeItem(at: oldest.url)) != nil else {
                continue
            }
            totalAllocatedBytes = max(0, totalAllocatedBytes - oldest.allocatedSize)
        }
    }

    private func allocatedSize(of directory: URL) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let addition = total.addingReportingOverflow(size)
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        return total
    }
}
