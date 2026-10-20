import Foundation
import CryptoKit

/// Runner-only policy. It never configures or launches the application under test.
/// Account and baseline inputs are coordinator expectations, not proof of the app's account.
enum OMEMOThreeClientLiveUIAuthorization {
    enum Role: String, Equatable { case iphone, ipad }
    enum Idiom: Equatable { case phone, pad, other }
    enum Operation { case report, visibleMessage, terminalDone }

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
    }

    struct Rejection: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
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
        switch operation {
        case .report:
            break
        case .visibleMessage:
            guard environment[prefix + "ASSERT_MESSAGE"] == "1" else { return nil }
            guard let rawID = environment[prefix + "MESSAGE_ID"],
                  UUID(uuidString: rawID) != nil || matchesEntireString(rawID, pattern: "^[A-Za-z0-9_-]{8}$"),
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
            successLabel: successLabel, doneLabel: doneLabel
        )
    }

    private static func reject(_ reason: String) -> Rejection { Rejection(reason: reason) }

    private static func matchesEntireString(_ input: String, pattern: String) -> Bool {
        input.range(of: pattern, options: .regularExpression) == input.startIndex..<input.endIndex
    }
}
