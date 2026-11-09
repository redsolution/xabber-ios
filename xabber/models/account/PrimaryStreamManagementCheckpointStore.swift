import CryptoKit
import Foundation
import XMPPFramework

struct PrimaryStreamManagementCheckpointIdentity: Codable, Equatable {
    let owner: String
    let configuredResource: String
    let host: String?
    let port: UInt16?
    let authenticationContext: String
}

/// A checkpoint can be published only after the primary transport confirms an empty
/// unacknowledged outgoing queue and the account has accepted the incoming position.
struct PrimaryStreamManagementCheckpoint: Codable, Equatable {
    let boundFullJID: String
    let resumptionID: String
    let timeout: UInt32
    let disconnectedAt: Date
    let lastHandledByClient: UInt32
    let lastHandledByServer: UInt32
}

final class PrimaryStreamManagementCheckpointStore {
    static let shared: PrimaryStreamManagementCheckpointStore = {
        let manager = FileManager.default
        let directory: URL
        if HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment) {
            directory = manager.temporaryDirectory.appendingPathComponent("StreamManagementCheckpoints-\(UUID())")
        } else {
            directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StreamManagementCheckpoints", isDirectory: true)
        }
        return PrimaryStreamManagementCheckpointStore(directory: directory)
    }()

    private struct Record: Codable {
        let version: Int
        let identity: PrimaryStreamManagementCheckpointIdentity
        let checkpoint: PrimaryStreamManagementCheckpoint
    }

    private struct OwnerGeneration {
        let identity: PrimaryStreamManagementCheckpointIdentity
        let id: UUID
    }

    private static let version = 1
    private static let maximumRecordBytes = 16_384
    private static let maximumResumptionIDBytes = 4_096

    private let lock = NSLock()
    private let directory: URL
    private let now: () -> Date
    private var generations = [String: OwnerGeneration]()
    private var pendingInvalidations = Set<String>()

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// The active Account claims ownership. A stale disconnect callback cannot
    /// publish a checkpoint after a replacement Account or an explicit logout.
    func begin(for identity: PrimaryStreamManagementCheckpointIdentity) -> UUID {
        withLock {
            let generation = UUID()
            generations[identity.owner] = OwnerGeneration(identity: identity, id: generation)
            return generation
        }
    }

    func load(for identity: PrimaryStreamManagementCheckpointIdentity, generation: UUID)
        -> PrimaryStreamManagementCheckpoint? {
        withLock {
            guard owns(identity, generation: generation), let checkpoint = readCheckpoint(for: identity) else {
                return nil
            }
            guard hasTimeLeft(checkpoint) else {
                _ = removeCheckpoint(forOwner: identity.owner)
                return nil
            }
            return checkpoint
        }
    }

    /// Claim the exact candidate before the restored stream can send new traffic.
    /// An expired candidate still needs to be retired before standard binding.
    func consume(_ checkpoint: PrimaryStreamManagementCheckpoint,
                 for identity: PrimaryStreamManagementCheckpointIdentity, generation: UUID) -> Bool {
        withLock {
            guard owns(identity, generation: generation), readCheckpoint(for: identity) == checkpoint else {
                return false
            }
            return removeCheckpoint(forOwner: identity.owner)
        }
    }

    @discardableResult
    func save(_ checkpoint: PrimaryStreamManagementCheckpoint,
              for identity: PrimaryStreamManagementCheckpointIdentity, generation: UUID) -> Bool {
        withLock {
            guard owns(identity, generation: generation), isValid(checkpoint, for: identity),
                  hasTimeLeft(checkpoint) else { return false }
            let record = Record(version: Self.version, identity: identity, checkpoint: checkpoint)
            do {
                let data = try JSONEncoder().encode(record)
                guard data.count <= Self.maximumRecordBytes else { return false }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var directory = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                try data.write(to: checkpointURL(forOwner: identity.owner),
                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                return false
            }
        }
    }

    func invalidate(forOwner owner: String) {
        withLock {
            generations.removeValue(forKey: owner)
            _ = removeCheckpoint(forOwner: owner)
        }
    }

    private func owns(_ identity: PrimaryStreamManagementCheckpointIdentity, generation: UUID) -> Bool {
        guard let current = generations[identity.owner], current.id == generation, current.identity == identity else {
            return false
        }
        if pendingInvalidations.contains(identity.owner) {
            return removeCheckpoint(forOwner: identity.owner)
        }
        return true
    }

    private func readCheckpoint(for identity: PrimaryStreamManagementCheckpointIdentity)
        -> PrimaryStreamManagementCheckpoint? {
        let url = checkpointURL(forOwner: identity.owner)
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // Limit reads before decoding an obsolete or corrupt record.
        let data: Data
        do {
            data = try file.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= Self.maximumRecordBytes,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == Self.version,
              record.identity == identity, isValid(record.checkpoint, for: identity) else {
            _ = removeCheckpoint(forOwner: identity.owner)
            return nil
        }
        return record.checkpoint
    }

    private func isValid(_ checkpoint: PrimaryStreamManagementCheckpoint,
                         for identity: PrimaryStreamManagementCheckpointIdentity) -> Bool {
        guard !identity.authenticationContext.isEmpty,
              !checkpoint.resumptionID.isEmpty, checkpoint.resumptionID.utf8.count <= Self.maximumResumptionIDBytes,
              let bound = XMPPJID(string: checkpoint.boundFullJID), bound.bare == identity.owner,
              bound.resource?.isEmpty == false else { return false }
        return true
    }

    private func hasTimeLeft(_ checkpoint: PrimaryStreamManagementCheckpoint) -> Bool {
        let age = now().timeIntervalSince(checkpoint.disconnectedAt)
        return age >= 0 && age < TimeInterval(checkpoint.timeout)
    }

    private func removeCheckpoint(forOwner owner: String) -> Bool {
        let url = checkpointURL(forOwner: owner)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // A missing record is already invalidated.
        } catch {
            pendingInvalidations.insert(owner)
            return false
        }
        pendingInvalidations.remove(owner)
        return true
    }

    private func checkpointURL(forOwner owner: String) -> URL {
        let digest = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
