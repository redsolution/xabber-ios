import CryptoKit
import Foundation
import XMPPFramework

/// Scheduling submits pre-encrypted content. The future transport time is
/// authenticated inside SCE, while the account still revalidates recipient
/// authority at its final stream gate.
enum ScheduledOMEMO2 {
    private static let fileNamespace = "https://xabber.com/protocol/files"
    private static let stickerNamespace = "https://xabber.com/protocol/stickers"
    private static let esfsNamespace = "urn:xmpp:esfs:0"
    private static let chatType = "chat"

    static func makeEncryptedMessage(
        plaintext: XMPPMessage, conversation: String, deliverAt: Date, omemo: OmemoManager
    ) throws -> XMPPMessage {
        let plaintext = try XMPPMessage(xmlString: plaintext.xmlString)
        guard let destination = XMPPJID(string: conversation), destination.full == destination.bare,
              plaintext.to?.full == destination.bare,
              plaintext.from == nil || plaintext.from?.full == omemo.owner,
              plaintext.type == chatType,
              !SCEReceivePolicy.containsOMEMO2(plaintext),
              validateEncryptedFiles(in: plaintext, owner: omemo.owner) else {
            throw XMPPMessageScheduleManager.ScheduleError.malformedPayload
        }
        try MessageManager.validatePreparedContentSize(plaintext)
        let bodies = SCEReceivePolicy.children(of: plaintext, named: "body", xmlns: SCEReceivePolicy.client)
        guard bodies.count <= 1 else { throw XMPPMessageScheduleManager.ScheduleError.malformedPayload }
        let text = bodies.first?.stringValue ?? ""
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentElements(in: plaintext).filter { $0.localName != "body" }
        guard !body.isEmpty || content.contains(where: { $0.localName == "reference" }),
              let xml = omemo.prepareStanzaContent(message: text, date: deliverAt, jid: destination.bare,
                  additionalContent: content.map(SCEReceivePolicy.canonicalElementCopy), ignoreTimeSignature: false) else {
            throw XMPPMessageScheduleManager.ScheduleError.malformedPayload
        }
        let prepared = try omemo.encryptPreparedMessage(
            message: xml, to: destination.bare, authenticatedContentTime: wireDate(deliverAt)
        )
        let origin = UUID().uuidString
        let message = XMPPMessage(type: chatType, to: destination, elementID: origin)
        message.setXmlns(SCEReceivePolicy.client)
        message.addAttribute(withName: "from", stringValue: omemo.owner)
        message.addOriginId(origin)
        message.addChild(prepared.element)
        message.addChild(DDXMLElement(name: "store", xmlns: "urn:xmpp:hints"))
        OmemoManager.synchronizeOutgoingEncryptionMetadata(message)
        return message
    }

    static func permitsEncryptedFiles(in message: XMPPMessage, owner: String) -> Bool {
        // A newly built KissXML tree resolves inherited namespaces on parse.
        guard let normalized = try? XMPPMessage(xmlString: message.xmlString) else { return false }
        return validateEncryptedFiles(in: normalized, owner: owner)
    }

    private static func validateEncryptedFiles(in element: DDXMLElement, owner: String) -> Bool {
        let elements = (element.children ?? []).compactMap { $0 as? DDXMLElement }
        for child in elements {
            if SCEReceivePolicy.matches(child, name: "file-sharing", namespace: fileNamespace) {
                // Sticker artwork is public and already stored in its catalog.
                if SCEReceivePolicy.matches(element, name: "sticker", namespace: stickerNamespace) { continue }
                guard let file = only(child, "file", fileNamespace),
                      let encrypted = only(file, "encrypted", esfsNamespace),
                      let key = only(encrypted, "key", esfsNamespace)?.stringValue,
                      let iv = only(encrypted, "iv", esfsNamespace)?.stringValue,
                      let size = only(file, "size", fileNamespace)?.stringValue,
                      let sources = only(child, "sources", fileNamespace),
                      let uri = only(sources, "uri", fileNamespace)?.stringValue,
                      let url = URL(string: uri) else { return false }
                let metadata = ["encryption-key": key, "iv": iv, "size": size]
                let descriptor = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: url, owner: owner, referenceIdentity: "scheduled")
                guard descriptor.state == .encrypted else { return false }
            } else if !validateEncryptedFiles(in: child, owner: owner) { return false }
        }
        return true
    }

    /// Masks server/projector input for encrypted rows. Legacy fallback text
    /// and unverified file metadata must never become scheduled content.
    static func sealedSnapshot(_ raw: String, owner: String, conversation: String) -> String? {
        guard !raw.isEmpty,
              let message = try? XMPPMessage(xmlString: raw),
              sealedElement(in: message, owner: owner, conversation: conversation) != nil else { return nil }
        for child in (message.children ?? []).compactMap({ $0 as? DDXMLElement }) {
            if !isSealedChild(child) { child.detach() }
        }
        return message.xmlString
    }

    static func isSealedMessage(_ message: XMPPMessage, owner: String, conversation: String) -> Bool {
        sealedElement(in: message, owner: owner, conversation: conversation) != nil
            && (message.children ?? []).compactMap({ $0 as? DDXMLElement }).allSatisfy(isSealedChild)
    }

    fileprivate static func sealedElement(in message: XMPPMessage, owner: String, conversation: String) -> DDXMLElement? {
        guard SCEReceivePolicy.matches(message, name: "message", namespace: SCEReceivePolicy.client),
              message.type == chatType, message.to?.full == conversation,
              message.from == nil || message.from?.bare == owner,
              let encrypted = only(message, "encrypted", SCEReceivePolicy.omemo),
              only(encrypted, "payload", SCEReceivePolicy.omemo) != nil else { return nil }
        return encrypted
    }

    private static func isSealedChild(_ element: DDXMLElement) -> Bool {
        switch element.uri {
        case SCEReceivePolicy.omemo:
            return element.localName == "encrypted"
        case "urn:xmpp:sid:0":
            return element.localName == "origin-id"
        case "urn:xmpp:hints":
            return element.localName == "store"
        case "urn:xmpp:eme:0":
            return element.localName == "encryption" && element.attributeStringValue(forName: "namespace") == SCEReceivePolicy.omemo
        default:
            return false
        }
    }

    private static func contentElements(in message: XMPPMessage) -> [DDXMLElement] {
        (message.children ?? []).compactMap { $0 as? DDXMLElement }.filter {
            $0.localName != "origin-id" && $0.localName != "opt-out" && $0.localName != "share" &&
            SCEReceivePolicy.isClientContentElement($0)
        }
    }

    private static func only(_ parent: DDXMLElement, _ name: String, _ namespace: String) -> DDXMLElement? {
        let children = SCEReceivePolicy.children(of: parent, named: name, xmlns: namespace)
        return children.count == 1 ? children.first : nil
    }

    /// XEP-SCHEDULE serializes a whole second. Bind the same instant into SCE
    /// and the local preview, even if the picked date had fractional seconds.
    static func wireDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    static func preview(owner: String, conversation: String, deliverAt: Date, messageXML: String) -> String? {
        ScheduledOMEMO2PreviewStore.shared.preview(owner: owner, conversation: conversation,
            deliverAt: deliverAt, messageXML: messageXML)
    }

    /// The creating device is not a recipient of its own OMEMO ciphertext.
    /// Reconstruct only an authenticated own-account echo with the exact
    /// locally sealed packet, route and due time. No incoming ratchet is used.
    static func localDeliveryContent(
        for message: XMPPMessage, owner: String, originalTime: OMEMOOriginalSendingTime?,
        previews: ScheduledOMEMO2PreviewStore = .shared
    ) -> DDXMLElement? {
        guard message.from?.bare == owner, let opponent = message.to?.bare, let originalTime else { return nil }
        let markers = SCEReceivePolicy.children(of: message, named: "deferred", xmlns: SCEReceivePolicy.schedule)
        guard markers.count == 1, let marker = markers.first, SCEReceivePolicy.isScheduledDeliveryMetadata(marker),
              let timestamp = marker.attributeStringValue(forName: "deliver-at"),
              let date = try? Omemo2PayloadCodec.timestamp(timestamp),
              abs(date.timeIntervalSince(originalTime.date)) <= Omemo2PayloadCodec.clockSkewAllowance,
              let plaintext = previews.preview(owner: owner, conversation: opponent, deliverAt: date, messageXML: message.xmlString),
              let packet = try? XMPPMessage(xmlString: plaintext) else { return nil }
        let content = DDXMLElement(name: "content", xmlns: SCEReceivePolicy.sce)
        for child in contentElements(in: packet) {
            content.addChild(SCEReceivePolicy.canonicalElementCopy(child))
        }
        return content
    }

    static func removePreviews(owner: String) throws {
        try ScheduledOMEMO2PreviewStore.shared.removePreviews(owner: owner)
    }

    static func removeAllPreviews() throws {
        try ScheduledOMEMO2PreviewStore.shared.removeAllPreviews()
    }
}

/// Only the creating installation can open a preview. Realm and the XMPP
/// mirror retain only ciphertext. The AES-GCM key is device-only Keychain data.
final class ScheduledOMEMO2PreviewStore {
    static let shared = ScheduledOMEMO2PreviewStore(directory: {
        let files = FileManager.default
        let base = HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment)
            ? files.temporaryDirectory.appendingPathComponent("ScheduledOMEMO2PreviewTests-\(UUID().uuidString)")
            : files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScheduledOMEMO2Previews", isDirectory: true)
    }(), keyProvider: { owner, create in
        try CredentialsManager.shared.scheduledOMEMO2PreviewKey(for: owner, create: create)
    })

    private struct Preview: Codable {
        let conversation: String
        let deliverAt: Date
        let plaintext: String
    }

    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let maxFileCount = 256
    private static let maxXMLBytes = 65_536
    private let directory: URL
    private let keyProvider: (String, Bool) throws -> Data?
    private let lock = NSLock()

    init(directory: URL, keyProvider: @escaping (String, Bool) throws -> Data?) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    func save(plaintext: XMPPMessage, sealed: XMPPMessage, owner: String, conversation: String, deliverAt: Date) throws {
        guard let address = address(of: sealed, owner: owner, conversation: conversation),
              let xml = plaintext.compactXMLString, xml.utf8.count <= Self.maxXMLBytes else {
            throw XMPPMessageScheduleManager.ScheduleError.malformedPayload
        }
        try lock.withLock {
            guard let key = try keyProvider(owner, true), key.count == 32 else {
                throw XMPPMessageScheduleManager.ScheduleError.sendRejected
            }
            let files = FileManager.default
            var folder = directory
            let ownerFolder = ownerDirectory(owner)
            try files.createDirectory(at: ownerFolder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var protection = URLResourceValues()
            protection.isExcludedFromBackup = true
            try folder.setResourceValues(protection)
            let existing = try files.contentsOfDirectory(at: ownerFolder, includingPropertiesForKeys: [.contentModificationDateKey])
            let now = Date()
            var liveCount = 0
            for candidate in existing {
                if let expiration = try candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   expiration < now {
                    try files.removeItem(at: candidate)
                } else { liveCount += 1 }
            }
            guard liveCount < Self.maxFileCount else { throw XMPPMessageScheduleManager.ScheduleError.resourceConstraint }
            let due = ScheduledOMEMO2.wireDate(deliverAt)
            let record = try JSONEncoder().encode(Preview(conversation: conversation, deliverAt: due, plaintext: xml))
            let box = try AES.GCM.seal(record, using: SymmetricKey(data: key), authenticating: address.associatedData)
            guard let ciphertext = box.combined else { throw XMPPMessageScheduleManager.ScheduleError.sendRejected }
            try ciphertext.write(to: address.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try files.setAttributes([.modificationDate: due.addingTimeInterval(Self.retention)], ofItemAtPath: address.url.path)
        }
    }

    func preview(owner: String, conversation: String, deliverAt: Date, messageXML: String) -> String? {
        guard messageXML.utf8.count <= Self.maxXMLBytes * 2, let sealed = try? XMPPMessage(xmlString: messageXML),
              let address = address(of: sealed, owner: owner, conversation: conversation) else { return nil }
        return lock.withLock {
            do {
                guard let key = try keyProvider(owner, false), key.count == 32 else { return nil }
                let handle = try FileHandle(forReadingFrom: address.url)
                defer { try? handle.close() }
                guard let ciphertext = try handle.read(upToCount: Self.maxXMLBytes * 3 + 1),
                      ciphertext.count <= Self.maxXMLBytes * 3 else { return nil }
                let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                    using: SymmetricKey(data: key), authenticating: address.associatedData)
                let record = try JSONDecoder().decode(Preview.self, from: plaintext)
                guard record.conversation == conversation, record.deliverAt == ScheduledOMEMO2.wireDate(deliverAt),
                      Date() <= record.deliverAt.addingTimeInterval(Self.retention) else { return nil }
                return record.plaintext
            } catch { return nil }
        }
    }

    func remove(owner: String, conversation: String, sealed: XMPPMessage) {
        guard let address = address(of: sealed, owner: owner, conversation: conversation) else { return }
        lock.withLock { try? removeItem(at: address.url) }
    }

    func removePreviews(owner: String) throws {
        try lock.withLock { try removeItem(at: ownerDirectory(owner)) }
    }

    func removeAllPreviews() throws {
        try lock.withLock { try removeItem(at: directory) }
    }

    private func removeItem(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }

    private func ownerDirectory(_ owner: String) -> URL {
        directory.appendingPathComponent(Self.hex(Data(SHA256.hash(data: Data(owner.utf8)))), isDirectory: true)
    }

    private func address(of sealed: XMPPMessage, owner: String, conversation: String) -> (url: URL, associatedData: Data)? {
        guard let encrypted = ScheduledOMEMO2.sealedElement(in: sealed, owner: owner, conversation: conversation),
              let fingerprint = try? OmemoManager.outgoingOMEMO2Fingerprint(encrypted) else { return nil }
        var context = Data("Xabber scheduled OMEMO2 preview v1\n\(owner)\n\(conversation)\n".utf8)
        context.append(fingerprint)
        return (ownerDirectory(owner).appendingPathComponent(Self.hex(fingerprint)), context)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
