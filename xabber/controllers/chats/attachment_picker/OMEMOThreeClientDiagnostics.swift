#if DEBUG
import CoreFoundation
import CryptoKit
import Foundation
import RealmSwift
import UIKit

/// Explicit local Debug diagnostics; never registered with startup, URL routing or a network listener.
enum OMEMOThreeClientDiagnosticRole: String {
    case phone = "P", tablet = "T"
    var owner: String { self == .phone ? "igor.boldin@redsolution.com" : "test.omemo.igor@dxs.xabber.com" }
    var peer: String { self == .phone ? "test.omemo.igor@dxs.xabber.com" : "igor.boldin@redsolution.com" }
    var sid: Int { self == .phone ? 201978182 : 504224163 }
    var fingerprint: String {
        self == .phone
            ? "ee9d4725692944420886c725c7039c8a48f04330f1d2af0332380d7d395d3951"
            : "0a0cd7daeded7269eaa6435a13000f694a23c9e63d7ef04055b46909cdbbfd19"
    }
}

enum OMEMOThreeClientDiagnosticFixture: String {
    case png = "QA3-image.png", text = "QA3-document.txt", audio = "QA3-audio.wav"
    case video = "QA3-video.mp4", voice = "QA3-voice.ogg"
    var byteCount: Int {
        switch self { case .png: return 14205; case .text: return 2738; case .audio: return 16044
        case .video: return 1870; case .voice: return 1420 }
    }
    var sha256: String {
        switch self {
        case .png: return "10e3ad9db045757011ccac1be7b224584a2d4a41433c010910423cebf9eb2529"
        case .text: return "37a4be8e8dd6c7fcb7af2a306909b658075b9a00fe1ab8c02be4b64a7d3877d0"
        case .audio: return "c5b99ceef5c83a371360cad83a267daa6fb69cb96525672d353dddcd8fc33e9c"
        case .video: return "0c4ecc8cee6f7bf03ee9ffeac5394e2e0860d3e496e5329f5f94bbbc5cbc063a"
        case .voice: return "c88e7fddcea31b4b04d98b969fb939f79205bf8019fc9726f969099c18c85b83"
        }
    }
    var mime: String {
        switch self { case .png: return "image/png"; case .text: return "text/plain"
        case .audio: return "audio/wav"; case .video: return "video/mp4"; case .voice: return "audio/ogg" }
    }
    var mediaKind: AttachmentMediaKind {
        switch self { case .png: return .image; case .text, .audio: return .file
        case .video: return .video; case .voice: return .audio }
    }
}

struct OMEMOThreeClientDiagnosticSnapshot {
    let bundleIdentifier: String
    let pid: Int
    let owner: String
    let fullJID: String
    let sid: Int
    let fingerprint: String
    let authenticated: Bool
    let canFlush: Bool
}

struct OMEMOThreeClientDiagnosticCommand {
    enum Operation: String { case route, sendAttachment, receiveAttachment }
    let token: String
    let operation: Operation
    let role: OMEMOThreeClientDiagnosticRole
    let expires: TimeInterval
    let expectedPID: Int
    let fixture: OMEMOThreeClientDiagnosticFixture?
    let messageID: String?
    let messageToken: String?
}

enum OMEMOThreeClientDiagnosticPolicy {
    enum Rejection: Error { case invalidCommand, unsafePath, invalidFixture, invalidRuntime }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }
    static func isToken(_ value: String) -> Bool { matches(value, "^QA3-[A-Za-z0-9][A-Za-z0-9._-]{1,59}$") }
    static func isMessageID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil || matches(value, "^[A-Za-z0-9~_]{8}$")
    }
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
    static func decode(_ data: Data, basename: String, now: TimeInterval) throws -> OMEMOThreeClientDiagnosticCommand {
        guard data.count <= 8192, basename.hasSuffix(".json"),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["version", "token", "operation", "role", "expires", "expectedPID", "fixture", "messageID", "messageToken"]),
              number(fields["version"])?.doubleValue == 1,
              let token = fields["token"] as? String, isToken(token), basename == token + ".json",
              let rawOperation = fields["operation"] as? String, let operation = OMEMOThreeClientDiagnosticCommand.Operation(rawValue: rawOperation),
              let rawRole = fields["role"] as? String, let role = OMEMOThreeClientDiagnosticRole(rawValue: rawRole),
              let expires = number(fields["expires"])?.doubleValue, expires.isFinite, expires > now, expires - now <= 300,
              let pid = number(fields["expectedPID"])?.doubleValue, pid.isFinite, pid.rounded() == pid, pid > 1, pid <= Double(Int32.max)
        else { throw Rejection.invalidCommand }
        let fixture = (fields["fixture"] as? String).flatMap(OMEMOThreeClientDiagnosticFixture.init(rawValue:))
        let messageID = fields["messageID"] as? String
        let messageToken = fields["messageToken"] as? String
        switch operation {
        case .route:
            guard fields["fixture"] == nil, fields["messageID"] == nil, fields["messageToken"] == nil else { throw Rejection.invalidCommand }
        case .sendAttachment:
            guard fixture != nil, fields["messageID"] == nil, fields["messageToken"] == nil else { throw Rejection.invalidCommand }
        case .receiveAttachment:
            guard fixture != nil, let messageID, isMessageID(messageID), let messageToken, isToken(messageToken) else { throw Rejection.invalidCommand }
        }
        return .init(token: token, operation: operation, role: role, expires: expires,
                     expectedPID: Int(pid), fixture: fixture, messageID: messageID, messageToken: messageToken)
    }
    static func validate(_ snapshot: OMEMOThreeClientDiagnosticSnapshot?, command: OMEMOThreeClientDiagnosticCommand, now: TimeInterval) throws {
        guard command.expires > now, let snapshot, snapshot.bundleIdentifier == "xabber.ios",
              snapshot.pid == command.expectedPID, snapshot.owner == command.role.owner,
              snapshot.fullJID.hasPrefix(command.role.owner + "/"), snapshot.fullJID != command.role.owner + "/",
              snapshot.sid == command.role.sid,
              snapshot.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == command.role.fingerprint,
              snapshot.authenticated, snapshot.canFlush else { throw Rejection.invalidRuntime }
    }
    static func validateFixtureBytes(_ data: Data, count: Int, sha256: String) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024, data.count == count,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw Rejection.invalidFixture }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Rejection.unsafePath }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= limit, let chunk = try file.read(upToCount: limit + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        guard data.count <= limit else { throw Rejection.invalidCommand }
        return data
    }
    static func acceptsLocalAdmission(_ didAdmit: Bool, _ rowCount: Int, _ outgoing: Bool,
                                     _ body: String, _ token: String, _ referenceCount: Int,
                                     _ protectedReference: Bool, _ noError: Bool) -> Bool {
        didAdmit && rowCount == 1 && outgoing && body == token && referenceCount == 1 && protectedReference && noError
    }
    static func validSender(_ sender: String, sid: Int, fingerprint: String,
                            role: OMEMOThreeClientDiagnosticRole, outgoing: Bool) -> Bool {
        let canonical = fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        let webSID = 1761201430
        let webFingerprint = "868390cb370b3b6ce0e40203807fff0ef0ecbd232a4e3a56ceec64d8ff6c133d"
        if outgoing { return role == .tablet && sender == role.owner && sid == webSID && canonical == webFingerprint }
        guard sender == role.peer else { return false }
        let native: OMEMOThreeClientDiagnosticRole = role == .phone ? .tablet : .phone
        return (sid == native.sid && canonical == native.fingerprint)
            || (role == .phone && sid == webSID && canonical == webFingerprint)
    }
}

struct OMEMOThreeClientDiagnosticExecution {
    let command: OMEMOThreeClientDiagnosticCommand
    let fixtureURL: URL?
    let runtimeSnapshot: OMEMOThreeClientDiagnosticSnapshot
    var context: ChatAttachmentFlowContext {
        .init(owner: command.role.owner, jid: command.role.peer, conversationType: .omemo, forwardedMessageIds: [])
    }
}

struct OMEMOThreeClientDiagnosticOutcome: Encodable {
    enum Stage: String, Encodable { case routeAccepted, routeDeclined, localAdmission, receivedFile, rejected, timedOut }
    let stage: Stage
    let success: Bool
    var messageIDs: [String] = []
    var byteCount: Int? = nil
    var sha256: String? = nil
}

/// File claims/output are confined to disposable QA files. All app state changes go through the normal action sink.
final class OMEMOThreeClientDiagnosticRunner {
    typealias Action = (OMEMOThreeClientDiagnosticExecution, @escaping (OMEMOThreeClientDiagnosticOutcome) -> Void) -> ChatEncryptedAttachmentReceiveTask?
    private let directory: URL
    private let now: () -> TimeInterval
    private let snapshot: (OMEMOThreeClientDiagnosticRole) -> OMEMOThreeClientDiagnosticSnapshot?
    private let schedule: (@escaping () -> Void) -> Void
    private let timeout: (@escaping () -> Void) -> Void
    private let validateFixture: (OMEMOThreeClientDiagnosticFixture, URL) throws -> Data
    private let execute: Action

    init(directory: URL, now: @escaping () -> TimeInterval,
         snapshot: @escaping (OMEMOThreeClientDiagnosticRole) -> OMEMOThreeClientDiagnosticSnapshot?,
         schedule: @escaping (@escaping () -> Void) -> Void, timeout: @escaping (@escaping () -> Void) -> Void,
         validateFixture: @escaping (OMEMOThreeClientDiagnosticFixture, URL) throws -> Data,
         execute: @escaping Action) {
        self.directory = directory.standardizedFileURL; self.now = now; self.snapshot = snapshot
        self.schedule = schedule; self.timeout = timeout; self.validateFixture = validateFixture; self.execute = execute
    }
    func submit(_ basename: String) -> String {
        do {
            guard basename.hasSuffix(".json"), OMEMOThreeClientDiagnosticPolicy.isToken(String(basename.dropLast(5))),
                  directory == directory.resolvingSymlinksInPath().standardizedFileURL else { return "rejected" }
            let bytes = try OMEMOThreeClientDiagnosticPolicy.read(directory.appendingPathComponent(basename), limit: 8192)
            let command = try OMEMOThreeClientDiagnosticPolicy.decode(bytes, basename: basename, now: now())
            guard !FileManager.default.fileExists(atPath: resultURL(command).path) else { return "rejected" }
            try Data().write(to: directory.appendingPathComponent(command.token + ".claim"), options: .withoutOverwriting)
            schedule { [self] in run(command) }
            return "scheduled"
        } catch { return "rejected" }
    }
    private func run(_ command: OMEMOThreeClientDiagnosticCommand) {
        do {
            let runtime = snapshot(command.role)
            try OMEMOThreeClientDiagnosticPolicy.validate(runtime, command: command, now: now())
            guard let runtime else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidRuntime }
            var fixtureURL: URL?
            if command.operation == .sendAttachment, let fixture = command.fixture {
                let source = directory.appendingPathComponent("fixtures").appendingPathComponent(fixture.rawValue)
                let data = try validateFixture(fixture, source)
                let work = directory.appendingPathComponent(command.token, isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
                guard work.standardizedFileURL == work.resolvingSymlinksInPath().standardizedFileURL else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.unsafePath }
                let copy = work.appendingPathComponent(fixture.rawValue)
                try data.write(to: copy, options: .withoutOverwriting)
                fixtureURL = copy
            }
            let task = execute(.init(command: command, fixtureURL: fixtureURL, runtimeSnapshot: runtime)) { [self] outcome in
                if outcome.success {
                    do {
                        let current = snapshot(command.role)
                        try OMEMOThreeClientDiagnosticPolicy.validate(current, command: command, now: now())
                        guard current?.fullJID == runtime.fullJID else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidRuntime }
                    } catch { write(.init(stage: .rejected, success: false), command: command); return }
                }
                write(outcome, command: command)
            }
            timeout { [self] in
                guard !FileManager.default.fileExists(atPath: resultURL(command).path) else { return }
                task?.cancel()
                write(.init(stage: .timedOut, success: false), command: command)
            }
        } catch { write(.init(stage: .rejected, success: false), command: command) }
    }
    private func resultURL(_ command: OMEMOThreeClientDiagnosticCommand) -> URL { directory.appendingPathComponent(command.token + ".result.json") }
    private func write(_ outcome: OMEMOThreeClientDiagnosticOutcome, command: OMEMOThreeClientDiagnosticCommand) {
        do {
            guard outcome.messageIDs.count <= 4, outcome.messageIDs.allSatisfy(OMEMOThreeClientDiagnosticPolicy.isMessageID),
                  outcome.sha256.map({ OMEMOThreeClientDiagnosticPolicy.matches($0, "^[a-f0-9]{64}$") }) ?? true else { return }
            let encoded = try JSONEncoder().encode(outcome)
            var fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            fields["token"] = command.token; fields["operation"] = command.operation.rawValue
            fields["role"] = command.role.rawValue; fields["deliveryProved"] = false
            fields["originalFileByteProof"] = outcome.stage == .receivedFile && outcome.success
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            guard data.count <= 8192 else { return }
            let path = resultURL(command)
            try data.write(to: path, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { /* First bounded result wins, including duplicate callbacks and timeout. */ }
    }
}

/// One primitive ObjC call avoids evaluating Swift/UIKit/Realm generic closures in LLDB.
@objc(XabberOMEMOThreeClientDiagnostics)
final class OMEMOThreeClientDiagnostics: NSObject {
    private static let runner = OMEMOThreeClientDiagnosticRunner(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("qa3-omemo-acceptance", isDirectory: true),
        now: { Date().timeIntervalSince1970 }, snapshot: currentSnapshot,
        schedule: { action in DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: action) },
        timeout: { action in DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: action) },
        validateFixture: { fixture, source in
            let data = try OMEMOThreeClientDiagnosticPolicy.read(source, limit: 2 * 1024 * 1024)
            try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(data, count: fixture.byteCount, sha256: fixture.sha256)
            return data
        }, execute: perform)

    @objc(submitCommandFileName:)
    static func submitCommandFileName(_ basename: String) -> String { runner.submit(basename) }

    private static func currentSnapshot(_ role: OMEMOThreeClientDiagnosticRole) -> OMEMOThreeClientDiagnosticSnapshot? {
        guard let account = AccountManager.shared.find(for: role.owner),
              let storage = account.omemo.omemo2Storage, let bundle = try? storage.localBundle(),
              let fingerprint = try? Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey) else { return nil }
        return .init(bundleIdentifier: Bundle.main.bundleIdentifier ?? "", pid: Int(ProcessInfo.processInfo.processIdentifier),
                     owner: account.xmppStream.myJID?.bare ?? "", fullJID: account.xmppStream.myJID?.full ?? "",
                     sid: Int(bundle.deviceID), fingerprint: fingerprint,
                     authenticated: account.xmppStream.isAuthenticated, canFlush: account.sendReadiness.snapshot.canFlushApplicationStanzas)
    }
    private static func perform(_ request: OMEMOThreeClientDiagnosticExecution,
                                completion: @escaping (OMEMOThreeClientDiagnosticOutcome) -> Void) -> ChatEncryptedAttachmentReceiveTask? {
        guard Thread.isMainThread else { completion(.init(stage: .rejected, success: false)); return nil }
        switch request.command.operation {
        case .route:
            let accepted = AppRootCoordinator.active?.route(.chatMessage(owner: request.context.owner, jid: request.context.jid,
                conversationType: .omemo, openMessageRequest: nil, configure: nil)) ?? false
            completion(.init(stage: accepted ? .routeAccepted : .routeDeclined, success: accepted))
        case .sendAttachment:
            send(request, completion: completion)
        case .receiveAttachment:
            return receive(request, completion: completion)
        }
        return nil
    }
    private static func send(_ request: OMEMOThreeClientDiagnosticExecution,
                             completion: @escaping (OMEMOThreeClientDiagnosticOutcome) -> Void) {
        do {
            guard let source = request.fixtureURL, let fixture = request.command.fixture else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidFixture }
            let realm = try WRealm.safe(); realm.refresh()
            guard realm.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND body CONTAINS %@",
                request.context.owner, request.context.jid, "urn:xmpp:omemo:2", request.command.token).isEmpty else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidCommand }
            let data = try OMEMOThreeClientDiagnosticPolicy.read(source, limit: 2 * 1024 * 1024)
            try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(data, count: fixture.byteCount, sha256: fixture.sha256)
            var dimensions: CGSize?
            if fixture == .png {
                guard let image = UIImage(data: data), let cg = image.cgImage else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidFixture }
                dimensions = CGSize(width: cg.width, height: cg.height)
            }
            let admission: (Bool) -> Void = { didAdmit in
                do {
                    guard didAdmit else { completion(.init(stage: .rejected, success: false)); return }
                    let current = try WRealm.safe(); current.refresh()
                    let rows = current.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND body == %@",
                        request.context.owner, request.context.jid, "urn:xmpp:omemo:2", request.command.token)
                    guard let row = rows.first else { completion(.init(stage: .rejected, success: false)); return }
                    let reference = row.references.first
                    let protected = reference.map { $0.owner == request.context.owner && $0.jid == request.context.jid
                        && $0.conversationType == .omemo && [.media, .voice].contains($0.kind)
                        && ($0.metadata?["encryption-key"] as? String)?.isEmpty == false
                        && ($0.metadata?["iv"] as? String)?.isEmpty == false } ?? false
                    guard OMEMOThreeClientDiagnosticPolicy.acceptsLocalAdmission(didAdmit, rows.count, row.outgoing,
                        row.body, request.command.token, row.references.count, protected,
                        (row.messageError ?? "").isEmpty && (row.messageErrorCode ?? "").isEmpty)
                    else { completion(.init(stage: .rejected, success: false)); return }
                    completion(.init(stage: .localAdmission, success: true, messageIDs: [row.messageId]))
                } catch { completion(.init(stage: .rejected, success: false)) }
            }
            if fixture == .voice {
                let reference = VoiceMessageReferenceBuilder.make(owner: request.context.owner, jid: request.context.jid,
                    conversationType: .omemo, rawUrl: source, duration: 1, meteringLevels: [0.25, 0.5, 0.25])
                AccountChatAttachmentMediaMessageSender().sendMediaMessage(references: [reference], body: request.command.token,
                    legacyBody: request.command.token, requiresUpload: true, context: request.context, completion: admission)
            } else {
                let loaded = ChatAttachmentLoadedMedia(content: .file(source), referenceURL: source, filename: fixture.rawValue,
                    mediaType: fixture.mime, mediaKind: fixture.mediaKind, dimensions: dimensions, duration: nil)
                let prepared = try ChatAttachmentMediaPreparationFileWriter().makePreparedFile(from: loaded)
                let draft = AttachmentDraft(id: "qa3:" + request.command.token, source: .file, mediaKind: fixture.mediaKind,
                    thumbnailState: .none, filename: prepared.filename, byteSize: prepared.byteSize, duration: nil,
                    dimensions: dimensions, preparationState: .prepared(prepared))
                var caption = ChatAttachmentCaptionState(); caption.rawText = request.command.token
                ChatAttachmentSendPipeline().send(drafts: [draft], captionState: caption, context: request.context) {
                    if case .sent = $0 { admission(true) } else { admission(false) }
                }
            }
        } catch { completion(.init(stage: .rejected, success: false)) }
    }
    private static func receive(_ request: OMEMOThreeClientDiagnosticExecution,
                                completion: @escaping (OMEMOThreeClientDiagnosticOutcome) -> Void) -> ChatEncryptedAttachmentReceiveTask? {
        do {
            guard let id = request.command.messageID, let fixture = request.command.fixture else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidCommand }
            let descriptor = try receivedDescriptor(request)
            return ChatEncryptedAttachmentReceiver.shared.receive(descriptor) { result in
                switch result {
                case .success(let file):
                    do {
                        guard try receivedDescriptor(request) == descriptor else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidRuntime }
                        let matches = file.byteCount == fixture.byteCount && file.plaintextSHA256 == fixture.sha256
                        completion(.init(stage: .receivedFile, success: matches, messageIDs: [id], byteCount: file.byteCount, sha256: file.plaintextSHA256))
                    } catch { completion(.init(stage: .rejected, success: false)) }
                case .failure: completion(.init(stage: .rejected, success: false))
                }
            }
        } catch { completion(.init(stage: .rejected, success: false)); return nil }
    }
    private static func receivedDescriptor(_ request: OMEMOThreeClientDiagnosticExecution) throws -> ChatEncryptedAttachmentDescriptor {
            let current = currentSnapshot(request.command.role)
            try OMEMOThreeClientDiagnosticPolicy.validate(current, command: request.command, now: Date().timeIntervalSince1970)
            guard current?.fullJID == request.runtimeSnapshot.fullJID,
                  let id = request.command.messageID, let token = request.command.messageToken else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidRuntime }
            let realm = try WRealm.safe(); realm.refresh()
            let rows = realm.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageId == %@",
                request.context.owner, request.context.jid, "urn:xmpp:omemo:2", id)
            guard rows.count == 1, let message = rows.first, !message.isDeleted, !message.isLocallyHiddenByReport,
                  message.body.contains(token), (message.messageError ?? "").isEmpty, (message.messageErrorCode ?? "").isEmpty,
                  let auth = message.systemMetadata?["omemo_authenticated_sender_v1"] as? [String: Any],
                  auth["owner"] as? String == request.context.owner, auth["trusted"] as? Bool == true,
                  let sender = auth["jid"] as? String, let senderSID = auth["deviceID"] as? Int,
                  let senderFingerprint = auth["fingerprint"] as? String,
                  OMEMOThreeClientDiagnosticPolicy.validSender(sender, sid: senderSID, fingerprint: senderFingerprint, role: request.command.role, outgoing: message.outgoing)
            else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidRuntime }
            let references = message.references.filter { $0.owner == request.context.owner && $0.jid == request.context.jid && $0.metadata?.keys.contains("encryption-key") == true }
            guard references.count == 1, let reference = references.first, let url = reference.downloadUrl, url.scheme == "https" else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidFixture }
            let descriptor = ChatEncryptedAttachmentDescriptor(metadata: reference.metadata, url: url, owner: request.context.owner, referenceIdentity: reference.primary)
            guard descriptor.state == .encrypted else { throw OMEMOThreeClientDiagnosticPolicy.Rejection.invalidFixture }
            return descriptor
    }
}
#endif
