import Foundation
import CocoaLumberjack

enum APNSDiagnosticTargetCategory: String, Equatable {
    case node
    case xabberAccount = "xabber_account"
    case unknown

    static func classify(_ rawValue: String?) -> APNSDiagnosticTargetCategory {
        switch rawValue {
        case "node":
            return .node
        case "xaccount":
            return .xabberAccount
        default:
            return .unknown
        }
    }
}

enum APNSDiagnosticActionCategory: String, Equatable {
    case registration
    case displayed
    case data
    case unknown

    static func classify(_ rawValue: String?) -> APNSDiagnosticActionCategory {
        switch rawValue {
        case "regjid":
            return .registration
        case "displayed":
            return .displayed
        case "data":
            return .data
        default:
            return .unknown
        }
    }
}

enum APNSDiagnosticRegistrationResultCategory: String, Equatable {
    case success
    case failure
    case missing

    static func classify(_ rawValue: String?) -> APNSDiagnosticRegistrationResultCategory {
        guard let rawValue else {
            return .missing
        }
        return rawValue == "success" ? .success : .failure
    }
}

enum APNSDiagnosticPathCategory: String, Equatable {
    case jidEndpoints = "jid_endpoints"
    case unknown

    static func classify(_ rawPath: String) -> APNSDiagnosticPathCategory {
        let pathWithoutQueryOrFragment = rawPath.prefix { character in
            character != "?" && character != "#"
        }
        let normalizedPath = String(pathWithoutQueryOrFragment)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalizedPath == "jid/endpoints" ? .jidEndpoints : .unknown
    }
}

enum APNSDiagnosticEvent: Equatable {
    case endpointResolved(
        hasScheme: Bool,
        hasHost: Bool,
        pathCategory: APNSDiagnosticPathCategory
    )
    case received(
        targetType: APNSDiagnosticTargetCategory,
        hasTarget: Bool,
        hasBody: Bool
    )
    case decoded(action: APNSDiagnosticActionCategory)
    case registration(
        result: APNSDiagnosticRegistrationResultCategory,
        hasJID: Bool,
        hasNode: Bool,
        hasService: Bool
    )
    case displayed(stanzaIDCount: Int)

    static let maximumReportedCount = 10_000

    var diagnosticLine: String {
        switch self {
        case .endpointResolved(let hasScheme, let hasHost, let pathCategory):
            return [
                "APNS_DIAGNOSTIC",
                "event=endpoint_resolved",
                "hasScheme=\(hasScheme)",
                "hasHost=\(hasHost)",
                "pathCategory=\(pathCategory.rawValue)"
            ].joined(separator: " ")
        case .received(let targetType, let hasTarget, let hasBody):
            return [
                "APNS_DIAGNOSTIC",
                "event=received",
                "targetType=\(targetType.rawValue)",
                "hasTarget=\(hasTarget)",
                "hasBody=\(hasBody)"
            ].joined(separator: " ")
        case .decoded(let action):
            return [
                "APNS_DIAGNOSTIC",
                "event=decoded",
                "action=\(action.rawValue)"
            ].joined(separator: " ")
        case .registration(let result, let hasJID, let hasNode, let hasService):
            return [
                "APNS_DIAGNOSTIC",
                "event=registration",
                "result=\(result.rawValue)",
                "hasJID=\(hasJID)",
                "hasNode=\(hasNode)",
                "hasService=\(hasService)"
            ].joined(separator: " ")
        case .displayed(let stanzaIDCount):
            let boundedCount = min(
                max(0, stanzaIDCount),
                Self.maximumReportedCount
            )
            return [
                "APNS_DIAGNOSTIC",
                "event=displayed",
                "stanzaIDCount=\(boundedCount)"
            ].joined(separator: " ")
        }
    }
}

final class APNSDiagnosticLogger {
    typealias Sink = (APNSDiagnosticEvent) -> Void

    static let live = APNSDiagnosticLogger { event in
        DDLogDebug(event.diagnosticLine)
    }

    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func record(_ event: APNSDiagnosticEvent) {
        sink(event)
    }
}
