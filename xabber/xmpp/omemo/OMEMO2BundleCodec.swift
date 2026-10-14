import Foundation
import XMPPFramework

/// Detached public PEP data. Secret key material belongs to XabberOMEMO2Storage.
struct OMEMO2PublishedBundle {
    let deviceID: Int
    let identityKey: Data
    let fingerprintPublicKey: Data
    let signedPreKey: Data
    let signedPreKeyID: UInt32
    let signature: Data
    let preKeys: [OMEMO2PublicPreKey]

    func selectedBundle(preKeyID: UInt32) throws -> OMEMO2Bundle {
        guard let preKey = preKeys.first(where: { $0.id == preKeyID }) else {
            throw OMEMO2BundleCodec.Error.invalidBundle
        }
        return try OMEMO2Bundle(
            identityKey: identityKey, signedPreKey: signedPreKey, signedPreKeyID: signedPreKeyID,
            signature: signature, preKey: preKey.publicKey, preKeyID: preKey.id
        )
    }

    init(deviceID: Int, identityKey: Data, fingerprintPublicKey: Data, signedPreKey: Data,
         signedPreKeyID: UInt32, signature: Data, preKeys: [OMEMO2PublicPreKey]) {
        self.deviceID = deviceID
        self.identityKey = identityKey
        self.fingerprintPublicKey = fingerprintPublicKey
        self.signedPreKey = signedPreKey
        self.signedPreKeyID = signedPreKeyID
        self.signature = signature
        self.preKeys = preKeys
    }

    init(_ localBundle: OMEMO2LocalBundle) {
        self.init(deviceID: localBundle.deviceID, identityKey: localBundle.identityKey,
                  fingerprintPublicKey: localBundle.fingerprintPublicKey, signedPreKey: localBundle.signedPreKey,
                  signedPreKeyID: localBundle.signedPreKeyID, signature: localBundle.signature, preKeys: localBundle.preKeys)
    }
}

enum OMEMO2BundleCodec {
    enum Error: Swift.Error {
        case invalidBundle
        case invalidKeyID
        case invalidBase64
        case unsupportedProfile
    }

    static let namespace = "urn:xmpp:omemo:2"
    static let maximumPreKeyCount = 1000

    /// Safe diagnosis for incompatible publishers: report the rejected public
    /// field shape, never XML, key bytes, signatures or private state.
    static func rejectionDiagnostics(item: DDXMLElement, error: Swift.Error) -> String {
        let reason: String
        switch error as? Error {
        case .invalidBundle: reason = "invalidBundleStructure"
        case .invalidKeyID: reason = "invalidKeyID"
        case .invalidBase64: reason = "invalidBase64OrKeyLength"
        case .unsupportedProfile: reason = "unsupportedProfile"
        case nil: reason = "publicKeyValidationOrStorage"
        }
        let bundle = children(named: "bundle", in: item).first
        func length(_ field: String) -> String {
            guard let bundle, let value = children(named: field, in: bundle).first?.stringValue,
                  value.utf8.count <= 256 else { return "missingOrOversized" }
            let whitespace: Set<UInt8> = [9, 10, 13, 32]
            let normalized = Data(value.utf8.filter { !whitespace.contains($0) })
            guard let encoded = String(data: normalized, encoding: .ascii),
                  let bytes = Data(base64Encoded: encoded) else { return "invalid" }
            return String(bytes.count)
        }
        let count = bundle.flatMap { children(named: "prekeys", in: $0).first }
            .map { children(named: "pk", in: $0).count } ?? 0
        return "reason=\(reason) ikBytes=\(length("ik")) spkBytes=\(length("spk")) signatureBytes=\(length("spks")) preKeys=\(count)"
    }

    static func decode(item: DDXMLElement) throws -> OMEMO2PublishedBundle {
        let deviceID = Int(try keyID(item.attributeStringValue(forName: "id")))
        let bundle = try singleChild("bundle", in: item, namespace: namespace)
        let spk = try singleChild("spk", in: bundle, namespace: namespace)
        let spks = try singleChild("spks", in: bundle, namespace: namespace)
        let ik = try singleChild("ik", in: bundle, namespace: namespace)
        let preKeys = try singleChild("prekeys", in: bundle, namespace: namespace)
        let pkElements = children(named: "pk", in: preKeys)
        guard !pkElements.isEmpty, pkElements.count <= maximumPreKeyCount else { throw Error.invalidBundle }
        let keys = try pkElements.map { pk -> OMEMO2PublicPreKey in
            guard pk.uri == namespace else { throw Error.invalidBundle }
            return OMEMO2PublicPreKey(id: try keyID(pk.attributeStringValue(forName: "id")),
                                     publicKey: try base64(pk, expectedLength: 32))
        }
        let identityKey = try base64(ik, expectedLength: 32)
        let result = OMEMO2PublishedBundle(
            deviceID: deviceID, identityKey: identityKey,
            fingerprintPublicKey: try fingerprintPublicKey(identityKey: identityKey),
            signedPreKey: try base64(spk, expectedLength: 32),
            signedPreKeyID: try keyID(spk.attributeStringValue(forName: "id")),
            signature: try base64(spks, expectedLength: 64), preKeys: keys
        )
        try validate(result)
        return result
    }

    static func encode(_ value: OMEMO2PublishedBundle) throws -> DDXMLElement {
        try validate(value)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", integerValue: value.deviceID)
        let bundle = DDXMLElement(name: "bundle", xmlns: namespace)
        let spk = dataElement("spk", value.signedPreKey)
        spk.addAttribute(withName: "id", stringValue: String(value.signedPreKeyID))
        bundle.addChild(spk)
        bundle.addChild(dataElement("spks", value.signature))
        bundle.addChild(dataElement("ik", value.identityKey))
        let preKeys = DDXMLElement(name: "prekeys", xmlns: namespace)
        for key in value.preKeys {
            let element = dataElement("pk", key.publicKey)
            element.addAttribute(withName: "id", stringValue: String(key.id))
            preKeys.addChild(element)
        }
        bundle.addChild(preKeys)
        item.addChild(bundle)
        return item
    }

    static func publication(_ bundle: OMEMO2PublishedBundle) throws -> DDXMLElement {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: namespace + ":bundles")
        publish.addChild(try encode(bundle))
        pubsub.addChild(publish)
        pubsub.addChild(publishOptions(maxItems: "max"))
        return pubsub
    }

    static func publishOptions(maxItems: String) -> DDXMLElement {
        let options = DDXMLElement(name: "publish-options")
        let form = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        form.addAttribute(withName: "type", stringValue: "submit")
        for (name, value) in [
            ("FORM_TYPE", "http://jabber.org/protocol/pubsub#publish-options"),
            ("pubsub#access_model", "open"), ("pubsub#max_items", maxItems)
        ] {
            let field = DDXMLElement(name: "field")
            field.addAttribute(withName: "var", stringValue: name)
            if name == "FORM_TYPE" { field.addAttribute(withName: "type", stringValue: "hidden") }
            field.addChild(DDXMLElement(name: "value", stringValue: value))
            form.addChild(field)
        }
        options.addChild(form)
        return options
    }

    static func fingerprintPublicKey(identityKey: Data) throws -> Data {
        try Omemo2IdentityRepresentation.curvePublicKey(from: identityKey)
    }

    static func fingerprintPublicKey(storedIdentityKey: Data) throws -> Data {
        try Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: storedIdentityKey)
    }

    static func storedBundle(_ identity: SignalIdentityStorageItem, preKeys: [SignalPreKeysStorageItem]) throws -> OMEMO2PublishedBundle {
        guard identity.protocolProfile == namespace else { throw Error.unsupportedProfile }
        let identityData = try base64(identity.identityKey, expectedLength: 32)
        let value = OMEMO2PublishedBundle(
            deviceID: identity.deviceId, identityKey: identityData,
            fingerprintPublicKey: try fingerprintPublicKey(identityKey: identityData),
            signedPreKey: try base64(identity.signedPreKey, expectedLength: 32),
            signedPreKeyID: try keyID(String(identity.signedPreKeyId)),
            signature: try base64(identity.signedPreKeySignature, expectedLength: 64),
            preKeys: try preKeys.map {
                OMEMO2PublicPreKey(id: try keyID(String($0.pkId)), publicKey: try base64($0.preKey, expectedLength: 32))
            }
        )
        try validate(value)
        return value
    }

    private static func validate(_ value: OMEMO2PublishedBundle) throws {
        guard value.deviceID > 0, value.deviceID <= Int(Int32.max),
              !value.preKeys.isEmpty, value.preKeys.count <= maximumPreKeyCount,
              Set(value.preKeys.map(\.id)).count == value.preKeys.count,
              try fingerprintPublicKey(identityKey: value.identityKey) == value.fingerprintPublicKey else {
            throw Error.invalidBundle
        }
        // This authenticates the signed key and rejects invalid public keys for
        // every advertised OPK before the cache/trust transaction is entered.
        for preKey in value.preKeys { _ = try value.selectedBundle(preKeyID: preKey.id) }
    }

    private static func children(named name: String, in parent: DDXMLElement) -> [DDXMLElement] {
        (parent.children ?? []).compactMap { $0 as? DDXMLElement }.filter { $0.localName == name }
    }

    private static func singleChild(_ name: String, in parent: DDXMLElement, namespace: String) throws -> DDXMLElement {
        let values = children(named: name, in: parent)
        guard values.count == 1, values[0].uri == namespace else { throw Error.invalidBundle }
        return values[0]
    }

    static func keyID(_ string: String?) throws -> UInt32 {
        guard let string = string, !string.isEmpty,
              string.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = UInt32(string), value > 0, value <= UInt32(Int32.max) else { throw Error.invalidKeyID }
        return value
    }

    private static func base64(_ element: DDXMLElement, expectedLength: Int) throws -> Data {
        guard !(element.children ?? []).contains(where: { $0 is DDXMLElement }) else { throw Error.invalidBundle }
        return try base64(element.stringValue, expectedLength: expectedLength)
    }

    private static func base64(_ string: String?, expectedLength: Int) throws -> Data {
        guard let string = string, string.utf8.count <= 256 else { throw Error.invalidBase64 }
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        let normalized = Data(string.utf8.filter { !whitespace.contains($0) })
        guard let text = String(data: normalized, encoding: .ascii),
              let result = Data(base64Encoded: text), result.count == expectedLength,
              result.base64EncodedString() == text else { throw Error.invalidBase64 }
        return result
    }

    private static func dataElement(_ name: String, _ data: Data) -> DDXMLElement {
        let result = DDXMLElement(name: name, xmlns: namespace)
        result.stringValue = data.base64EncodedString()
        return result
    }
}
