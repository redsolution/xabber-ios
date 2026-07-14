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

import Foundation
import XMPPFramework

enum XMPPAuthenticationFailureReason: Equatable {
    case aborted
    case accountDisabled
    case credentialsExpired
    case encryptionRequired
    case incorrectEncoding
    case invalidAuthzid
    case invalidMechanism
    case malformedRequest
    case mechanismTooWeak
    case notAuthorized
    case temporaryAuthFailure
    case missingCondition
    case unknown(String)

    init(elementName: String?) {
        switch elementName {
        case "aborted": self = .aborted
        case "account-disabled": self = .accountDisabled
        case "credentials-expired": self = .credentialsExpired
        case "encryption-required": self = .encryptionRequired
        case "incorrect-encoding": self = .incorrectEncoding
        case "invalid-authzid": self = .invalidAuthzid
        case "invalid-mechanism": self = .invalidMechanism
        case "malformed-request": self = .malformedRequest
        case "mechanism-too-weak": self = .mechanismTooWeak
        case "not-authorized": self = .notAuthorized
        case "temporary-auth-failure": self = .temporaryAuthFailure
        case .some(let value): self = .unknown(value)
        case .none: self = .missingCondition
        }
    }

    var elementName: String {
        switch self {
        case .aborted: return "aborted"
        case .accountDisabled: return "account-disabled"
        case .credentialsExpired: return "credentials-expired"
        case .encryptionRequired: return "encryption-required"
        case .incorrectEncoding: return "incorrect-encoding"
        case .invalidAuthzid: return "invalid-authzid"
        case .invalidMechanism: return "invalid-mechanism"
        case .malformedRequest: return "malformed-request"
        case .mechanismTooWeak: return "mechanism-too-weak"
        case .notAuthorized: return "not-authorized"
        case .temporaryAuthFailure: return "temporary-auth-failure"
        case .missingCondition: return "missing-condition"
        case .unknown(let value): return value
        }
    }
}

struct XMPPAuthenticationFailure: Equatable {
    static let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

    let reason: XMPPAuthenticationFailureReason
    let text: String?
    let rawXML: String

    init?(element: DDXMLElement) {
        guard Self.isSASLFailure(element) else {
            return nil
        }
        self.reason = XMPPAuthenticationFailureReason(elementName: Self.conditionElement(in: element)?.name)
        self.text = Self.textElement(in: element)?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.rawXML = element.xmlString
    }

    private static func isSASLFailure(_ element: DDXMLElement) -> Bool {
        if element.name == "failure",
           element.xmlns() == saslNamespace {
            return true
        }
        return childElements(in: element).contains { child in
            child.xmlns() == saslNamespace
        }
    }

    private static func conditionElement(in element: DDXMLElement) -> DDXMLElement? {
        return childElements(in: element)
            .first { child in
                child.name != "text"
            }
    }

    private static func textElement(in element: DDXMLElement) -> DDXMLElement? {
        return childElements(in: element)
            .first { child in
                child.name == "text"
            }
    }

    private static func childElements(in element: DDXMLElement) -> [DDXMLElement] {
        return element.children?.compactMap { $0 as? DDXMLElement } ?? []
    }
}

enum XMPPAuthenticationFailureClientAction: Equatable {
    case retryAuthentication(message: String)
    case removeAccount(alertMessage: String)
    case refreshDeviceSecret
    case rejectPassword(message: String)
    case reportGeneric(message: String)

    var revokesCredential: Bool {
        if case .removeAccount = self {
            return true
        }
        return false
    }
}

enum XMPPAuthenticationFailureSource: Equatable {
    case primaryAccount
    case secondaryStream
}

struct AccountRevocationEvidence: Equatable {
    enum Source: String, Equatable {
        case currentPrimarySASLAccountDisabled
        case verifiedCurrentDeviceHeadline
    }

    let source: Source
    let eventID: String
}

struct AccountRevocationRequest: Equatable {
    let jid: String
    let message: String
    let evidence: AccountRevocationEvidence
}

enum AccountAuthenticationSafetyEvent: Equatable {
    case missingLocalCredential(kind: CredentialsManager.Storage.Kind)
    case locallyInvalidatedCredential(kind: CredentialsManager.Storage.Kind)
    case authenticationStartFailed
    case ambiguousAuthenticationFailure
    case saslAccountDisabled(
        source: XMPPAuthenticationFailureSource,
        isCurrentStream: Bool,
        eventID: String
    )
    case deviceHeadlineRevocation(
        isServerSender: Bool,
        isHeadline: Bool,
        namespaceMatches: Bool,
        revokedDeviceID: String?,
        currentDeviceID: String?,
        eventID: String
    )
}

enum AccountAuthenticationSafetyDisposition: Equatable {
    case retryableFailure
    case reauthenticationRequired(kind: CredentialsManager.Storage.Kind)
    case authoritativeRevocation(AccountRevocationEvidence)

    var authorizesAccountDeletion: Bool {
        if case .authoritativeRevocation = self {
            return true
        }
        return false
    }

    var userMessage: String {
        switch self {
        case .reauthenticationRequired:
            return "Sign in again to restore account access. Your local data was kept."
        case .retryableFailure:
            return "Authentication failed. Please try again."
        case .authoritativeRevocation:
            return "Device was revoked"
        }
    }
}

struct AccountAuthenticationSafetyPolicy {
    static func disposition(
        for event: AccountAuthenticationSafetyEvent
    ) -> AccountAuthenticationSafetyDisposition {
        switch event {
        case .missingLocalCredential(let kind),
             .locallyInvalidatedCredential(let kind):
            return .reauthenticationRequired(kind: kind)

        case .authenticationStartFailed,
             .ambiguousAuthenticationFailure:
            return .retryableFailure

        case .saslAccountDisabled(let source, let isCurrentStream, let eventID):
            guard source == .primaryAccount, isCurrentStream else {
                return .retryableFailure
            }
            return .authoritativeRevocation(
                AccountRevocationEvidence(
                    source: .currentPrimarySASLAccountDisabled,
                    eventID: eventID
                )
            )

        case .deviceHeadlineRevocation(
            let isServerSender,
            let isHeadline,
            let namespaceMatches,
            let revokedDeviceID,
            let currentDeviceID,
            let eventID
        ):
            guard isServerSender,
                  isHeadline,
                  namespaceMatches,
                  let revokedDeviceID = revokedDeviceID?.nilIfEmpty,
                  let currentDeviceID = currentDeviceID?.nilIfEmpty,
                  revokedDeviceID == currentDeviceID else {
                return .retryableFailure
            }
            return .authoritativeRevocation(
                AccountRevocationEvidence(
                    source: .verifiedCurrentDeviceHeadline,
                    eventID: eventID
                )
            )
        }
    }
}

final class AccountRevocationProcessingGate {
    private let lock = NSLock()
    private var processedKeys: Set<String> = []

    func claim(_ request: AccountRevocationRequest) -> Bool {
        let key = [
            request.jid,
            request.evidence.source.rawValue,
            request.evidence.eventID
        ].joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        return processedKeys.insert(key).inserted
    }
}

struct AccountRevocationNotificationParser {
    static func request(from notification: Notification) -> AccountRevocationRequest? {
        notification.object as? AccountRevocationRequest
    }
}

struct AccountAuthenticationSafetyDiagnostic {
    enum Source: String {
        case localCredential
        case primarySASL
        case secondaryStream
        case deviceHeadline
        case transport
    }

    enum Reason: String {
        case missingLocalCredential
        case locallyInvalidatedCredential
        case authenticationStartFailed
        case ambiguousAuthenticationFailure
        case authoritativeRevocation
    }

    let source: Source
    let reason: Reason
    let credentialKind: CredentialsManager.Storage.Kind?
    let counterReserved: Bool

    var line: String {
        [
            "event=authentication_safety_disposition",
            "source=\(source.rawValue)",
            "reason=\(reason.rawValue)",
            "credentialKind=\(credentialKind?.rawValue ?? "none")",
            "counterReserved=\(counterReserved)"
        ].joined(separator: " ")
    }
}

struct XMPPAuthenticationFailureResolution: Equatable {
    let action: XMPPAuthenticationFailureClientAction
    let statusMessage: String
    let shouldLogRawFailure: Bool

    static func resolve(
        failure: XMPPAuthenticationFailure,
        credentialKind: CredentialsManager.Storage.Kind,
        source: XMPPAuthenticationFailureSource = .primaryAccount
    ) -> XMPPAuthenticationFailureResolution {
        switch failure.reason {
        case .temporaryAuthFailure:
            let message = failure.text ?? Self.genericAuthenticationFailureMessage
            return XMPPAuthenticationFailureResolution(
                action: .retryAuthentication(message: message),
                statusMessage: message,
                shouldLogRawFailure: true
            )

        case .accountDisabled:
            let message = Self.revokedDeviceMessage(from: failure.text)
            guard source == .primaryAccount else {
                return XMPPAuthenticationFailureResolution(
                    action: .reportGeneric(message: message),
                    statusMessage: message,
                    shouldLogRawFailure: true
                )
            }
            return XMPPAuthenticationFailureResolution(
                action: .removeAccount(alertMessage: message),
                statusMessage: message,
                shouldLogRawFailure: false
            )

        case .credentialsExpired:
            return XMPPAuthenticationFailureResolution(
                action: .refreshDeviceSecret,
                statusMessage: Self.deviceSecretRefreshMessage(from: failure.text),
                shouldLogRawFailure: false
            )

        case .notAuthorized:
            if credentialKind == .password {
                return XMPPAuthenticationFailureResolution(
                    action: .rejectPassword(message: Self.incorrectPasswordMessage),
                    statusMessage: Self.incorrectPasswordMessage,
                    shouldLogRawFailure: false
                )
            }
            return XMPPAuthenticationFailureResolution(
                action: .refreshDeviceSecret,
                statusMessage: Self.deviceSecretRefreshMessage(from: failure.text),
                shouldLogRawFailure: false
            )

        case .aborted,
             .encryptionRequired,
             .incorrectEncoding,
             .invalidAuthzid,
             .invalidMechanism,
             .malformedRequest,
             .mechanismTooWeak,
             .missingCondition,
             .unknown:
            let message = failure.text ?? Self.genericAuthenticationFailureMessage
            return XMPPAuthenticationFailureResolution(
                action: .reportGeneric(message: message),
                statusMessage: message,
                shouldLogRawFailure: true
            )
        }
    }

    private static let incorrectPasswordMessage = "Incorrect username or password"
    private static let genericAuthenticationFailureMessage = "Authentication failed"

    private static func revokedDeviceMessage(from serverText: String?) -> String {
        guard let serverText = serverText,
              serverText != "Device access revoked" else {
            return "Device was revoked"
        }
        return serverText
    }

    private static func deviceSecretRefreshMessage(from serverText: String?) -> String {
        return serverText ?? genericAuthenticationFailureMessage
    }

    var releaseOutcome: CredentialsManager.Storage.ReleaseOutcome {
        action.revokesCredential ? .credentialRevoked : .authFailedRecoverable
    }
}

enum XMPPStoredCredentialAuthenticationResult: Equatable {
    case started
    case missingCredential
}

struct XMPPStoredCredentialAuthenticator {
    static func authenticate(
        stream: XMPPStream,
        storage: CredentialsManager.Storage,
        ownerJID: String,
        counterTracker: XMPPAuthenticationCounterTracker
    ) throws -> XMPPStoredCredentialAuthenticationResult {
        stream.shouldRequestXToken = false
        stream.shouldRegisterDevice = false

        switch storage.kind {
        case .token:
            guard let token = storage.creditionalString else {
                return .missingCredential
            }
            let counter = try counterTracker.counterForAuthentication(using: storage)
            try stream.authenticate(withXabberToken: token, counter: counter)
            return .started

        case .secret:
            guard let secret = storage.creditionalString else {
                return .missingCredential
            }
            if stream.supportsOCRAAuthentication {
                let storedDeviceUUID = try currentDeviceUUID(for: ownerJID)
                guard let validationKey = storage.validationKey?.nilIfEmpty,
                      let deviceUUID = storedDeviceUUID?.nilIfEmpty else {
                    return .missingCredential
                }
                let counter = try counterTracker.counterForAuthentication(using: storage)
                try stream.authenticate(
                    withOCRASecret: secret,
                    validationKey: validationKey,
                    deviceId: deviceUUID,
                    counter: counter
                )
            } else {
                let counter = try counterTracker.counterForAuthentication(using: storage)
                try stream.authenticate(withHOTPSecret: secret, counter: counter)
            }
            return .started

        case .password:
            return .missingCredential
        }
    }

    private static func currentDeviceUUID(for ownerJID: String) throws -> String? {
        let realm = try WRealm.safe()
        let realmDeviceUUID = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: ownerJID)?.deviceUuid
        return realmDeviceUUID?.nilIfEmpty ?? CredentialsManager.getXabberDeviceId(for: ownerJID)?.nilIfEmpty
    }
}

final class XMPPAuthenticationCounterTracker {
    private var pendingReservation: CredentialsManager.Storage.AuthenticationCounterReservation?
    private let lock = NSRecursiveLock()

    func counterForAuthentication(using storage: CredentialsManager.Storage) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let reservation = try storage.reserveCounterForAuthentication()
        pendingReservation = reservation
        return reservation.counter
    }

    func authenticationDidSucceed(using storage: CredentialsManager.Storage) {
        lock.lock()
        defer { lock.unlock() }
        if pendingReservation?.jid == storage.jid {
            pendingReservation = nil
        }
    }

    func authenticationDidFail() {
        lock.lock()
        defer { lock.unlock() }
        pendingReservation = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
