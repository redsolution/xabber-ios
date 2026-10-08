import Foundation
import XMPPFramework
import RealmSwift

enum ForwardPreparationError: Error, Equatable {
    case missingSource(String)
    case foreignOwner(String)
    case malformedSource(String)
    case unavailablePlaintext(String)
    case maximumDepth
    case oversizedContent
}

/// XML is captured at selection/admission time. Accessors return new trees so
/// neither a Realm update nor a caller mutating a parsed tree changes a retry.
struct ForwardSourceSnapshot {
    private let xml: String
    let date: Date?
    let selectionID: String
    let attributionCard: ForwardContactCard?

    init(message: XMPPMessage, date: Date?, selectionID: String,
         attributionCard: ForwardContactCard? = nil) {
        xml = message.xmlString
        self.date = date
        self.selectionID = selectionID
        self.attributionCard = attributionCard
    }

    var message: XMPPMessage {
        // Captured XML came from an XML tree; it is never user-entered XML.
        let document = try! DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: document.rootElement()!)
    }
}

enum ForwardSendIntent { case forward, reply }

struct ForwardSendOptions {
    var hideComments: Bool
    var hideSender: Bool

    init(hideComments: Bool = false, hideSender: Bool = false) {
        self.hideComments = hideComments
        self.hideSender = hideSender
    }
}

struct ForwardPreparedUnit {
    enum Kind { case forwardEnvelope, plain }
    let body: String
    let kind: Kind
    private let referenceXML: [String]

    init(body: String, refs: [DDXMLElement], kind: Kind) {
        self.body = body
        self.kind = kind
        referenceXML = refs.map(\.xmlString)
    }

    var refs: [DDXMLElement] {
        referenceXML.map {
            let root = try! DDXMLDocument(xmlString: $0, options: 0).rootElement()!
            root.detach()
            return root
        }
    }

    func appendContent(to message: XMPPMessage) {
        let bodyElement = DDXMLElement(name: "body", xmlns: "jabber:client")
        bodyElement.stringValue = body
        message.addChild(bodyElement)
        refs.forEach(message.addChild)
    }

    /// Includes the serialized body element and escaped XML, not String.count.
    var serializedByteCount: Int {
        let element = DDXMLElement(name: "body", xmlns: "jabber:client")
        element.stringValue = body
        return element.xmlString.utf8.count + referenceXML.reduce(0) { $0 + $1.utf8.count }
    }
}

/// Pure content planning. Transport IDs, encryption, queue admission and upload
/// belong to the common sender and are applied to every resulting carrier.
enum ForwardSendPlanner {
    private static let referencesNS = "https://xabber.com/protocol/references"
    private static let forwardNS = "urn:xmpp:forward:0"
    private static let groupsNS = "https://xabber.com/protocol/groups"

    private struct Entry {
        let message: XMPPMessage
        let date: Date?
        let card: ForwardContactCard?
    }

    private struct Envelope {
        var entries: [Entry]
        var cards: [DDXMLElement]
    }

    private struct Decomposition {
        var donated: [Envelope] = []
        var own: Entry?
    }

    static func plan(sources: [ForwardSourceSnapshot], comment: String,
                     intent: ForwardSendIntent = .forward,
                     options: ForwardSendOptions = .init(),
                     byteBudget: Int = 32_768) throws -> [ForwardPreparedUnit] {
        guard byteBudget > 0 else { throw ForwardPreparationError.oversizedContent }
        let ordered = sources.enumerated().sorted {
            let left = $0.element.date ?? .distantPast
            let right = $1.element.date ?? .distantPast
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        var donated: [Envelope] = []
        var own: [Entry] = []
        for source in ordered {
            let parts = try decompose(source.message, date: source.date,
                                      card: source.attributionCard,
                                      options: options, depth: 0,
                                      selectionID: source.selectionID)
            donated += parts.donated
            if let entry = parts.own { own.append(entry) }
        }

        if options.hideSender {
            let flattened = (donated.flatMap(\.entries) + own).enumerated().sorted {
                let left = $0.element.date ?? .distantPast
                let right = $1.element.date ?? .distantPast
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            var units = flattened.map(plainUnit)
            if !comment.isEmpty { units.append(ForwardPreparedUnit(body: comment, refs: [], kind: .plain)) }
            guard units.allSatisfy({ $0.serializedByteCount <= byteBudget }) else {
                throw ForwardPreparationError.oversizedContent
            }
            return units
        }

        if intent == .reply {
            let entries = (donated.flatMap(\.entries) + own).enumerated().sorted {
                let left = $0.element.date ?? .distantPast
                let right = $1.element.date ?? .distantPast
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            guard !entries.isEmpty else {
                return try plainComment(comment, budget: byteBudget)
            }
            let unit = serialize(entries: entries, cards: donated.flatMap(\.cards), comment: comment)
            guard unit.serializedByteCount <= byteBudget else { throw ForwardPreparationError.oversizedContent }
            return [unit]
        }

        // Existing deliverable envelopes are donated as units. Replanning a new
        // selection must not truncate or split their previously supplied payload.
        var units = donated.map { serialize(entries: $0.entries, cards: $0.cards, comment: "") }
        if own.isEmpty {
            units += try plainComment(comment, budget: byteBudget)
            return units
        }

        var chunks: [[Entry]] = []
        var chunk: [Entry] = []
        for entry in own {
            let candidate = serialize(entries: chunk + [entry], cards: [], comment: "")
            if candidate.serializedByteCount <= byteBudget {
                chunk.append(entry)
            } else {
                guard !chunk.isEmpty else { throw ForwardPreparationError.oversizedContent }
                chunks.append(chunk)
                chunk = [entry]
                guard serialize(entries: chunk, cards: [], comment: "").serializedByteCount <= byteBudget else {
                    throw ForwardPreparationError.oversizedContent
                }
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        // Move entries to a final chunk when reserving the new comment requires
        // it. A single entry plus its comment remains an indivisible new unit.
        if !comment.isEmpty {
            while let last = chunks.last,
                  serialize(entries: last, cards: [], comment: comment).serializedByteCount > byteBudget {
                guard last.count > 1 else { throw ForwardPreparationError.oversizedContent }
                let final = [last.last!]
                chunks[chunks.count - 1] = Array(last.dropLast())
                chunks.append(final)
            }
        }
        for (index, entries) in chunks.enumerated() {
            units.append(serialize(entries: entries, cards: [], comment: index == chunks.count - 1 ? comment : ""))
        }
        return units
    }

    private static func plainComment(_ comment: String, budget: Int) throws -> [ForwardPreparedUnit] {
        guard !comment.isEmpty else { return [] }
        let unit = ForwardPreparedUnit(body: comment, refs: [], kind: .plain)
        guard unit.serializedByteCount <= budget else { throw ForwardPreparationError.oversizedContent }
        return [unit]
    }

    private static func decompose(_ source: XMPPMessage, date: Date?, card: ForwardContactCard?,
                                  options: ForwardSendOptions, depth: Int,
                                  selectionID: String) throws -> Decomposition {
        guard depth < inlineForwardMaximumDepth else { throw ForwardPreparationError.maximumDepth }
        try validate(source, selectionID: selectionID)
        let forwards = admittedInlineForwardReferences(in: source)
        let canonicalForwardReferences = children(source, "reference", referencesNS).filter {
            !children($0, "forwarded", forwardNS).isEmpty
        }
        guard canonicalForwardReferences.count == forwards.count else {
            // Invalid canonical forwards remain readable on receive. They cannot
            // be wrapped into a new outgoing forward as if flattening succeeded.
            throw ForwardPreparationError.malformedSource(selectionID)
        }
        var result = Decomposition()
        var flat: [Entry] = []
        let parentCards = scopedCards(in: source)
        func flush() {
            guard !flat.isEmpty else { return }
            result.donated.append(Envelope(entries: flat, cards: parentCards))
            flat = []
        }
        for reference in forwards.sorted(by: {
            (Int($0.attributeStringValue(forName: "begin") ?? "") ?? 0) <
                (Int($1.attributeStringValue(forName: "begin") ?? "") ?? 0)
        }) {
            guard let forwarded = children(reference, "forwarded", forwardNS).first,
                  let raw = children(forwarded, "message", "jabber:client").first,
                  let payload = inlineForwardPayloadMessage(from: reference) else {
                throw ForwardPreparationError.malformedSource(selectionID)
            }
            let inner = XMPPMessage(from: raw.copy() as! DDXMLElement)
            try validate(inner, selectionID: selectionID)
            let innerCard = ForwardContactDataCodec.matchingCard(
                for: inner.attributeStringValue(forName: "from") ?? "",
                cards: ForwardContactDataCodec.cards(in: source))
            let parts = try decompose(inner, date: payload.date, card: innerCard,
                                      options: ForwardSendOptions(hideComments: false, hideSender: options.hideSender),
                                      depth: depth + 1, selectionID: selectionID)
            if !parts.donated.isEmpty {
                flush()
                result.donated += parts.donated
            }
            if let own = parts.own { flat.append(own) }
        }
        flush()

        let ownMessage = try isolateOwnContent(source, excluding: forwards, hideComments: options.hideComments)
        if hasVisibleContent(ownMessage) {
            stripGroupRole(in: ownMessage)
            result.own = Entry(message: ownMessage, date: date, card: card)
        }
        return result
    }

    private static func validate(_ source: XMPPMessage, selectionID: String) throws {
        guard SCEReceivePolicy.matches(source, name: "message", namespace: "jabber:client"),
              let from = source.from?.full, !from.isEmpty,
              let to = source.to?.full, !to.isEmpty,
              children(source, "body", "jabber:client").count <= 1 else {
            throw ForwardPreparationError.malformedSource(selectionID)
        }
        // A forwarded ciphertext does not authorize its plaintext siblings.
        guard !SCEReceivePolicy.hasOMEMO2(source) else {
            throw ForwardPreparationError.unavailablePlaintext(selectionID)
        }
    }

    private static func isolateOwnContent(_ source: XMPPMessage, excluding forwards: [DDXMLElement],
                                         hideComments: Bool) throws -> XMPPMessage {
        let copy = XMPPMessage(from: source.copy() as! DDXMLElement)
        if forwards.isEmpty && !hideComments { return copy }
        let sourceBody = children(source, "body", "jabber:client").first?.stringValue ?? ""
        let escaped = Array(sourceBody.xmlEscaping(reverse: false).unicodeScalars)
        let ranges = forwards.compactMap(range).sorted { $0.lowerBound < $1.lowerBound }
        let sourceRefs = children(source, "reference", referencesNS)
        let forwardIndices = admittedInlineForwardReferenceIndices(in: source)
        let remainingRefs = sourceRefs.enumerated().filter { index, _ in
            !forwardIndices.contains(index)
        }
        let admitted = admittedMessageContentReferenceIndices(in: source)
        for (index, reference) in remainingRefs {
            let hasRange = reference.attribute(forName: "begin") != nil || reference.attribute(forName: "end") != nil
            if hasRange {
                guard let bounds = range(reference), bounds.upperBound <= escaped.count else {
                    throw ForwardPreparationError.malformedSource(source.elementID ?? "")
                }
                if ["mutable", "decoration"].contains(reference.attributeStringValue(forName: "type") ?? ""),
                   !admitted.contains(index) {
                    throw ForwardPreparationError.malformedSource(source.elementID ?? "")
                }
            }
        }
        var retainedIndices = Array(escaped.indices).filter { index in
            !ranges.contains(where: { $0.contains(index) })
        }
        if hideComments {
            let mediaRanges = remainingRefs.map(\.element).filter { reference in
                guard let kind = getReferenceType(reference) else { return false }
                return ["media", "voice", "geoloc", "contact"].contains(kind)
            }.compactMap(range)
            retainedIndices = retainedIndices.filter { index in mediaRanges.contains { $0.contains(index) } }
        }
        let retainedSet = Set(retainedIndices)
        let newEscaped = String(String.UnicodeScalarView(retainedIndices.map { escaped[$0] }))
        children(copy, "body", "jabber:client").forEach { $0.detach() }
        let newBody = DDXMLElement(name: "body", xmlns: "jabber:client")
        newBody.stringValue = newEscaped.xmlEscaping(reverse: true)
        copy.addChild(newBody)
        children(copy, "reference", referencesNS).forEach { $0.detach() }
        for (_, reference) in remainingRefs {
            let refCopy = reference.copy() as! DDXMLElement
            if let originalRange = range(reference) {
                let surviving = originalRange.filter { retainedSet.contains($0) }
                guard !surviving.isEmpty else { continue }
                let begin = retainedIndices.filter { $0 < originalRange.lowerBound }.count
                refCopy.removeAttribute(forName: "begin")
                refCopy.removeAttribute(forName: "end")
                refCopy.addAttribute(withName: "begin", integerValue: begin)
                refCopy.addAttribute(withName: "end", integerValue: begin + surviving.count)
            }
            copy.addChild(refCopy)
        }
        return copy
    }

    private static func hasVisibleContent(_ message: XMPPMessage) -> Bool {
        let body = children(message, "body", "jabber:client").first?.stringValue ?? ""
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return children(message, "reference", referencesNS).contains {
            ["media", "voice", "geoloc", "contact"].contains(getReferenceType($0) ?? "")
        }
    }

    private static func plainUnit(_ entry: Entry) -> ForwardPreparedUnit {
        let body = children(entry.message, "body", "jabber:client").first?.stringValue ?? ""
        let refs = children(entry.message, "reference", referencesNS).filter {
            guard let kind = getReferenceType($0) else { return false }
            return ["media", "voice", "geoloc", "contact", "markup"].contains(kind)
        }
        return ForwardPreparedUnit(body: body, refs: refs, kind: .plain)
    }

    private static func serialize(entries: [Entry], cards: [DDXMLElement], comment: String) -> ForwardPreparedUnit {
        var body = ""
        var refs: [DDXMLElement] = []
        var offset = 0
        for entry in entries {
            let original = entry.message.copy() as! DDXMLElement
            stripGroupRole(in: original)
            let quote = fallback(for: entry)
            let reference = DDXMLElement(name: "reference", xmlns: referencesNS)
            reference.addAttribute(withName: "type", stringValue: "mutable")
            reference.addAttribute(withName: "begin", integerValue: offset)
            offset += quote.xmlEscaping(reverse: false).unicodeScalars.count
            reference.addAttribute(withName: "end", integerValue: offset)
            let forwarded = DDXMLElement(name: "forwarded", xmlns: forwardNS)
            if let date = entry.date {
                let delay = DDXMLElement(name: "delay", xmlns: "urn:xmpp:delay")
                delay.addAttribute(withName: "stamp", stringValue: date.XMPPFormattedDate)
                forwarded.addChild(delay)
            }
            forwarded.addChild(original)
            reference.addChild(forwarded)
            refs.append(reference)
            body += quote
        }
        body += comment
        var allCards = cards
        allCards += entries.compactMap(\.card).map(ForwardContactDataCodec.encode)
        // Keep full supplied xCard XML (including unknown properties), but reject
        // conflicting identity assertions exactly like the receive codec.
        let holder = XMPPMessage(messageType: .chat, to: nil, elementID: nil, child: nil)
        allCards.forEach { holder.addChild($0.copy() as! DDXMLElement) }
        let accepted = ForwardContactDataCodec.cards(in: holder)
        let entryJIDs = Set(entries.compactMap { $0.message.from?.bare })
        var included = Set<String>()
        for rawCard in allCards {
            guard let card = ForwardContactDataCodec.decode(rawCard), accepted.contains(card),
                  entryJIDs.contains(card.jid), included.insert(card.jid).inserted else { continue }
            refs.append(rawCard.copy() as! DDXMLElement)
        }
        return ForwardPreparedUnit(body: body, refs: refs, kind: .forwardEnvelope)
    }

    private static func fallback(for entry: Entry) -> String {
        let from = entry.card?.name ?? entry.message.from?.bare ?? ""
        let date = entry.date.map { "[\($0.XMPPFormattedDate)] " } ?? ""
        let text = children(entry.message, "body", "jabber:client").first?.stringValue ?? ""
        return (date + from + ":\n" + text).components(separatedBy: "\n")
            .map { "> " + $0 }.joined(separator: "\n") + "\n"
    }

    private static func scopedCards(in message: XMPPMessage) -> [DDXMLElement] {
        let accepted = ForwardContactDataCodec.cards(in: message)
        return children(message, "reference", referencesNS).filter {
            guard let card = ForwardContactDataCodec.decode($0) else { return false }
            return accepted.contains(card)
        }
    }

    private static func stripGroupRole(in message: DDXMLElement) {
        var users = children(message, "x", groupsNS).flatMap { children($0, "user", groupsNS) }
        users += children(message, "reference", referencesNS).flatMap { children($0, "user", groupsNS) }
        users.forEach { children($0, "role", groupsNS).forEach { $0.detach() } }
    }

    private static func range(_ reference: DDXMLElement) -> Range<Int>? {
        guard let begin = Int(reference.attributeStringValue(forName: "begin") ?? ""),
              let end = Int(reference.attributeStringValue(forName: "end") ?? ""),
              begin >= 0, end > begin else { return nil }
        return begin..<end
    }

    private static func children(_ element: DDXMLElement, _ name: String, _ namespace: String) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: element, named: name, xmlns: namespace)
    }
}

enum ForwardSourceLoader {
    static func load(ids: [String], owner: String, realm: Realm) throws -> [ForwardSourceSnapshot] {
        try ids.map { primary in
            let row = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            guard let raw = realm.object(ofType: MessageStanzaStorageItem.self,
                                         forPrimaryKey: [primary, "stanza"].prp()) else {
                throw ForwardPreparationError.missingSource(primary)
            }
            guard raw.owner == owner, row == nil || row?.owner == owner else {
                throw ForwardPreparationError.foreignOwner(primary)
            }
            guard let document = try? DDXMLDocument(xmlString: raw.stanza, options: 0),
                  let root = document.rootElement(), root.localName == "message" else {
                throw ForwardPreparationError.malformedSource(primary)
            }
            let message = XMPPMessage(from: root)
            if SCEReceivePolicy.hasOMEMO2(message) {
                guard row?.canForwardAuthenticatedPlaintext(stanzaXML: raw.stanza, owner: owner) == true else {
                    throw ForwardPreparationError.unavailablePlaintext(primary)
                }
                // Reconstruction retains the verified outer ciphertext first.
                // Remove only that transport wrapper from the snapshot; any
                // encrypted child supplied by the peer remains unavailable.
                SCEReceivePolicy.children(of: message, named: "encrypted", xmlns: SCEReceivePolicy.omemo).first?.detach()
                SCEReceivePolicy.children(of: message, named: "encryption", xmlns: "urn:xmpp:eme:0")
                    .filter { $0.attributeStringValue(forName: "namespace") == SCEReceivePolicy.omemo }
                    .forEach { $0.detach() }
            }
            // Old locally generated outgoing XML omitted the stream's implicit
            // namespace/from. Restore only what this owner-scoped local row knows.
            if (message.uri ?? "").isEmpty { message.setXmlns("jabber:client") }
            if row?.outgoing == true, message.attribute(forName: "from") == nil {
                message.addAttribute(withName: "from", stringValue: owner)
            }
            if let row, row.outgoing, message.attribute(forName: "to") == nil {
                message.addAttribute(withName: "to", stringValue: row.opponent)
            }
            // A Saved service wrapper has one canonical, admitted forward and
            // no own content. Rejected payloads must remain for planner validation.
            let references = admittedInlineForwardReferences(in: message)
            let canonicalForwardReferenceCount = SCEReceivePolicy.children(
                of: message, named: "reference", xmlns: "https://xabber.com/protocol/references"
            ).filter {
                !SCEReceivePolicy.children(of: $0, named: "forwarded", xmlns: "urn:xmpp:forward:0").isEmpty
            }.count
            if let row, row.conversationType == .saved,
               [message.from?.bare, message.to?.bare].contains(row.opponent),
               canonicalForwardReferenceCount == 1, references.count == 1,
               message.body?.xmlEscaping(reverse: false)
                .excludeFromBody(references, groupchat: nil).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
               let payload = inlineForwardPayloadMessage(from: references[0]) {
                return ForwardSourceSnapshot(message: payload.message, date: payload.date,
                                             selectionID: primary,
                                             attributionCard: ForwardContactDataCodec.matchingCard(
                                                for: payload.message.from?.bare ?? "",
                                                cards: ForwardContactDataCodec.cards(in: message)))
            }
            let carriedCard = ForwardContactDataCodec.matchingCard(
                for: message.from?.bare ?? "", references: row?.references.toArray() ?? [])
            let originalDate: Date? = row?.systemMetadata?["forwardOriginalDateUnknown"] as? Bool == true
                ? nil : (getDeliveryDate(message) ?? row?.sentDate ?? raw.timestamp)
            return ForwardSourceSnapshot(message: message,
                                         date: originalDate,
                                         selectionID: primary,
                                         attributionCard: carriedCard ?? localCard(for: message, owner: owner, realm: realm))
        }
    }

    private static func localCard(for message: XMPPMessage, owner: String, realm: Realm) -> ForwardContactCard? {
        guard let jid = message.from?.bare, !jid.isEmpty else { return nil }
        let roster = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
        if let group = realm.object(ofType: GroupSnapshotStorageItem.self,
                                    forPrimaryKey: GroupStorageKey.groupPrimary(owner: owner, groupJID: jid)),
           group.owner == owner {
            return ForwardContactCard(jid: jid, name: group.name ?? roster?.displayName ?? jid,
                                      nickname: nil, kind: .group,
                                      privacy: group.privacyRaw.flatMap(ForwardContactCard.Privacy.init(rawValue:)),
                                      avatarURI: group.avatarURL)
        }
        let storedProfile = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid)
        let vcard = storedProfile?.owner == owner ? storedProfile : nil
        let name = roster?.displayName ?? vcard?.generatedNickname ?? jid
        return ForwardContactCard(jid: jid, name: name, nickname: vcard?.nickname.isEmpty == false ? vcard?.nickname : nil,
                                  kind: groupchatUserElement(from: message) == nil ? .individual : .group,
                                  privacy: nil, avatarURI: roster?.avatarMaxUrl ?? roster?.avatarMinUrl)
    }
}
