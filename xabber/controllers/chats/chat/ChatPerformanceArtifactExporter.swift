//
//  ChatPerformanceArtifactExporter.swift
//  xabber
//
//  Closed, privacy-safe export used only when an explicit performance-lab
//  environment contract is present. Product identifiers and file paths are
//  never copied into either artifact.
//

import CryptoKit
import Foundation

enum ChatPerformanceArtifactExportEnvironment {
    static let signpostPathKey = "XABBER_CHAT_SIGNPOST_EXPORT_PATH"
    static let markerEventPathKey =
        "XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH"
    static let dataContainerPathKey =
        "XABBER_CHAT_ARTIFACT_DATA_CONTAINER_PATH"
}

enum ChatPerformanceVideoMarkerID: String, CaseIterable, Codable {
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
}

enum ChatPerformanceVideoMarkerVisualCode: String, CaseIterable, Codable {
    case verticalBars = "vertical_bars"
    case checkerboard = "checkerboard"
    case concentricRings = "concentric_rings"
}

enum ChatPerformancePhaseManifest {
    /// Byte-for-byte equivalent to Python's
    /// `json.dumps(value, sort_keys=True, separators=(",", ":"),
    /// ensure_ascii=True).encode("ascii")` for the closed ASCII phase enum.
    static let canonicalJSON: String = {
        let phases = ChatPerformanceSignpostPhase.allCases.map(\.rawValue)
        precondition(phases.allSatisfy { value in
            value.unicodeScalars.allSatisfy(\.isASCII) &&
                !value.contains("\"") &&
                !value.contains("\\")
        })
        let encodedPhases = phases
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        return "{\"phases\":[\(encodedPhases)],\"schema_version\":1}"
    }()

    static let sha256 = digest(canonicalJSON)

    static func code(for phase: ChatPerformanceSignpostPhase) -> Int {
        guard let index = ChatPerformanceSignpostPhase.allCases.firstIndex(of: phase) else {
            preconditionFailure("Every signpost phase must be present in its closed manifest")
        }
        return index + 1
    }

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Stable numeric codes for the only counter fields that can cross the
/// performance-artifact privacy boundary. Adding a field is a schema change
/// and must be reviewed together with the offline validator.
enum ChatPerformancePublicCounterCode: Int, CaseIterable, Codable {
    case operationCode = 1
    case directionCode = 2
    case remoteCode = 3
    case deliveredCount = 4
    case receivedCount = 5
    case expectedCount = 6
    case persistedCount = 7
    case failedCount = 8
    case rejectedFieldCount = 9
    case rowCount = 10
    case sectionCount = 11
    case candidateCount = 12
    case applyCount = 13
    case operationCount = 14
    case resultCode = 15
    case receiptCode = 16
    case visibleRowCount = 17
    case correctionCount = 18
    case frameCode = 19
    case targetCode = 20
    case queryOperationCount = 21
    case mapCount = 22
    case blankFrameCount = 23
    case presentationCode = 24
    case staleCode = 25
    case pageCount = 26
    case itemCount = 27
    case datasetGeneration = 28

    fileprivate init?(fieldName: String) {
        switch fieldName {
        case "operationCode": self = .operationCode
        case "directionCode": self = .directionCode
        case "remoteCode": self = .remoteCode
        case "deliveredCount": self = .deliveredCount
        case "receivedCount": self = .receivedCount
        case "expectedCount": self = .expectedCount
        case "persistedCount": self = .persistedCount
        case "failedCount": self = .failedCount
        case "rejectedFieldCount": self = .rejectedFieldCount
        case "rowCount": self = .rowCount
        case "sectionCount": self = .sectionCount
        case "candidateCount": self = .candidateCount
        case "applyCount": self = .applyCount
        case "operationCount": self = .operationCount
        case "resultCode": self = .resultCode
        case "receiptCode": self = .receiptCode
        case "visibleRowCount": self = .visibleRowCount
        case "correctionCount": self = .correctionCount
        case "frameCode": self = .frameCode
        case "targetCode": self = .targetCode
        case "queryOperationCount": self = .queryOperationCount
        case "mapCount": self = .mapCount
        case "blankFrameCount": self = .blankFrameCount
        case "presentationCode": self = .presentationCode
        case "staleCode": self = .staleCode
        case "pageCount": self = .pageCount
        case "itemCount": self = .itemCount
        case "datasetGeneration": self = .datasetGeneration
        default: return nil
        }
    }
}

enum ChatPerformanceArtifactExportError: Error, Equatable {
    case incompleteEnvironment
    case pathMustBeAbsolute
    case invalidRelativeDestination
    case dataContainerMismatch
    case destinationOutsideContainer
    case duplicateDestination
    case sessionNotActive
    case invalidMarkerTransition
    case incompleteMarkerSequence
    case traceContractMissing
    case incompatibleTraceContract
    case duplicateTraceBinding
    case duplicateVideoRouteBinding
    case invalidVideoRouteBinding
    case unexpectedTraceContext
    case incompleteTraceContract
    case noCorrelatedTraceRecords
    case unsafeTraceRecord
    case unknownCounter
    case invalidRecordOrder
    case destinationExists
    case parentDirectoryMissing
    case artifactWriteFailed

    var diagnosticFailureCode: ChatPerformanceArtifactExportFailureCode {
        switch self {
        case .incompleteEnvironment: return .incompleteEnvironment
        case .pathMustBeAbsolute: return .pathMustBeAbsolute
        case .invalidRelativeDestination: return .invalidRelativeDestination
        case .dataContainerMismatch: return .dataContainerMismatch
        case .destinationOutsideContainer: return .destinationOutsideContainer
        case .duplicateDestination: return .duplicateDestination
        case .sessionNotActive: return .sessionNotActive
        case .invalidMarkerTransition: return .invalidMarkerTransition
        case .incompleteMarkerSequence: return .incompleteMarkerSequence
        case .traceContractMissing: return .traceContractMissing
        case .incompatibleTraceContract: return .incompatibleTraceContract
        case .duplicateTraceBinding: return .duplicateTraceBinding
        case .duplicateVideoRouteBinding: return .duplicateVideoRouteBinding
        case .invalidVideoRouteBinding: return .invalidVideoRouteBinding
        case .unexpectedTraceContext: return .unexpectedTraceContext
        case .incompleteTraceContract: return .incompleteTraceContract
        case .noCorrelatedTraceRecords: return .noCorrelatedTraceRecords
        case .unsafeTraceRecord: return .unsafeTraceRecord
        case .unknownCounter: return .unknownCounter
        case .invalidRecordOrder: return .invalidRecordOrder
        case .destinationExists: return .destinationExists
        case .parentDirectoryMissing: return .parentDirectoryMissing
        case .artifactWriteFailed: return .artifactWriteFailed
        }
    }
}

/// Closed, identifier-free reason exported only through the performance-lab
/// accessibility receipt. This preserves the exact fail-closed boundary
/// without exposing a filesystem path, trace identifier or thrown message.
enum ChatPerformanceArtifactExportFailureCode: String, CaseIterable {
    case none = "none"
    case incompleteEnvironment = "incomplete-environment"
    case pathMustBeAbsolute = "path-must-be-absolute"
    case invalidRelativeDestination = "invalid-relative-destination"
    case dataContainerMismatch = "data-container-mismatch"
    case destinationOutsideContainer = "destination-outside-container"
    case duplicateDestination = "duplicate-destination"
    case sessionNotActive = "session-not-active"
    case invalidMarkerTransition = "invalid-marker-transition"
    case incompleteMarkerSequence = "incomplete-marker-sequence"
    case traceContractMissing = "trace-contract-missing"
    case incompatibleTraceContract = "incompatible-trace-contract"
    case duplicateTraceBinding = "duplicate-trace-binding"
    case duplicateVideoRouteBinding = "duplicate-video-route-binding"
    case invalidVideoRouteBinding = "invalid-video-route-binding"
    case unexpectedTraceContext = "unexpected-trace-context"
    case incompleteTraceContract = "incomplete-trace-contract"
    case noCorrelatedTraceRecords = "no-correlated-trace-records"
    case unsafeTraceRecord = "unsafe-trace-record"
    case unknownCounter = "unknown-counter"
    case invalidRecordOrder = "invalid-record-order"
    case destinationExists = "destination-exists"
    case parentDirectoryMissing = "parent-directory-missing"
    case artifactWriteFailed = "artifact-write-failed"
}

enum ChatPerformanceArtifactTraceContractFailureCode: String, CaseIterable {
    case none = "none"
    case requiredRecordMissing = "required-record-missing"
    case requiredRecordDuplicate = "required-record-duplicate"
    case requiredRecordOrder = "required-record-order"
    case forbiddenPhase = "forbidden-phase"
    case intervalCountMismatch = "interval-count-mismatch"
    case intervalTerminalInvalid = "interval-terminal-invalid"
    case noncommittedTerminalCountMismatch =
        "noncommitted-terminal-count-mismatch"
    case noncommittedTerminalInvalid = "noncommitted-terminal-invalid"
    case routeSpecificShapeInvalid = "route-specific-shape-invalid"
}

/// Numeric-only detail for a failed trace contract. Phase, record-kind and
/// terminal values are all members of closed public enums; zero means absent.
/// Counts describe only recorder cardinality and cannot identify a user,
/// conversation, message, query or filesystem location.
struct ChatPerformanceArtifactTraceContractFailureDiagnostics: Equatable {
    let code: ChatPerformanceArtifactTraceContractFailureCode
    let phaseCode: Int
    let relatedPhaseCode: Int
    let recordKindCode: UInt64
    let observedCount: Int
    let expectedCount: Int
    let beginCount: Int
    let endCount: Int
    let terminalCode: UInt64
    let expectedTerminalCode: UInt64

    static let none = ChatPerformanceArtifactTraceContractFailureDiagnostics(
        code: .none,
        phaseCode: 0,
        relatedPhaseCode: 0,
        recordKindCode: 0,
        observedCount: 0,
        expectedCount: 0,
        beginCount: 0,
        endCount: 0,
        terminalCode: 0,
        expectedTerminalCode: 0
    )
}

enum ChatPerformanceArtifactTraceContract: UInt64, Equatable {
    case initialLocalContent = 1
    case initialArchiveContent = 2
    case initialArchiveEmpty = 3
    case linkedArchivePage = 4
    case initialLocalEmpty = 5
    case initialArchiveFailure = 6
    case initialArchiveActiveDwellThenCancel = 7

    fileprivate var requiredKindCode: UInt64 {
        switch self {
        case .initialLocalContent, .initialLocalEmpty,
             .initialArchiveContent, .initialArchiveEmpty,
             .initialArchiveFailure, .initialArchiveActiveDwellThenCancel:
            return ChatOpenPerformanceTraceKind.initialOpen.rawValue
        case .linkedArchivePage:
            return ChatOpenPerformanceTraceKind.paging.rawValue
        }
    }

    fileprivate var isTopLevel: Bool {
        self != .linkedArchivePage
    }
}

final class ChatPerformanceArtifactExportSession {
    static let minimumActiveDwellNanoseconds: UInt64 = 5_000_000_000

    private enum State {
        case active
        case finalizing
        case finalized
        case failed
    }

    private struct MarkerContract {
        let markerID: ChatPerformanceVideoMarkerID
        let visualCode: ChatPerformanceVideoMarkerVisualCode
    }

    private struct TraceBinding: Equatable {
        let context: ChatOpenPerformanceTraceContext
        let contract: ChatPerformanceArtifactTraceContract
    }

    private struct VideoRouteEvidenceBinding: Equatable {
        let matrixRouteCode: String
        let fixtureScenario: String
    }

    private struct RequiredRecord: Equatable {
        let phase: ChatPerformanceSignpostPhase
        let kind: ChatPerformanceTraceRecord.Kind
        let terminal: ChatPerformanceIntervalTerminal?

        func matches(_ record: ChatPerformanceTraceRecord) -> Bool {
            record.phase == phase &&
                record.kind == kind &&
                record.terminal == terminal
        }
    }

    private struct TraceContractViolation: Error {
        let diagnostics:
            ChatPerformanceArtifactTraceContractFailureDiagnostics
    }

    private struct MarkerEventDocument: Codable {
        let markerID: ChatPerformanceVideoMarkerID
        let visualCode: ChatPerformanceVideoMarkerVisualCode
        let uptimeNanoseconds: UInt64

        enum CodingKeys: String, CodingKey {
            case markerID = "marker_id"
            case visualCode = "visual_code"
            case uptimeNanoseconds = "uptime_ns"
        }
    }

    private struct MarkerDocument: Codable {
        let schemaVersion: Int
        let markerManifestSHA256: String
        let events: [MarkerEventDocument]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case markerManifestSHA256 = "marker_manifest_sha256"
            case events
        }
    }

    private struct CounterDocument: Codable {
        let code: Int
        let value: Int
    }

    private struct TraceRecordDocument: Codable {
        let sequence: UInt64
        let recordKindCode: UInt64
        let phaseCode: Int
        let traceID: UInt64
        let generation: UInt64
        let operationKindCode: UInt64
        let purposeCode: UInt64
        let terminalCode: UInt64
        let uptimeNanoseconds: UInt64
        let threadCode: UInt64
        let counters: [CounterDocument]

        enum CodingKeys: String, CodingKey {
            case sequence
            case recordKindCode = "record_kind_code"
            case phaseCode = "phase_code"
            case traceID = "trace_id"
            case generation
            case operationKindCode = "operation_kind_code"
            case purposeCode = "purpose_code"
            case terminalCode = "terminal_code"
            case uptimeNanoseconds = "uptime_ns"
            case threadCode = "thread_code"
            case counters
        }
    }

    private struct TraceDocument: Codable {
        let schemaVersion: Int
        let phaseManifestSHA256: String
        let phaseCount: Int
        let matrixRouteCode: String?
        let fixtureScenario: String?
        let records: [TraceRecordDocument]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case phaseManifestSHA256 = "phase_manifest_sha256"
            case phaseCount = "phase_count"
            case matrixRouteCode = "matrix_route_code"
            case fixtureScenario = "fixture_scenario"
            case records
        }
    }

    private static let markerContract: [MarkerContract] = [
        MarkerContract(markerID: .m1, visualCode: .verticalBars),
        MarkerContract(markerID: .m2, visualCode: .checkerboard),
        MarkerContract(markerID: .m3, visualCode: .concentricRings)
    ]

    private static let markerManifestSHA256 = ChatPerformancePhaseManifest.digest(
        markerContract
            .map { "\($0.markerID.rawValue):\($0.visualCode.rawValue)" }
            .joined(separator: "\n")
    )

    private let signpostURL: URL
    private let markerEventURL: URL
    private let dataContainerURL: URL
    private let recorder: ChatPerformanceTraceRecorder
    private let recorderInstallation: ChatPerformanceTraceRecorderInstallation
    private let lock = NSLock()
    private var state = State.active
    private var markerEvents: [MarkerEventDocument] = []
    private var primaryTraceBinding: TraceBinding?
    private var linkedTraceBindings: [ChatOpenPerformanceTraceContext: TraceBinding] = [:]
    private var videoRouteEvidenceBinding: VideoRouteEvidenceBinding?
    private var traceContractFailureDiagnostics:
        ChatPerformanceArtifactTraceContractFailureDiagnostics = .none

    private init(
        signpostURL: URL,
        markerEventURL: URL,
        dataContainerURL: URL,
        monotonicClock: @escaping () -> UInt64
    ) {
        self.signpostURL = signpostURL
        self.markerEventURL = markerEventURL
        self.dataContainerURL = dataContainerURL
        let recorder = ChatPerformanceTraceRecorder(
            monotonicClock: monotonicClock
        )
        self.recorder = recorder
        self.recorderInstallation =
            ChatPerformanceSignposts.installRecorderForTesting(recorder)
    }

    static func makeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationHomeDirectory: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ),
        monotonicClock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> ChatPerformanceArtifactExportSession? {
        let signpostPath = environment[
            ChatPerformanceArtifactExportEnvironment.signpostPathKey
        ]
        let markerEventPath = environment[
            ChatPerformanceArtifactExportEnvironment.markerEventPathKey
        ]
        let dataContainerPath = environment[
            ChatPerformanceArtifactExportEnvironment.dataContainerPathKey
        ]
        if signpostPath == nil,
           markerEventPath == nil,
           dataContainerPath == nil {
            return nil
        }
        guard let signpostPath,
              let markerEventPath,
              dataContainerPath == nil else {
            throw ChatPerformanceArtifactExportError.incompleteEnvironment
        }
        let ownContainerURL = applicationHomeDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let signpostURL = try runtimeDestination(
            for: signpostPath,
            inside: ownContainerURL
        )
        let markerEventURL = try runtimeDestination(
            for: markerEventPath,
            inside: ownContainerURL
        )
        guard signpostURL.path != markerEventURL.path else {
            throw ChatPerformanceArtifactExportError.duplicateDestination
        }
        try validatePairedRouteDestinations(
            signpostPath: signpostPath,
            markerEventPath: markerEventPath
        )
        try validateDestinations(
            [signpostURL, markerEventURL],
            inside: ownContainerURL,
            requireNewFiles: false
        )
        try removeStaleRouteArtifacts([
            signpostURL,
            markerEventURL
        ])
        return ChatPerformanceArtifactExportSession(
            signpostURL: signpostURL,
            markerEventURL: markerEventURL,
            dataContainerURL: ownContainerURL,
            monotonicClock: monotonicClock
        )
    }

    private static func runtimeDestination(
        for relativePath: String,
        inside dataContainerURL: URL
    ) throws -> URL {
        let path = NSString(string: relativePath)
        let components = path.pathComponents
        guard !path.isAbsolutePath,
              components.count == 3,
              components[0] == "Library",
              components[1] == "Caches",
              components[2].count <= 128,
              components[2].hasSuffix(".json"),
              components[2].unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII &&
                    (CharacterSet.alphanumerics.contains(scalar) ||
                        scalar.value == 45 || scalar.value == 46 ||
                        scalar.value == 95)
              }) else {
            throw ChatPerformanceArtifactExportError.invalidRelativeDestination
        }
        let destination = dataContainerURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let expectedParent = dataContainerURL
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let actualParent = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        guard actualParent == expectedParent else {
            throw ChatPerformanceArtifactExportError.invalidRelativeDestination
        }
        return destination
    }

    private static func validatePairedRouteDestinations(
        signpostPath: String,
        markerEventPath: String
    ) throws {
        let prefix = "Library/Caches/chat-open-"
        let signpostSuffix = "-signposts.json"
        let markerSuffix = "-markers.json"
        guard signpostPath.hasPrefix(prefix),
              signpostPath.hasSuffix(signpostSuffix),
              markerEventPath.hasPrefix(prefix),
              markerEventPath.hasSuffix(markerSuffix) else {
            throw ChatPerformanceArtifactExportError.invalidRelativeDestination
        }
        let signpostRoute = signpostPath
            .dropFirst(prefix.count)
            .dropLast(signpostSuffix.count)
        let markerRoute = markerEventPath
            .dropFirst(prefix.count)
            .dropLast(markerSuffix.count)
        guard !signpostRoute.isEmpty,
              signpostRoute == markerRoute else {
            throw ChatPerformanceArtifactExportError.invalidRelativeDestination
        }
    }

    private static func removeStaleRouteArtifacts(
        _ destinations: [URL]
    ) throws {
        let fileManager = FileManager.default
        do {
            for destination in destinations where
                fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw ChatPerformanceArtifactExportError.artifactWriteFailed
                }
                try fileManager.removeItem(at: destination)
            }
        } catch let error as ChatPerformanceArtifactExportError {
            throw error
        } catch {
            throw ChatPerformanceArtifactExportError.artifactWriteFailed
        }
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .failed
    }

    var didFinalizeSuccessfully: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .finalized
    }

    var diagnosticTraceContractFailureCode:
        ChatPerformanceArtifactTraceContractFailureCode {
        lock.lock()
        defer { lock.unlock() }
        return traceContractFailureDiagnostics.code
    }

    var diagnosticTraceContractFailureDetails:
        ChatPerformanceArtifactTraceContractFailureDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return traceContractFailureDiagnostics
    }

    /// A route diagnostic discovered after terminal publication must be able
    /// to revoke an otherwise sealed evidence pair. The in-process state turns
    /// failed before either file is removed, so no later acceptance query can
    /// observe a finalized session while stale artifacts are being discarded.
    func revokeFinalizedEvidenceAcceptance() {
        lock.lock()
        state = .failed
        lock.unlock()
        recorderInstallation.cancel()
        [signpostURL, markerEventURL].forEach { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func bindVideoRouteEvidence(
        matrixRouteCode: String,
        fixtureScenario: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else {
            throw ChatPerformanceArtifactExportError.sessionNotActive
        }
        guard videoRouteEvidenceBinding == nil else {
            state = .failed
            throw ChatPerformanceArtifactExportError.duplicateVideoRouteBinding
        }
        let routeScalars = matrixRouteCode.unicodeScalars
        let scenarioScalars = fixtureScenario.unicodeScalars
        guard !matrixRouteCode.isEmpty,
              matrixRouteCode.count <= 16,
              routeScalars.allSatisfy({
                  $0.isASCII &&
                    (CharacterSet.alphanumerics.contains($0) || $0.value == 45)
              }),
              !fixtureScenario.isEmpty,
              fixtureScenario.count <= 64,
              scenarioScalars.allSatisfy({
                  $0.isASCII &&
                    (CharacterSet.lowercaseLetters.contains($0) ||
                        CharacterSet.decimalDigits.contains($0) ||
                        $0.value == 45)
              }) else {
            state = .failed
            throw ChatPerformanceArtifactExportError.invalidVideoRouteBinding
        }
        videoRouteEvidenceBinding = VideoRouteEvidenceBinding(
            matrixRouteCode: matrixRouteCode,
            fixtureScenario: fixtureScenario
        )
    }

    func bindTraceContext(
        _ context: ChatOpenPerformanceTraceContext,
        contract: ChatPerformanceArtifactTraceContract
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else {
            throw ChatPerformanceArtifactExportError.sessionNotActive
        }
        guard contract.isTopLevel,
              context.kindCode == contract.requiredKindCode else {
            state = .failed
            throw ChatPerformanceArtifactExportError.incompatibleTraceContract
        }
        guard primaryTraceBinding == nil,
              linkedTraceBindings[context] == nil else {
            state = .failed
            throw ChatPerformanceArtifactExportError.duplicateTraceBinding
        }
        primaryTraceBinding = TraceBinding(context: context, contract: contract)
    }

    func bindLinkedTraceContext(
        _ context: ChatOpenPerformanceTraceContext,
        contract: ChatPerformanceArtifactTraceContract = .linkedArchivePage
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else {
            throw ChatPerformanceArtifactExportError.sessionNotActive
        }
        guard primaryTraceBinding != nil,
              !contract.isTopLevel,
              context.kindCode == contract.requiredKindCode else {
            state = .failed
            throw ChatPerformanceArtifactExportError.incompatibleTraceContract
        }
        guard primaryTraceBinding?.context != context,
              linkedTraceBindings[context] == nil else {
            state = .failed
            throw ChatPerformanceArtifactExportError.duplicateTraceBinding
        }
        linkedTraceBindings[context] = TraceBinding(
            context: context,
            contract: contract
        )
    }

    func recordMarkerTransition(
        markerID: ChatPerformanceVideoMarkerID,
        visualCode: ChatPerformanceVideoMarkerVisualCode,
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else {
            throw ChatPerformanceArtifactExportError.sessionNotActive
        }
        let nextIndex = markerEvents.count
        guard nextIndex < Self.markerContract.count else {
            state = .failed
            throw ChatPerformanceArtifactExportError.invalidMarkerTransition
        }
        let expected = Self.markerContract[nextIndex]
        let hasIncreasingUptime = markerEvents.last.map {
            uptimeNanoseconds > $0.uptimeNanoseconds
        } ?? (uptimeNanoseconds > 0)
        guard markerID == expected.markerID,
              visualCode == expected.visualCode,
              hasIncreasingUptime else {
            state = .failed
            throw ChatPerformanceArtifactExportError.invalidMarkerTransition
        }
        markerEvents.append(MarkerEventDocument(
            markerID: markerID,
            visualCode: visualCode,
            uptimeNanoseconds: uptimeNanoseconds
        ))
    }

    func finalize() throws {
        let markers: [MarkerEventDocument]
        let traceBindings: [TraceBinding]
        let videoRouteEvidenceBinding: VideoRouteEvidenceBinding?
        lock.lock()
        guard state == .active else {
            lock.unlock()
            throw ChatPerformanceArtifactExportError.sessionNotActive
        }
        state = .finalizing
        markers = markerEvents
        videoRouteEvidenceBinding = self.videoRouteEvidenceBinding
        if let primaryTraceBinding {
            traceBindings = [primaryTraceBinding] + linkedTraceBindings.values
                .sorted { lhs, rhs in
                    if lhs.context.traceID == rhs.context.traceID {
                        return lhs.context.generation < rhs.context.generation
                    }
                    return lhs.context.traceID < rhs.context.traceID
                }
        } else {
            traceBindings = []
        }
        lock.unlock()

        // Cancellation is linearized with all publishers. The snapshot below
        // is therefore closed: no later trace record can enter this session.
        recorderInstallation.cancel()

        do {
            guard markers.count == Self.markerContract.count else {
                throw ChatPerformanceArtifactExportError.incompleteMarkerSequence
            }
            guard !traceBindings.isEmpty else {
                throw ChatPerformanceArtifactExportError.traceContractMissing
            }
            let records = try traceRecords(
                from: recorder.snapshot(),
                bindings: traceBindings
            )
            guard !records.isEmpty else {
                throw ChatPerformanceArtifactExportError.noCorrelatedTraceRecords
            }
            let traceDocument = TraceDocument(
                schemaVersion: 1,
                phaseManifestSHA256: ChatPerformancePhaseManifest.sha256,
                phaseCount: ChatPerformanceSignpostPhase.allCases.count,
                matrixRouteCode: videoRouteEvidenceBinding?.matrixRouteCode,
                fixtureScenario: videoRouteEvidenceBinding?.fixtureScenario,
                records: records
            )
            let markerDocument = MarkerDocument(
                schemaVersion: 1,
                markerManifestSHA256: Self.markerManifestSHA256,
                events: markers
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let traceData = try encoder.encode(traceDocument)
            let markerData = try encoder.encode(markerDocument)
            try Self.writeNewArtifactsAtomically([
                (data: traceData, destination: signpostURL),
                (data: markerData, destination: markerEventURL)
            ], inside: dataContainerURL)
            lock.lock()
            state = .finalized
            lock.unlock()
        } catch let violation as TraceContractViolation {
            lock.lock()
            traceContractFailureDiagnostics = violation.diagnostics
            state = .failed
            lock.unlock()
            throw ChatPerformanceArtifactExportError.incompleteTraceContract
        } catch {
            lock.lock()
            state = .failed
            lock.unlock()
            if let exportError = error as? ChatPerformanceArtifactExportError {
                throw exportError
            }
            throw ChatPerformanceArtifactExportError.artifactWriteFailed
        }
    }

    deinit {
        recorderInstallation.cancel()
    }

    private func traceRecords(
        from snapshot: [ChatPerformanceTraceRecord],
        bindings: [TraceBinding]
    ) throws -> [TraceRecordDocument] {
        let acceptedContexts = Set(bindings.map(\.context))
        let allCorrelated = snapshot.filter { $0.context != nil }
        guard allCorrelated.allSatisfy({ record in
            record.context.map(acceptedContexts.contains) == true
        }) else {
            throw ChatPerformanceArtifactExportError.unexpectedTraceContext
        }
        for binding in bindings {
            let boundRecords = allCorrelated.filter {
                $0.context == binding.context
            }
            guard !boundRecords.isEmpty else {
                throw ChatPerformanceArtifactExportError.noCorrelatedTraceRecords
            }
            try Self.validateTraceContract(
                binding.contract,
                records: boundRecords
            )
        }

        let correlated = allCorrelated.filter { record in
            record.context.map(acceptedContexts.contains) == true
        }
        var previousSequence: UInt64 = 0
        var previousUptimeNanoseconds: UInt64 = 0
        return try correlated.map { record in
            guard record.emissionSequence > previousSequence,
                  record.monotonicNanoseconds >= previousUptimeNanoseconds else {
                throw ChatPerformanceArtifactExportError.invalidRecordOrder
            }
            previousSequence = record.emissionSequence
            previousUptimeNanoseconds = record.monotonicNanoseconds
            guard record.isPrivacySafe,
                  record.sortedCounterNames.count <=
                    ChatPerformanceSignposts.maximumPublicCounterCount,
                  let context = record.context else {
                throw ChatPerformanceArtifactExportError.unsafeTraceRecord
            }
            let counters = try record.sortedCounterNames.map { fieldName in
                guard let code = ChatPerformancePublicCounterCode(
                    fieldName: fieldName
                ) else {
                    throw ChatPerformanceArtifactExportError.unknownCounter
                }
                return CounterDocument(
                    code: code.rawValue,
                    value: record.counter(fieldName)
                )
            }.sorted { $0.code < $1.code }
            return TraceRecordDocument(
                sequence: record.emissionSequence,
                recordKindCode: record.kind.rawValue,
                phaseCode: ChatPerformancePhaseManifest.code(for: record.phase),
                traceID: context.traceID,
                generation: context.generation,
                operationKindCode: context.kindCode,
                purposeCode: context.purposeCode,
                terminalCode: record.terminal?.rawValue ?? 0,
                uptimeNanoseconds: record.monotonicNanoseconds,
                threadCode: record.threadCode,
                counters: counters
            )
        }
    }

    private static func validateTraceContract(
        _ contract: ChatPerformanceArtifactTraceContract,
        records: [ChatPerformanceTraceRecord]
    ) throws {
        switch contract {
        case .initialArchiveFailure:
            try validateArchiveFailure(records: records)
            return
        case .initialArchiveActiveDwellThenCancel:
            try validateArchiveActiveDwellThenCancel(records: records)
            return
        case .initialLocalContent, .initialArchiveContent,
             .initialArchiveEmpty, .linkedArchivePage, .initialLocalEmpty:
            break
        }
        if let rejectedTerminal = records.first(where: { record in
            record.terminal == .failed || record.terminal == .cancelled
        }) {
            throw traceContractViolation(
                .intervalTerminalInvalid,
                phase: rejectedTerminal.phase,
                recordKind: rejectedTerminal.kind,
                observedCount: 1,
                expectedCount: 0,
                terminal: rejectedTerminal.terminal,
                expectedTerminal: .committed
            )
        }

        let required = requiredRecords(for: contract)
        _ = try orderedUniqueIndices(required, in: records)
        try validateBalancedIntervals(
            records,
            allowedEndTerminals: [.committed],
            requiredNoncommittedEnd: nil
        )

        let forbidden = forbiddenPhases(for: contract)
        if let forbiddenPhase = records.first(where: {
            forbidden.contains($0.phase)
        })?.phase {
            throw traceContractViolation(
                .forbiddenPhase,
                phase: forbiddenPhase,
                observedCount: records.filter {
                    $0.phase == forbiddenPhase
                }.count,
                expectedCount: 0
            )
        }
    }

    private static func validateArchiveFailure(
        records: [ChatPerformanceTraceRecord]
    ) throws {
        if let invalid = records.first(where: {
            $0.terminal == .cancelled ||
                $0.phase == .contentReceipt ||
                $0.phase == .emptyReceipt ||
                $0.phase == .pagePlan ||
                $0.phase == .pageQuery ||
                $0.phase == .pagePersist ||
                $0.phase == .pageApply
        }) {
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: invalid.phase,
                recordKind: invalid.kind,
                observedCount: 1,
                expectedCount: 0,
                terminal: invalid.terminal
            )
        }
        let failedEnds = records.filter {
            $0.kind == .end && $0.terminal == .failed
        }
        guard failedEnds.count == 1, let failedPhase = failedEnds.first?.phase else {
            throw traceContractViolation(
                .noncommittedTerminalCountMismatch,
                phase: failedEnds.first?.phase,
                recordKind: .end,
                observedCount: failedEnds.count,
                expectedCount: 1,
                terminal: failedEnds.first?.terminal,
                expectedTerminal: .failed
            )
        }
        let prefix: [RequiredRecord] = [
            RequiredRecord(phase: .openRequest, kind: .event, terminal: nil),
            RequiredRecord(phase: .skeletonReceipt, kind: .event, terminal: nil),
            RequiredRecord(phase: .leaseQueued, kind: .begin, terminal: nil),
            RequiredRecord(phase: .leaseQueued, kind: .end, terminal: .committed),
            RequiredRecord(phase: .leaseTransport, kind: .begin, terminal: nil)
        ]
        let required: [RequiredRecord]
        switch failedPhase {
        case .leaseTransport:
            if let invalid = records.first(where: {
                [.rawFinal, .ingressComplete, .leasePersistence,
                 .persistenceTerminal].contains($0.phase)
            }) {
                throw traceContractViolation(
                    .routeSpecificShapeInvalid,
                    phase: invalid.phase,
                    observedCount: 1,
                    expectedCount: 0
                )
            }
            required = prefix + [
                RequiredRecord(
                    phase: .leaseTransport,
                    kind: .end,
                    terminal: .failed
                )
            ]
        case .leasePersistence:
            required = prefix + [
                RequiredRecord(
                    phase: .leaseTransport,
                    kind: .end,
                    terminal: .committed
                ),
                RequiredRecord(phase: .rawFinal, kind: .event, terminal: nil),
                RequiredRecord(
                    phase: .leasePersistence,
                    kind: .begin,
                    terminal: nil
                ),
                RequiredRecord(
                    phase: .ingressComplete,
                    kind: .event,
                    terminal: nil
                ),
                RequiredRecord(
                    phase: .persistenceTerminal,
                    kind: .event,
                    terminal: .failed
                ),
                RequiredRecord(
                    phase: .leasePersistence,
                    kind: .end,
                    terminal: .failed
                )
            ]
        default:
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: failedPhase,
                recordKind: .end,
                observedCount: 1,
                expectedCount: 0,
                terminal: .failed
            )
        }
        let indices = try orderedUniqueIndices(required, in: records)
        let stableIndices = records.indices.filter {
            RequiredRecord(
                phase: .stableFrame,
                kind: .event,
                terminal: nil
            ).matches(records[$0])
        }
        guard stableIndices.count == 1,
              let stableIndex = stableIndices.first,
              let skeletonIndex = indices.dropFirst().first,
              let failedTerminalIndex = indices.last,
              skeletonIndex < stableIndex,
              stableIndex < failedTerminalIndex else {
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: .stableFrame,
                recordKind: .event,
                observedCount: stableIndices.count,
                expectedCount: 1
            )
        }
        try validateBalancedIntervals(
            records,
            allowedEndTerminals: [.committed, .failed],
            requiredNoncommittedEnd: .failed
        )
    }

    private static func validateArchiveActiveDwellThenCancel(
        records: [ChatPerformanceTraceRecord]
    ) throws {
        if let invalid = records.first(where: {
            $0.terminal == .failed ||
                $0.phase == .contentReceipt ||
                $0.phase == .emptyReceipt ||
                $0.phase == .persistenceTerminal ||
                $0.phase == .pagePlan ||
                $0.phase == .pageQuery ||
                $0.phase == .pagePersist ||
                $0.phase == .pageApply
        }) {
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: invalid.phase,
                recordKind: invalid.kind,
                observedCount: 1,
                expectedCount: 0,
                terminal: invalid.terminal
            )
        }
        let cancelledEnds = records.filter {
            $0.kind == .end && $0.terminal == .cancelled
        }
        guard cancelledEnds.count == 1,
              let cancelled = cancelledEnds.first,
              [.leaseQueued, .leaseTransport, .leasePersistence]
                .contains(cancelled.phase) else {
            throw traceContractViolation(
                .noncommittedTerminalCountMismatch,
                phase: cancelledEnds.first?.phase,
                recordKind: .end,
                observedCount: cancelledEnds.count,
                expectedCount: 1,
                terminal: cancelledEnds.first?.terminal,
                expectedTerminal: .cancelled
            )
        }
        var required: [RequiredRecord] = [
            RequiredRecord(phase: .openRequest, kind: .event, terminal: nil),
            RequiredRecord(phase: .skeletonReceipt, kind: .event, terminal: nil),
            RequiredRecord(phase: .leaseQueued, kind: .begin, terminal: nil)
        ]
        switch cancelled.phase {
        case .leaseQueued:
            if let invalid = records.first(where: {
                [.leaseTransport, .rawFinal, .ingressComplete,
                 .leasePersistence].contains($0.phase)
            }) {
                throw traceContractViolation(
                    .routeSpecificShapeInvalid,
                    phase: invalid.phase,
                    observedCount: 1,
                    expectedCount: 0
                )
            }
        case .leaseTransport:
            required += [
                RequiredRecord(
                    phase: .leaseQueued,
                    kind: .end,
                    terminal: .committed
                ),
                RequiredRecord(
                    phase: .leaseTransport,
                    kind: .begin,
                    terminal: nil
                )
            ]
            if let invalid = records.first(where: {
                [.rawFinal, .ingressComplete, .leasePersistence]
                    .contains($0.phase)
            }) {
                throw traceContractViolation(
                    .routeSpecificShapeInvalid,
                    phase: invalid.phase,
                    observedCount: 1,
                    expectedCount: 0
                )
            }
        case .leasePersistence:
            required += [
                RequiredRecord(
                    phase: .leaseQueued,
                    kind: .end,
                    terminal: .committed
                ),
                RequiredRecord(
                    phase: .leaseTransport,
                    kind: .begin,
                    terminal: nil
                ),
                RequiredRecord(
                    phase: .leaseTransport,
                    kind: .end,
                    terminal: .committed
                ),
                RequiredRecord(phase: .rawFinal, kind: .event, terminal: nil),
                RequiredRecord(
                    phase: .leasePersistence,
                    kind: .begin,
                    terminal: nil
                )
            ]
        default:
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: cancelled.phase,
                recordKind: .end,
                observedCount: 1,
                expectedCount: 0,
                terminal: .cancelled
            )
        }
        required.append(RequiredRecord(
            phase: cancelled.phase,
            kind: .end,
            terminal: .cancelled
        ))
        let indices = try orderedUniqueIndices(required, in: records)
        let stableIndices = records.indices.filter {
            RequiredRecord(
                phase: .stableFrame,
                kind: .event,
                terminal: nil
            ).matches(records[$0])
        }
        guard let beginIndex = indices.dropLast().last,
              let endIndex = indices.last,
              stableIndices.count == 1,
              let stableIndex = stableIndices.first,
              let skeletonIndex = indices.dropFirst().first,
              skeletonIndex < stableIndex,
              stableIndex < endIndex,
              records[endIndex].monotonicNanoseconds >=
                records[beginIndex].monotonicNanoseconds,
              records[endIndex].monotonicNanoseconds -
                records[beginIndex].monotonicNanoseconds >=
                minimumActiveDwellNanoseconds,
              records[endIndex].monotonicNanoseconds >=
                records[stableIndex].monotonicNanoseconds,
              records[endIndex].monotonicNanoseconds -
                records[stableIndex].monotonicNanoseconds >=
                minimumActiveDwellNanoseconds else {
            throw traceContractViolation(
                .routeSpecificShapeInvalid,
                phase: .stableFrame,
                recordKind: .event,
                observedCount: stableIndices.count,
                expectedCount: 1
            )
        }
        try validateBalancedIntervals(
            records,
            allowedEndTerminals: [.committed, .cancelled],
            requiredNoncommittedEnd: .cancelled
        )
    }

    private static func traceContractViolation(
        _ code: ChatPerformanceArtifactTraceContractFailureCode,
        phase: ChatPerformanceSignpostPhase? = nil,
        relatedPhase: ChatPerformanceSignpostPhase? = nil,
        recordKind: ChatPerformanceTraceRecord.Kind? = nil,
        observedCount: Int = 0,
        expectedCount: Int = 0,
        beginCount: Int = 0,
        endCount: Int = 0,
        terminal: ChatPerformanceIntervalTerminal? = nil,
        expectedTerminal: ChatPerformanceIntervalTerminal? = nil
    ) -> TraceContractViolation {
        TraceContractViolation(
            diagnostics:
                ChatPerformanceArtifactTraceContractFailureDiagnostics(
                    code: code,
                    phaseCode: phase.map {
                        ChatPerformancePhaseManifest.code(for: $0)
                    } ?? 0,
                    relatedPhaseCode: relatedPhase.map {
                        ChatPerformancePhaseManifest.code(for: $0)
                    } ?? 0,
                    recordKindCode: recordKind?.rawValue ?? 0,
                    observedCount: observedCount,
                    expectedCount: expectedCount,
                    beginCount: beginCount,
                    endCount: endCount,
                    terminalCode: terminal?.rawValue ?? 0,
                    expectedTerminalCode: expectedTerminal?.rawValue ?? 0
                )
        )
    }

    private static func orderedUniqueIndices(
        _ required: [RequiredRecord],
        in records: [ChatPerformanceTraceRecord]
    ) throws -> [Int] {
        var requiredIndices: [Int] = []
        for expected in required {
            let indices = records.indices.filter {
                expected.matches(records[$0])
            }
            guard let index = indices.first, indices.count == 1 else {
                throw traceContractViolation(
                    indices.isEmpty
                        ? .requiredRecordMissing
                        : .requiredRecordDuplicate,
                    phase: expected.phase,
                    recordKind: expected.kind,
                    observedCount: indices.count,
                    expectedCount: 1,
                    terminal: expected.terminal,
                    expectedTerminal: expected.terminal
                )
            }
            requiredIndices.append(index)
        }
        for index in 0..<max(0, requiredIndices.count - 1) where
            requiredIndices[index] >= requiredIndices[index + 1] {
            throw traceContractViolation(
                .requiredRecordOrder,
                phase: required[index].phase,
                relatedPhase: required[index + 1].phase,
                recordKind: required[index].kind,
                observedCount: requiredIndices[index],
                expectedCount: requiredIndices[index + 1],
                terminal: required[index].terminal,
                expectedTerminal: required[index + 1].terminal
            )
        }
        return requiredIndices
    }

    private static func validateBalancedIntervals(
        _ records: [ChatPerformanceTraceRecord],
        allowedEndTerminals: Set<ChatPerformanceIntervalTerminal>,
        requiredNoncommittedEnd: ChatPerformanceIntervalTerminal?
    ) throws {
        var noncommittedEnds: [ChatPerformanceTraceRecord] = []
        for phase in ChatPerformanceSignpostPhase.allCases {
            let begins = records.filter {
                $0.phase == phase && $0.kind == .begin
            }.count
            let ends = records.filter {
                $0.phase == phase && $0.kind == .end
            }
            guard begins == ends.count else {
                throw traceContractViolation(
                    .intervalCountMismatch,
                    phase: phase,
                    observedCount: ends.count,
                    expectedCount: begins,
                    beginCount: begins,
                    endCount: ends.count
                )
            }
            if let invalidEnd = ends.first(where: { record in
                record.terminal.map(allowedEndTerminals.contains) != true
            }) {
                throw traceContractViolation(
                    .intervalTerminalInvalid,
                    phase: phase,
                    recordKind: .end,
                    observedCount: 1,
                    expectedCount: 0,
                    beginCount: begins,
                    endCount: ends.count,
                    terminal: invalidEnd.terminal
                )
            }
            noncommittedEnds += ends.filter { $0.terminal != .committed }
        }
        if let requiredNoncommittedEnd {
            guard noncommittedEnds.count == 1 else {
                throw traceContractViolation(
                    .noncommittedTerminalCountMismatch,
                    phase: noncommittedEnds.first?.phase,
                    recordKind: .end,
                    observedCount: noncommittedEnds.count,
                    expectedCount: 1,
                    terminal: noncommittedEnds.first?.terminal,
                    expectedTerminal: requiredNoncommittedEnd
                )
            }
            guard noncommittedEnds.first?.terminal ==
                    requiredNoncommittedEnd else {
                throw traceContractViolation(
                    .noncommittedTerminalInvalid,
                    phase: noncommittedEnds.first?.phase,
                    recordKind: .end,
                    observedCount: 1,
                    expectedCount: 1,
                    terminal: noncommittedEnds.first?.terminal,
                    expectedTerminal: requiredNoncommittedEnd
                )
            }
        } else if !noncommittedEnds.isEmpty {
            throw traceContractViolation(
                .noncommittedTerminalCountMismatch,
                phase: noncommittedEnds.first?.phase,
                recordKind: .end,
                observedCount: noncommittedEnds.count,
                expectedCount: 0,
                terminal: noncommittedEnds.first?.terminal
            )
        }
    }

    private static func requiredRecords(
        for contract: ChatPerformanceArtifactTraceContract
    ) -> [RequiredRecord] {
        let open = RequiredRecord(
            phase: .openRequest,
            kind: .event,
            terminal: nil
        )
        let localQueryAndPresentation: [RequiredRecord] = [
            RequiredRecord(phase: .localHistoryQuery, kind: .begin, terminal: nil),
            RequiredRecord(phase: .localHistoryQuery, kind: .end, terminal: .committed),
            RequiredRecord(phase: .mapDataset, kind: .begin, terminal: nil),
            RequiredRecord(phase: .mapDataset, kind: .end, terminal: .committed),
            RequiredRecord(phase: .presenting, kind: .begin, terminal: nil),
            RequiredRecord(phase: .presenting, kind: .end, terminal: .committed)
        ]
        let stable = RequiredRecord(
            phase: .stableFrame,
            kind: .event,
            terminal: nil
        )
        let archiveLifecycle: [RequiredRecord] = [
            RequiredRecord(phase: .leaseQueued, kind: .begin, terminal: nil),
            RequiredRecord(phase: .leaseQueued, kind: .end, terminal: .committed),
            RequiredRecord(phase: .leaseTransport, kind: .begin, terminal: nil),
            RequiredRecord(phase: .leaseTransport, kind: .end, terminal: .committed),
            RequiredRecord(phase: .rawFinal, kind: .event, terminal: nil),
            RequiredRecord(phase: .leasePersistence, kind: .begin, terminal: nil),
            RequiredRecord(phase: .ingressComplete, kind: .event, terminal: nil),
            RequiredRecord(
                phase: .persistenceTerminal,
                kind: .event,
                terminal: .committed
            ),
            RequiredRecord(
                phase: .leasePersistence,
                kind: .end,
                terminal: .committed
            )
        ]

        switch contract {
        case .initialLocalContent:
            return [open] + localQueryAndPresentation + [
                RequiredRecord(phase: .contentReceipt, kind: .event, terminal: nil),
                stable
            ]
        case .initialLocalEmpty:
            return [open] + localQueryAndPresentation + [
                RequiredRecord(phase: .emptyReceipt, kind: .event, terminal: nil),
                stable
            ]
        case .initialArchiveContent:
            return [
                open,
                RequiredRecord(phase: .skeletonReceipt, kind: .event, terminal: nil)
            ] + archiveLifecycle + localQueryAndPresentation + [
                RequiredRecord(phase: .contentReceipt, kind: .event, terminal: nil),
                stable
            ]
        case .initialArchiveEmpty:
            return [
                open,
                RequiredRecord(phase: .skeletonReceipt, kind: .event, terminal: nil)
            ] + archiveLifecycle + localQueryAndPresentation + [
                RequiredRecord(phase: .emptyReceipt, kind: .event, terminal: nil),
                stable
            ]
        case .linkedArchivePage:
            return [
                RequiredRecord(phase: .pagePlan, kind: .event, terminal: nil),
                RequiredRecord(phase: .pageQuery, kind: .begin, terminal: nil),
                RequiredRecord(phase: .pageQuery, kind: .end, terminal: .committed),
                RequiredRecord(phase: .rawFinal, kind: .event, terminal: nil),
                RequiredRecord(phase: .pagePersist, kind: .begin, terminal: nil),
                RequiredRecord(phase: .ingressComplete, kind: .event, terminal: nil),
                RequiredRecord(
                    phase: .persistenceTerminal,
                    kind: .event,
                    terminal: .committed
                ),
                RequiredRecord(phase: .pagePersist, kind: .end, terminal: .committed),
                RequiredRecord(phase: .pageApply, kind: .begin, terminal: nil),
                RequiredRecord(phase: .pageApply, kind: .end, terminal: .committed)
            ]
        case .initialArchiveFailure, .initialArchiveActiveDwellThenCancel:
            return []
        }
    }

    private static func forbiddenPhases(
        for contract: ChatPerformanceArtifactTraceContract
    ) -> Set<ChatPerformanceSignpostPhase> {
        switch contract {
        case .initialLocalContent:
            return [
                .leaseQueued,
                .leaseTransport,
                .leasePersistence,
                .rawFinal,
                .ingressComplete,
                .persistenceTerminal,
                .pagePlan,
                .pageQuery,
                .pagePersist,
                .pageApply,
                .skeletonReceipt,
                .emptyReceipt
            ]
        case .initialLocalEmpty:
            return [
                .leaseQueued,
                .leaseTransport,
                .leasePersistence,
                .rawFinal,
                .ingressComplete,
                .persistenceTerminal,
                .pagePlan,
                .pageQuery,
                .pagePersist,
                .pageApply,
                .skeletonReceipt,
                .contentReceipt
            ]
        case .initialArchiveContent:
            return [
                .emptyReceipt,
                .pagePlan,
                .pageQuery,
                .pagePersist,
                .pageApply
            ]
        case .initialArchiveEmpty:
            return [
                .contentReceipt,
                .pagePlan,
                .pageQuery,
                .pagePersist,
                .pageApply
            ]
        case .linkedArchivePage:
            return [
                .openRequest,
                .skeletonReceipt,
                .contentReceipt,
                .emptyReceipt,
                .leaseQueued,
                .leaseTransport,
                .leasePersistence,
                .localHistoryQuery,
                .presenting,
                .stableFrame
            ]
        case .initialArchiveFailure, .initialArchiveActiveDwellThenCancel:
            return []
        }
    }

    private static func writeNewArtifactsAtomically(
        _ artifacts: [(data: Data, destination: URL)],
        inside dataContainerURL: URL
    ) throws {
        let fileManager = FileManager.default
        let destinationPaths = Set(artifacts.map { $0.destination.path })
        guard destinationPaths.count == artifacts.count else {
            throw ChatPerformanceArtifactExportError.duplicateDestination
        }

        try validateDestinations(
            artifacts.map(\.destination),
            inside: dataContainerURL,
            requireNewFiles: true
        )

        var temporaryURLs: [URL] = []
        var publishedURLs: [URL] = []
        do {
            for artifact in artifacts {
                let temporaryURL = artifact.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(artifact.destination.lastPathComponent).\(UUID().uuidString).tmp"
                    )
                try artifact.data.write(
                    to: temporaryURL,
                    options: .withoutOverwriting
                )
                temporaryURLs.append(temporaryURL)
            }
            for (index, artifact) in artifacts.enumerated() {
                try fileManager.linkItem(
                    at: temporaryURLs[index],
                    to: artifact.destination
                )
                publishedURLs.append(artifact.destination)
            }
            temporaryURLs.forEach { try? fileManager.removeItem(at: $0) }
        } catch {
            publishedURLs.forEach { try? fileManager.removeItem(at: $0) }
            temporaryURLs.forEach { try? fileManager.removeItem(at: $0) }
            if let exportError = error as? ChatPerformanceArtifactExportError {
                throw exportError
            }
            throw ChatPerformanceArtifactExportError.artifactWriteFailed
        }
    }

    private static func validateDestinations(
        _ destinations: [URL],
        inside dataContainerURL: URL,
        requireNewFiles: Bool
    ) throws {
        let fileManager = FileManager.default
        let canonicalContainer = dataContainerURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var containerIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: canonicalContainer.path,
            isDirectory: &containerIsDirectory
        ),
              containerIsDirectory.boolValue,
              fileManager.isWritableFile(atPath: canonicalContainer.path) else {
            throw ChatPerformanceArtifactExportError.dataContainerMismatch
        }
        let containerPrefix = canonicalContainer.path.hasSuffix("/")
            ? canonicalContainer.path
            : canonicalContainer.path + "/"

        for destination in destinations {
            guard NSString(string: destination.path).isAbsolutePath else {
                throw ChatPerformanceArtifactExportError.pathMustBeAbsolute
            }
            let parent = destination.deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard parent.path != canonicalContainer.path,
                  parent.path.hasPrefix(containerPrefix) else {
                throw ChatPerformanceArtifactExportError
                    .destinationOutsideContainer
            }
            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: parent.path,
                isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue else {
                throw ChatPerformanceArtifactExportError.parentDirectoryMissing
            }
            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw ChatPerformanceArtifactExportError.artifactWriteFailed
            }
            if requireNewFiles,
               fileManager.fileExists(atPath: destination.path) {
                throw ChatPerformanceArtifactExportError.destinationExists
            }
        }
    }
}
