import Foundation
import CryptoKit

/// Runner-only policy. It never configures or launches the application under test.
/// Account and baseline inputs are coordinator expectations, not proof of the app's account.
enum OMEMOThreeClientLiveUIAuthorization {
    enum Role: String, Equatable { case iphone, ipad }
    enum Idiom: Equatable { case phone, pad, other }
    enum Operation { case report, visibleMessage, terminalDone, openAttachment, dismissAttachment }
    enum AttachmentKind: String { case image, file, audio, video, voice }
    struct Attachment: Equatable {
        let kind: AttachmentKind
        let referencePrimary: String
        let filename: String
        let byteCount: Int
        let sha256: String
    }

    struct Configuration: Equatable {
        let role: Role
        let account: String
        let token: String
        let baselineSHA256: String
        let messageID: String?
        let messageBody: String?
        let messageManifestSHA256: String?
        let verifiedSID: String?
        let successLabel: String?
        let doneLabel: String?
        let attachment: Attachment?
        let dismissLabel: String?
    }

    struct Rejection: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct VisibleMessageWitness {
        let collectionIdentifier: String
        let cellIdentifier: String
        let body: String
        let isVisible: Bool
    }

    struct ElementVisibilityWitness {
        let exists: Bool
        let isHittable: Bool
        let frame: CGRect
        let viewport: CGRect
    }

    static func isVisible(_ witness: ElementVisibilityWitness) -> Bool {
        witness.exists && witness.isHittable && !witness.frame.isEmpty
            && witness.frame.intersects(witness.viewport)
    }

    static func isTappable(_ witness: ElementVisibilityWitness) -> Bool {
        isVisible(witness) && witness.isHittable
    }

    static func isVisibleContainer(_ witness: ElementVisibilityWitness) -> Bool {
        // The collection is a read-only scope, never the target of the tap.
        witness.exists && !witness.frame.isEmpty && !witness.viewport.isEmpty
            && witness.frame.intersects(witness.viewport)
    }

    struct PhotoGalleryWitness {
        let identifier: String
        let root: ElementVisibilityWitness
        let readyCells: [ElementVisibilityWitness]
        let closeControls: [ElementVisibilityWitness]
    }

    struct MessageBodyWitness {
        let text: String
        let visibility: ElementVisibilityWitness
    }

    static func hasVisibleExactBody(_ expected: String, cell: ElementVisibilityWitness, bodies: [MessageBodyWitness]) -> Bool {
        guard bodies.count == 1, bodies[0].text == expected, isVisible(cell) else { return false }
        return isVisibleContainer(bodies[0].visibility)
    }

    static func hasExactlyOneReadyPhotoGallery(identifier: String, witnesses: [PhotoGalleryWitness]) -> Bool {
        guard witnesses.count == 1, let gallery = witnesses.first, gallery.identifier == identifier,
              isVisibleContainer(gallery.root), gallery.readyCells.count == 1,
              isVisibleContainer(gallery.readyCells[0]), gallery.closeControls.count == 1,
              isVisible(gallery.closeControls[0]) else { return false }
        return true
    }

    static let conversationCollectionIdentifier = "chat.conversation.messages"

    static func messageIdentifierPrefix(_ id: String) -> String {
        "chat.message.\(Data(id.utf8).base64EncodedString())."
    }

    static func hasExactlyOneVisibleMessage(id: String, body: String, witnesses: [VisibleMessageWitness]) -> Bool {
        let prefix = messageIdentifierPrefix(id)
        let matches = witnesses.filter { witness in
            guard witness.collectionIdentifier == conversationCollectionIdentifier,
                  witness.cellIdentifier.hasPrefix(prefix) else { return false }
            let encodedPrimary = String(witness.cellIdentifier.dropFirst(prefix.count))
            guard let primary = Data(base64Encoded: encodedPrimary), !primary.isEmpty,
                  primary.base64EncodedString() == encodedPrimary,
                  String(data: primary, encoding: .utf8)?.isEmpty == false else { return false }
            return true
        }
        return matches.count == 1 && matches[0].body == body && matches[0].isVisible
    }

    static func attachmentIdentifier(kind: AttachmentKind, referencePrimary: String) -> String {
        "chat.attachment.\(kind == .audio ? "file" : kind.rawValue).\(Data(referencePrimary.utf8).base64EncodedString())"
    }

    static func viewerIdentifier(for attachment: Attachment) -> String {
        let kind: String
        switch attachment.kind {
        case .image: kind = "photo.gallery"
        case .file, .audio: kind = "file.viewer"
        case .video: kind = "video.viewer"
        case .voice: return ""
        }
        return "chat.media.\(kind).\(Data(attachment.referencePrimary.utf8).base64EncodedString())"
    }

    static func isVoiceReadyForPlayback(referencePrimary: String, identifier: String) -> Bool {
        guard let witness = voiceWitness(referencePrimary: referencePrimary, identifier: identifier) else { return false }
        return ["downloaded", "paused"].contains(witness.state)
    }

    static func hasNewVoicePlayback(referencePrimary: String, before: String, after: String) -> Bool {
        guard let previous = voiceWitness(referencePrimary: referencePrimary, identifier: before),
              let current = voiceWitness(referencePrimary: referencePrimary, identifier: after),
              ["downloaded", "paused"].contains(previous.state),
              ["playing", "paused", "downloaded"].contains(current.state) else { return false }
        return current.entries > previous.entries
    }

    private static func voiceWitness(referencePrimary: String, identifier: String) -> (state: String, entries: Int)? {
        let prefix = attachmentIdentifier(kind: .voice, referencePrimary: referencePrimary) + "."
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasPrefix("p"),
              let entries = Int(parts[1].dropFirst()), entries >= 0,
              String(entries) == parts[1].dropFirst() else { return nil }
        return (String(parts[0]), entries)
    }

    private static let prefix = "XABBER_OMEMO_UI_"

    /// `nil` means skip before XCUIApplication creation. Invalid opted-in inputs fail closed.
    static func authorize(
        environment: [String: String],
        isSimulator: Bool,
        idiom: Idiom,
        operation: Operation
    ) throws -> Configuration? {
        guard environment[prefix + "ACCEPTANCE"] == "1" else { return nil }
        guard !isSimulator else { throw reject("Physical UI acceptance does not allow Simulator.") }
        guard let role = Role(rawValue: environment[prefix + "ROLE"] ?? "") else {
            throw reject("Physical UI acceptance requires the explicitly bound iphone or ipad role.")
        }
        guard (role == .iphone && idiom == .phone) || (role == .ipad && idiom == .pad) else {
            throw reject("The actual device idiom does not match the bound role.")
        }
        let account = role == .iphone
            ? "igor.boldin@redsolution.com" : "test.omemo.igor@dxs.xabber.com"
        guard environment[prefix + "ACCOUNT"] == account else {
            throw reject("The runner account expectation does not match the bound role allowlist.")
        }
        guard let token = environment[prefix + "TOKEN"],
              matchesEntireString(token, pattern: "^QA3-[A-Za-z0-9][A-Za-z0-9._-]{1,59}$") else {
            throw reject("A bounded fresh QA3 token is required.")
        }
        guard let baselineSHA256 = environment[prefix + "BASELINE_SHA256"],
              matchesEntireString(baselineSHA256, pattern: "^[0-9a-f]{64}$") else {
            throw reject("Bind the runner to the coordinator's private read-only baseline SHA256.")
        }
        let forbidden = [
            "FIXTURE", "RESET", "ISOLATED", "SEED", "UNINSTALL", "ERASE", "LOGOUT", "CLEAN_REALM",
            "DISABLE_ACCOUNT_AUTOCONNECT", "PERFORMANCE_UI_TEST"
        ]
        for (key, value) in environment where key.uppercased().contains("XABBER") {
            guard !["", "0", "false"].contains(value.lowercased()) else { continue }
            if forbidden.contains(where: { key.uppercased().contains($0) }) {
                throw reject("Physical UI acceptance rejects fixture/reset/storage or account mutation inputs.")
            }
        }

        var messageID: String?
        var messageBody: String?
        var messageManifestSHA256: String?
        var verifiedSID: String?
        var successLabel: String?
        var doneLabel: String?
        var attachment: Attachment?
        var dismissLabel: String?
        switch operation {
        case .report:
            break
        case .visibleMessage, .openAttachment, .dismissAttachment:
            if case .openAttachment = operation {
                guard environment[prefix + "OPEN_ATTACHMENT"] == "1" else { return nil }
            }
            if case .dismissAttachment = operation {
                guard environment[prefix + "DISMISS_ATTACHMENT"] == "1" else { return nil }
            }
            guard environment[prefix + "ASSERT_MESSAGE"] == "1" else {
                if case .visibleMessage = operation { return nil }
                throw reject("Attachment actions require the separate exact-message opt-in.")
            }
            guard let rawID = environment[prefix + "MESSAGE_ID"],
                  UUID(uuidString: rawID) != nil || matchesEntireString(rawID, pattern: "^[A-Za-z0-9~_]{8}$"),
                  let body = environment[prefix + "MESSAGE_BODY"],
                  body.contains(token), body.utf8.count <= 16_384,
                  let encoded = environment[prefix + "MESSAGE_MANIFEST_BASE64"],
                  let data = Data(base64Encoded: encoded), data.count <= 256 * 1024,
                  data.base64EncodedString() == encoded,
                  let expectedHash = environment[prefix + "MESSAGE_MANIFEST_SHA256"],
                  matchesEntireString(expectedHash, pattern: "^[0-9a-f]{64}$"),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash,
                  let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  records.filter({ $0["id"] as? String == rawID }).count == 1,
                  records.contains(where: { $0["id"] as? String == rawID && $0["body"] as? String == body }) else {
                throw reject("Visible-message assertions require an exact native ID/UUID and body from the hash-bound fresh manifest.")
            }
            messageID = rawID
            messageBody = body
            messageManifestSHA256 = expectedHash
            switch operation {
            case .openAttachment, .dismissAttachment:
                attachment = try decodeAttachment(records.first(where: { $0["id"] as? String == rawID })?["attachments"])
                if case .dismissAttachment = operation {
                    guard let attachment, [.image, .file, .audio, .video].contains(attachment.kind),
                          let label = environment[prefix + "DISMISS_LABEL"],
                          ["Close", "Done", "Закрыть", "Готово"].contains(label),
                          attachment.kind != .image || ["Close", "Закрыть"].contains(label) else {
                        throw reject("System dismissal requires an exact modal attachment and an actually observed canonical Close/Done label.")
                    }
                    dismissLabel = label
                }
            default: break
            }
        case .terminalDone:
            guard environment[prefix + "DISMISS_SUCCESS"] == "1" else { return nil }
            guard let sid = environment[prefix + "VERIFIED_SID"],
                  let decoded = Data(base64Encoded: sid), (16...64).contains(decoded.count),
                  decoded.base64EncodedString() == sid else {
                throw reject("Terminal dismissal requires a canonical already-verified session witness.")
            }
            // These are source-backed trusted-state labels, never request/accept/cancel actions.
            guard let heading = environment[prefix + "SUCCESS_LABEL"],
                  ["Verification Successful", "Проверка выполнена"].contains(heading),
                  let button = environment[prefix + "DONE_LABEL"],
                  ["Great", "Done", "Отлично", "Готово"].contains(button) else {
                throw reject("Terminal dismissal allows only the explicitly observed success heading and Done/Great label.")
            }
            verifiedSID = sid
            successLabel = heading
            doneLabel = button
        }
        return Configuration(
            role: role, account: account, token: token, baselineSHA256: baselineSHA256,
            messageID: messageID, messageBody: messageBody, messageManifestSHA256: messageManifestSHA256, verifiedSID: verifiedSID,
            successLabel: successLabel, doneLabel: doneLabel, attachment: attachment, dismissLabel: dismissLabel
        )
    }

    private static func decodeAttachment(_ raw: Any?) throws -> Attachment {
        guard let records = raw as? [[String: Any]], records.count == 1, let value = records.first,
              Set(value.keys) == ["kind", "referencePrimary", "filename", "byteCount", "sha256"],
              let kind = AttachmentKind(rawValue: value["kind"] as? String ?? ""),
              let primary = value["referencePrimary"] as? String, !primary.isEmpty, primary.utf8.count <= 2048,
              primary.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let filename = value["filename"] as? String, let byteCount = value["byteCount"] as? Int,
              let sha256 = value["sha256"] as? String else {
            throw reject("Attachment UI requires exactly one bounded reference and fixed fixture metadata in the hash-bound manifest.")
        }
        let expected: (String, Int, String)
        switch kind {
        case .image: expected = ("QA3-image.png", 14205, "10e3ad9db045757011ccac1be7b224584a2d4a41433c010910423cebf9eb2529")
        case .file: expected = ("QA3-document.txt", 2738, "37a4be8e8dd6c7fcb7af2a306909b658075b9a00fe1ab8c02be4b64a7d3877d0")
        case .audio: expected = ("QA3-audio.wav", 16044, "c5b99ceef5c83a371360cad83a267daa6fb69cb96525672d353dddcd8fc33e9c")
        case .video: expected = ("QA3-video.mp4", 1870, "0c4ecc8cee6f7bf03ee9ffeac5394e2e0860d3e496e5329f5f94bbbc5cbc063a")
        case .voice: expected = ("QA3-voice.ogg", 1420, "c88e7fddcea31b4b04d98b969fb939f79205bf8019fc9726f969099c18c85b83")
        }
        guard filename == expected.0, byteCount == expected.1, sha256 == expected.2 else {
            throw reject("Attachment UI does not permit unknown fixture names, sizes or hashes.")
        }
        return .init(kind: kind, referencePrimary: primary, filename: filename, byteCount: byteCount, sha256: sha256)
    }

    private static func reject(_ reason: String) -> Rejection { Rejection(reason: reason) }

    private static func matchesEntireString(_ input: String, pattern: String) -> Bool {
        input.range(of: pattern, options: .regularExpression) == input.startIndex..<input.endIndex
    }
}
