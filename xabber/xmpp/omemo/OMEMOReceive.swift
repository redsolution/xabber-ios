import Foundation
import XMPPFramework

enum OMEMOReceiveContext {
    case live, archive, carbon, syncPreview, push, modify
}

/// Transport ownership checked by the sync IQ receiver. This grants access to
/// server timestamps only; authentication still comes from the SCE decoder.
enum OMEMOReceiveServerContext: Equatable {
    case unverified, accountServer
}

/// The original stanza's transport timestamp, distinct from the time at which
/// an archive page, carbon, notification or sync event reaches this client.
struct OMEMOOriginalSendingTime: Equatable {
    enum Source: Equatable {
        case xabberDelivery, forwardedDelay, stanzaDelay, rewriteReplacement, caller
    }

    let date: Date
    let source: Source
}

enum OMEMOConsumptionReason: Equatable {
    case control, duplicate
    case invalidTransport
}

/// Local metadata from the native session that authenticated this message.
/// It is carried separately from XML and never grants or changes device trust.
struct OMEMOAuthenticatedSender: Hashable, Sendable {
    let owner: String
    let jid: String
    let deviceID: Int
    let identityFingerprint: String
    let isTrusted: Bool
}

enum OMEMOReceiveResult {
    case notEncrypted(XMPPMessage)
    case verified(XMPPMessage, MessageEncryptionProvenance, sender: OMEMOAuthenticatedSender? = nil)
    case consumed(OMEMOConsumptionReason)
    case failed(XMPPMessage, Error)

    var message: XMPPMessage? {
        switch self {
        case .notEncrypted(let message), .verified(let message, _, _), .failed(let message, _): return message
        case .consumed: return nil
        }
    }

    var provenance: MessageEncryptionProvenance {
        switch self {
        case .notEncrypted: return .plaintext
        case .verified(_, let provenance, _): return provenance
        case .failed: return .failedOMEMO
        case .consumed: return .unverifiedOMEMO
        }
    }

    var authenticatedSender: OMEMOAuthenticatedSender? {
        guard case .verified(_, .authenticatedSCE(profile: .omemo2), let sender) = self else { return nil }
        return sender
    }
}
