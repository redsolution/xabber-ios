import Foundation
import XMPPFramework

/// Logs the original stanza serialization without changing any XML content.
/// Diagnostics never determine bundle, identity, trust, or session admission.
enum OMEMO2BundleDiagnostics {
    struct Record {
        let summary: String
        let rawXML: String?
    }

    #if DEBUG
    static let debugXMLLoggingEnabled = true
    #else
    static let debugXMLLoggingEnabled = false
    #endif

    static func record(
        stanza: DDXMLElement,
        jid: String,
        error: Swift.Error? = nil,
        includeRawXML: Bool = debugXMLLoggingEnabled
    ) -> Record {
        let item = bundleItem(in: stanza)
        let deviceID = (try? OMEMO2BundleCodec.keyID(item?.attributeStringValue(forName: "id")))
            .map(String.init) ?? "unknown"
        var summary = "OMEMO2 bundle jid=\"\(jid)\" deviceID=\(deviceID)"
        if let error {
            summary += " outcome=rejected " + OMEMO2BundleCodec.rejectionDiagnostics(item: item ?? stanza, error: error)
        } else {
            summary += " outcome=observed"
        }
        // User requires the complete original stanza: no filtering,
        // reconstruction, redaction, Base64 normalization, or truncation.
        return Record(summary: summary, rawXML: includeRawXML ? stanza.xmlString : nil)
    }

    private static func bundleItem(in stanza: DDXMLElement) -> DDXMLElement? {
        if stanza.localName == "item" { return stanza }
        for (name, namespace) in [("pubsub", "http://jabber.org/protocol/pubsub"),
                                  ("event", "http://jabber.org/protocol/pubsub#event")] {
            guard let root = SCEReceivePolicy.children(of: stanza, named: name, xmlns: namespace).first else { continue }
            for container in ["items", "publish"] {
                guard let items = SCEReceivePolicy.children(of: root, named: container, xmlns: namespace).first else { continue }
                if let item = SCEReceivePolicy.children(of: items, named: "item", xmlns: namespace).first { return item }
            }
        }
        return nil
    }
}
