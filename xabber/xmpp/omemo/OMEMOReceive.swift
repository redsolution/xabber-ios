import Foundation
import XMPPFramework

enum OMEMOReceiveContext {
    case live, archive, carbon, syncPreview, push, modify
}

/// The original stanza's transport timestamp, distinct from the time at which
/// an archive page, carbon, notification or sync event reaches this client.
struct OMEMOOriginalSendingTime: Equatable {
    enum Source: Equatable {
        case xabberDelivery, forwardedDelay, stanzaDelay, caller
    }

    let date: Date
    let source: Source
}

enum OMEMOConsumptionReason: Equatable {
    case control, duplicate
    case invalidTransport
}

enum OMEMOReceiveResult {
    case notEncrypted(XMPPMessage)
    case verified(XMPPMessage, MessageEncryptionProvenance)
    case consumed(OMEMOConsumptionReason)
    case failed(XMPPMessage, Error)

    var message: XMPPMessage? {
        switch self {
        case .notEncrypted(let message), .verified(let message, _), .failed(let message, _): return message
        case .consumed: return nil
        }
    }

    var provenance: MessageEncryptionProvenance {
        switch self {
        case .notEncrypted: return .plaintext
        case .verified(_, let provenance): return provenance
        case .failed: return .failedOMEMO
        case .consumed: return .unverifiedOMEMO
        }
    }
}
