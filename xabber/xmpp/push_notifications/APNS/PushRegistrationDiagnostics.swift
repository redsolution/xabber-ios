import Foundation
import CocoaLumberjack
import XMPPFramework

/// Closed wire conditions only. Reflected XML and server-provided error text never enter the log.
enum PushRegistrationErrorCondition: String, Equatable {
    case badRequest = "bad-request"
    case conflict
    case featureNotImplemented = "feature-not-implemented"
    case forbidden
    case gone
    case internalServerError = "internal-server-error"
    case itemNotFound = "item-not-found"
    case jidMalformed = "jid-malformed"
    case notAcceptable = "not-acceptable"
    case notAllowed = "not-allowed"
    case notAuthorized = "not-authorized"
    case paymentRequired = "payment-required"
    case policyViolation = "policy-violation"
    case recipientUnavailable = "recipient-unavailable"
    case redirect
    case registrationRequired = "registration-required"
    case remoteServerNotFound = "remote-server-not-found"
    case remoteServerTimeout = "remote-server-timeout"
    case resourceConstraint = "resource-constraint"
    case serviceUnavailable = "service-unavailable"
    case subscriptionRequired = "subscription-required"
    case undefinedCondition = "undefined-condition"
    case unexpectedRequest = "unexpected-request"
    case missing, unknown, ambiguous

    static func classify(_ iq: XMPPIQ) -> PushRegistrationErrorCondition {
        guard let iqChildren = children(iq) else { return .ambiguous }
        let errors = iqChildren.filter { $0.localName == "error" }
        guard errors.count == 1, let error = errors.first else {
            return errors.isEmpty ? .missing : .ambiguous
        }
        guard [nil, "jabber:client"].contains(iq.uri), error.uri == iq.uri else { return .unknown }
        guard let errorChildren = children(error) else { return .ambiguous }
        let conditions = errorChildren.filter {
            $0.uri == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.localName != "text"
        }
        guard conditions.count == 1, let name = conditions.first?.localName else {
            return conditions.isEmpty ? .missing : .ambiguous
        }
        guard let condition = Self(rawValue: name) else { return .unknown }
        switch condition {
        case .missing, .unknown, .ambiguous: return .unknown
        default: return condition
        }
    }

    private static func children(_ element: DDXMLElement) -> [DDXMLElement]? {
        let nodes = element.children ?? []
        guard nodes.count <= 64 else { return nil }
        return nodes.compactMap { $0 as? DDXMLElement }
    }
}

enum PushRegistrationBlockReason: String, Equatable {
    case missingConfiguration = "missing_configuration"
    case invalidAccount = "invalid_account"
    case unsupportedServer = "unsupported_server"
    case credentialsUnavailable = "credentials_unavailable"
}

enum PushRegistrationDiagnosticEvent: Equatable {
    case waiting(request: UUID)
    case queued(request: UUID, mode: PushPayloadMode)
    case sent(request: UUID, mode: PushPayloadMode)
    case enabled(request: UUID, httpReady: Bool)
    case rejected(request: UUID, condition: PushRegistrationErrorCondition)
    case timedOut(request: UUID, sent: Bool)
    case blocked(reason: PushRegistrationBlockReason)

    var diagnosticLine: String {
        let prefix = "PUSH_REGISTRATION"
        switch self {
        case .waiting(let request):
            return "\(prefix) event=enable_waiting request=\(request.uuidString) reason=owner_capabilities"
        case .queued(let request, let mode):
            return "\(prefix) event=enable_queued request=\(request.uuidString) stanza=enable namespace=https://xabber.com/protocol/push mode=\(mode.rawValue)"
        case .sent(let request, let mode):
            return "\(prefix) event=enable_sent request=\(request.uuidString) stanza=enable namespace=https://xabber.com/protocol/push mode=\(mode.rawValue)"
        case .enabled(let request, let httpReady):
            return "\(prefix) event=enable_result request=\(request.uuidString) result=success httpReady=\(httpReady)"
        case .rejected(let request, let condition):
            return "\(prefix) event=enable_result request=\(request.uuidString) result=error condition=\(condition.rawValue)"
        case .timedOut(let request, let sent):
            return "\(prefix) event=enable_timeout request=\(request.uuidString) sent=\(sent)"
        case .blocked(let reason):
            return "\(prefix) event=enable_blocked reason=\(reason.rawValue)"
        }
    }
}

final class PushRegistrationDiagnosticLogger {
    static let live = PushRegistrationDiagnosticLogger { event in
        DDLogInfo(event.diagnosticLine)
    }

    private let sink: (PushRegistrationDiagnosticEvent) -> Void

    init(sink: @escaping (PushRegistrationDiagnosticEvent) -> Void) {
        self.sink = sink
    }

    func record(_ event: PushRegistrationDiagnosticEvent) {
        sink(event)
    }
}
