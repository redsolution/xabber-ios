import Foundation
import XMPPFramework

enum OMEMOReceiveContext {
    case live, archive, carbon, syncPreview, push, modify
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
