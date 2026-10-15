import Foundation

/// Debug trace shared by the host and NSE. Each process owns its file so append
/// operations cannot race another extension process; console chunks preserve long XML.
final class PushExtensionDiagnostics {
    let fileURL: URL
    private let lock = NSLock()
    private let console: (String) -> Void
    private let formatter = ISO8601DateFormatter()

    static func isOfflineHostRun(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment["XABBER_PUSH_DIAGNOSTICS_OFFLINE"] == "1"
        #else
        return false
        #endif
    }

    static let shared: PushExtensionDiagnostics = {
        let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CredentialsManager.uniqueAccessGroup()
        ) ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("Library/Logs/PushExtension", isDirectory: true)
        let name = "push-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).log"
        return PushExtensionDiagnostics(fileURL: directory.appendingPathComponent(name))
    }()

    init(fileURL: URL, console: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.fileURL = fileURL
        self.console = console
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        shared.record(message())
        #endif
    }

    static var sink: ((String) -> Void)? {
        #if DEBUG
        return { shared.record($0) }
        #else
        return nil
        #endif
    }

    func record(_ message: String) {
        lock.lock()
        let timestamp = formatter.string(from: Date())
        let prefix = "PUSH_EXTENSION \(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier)"
        var failure: Error?
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(prefix) \(message)\n".utf8))
        } catch { failure = error }
        lock.unlock()

        if let failure { console("\(prefix) event=log_write_failed path=\(fileURL.path) error=\(failure)") }
        let identifier = UUID().uuidString
        var chunks: [String] = []
        var chunk = ""
        var byteCount = 0
        for scalar in message.unicodeScalars {
            let value = String(scalar)
            if byteCount + value.utf8.count > 700 {
                chunks.append(chunk)
                chunk = ""
                byteCount = 0
            }
            chunk.append(value)
            byteCount += value.utf8.count
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        if chunks.isEmpty { chunks = [""] }
        for (index, chunk) in chunks.enumerated() {
            console("\(prefix) id=\(identifier) part=\(index + 1)/\(chunks.count)\n\(chunk)")
        }
    }
}
