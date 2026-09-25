import Foundation

/// This file is compiled into the app and notification service extension. Both
/// processes must agree on the same marker before either reads account data.
final class PasscodeWipeMarkerStore {
    static let markerName = "wipe-pending-v1"
    private static let initialGeneration = "initial"

    private struct State: Codable, Equatable {
        let version: Int
        let pending: Bool
        let generation: String

        static let initial = State(
            version: 1,
            pending: false,
            generation: PasscodeWipeMarkerStore.initialGeneration
        )
    }

    enum MarkerError: Error {
        case unavailable
        case invalidContents
        case writeNotDurable
    }

    let markerURL: URL?
    private let fileManager: FileManager

    init(markerURL: URL?, fileManager: FileManager = .default) {
        self.markerURL = markerURL
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> PasscodeWipeMarkerStore {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil,
           environment["XABBER_DISABLE_ACCOUNT_AUTOCONNECT"] == "1",
           environment["XABBER_ISOLATED_STORAGE"] == "1" {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "xabber-hosted-xctest-wipe-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            return PasscodeWipeMarkerStore(
                markerURL: directory.appendingPathComponent(markerName),
                fileManager: fileManager
            )
        }

        let groupID = CredentialsManager.uniqueAccessGroup()
        guard !groupID.isEmpty,
              let groupURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: groupID
              ) else {
            return PasscodeWipeMarkerStore(markerURL: nil, fileManager: fileManager)
        }
        return PasscodeWipeMarkerStore(
            markerURL: groupURL
                .appendingPathComponent("Library/Application Support/PasscodeSecurity", isDirectory: true)
                .appendingPathComponent(markerName),
            fileManager: fileManager
        )
    }

    /// Any I/O error or unknown marker value is treated as pending by UI gates.
    var isPendingOrUnavailable: Bool {
        (try? readPending()) ?? true
    }

    /// A request captures this before it checks `isPendingOrUnavailable`.
    /// Generation and pending status live in one atomically replaced file.
    func readGeneration() throws -> String {
        try readState().generation
    }

    func shouldNeutralizeRequest(
        startGeneration: String?,
        startedPending: Bool = false
    ) -> Bool {
        if startedPending || isPendingOrUnavailable { return true }
        guard let startGeneration,
              let currentGeneration = try? readGeneration() else { return true }
        return startGeneration != currentGeneration
    }

    func readPending() throws -> Bool {
        try readState().pending
    }

    private func readState() throws -> State {
        guard let markerURL else { throw MarkerError.unavailable }
        var parentIsDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: markerURL.deletingLastPathComponent().path,
            isDirectory: &parentIsDirectory
        ), !parentIsDirectory.boolValue {
            throw MarkerError.unavailable
        }
        do {
            let data = try Data(contentsOf: markerURL)
            guard let state = try? JSONDecoder().decode(State.self, from: data),
                  state.version == 1,
                  state.generation == Self.initialGeneration
                    || UUID(uuidString: state.generation) != nil else {
                throw MarkerError.invalidContents
            }
            return state
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return .initial
            }
            throw error
        }
    }

    func markPending() throws {
        try writeState(State(version: 1, pending: true, generation: UUID().uuidString))
    }

    private func writeState(_ state: State) throws {
        guard let markerURL else { throw MarkerError.unavailable }
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: markerURL, options: .atomic)
        guard try readState() == state else { throw MarkerError.writeNotDurable }
    }

    func clearPending() throws {
        guard try readPending() else { return }
        try writeState(State(version: 1, pending: false, generation: UUID().uuidString))
    }
}
