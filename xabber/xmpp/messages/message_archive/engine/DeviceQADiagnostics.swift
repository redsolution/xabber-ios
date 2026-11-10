import Foundation

#if DEBUG
/// Numeric-only QA evidence; this flag never supplies archive/account authority.
final class DeviceQADiagnostics {
    enum ChatPhase: Int { case open = 1, content = 2, empty = 3, stable = 4, skeleton = 5, cachedContent = 6 }
    static let fileName = "xabber-device-qa-numeric.jsonl"
    static let maximumFileBytes = 2 * 1024 * 1024
    static let shared = DeviceQADiagnostics(
        enabled: ProcessInfo.processInfo.environment["XABBER_DEVICE_QA_DIAGNOSTICS"] == "1",
        fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName))

    private struct Row: Encodable {
        let v = 1
        var seq: UInt64 = 0, uptime_ns: UInt64 = 0, process: UInt64 = 0
        let event: Int
        let conversation: UInt64
        var context: UInt64? = nil, execution: UInt64? = nil
        var purpose: Int? = nil, branch: Int? = nil, locator: Int? = nil
        var result: Int? = nil, failure_domain: Int? = nil, failure_reason: Int? = nil
        var proof_count: Int? = nil, archive_start: Int? = nil, live_edge: Int? = nil
        var dropped: UInt64? = nil
    }
    private let enabled: Bool, maxBytes: Int
    private let clock: () -> UInt64
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "com.xabber.device-qa.numeric-writer")
    private let encoder = JSONEncoder()
    private let processID = UInt64(ProcessInfo.processInfo.processIdentifier)
    private var codes: [ArchiveConversationKey: UInt64] = [:]
    private var sequence: UInt64 = 0
    private var reservedBytes = 0
    private var overflowed = false, failed = false, launchRecorded = false
    private var handle: FileHandle? // Accessed only on writer.

    init(enabled: Bool, fileURL: URL, maxBytes: Int = DeviceQADiagnostics.maximumFileBytes,
        clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.enabled = enabled
        self.maxBytes = min(Self.maximumFileBytes, max(512, maxBytes))
        self.clock = clock
        encoder.outputFormatting = [.sortedKeys]
        guard enabled else { return }
        writer.async { [self] in
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data().write(to: fileURL) // Truncate only this run's own file.
                handle = try FileHandle(forWritingTo: fileURL)
            } catch { markFailed() }
        }
    }

    func conversationCode(for conversation: ArchiveConversationKey) -> UInt64 {
        guard enabled else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard !overflowed, !failed else { return 0 }
        if let code = codes[conversation] { return code }
        guard codes.count < 4096 else {
            enqueueLocked(Row(event: 99, conversation: 0, dropped: 1))
            overflowed = true
            return 0
        }
        let code = UInt64(codes.count + 1)
        codes[conversation] = code
        return code
    }

    func recordLaunch() {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard !launchRecorded, !overflowed, !failed else { return }
        launchRecorded = true
        enqueueLocked(Row(event: 0, conversation: 0))
    }

    func recordChatOpen(conversation: ArchiveConversationKey, contextCode: UInt64,
        purposeCode: Int = 0) {
        recordChat(.open, conversation: conversation, contextCode: contextCode, purposeCode: purposeCode)
    }

    func recordChat(_ phase: ChatPhase, conversation: ArchiveConversationKey,
        contextCode: UInt64, purposeCode: Int = 0) {
        guard enabled else { return }
        append(Row(event: phase.rawValue, conversation: conversationCode(for: conversation),
            context: contextCode, purpose: purposeCode))
    }

    func recordArchive(conversationCode: UInt64, executionCode: UInt64,
        branch: Int, locator: Int, result: Int = 0, failureDomain: Int = 0,
        failureReason: Int = 0, proofMessageCount: Int? = nil,
        archiveStart: Int? = nil, liveEdge: Int? = nil) {
        guard enabled else { return }
        append(Row(event: 10, conversation: conversationCode, execution: executionCode,
            branch: branch, locator: locator, result: result, failure_domain: failureDomain,
            failure_reason: failureReason, proof_count: proofMessageCount,
            archive_start: archiveStart, live_edge: liveEdge))
    }

    var isEnabled: Bool { enabled }

    /// Event20 uses branch/result for stage/rejection bits, never product data.
    func recordSavedCache(stage: Int, rejectionMask: Int = 0,
        conversation: ArchiveConversationKey, contextCode: UInt64, purposeCode: Int = 0) {
        guard enabled else { return }
        append(Row(event: 20, conversation: conversationCode(for: conversation),
            context: contextCode, purpose: purposeCode, branch: stage, result: rejectionMask))
    }

    private func append(_ row: Row) {
        lock.lock(); defer { lock.unlock() }
        guard !overflowed, !failed else { return }
        enqueueLocked(row)
    }

    /// Lock reservation bounds both queued Data and disk bytes. The reserved
    /// 256 bytes fit an overflow row with maximum-width UInt64 values.
    private func enqueueLocked(_ template: Row) {
        var row = template
        row.seq = sequence + 1; row.uptime_ns = clock(); row.process = processID
        guard var data = try? encoder.encode(row) else { failed = true; return }
        data.append(0x0a)
        if reservedBytes + data.count + 256 > maxBytes {
            row = Row(seq: row.seq, uptime_ns: row.uptime_ns, process: processID,
                event: 99, conversation: 0, dropped: 1)
            guard let overflow = try? encoder.encode(row) else { failed = true; return }
            data = overflow; data.append(0x0a)
            overflowed = true
        }
        guard reservedBytes + data.count <= maxBytes else { failed = true; return }
        sequence = row.seq; reservedBytes += data.count
        writer.async { [self, data] in
            do {
                guard let handle else { markFailed(); return }
                try handle.write(contentsOf: data)
            } catch { markFailed() }
        }
    }

    private func markFailed() {
        lock.lock(); failed = true; lock.unlock()
    }

    /// Collection/test barrier only. Ordinary event calls never wait for I/O.
    func flush() {
        guard enabled else { return }
        writer.sync {
            do { try handle?.synchronize() } catch { markFailed() }
        }
    }
}
#endif
