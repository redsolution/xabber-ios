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
//

import Foundation
import XMPPFramework
import RealmSwift

private let groupchatXMLNS = "https://xabber.com/protocol/groups"
private let referencesXMLNS = "https://xabber.com/protocol/references"
private let geolocXMLNS = "http://jabber.org/protocol/geoloc"
private let contactSharingXMLNS = "https://xabber.com/protocol/contact-sharing"
private let avatarMetadataXMLNS = "urn:xmpp:avatar:metadata"
private let inlineForwardXMLNS = "urn:xmpp:forward:0"
private let delayedDeliveryXMLNS = "urn:xmpp:delay"
private let markupXMLNS = "https://xabber.com/protocol/markup"

let inlineForwardMaximumDepth = 8

private func validatedHTTPThumbnailURI(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.isNotEmpty else { return nil }
    let encoded = value.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed
    ) ?? value
    guard let url = URL(string: encoded),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host?.isNotEmpty == true else {
        return nil
    }
    return value
}

enum GroupSystemMessageSource: Equatable {
    case live
    case mam
}

private struct MessageReferenceWireRange: Equatable {
    let begin: Int
    let end: Int

    func stringRange(in body: String) -> Range<String.Index>? {
        let scalars = body.unicodeScalars
        guard begin >= 0,
              end >= begin,
              end <= scalars.count else {
            return nil
        }

        let lowerScalarIndex = scalars.index(scalars.startIndex, offsetBy: begin)
        let upperScalarIndex = scalars.index(scalars.startIndex, offsetBy: end)
        // Wire offsets can split a composed character at a scalar boundary.
        // Converting with String.Index(_:within:) requires a Character boundary
        // and would reject valid ranges before a combining mark.
        return lowerScalarIndex..<upperScalarIndex
    }
}

private func messageReferenceWireRange(
    _ reference: DDXMLElement,
    in escapedBody: String
) -> MessageReferenceWireRange? {
    guard let beginValue = reference.attributeStringValue(forName: "begin"),
          let endValue = reference.attributeStringValue(forName: "end"),
          let begin = Int(beginValue),
          let end = Int(endValue) else {
        return nil
    }

    let range = MessageReferenceWireRange(begin: begin, end: end)
    return range.stringRange(in: escapedBody) == nil ? nil : range
}

private func referenceHasAnyWireRangeAttribute(_ reference: DDXMLElement) -> Bool {
    reference.attributeStringValue(forName: "begin") != nil ||
    reference.attributeStringValue(forName: "end") != nil
}

private func referenceRequiresWireRange(_ reference: DDXMLElement, kind: String) -> Bool {
    if ["media", "voice"].contains(kind) {
        return true
    }
    return reference.attributeStringValue(forName: "type") == "mutable" ||
    reference.attributeStringValue(forName: "type") == "decoration"
}

private func isAnonymousMutableReference(_ reference: DDXMLElement) -> Bool {
    let elementChildren = reference.children?.compactMap { $0 as? DDXMLElement } ?? []
    return SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesXMLNS) &&
    reference.attributeStringValue(forName: "type") == "mutable" &&
    elementChildren.isEmpty &&
    getReferenceType(reference) == nil
}

private func geolocElement(from reference: DDXMLElement) -> DDXMLElement? {
    guard SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesXMLNS),
          reference.attributeStringValue(forName: "type") == "mutable" else {
        return nil
    }
    let geolocElements = SCEReceivePolicy.children(of: reference, named: "geoloc", xmlns: geolocXMLNS)
    guard geolocElements.count == 1 else { return nil }
    return geolocElements[0]
}

private func validGeolocElement(from reference: DDXMLElement) -> DDXMLElement? {
    guard let geoloc = geolocElement(from: reference),
          validGeolocCoordinate(childText(geoloc, name: "lat"), range: -90.0...90.0) != nil,
          validGeolocCoordinate(childText(geoloc, name: "lon"), range: -180.0...180.0) != nil else {
        return nil
    }
    return geoloc
}

private func contactElement(from reference: DDXMLElement) -> DDXMLElement? {
    guard SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesXMLNS),
          reference.attributeStringValue(forName: "type") == "mutable" else {
        return nil
    }
    let contactElements = SCEReceivePolicy.children(of: reference, named: "contact", xmlns: contactSharingXMLNS)
    guard contactElements.count == 1 else { return nil }
    return contactElements[0]
}

private func validContactJID(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.isNotEmpty,
          let jid = XMPPJID(string: value),
          jid.resource == nil,
          jid.bare == value else {
        return nil
    }
    return value
}

private func validContactEntity(_ value: String?) -> MessageContactEntityKind? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.isNotEmpty else {
        return .contact
    }
    return MessageContactEntityKind(rawValue: value)
}

private func validContactElement(from reference: DDXMLElement) -> DDXMLElement? {
    guard let contact = contactElement(from: reference),
          validContactJID(contact.attributeStringValue(forName: "jid")) != nil,
          validContactEntity(contact.attributeStringValue(forName: "entity")) != nil else {
        return nil
    }
    return contact
}

private func childText(_ element: DDXMLElement, name: String) -> String? {
    guard let value = referenceChild(element, named: name)?
        .stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          value.isNotEmpty else {
        return nil
    }
    return value
}

private func validGeolocCoordinate(_ value: String?, range: ClosedRange<Double>) -> String? {
    guard let value,
          let coordinate = Double(value),
          coordinate.isFinite,
          range.contains(coordinate) else {
        return nil
    }
    return value
}

private func validGeolocAccuracy(_ value: String?) -> String? {
    guard let value else { return nil }
    guard let accuracy = Double(value), accuracy.isFinite, accuracy >= 0 else {
        return nil
    }
    return value
}

func groupchatUserElement(from message: XMPPMessage) -> DDXMLElement? {
    guard message.attributeStringValue(forName: "type") == "chat",
          let groupDecoration = uniqueCanonicalGroupChild(named: "x", in: message),
          (try? GroupProtocolCodec.decodeMessageAuthor(groupDecoration)) != nil else {
        return nil
    }
    return directElementChildren(of: groupDecoration).first
}

private func uniqueCanonicalGroupChild(named name: String, in parent: DDXMLElement) -> DDXMLElement? {
    let matches = directElementChildren(of: parent).filter {
        $0.name == name && effectiveNamespace(of: $0) == groupchatXMLNS
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
}

private func directElementChildren(of element: DDXMLElement) -> [DDXMLElement] {
    element.children?.compactMap { $0 as? DDXMLElement } ?? []
}

private func effectiveNamespace(of element: DDXMLElement) -> String? {
    if let namespace = element.uri { return namespace }
    var current: DDXMLElement? = element
    while let candidate = current {
        if let namespace = candidate.xmlns() {
            return namespace
        }
        current = candidate.parent as? DDXMLElement
    }
    return nil
}

private func referenceChild(_ parent: DDXMLElement, named name: String, xmlns namespace: String? = nil) -> DDXMLElement? {
    guard let namespace = namespace ?? effectiveNamespace(of: parent) else { return nil }
    return SCEReceivePolicy.children(of: parent, named: name, xmlns: namespace).first
}

private func referenceMessageBody(_ message: XMPPMessage) -> String {
    SCEReceivePolicy.children(of: message, named: "body", xmlns: "jabber:client").first?.stringValue ?? ""
}

/// Classifying a reference also grants it permission to hide its fallback body.
/// Require the same qualified file/source shape used by materialization.
private func fileSharingPayload(_ fileSharing: DDXMLElement) -> (file: DDXMLElement, uri: String)? {
    guard SCEReceivePolicy.matches(fileSharing, name: "file-sharing", namespace: "https://xabber.com/protocol/files"),
          let file = referenceChild(fileSharing, named: "file"),
          let sources = referenceChild(fileSharing, named: "sources"),
          let uri = SCEReceivePolicy.children(of: sources, named: "uri", xmlns: "https://xabber.com/protocol/files")
            .compactMap({ $0.stringValue }).first(where: {
                URL(string: $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) != nil
            }) else { return nil }
    return (file, uri)
}

private func groupchatMetadata(from user: DDXMLElement) -> [String: Any] {
    var metadata: [String: Any] = [:]
    metadata["id"] = user.attributeStringValue(forName: "id", withDefaultValue: "")
    metadata["jid"] = user.element(forName: "jid")?.stringValue ?? ""
    metadata["nickname"] = user.element(forName: "nickname")?.stringValue ?? ""
    metadata["role"] = user.element(forName: "role")?.stringValue ?? ""
    metadata["badge"] = user.element(forName: "badge")?.stringValue ?? ""
    if let avatarInfo = user.element(forName: "avatar")?.element(forName: "info")
        ?? user.element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")?.element(forName: "info") {
        metadata["avatar_uri"] = avatarInfo.attributeStringValue(forName: "url", withDefaultValue: "")
        metadata["avatar_id"] = avatarInfo.attributeStringValue(forName: "id", withDefaultValue: "")
    }
    return metadata
}

private func groupchatMetadata(from member: GroupMember) -> [String: Any] {
    var metadata: [String: Any] = ["id": member.id]
    metadata["jid"] = member.jid ?? ""
    metadata["nickname"] = member.nickname ?? ""
    metadata["role"] = member.role?.rawValue ?? ""
    metadata["badge"] = member.badge ?? ""
    if let avatar = member.avatar {
        metadata["avatar_uri"] = avatar.url ?? ""
        metadata["avatar_id"] = avatar.id ?? ""
    }
    return metadata
}

func resolvedGroupchatAuthorDisplayName(
    userElement: DDXMLElement?,
    references: [MessageReferenceStorageItem]
) -> String? {
    let metadata = references.first(where: { $0.kind == .groupchat })?.metadata
    let candidates: [String?] = [
        userElement?.element(forName: "nickname")?.stringValue,
        metadata?["nickname"] as? String,
        userElement?.element(forName: "jid")?.stringValue,
        metadata?["jid"] as? String
    ]

    return candidates.compactMap { candidate in
        guard let candidate,
              candidate.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else {
            return nil
        }
        return candidate
    }.first
}

func parseSystemMessageMetadata(
    _ message: XMPPMessage,
    source: GroupSystemMessageSource = .live
) -> [String: Any]? {
    let messageType = message.attributeStringValue(forName: "type")
    guard messageType == "chat" || messageType == "headline",
          let groupDecoration = uniqueCanonicalGroupChild(named: "x", in: message),
          let event = try? GroupProtocolCodec.decodeSystemEvent(groupDecoration),
          event.type != .create || source == .mam else {
        return nil
    }

    var metadata: [String: Any] = ["type": event.type.rawValue]
    if let actor = event.user {
        metadata["user"] = groupchatMetadata(from: actor)
    }
    return metadata
}

private struct InlineForwardPayload {
    let message: XMPPMessage
    let from: String
    let to: String
    let originalDate: Date?
}

private func inlineForwardPayload(
    from reference: DDXMLElement
) -> InlineForwardPayload? {
    guard SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesXMLNS),
          reference.attributeStringValue(forName: "type") == "mutable" else {
        return nil
    }

    let forwardedElements = directElementChildren(of: reference).filter {
        SCEReceivePolicy.matches($0, name: "forwarded", namespace: inlineForwardXMLNS)
    }
    guard forwardedElements.count == 1,
          directElementChildren(of: reference).count == 1 else { return nil }

    let forwardedChildren = directElementChildren(of: forwardedElements[0])
    let delayElements = forwardedChildren.filter {
        SCEReceivePolicy.matches($0, name: "delay", namespace: delayedDeliveryXMLNS)
    }
    guard delayElements.count <= 1 else { return nil }

    let stanzaElements = forwardedChildren.filter { child in
        !SCEReceivePolicy.matches(child, name: "delay", namespace: delayedDeliveryXMLNS)
    }
    guard stanzaElements.count == 1,
          SCEReceivePolicy.matches(stanzaElements[0], name: "message", namespace: "jabber:client") else {
        return nil
    }

    let original = XMPPMessage(from: stanzaElements[0])
    // The outer authenticated reference does not authenticate a nested OMEMO
    // stanza's plaintext siblings. This parser has no nested decrypt authority.
    let message = SCEReceivePolicy.hasOMEMO2(original)
        ? XMPPMessage(from: SCEReceivePolicy.sanitized(original))
        : original
    guard let from = message.from?.bare,
          from.isNotEmpty,
          let to = message.to?.bare,
          to.isNotEmpty else {
        return nil
    }

    let forwardedDate: Date?
    if let delay = delayElements.first {
        guard let stamp = delay.attributeStringValue(forName: "stamp")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              stamp.isNotEmpty,
              let parsedDate = stamp.xmppDate else {
            return nil
        }
        forwardedDate = parsedDate
    } else {
        forwardedDate = getDeliveryDate(message)
    }

    return InlineForwardPayload(
        message: message,
        from: from,
        to: to,
        originalDate: forwardedDate
    )
}

private struct MessageReferenceAdmission {
    let reference: DDXMLElement
    let index: Int
    let kind: String?
    let range: MessageReferenceWireRange?
    let removesBody: Bool
    let forwardPayload: InlineForwardPayload?
}

/// Rich materialization and fallback removal share the same admission policy.
/// Decoration ranges may overlap, but two transformations of the same fallback
/// cannot both be represented. The first valid transformation owns its range.
private func admittedMessageReferences(
    _ references: [DDXMLElement],
    in escapedBody: String,
    forwardDepth: Int = 0
) -> [MessageReferenceAdmission] {
    var admitted: [MessageReferenceAdmission] = []
    var transformedRanges: [MessageReferenceWireRange] = []
    for (index, reference) in references.enumerated() {
        guard SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesXMLNS) else {
            continue
        }
        let kind = getReferenceType(reference)
        let anonymous = isAnonymousMutableReference(reference)
        guard kind != nil || anonymous else { continue }
        if kind == "forward", forwardDepth >= inlineForwardMaximumDepth { continue }

        let range = messageReferenceWireRange(reference, in: escapedBody)
        if referenceHasAnyWireRangeAttribute(reference), range == nil { continue }
        if anonymous || kind.map({ referenceRequiresWireRange(reference, kind: $0) }) == true {
            guard range != nil else { continue }
        }
        if ["media", "voice"].contains(kind ?? ""),
           reference.attributeStringValue(forName: "type") != "mutable" { continue }

        let removesBody = anonymous || ["media", "voice", "forward", "geoloc", "contact"].contains(kind ?? "")
        if let range, removesBody || kind == "quote" {
            guard !transformedRanges.contains(where: {
                range.begin < $0.end && $0.begin < range.end
            }) else { continue }
            transformedRanges.append(range)
        }
        admitted.append(MessageReferenceAdmission(
            reference: reference,
            index: index,
            kind: kind,
            range: range,
            removesBody: removesBody,
            forwardPayload: kind == "forward" ? inlineForwardPayload(from: reference) : nil
        ))
    }
    return admitted
}

/// Wire callers must use these same admitted direct entries rather than
/// independently choosing the first forwarded child of an arbitrary reference.
/// Indices address the qualified direct-reference array, excluding foreign
/// namespaces. KissXML can create different wrappers for the same XML node.
func admittedMessageContentReferenceIndices(in message: XMPPMessage, depth: Int = 0) -> Set<Int> {
    Set(admittedMessageReferences(
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS),
        in: referenceMessageBody(message).xmlEscaping(reverse: false),
        forwardDepth: depth
    ).map(\.index))
}

func admittedInlineForwardReferenceIndices(in message: XMPPMessage, depth: Int = 0) -> Set<Int> {
    guard depth < inlineForwardMaximumDepth else { return [] }
    return Set(admittedMessageReferences(
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS),
        in: referenceMessageBody(message).xmlEscaping(reverse: false),
        forwardDepth: depth
    ).compactMap { $0.forwardPayload == nil ? nil : $0.index })
}

func admittedMessageContentReferences(in message: XMPPMessage, depth: Int = 0) -> [DDXMLElement] {
    admittedMessageReferences(
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS),
        in: referenceMessageBody(message).xmlEscaping(reverse: false),
        forwardDepth: depth
    ).map(\.reference)
}

func admittedInlineForwardReferences(in message: XMPPMessage, depth: Int = 0) -> [DDXMLElement] {
    guard depth < inlineForwardMaximumDepth else { return [] }
    return admittedMessageReferences(
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS),
        in: referenceMessageBody(message).xmlEscaping(reverse: false),
        forwardDepth: depth
    ).compactMap { $0.forwardPayload == nil ? nil : $0.reference }
}

/// Nested ciphertext remains sanitized here: outer authentication is not
/// authority to interpret plaintext siblings of a forwarded encrypted stanza.
func inlineForwardPayloadMessage(from reference: DDXMLElement) -> (message: XMPPMessage, date: Date?)? {
    guard let payload = inlineForwardPayload(from: reference) else { return nil }
    return (payload.message, payload.originalDate)
}

private func displayBody(
    from escapedBody: String,
    admissions: [MessageReferenceAdmission],
    through wireOffset: Int? = nil
) -> String {
    let limit = wireOffset ?? escapedBody.unicodeScalars.count
    guard var body = escapedBody.prefixThroughUnicodeScalars(limit) else { return "" }
    // Prefixes retain the admission computed against the full body. Re-parsing
    // a short prefix could otherwise admit a previously rejected overlap.
    for admission in admissions.sorted(by: { ($0.range?.begin ?? 0) > ($1.range?.begin ?? 0) }) {
        guard let originalRange = admission.range,
              originalRange.begin < limit,
              admission.removesBody || admission.kind == "quote" else { continue }
        let clippedRange = MessageReferenceWireRange(
            begin: originalRange.begin,
            end: min(originalRange.end, limit)
        )
        guard let range = clippedRange.stringRange(in: body) else { continue }
        if admission.removesBody {
            body.removeSubrange(range)
        } else {
            body = body.replacingOccurrences(of: "&gt;", with: "", options: [], range: range)
        }
    }
    return body.xmlEscaping(reverse: true)
}

func parseInlineMessages(
    _ message: XMPPMessage,
    parentId: String,
    jid: String,
    owner: String,
    depth: Int = 0
) -> [MessageForwardsInlineStorageItem] {
    guard depth < inlineForwardMaximumDepth else { return [] }

    let escapedBody = referenceMessageBody(message).xmlEscaping(reverse: false)

    let cards = ForwardContactDataCodec.cards(in: message)
    return admittedMessageReferences(
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS),
        in: escapedBody,
        forwardDepth: depth
    ).compactMap { admission in
        guard let payload = admission.forwardPayload else {
            return nil
        }

        let outgoing = payload.from == owner && payload.to != owner
        let opponent = outgoing ? payload.to : payload.from
        let item = MessageForwardsInlineStorageItem()
        item.configureInline(
            payload.message,
            parentId: parentId,
            owner: owner,
            jid: jid,
            opponent: opponent,
            outgoing: outgoing,
            date: payload.originalDate,
            forwardJid: payload.from,
            forwardDepth: depth + 1,
            referenceIndex: admission.index,
            contactCard: ForwardContactDataCodec.matchingCard(for: payload.from, cards: cards)
        )

        do {
            let realm = try WRealm.safe()
            item.rosterItem = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: [opponent, owner].prp()
            )
        } catch {
            DDLogDebug("\(#function). \(error.localizedDescription)")
        }
        return item
    }
}

func getReferenceType(_ ref: DDXMLElement) -> String? {
    guard SCEReceivePolicy.matches(ref, name: "reference", namespace: referencesXMLNS) else { return nil }
    // A reference carrying forwarding and another payload cannot be given
    // separate media/forward interpretations by different consumers.
    if directElementChildren(of: ref).contains(where: {
        SCEReceivePolicy.matches($0, name: "forwarded", namespace: inlineForwardXMLNS)
    }) {
        return inlineForwardPayload(from: ref) == nil ? nil : "forward"
    }
    if ForwardContactDataCodec.decode(ref) != nil { return "forward-contact-data" }
    if let voice = referenceChild(ref, named: "voice-message", xmlns: "https://xabber.com/protocol/voice-messages"),
       let fileSharing = referenceChild(voice, named: "file-sharing", xmlns: "https://xabber.com/protocol/files"),
       fileSharingPayload(fileSharing) != nil {
        return "voice"
    } else if referenceChild(ref, named: "system-message", xmlns: "https://xabber.com/protocol/system-message") != nil {
        return "system-message"
    } else if let fileSharing = referenceChild(ref, named: "file-sharing", xmlns: "https://xabber.com/protocol/files"),
              fileSharingPayload(fileSharing) != nil {
        return "media"
    } else if validGeolocElement(from: ref) != nil {
        return "geoloc"
    } else if validContactElement(from: ref) != nil {
        return "contact"
    } else if ref.attributeStringValue(forName: "type") == "decoration" {
        if referenceChild(ref, named: "quote", xmlns: "https://xabber.com/protocol/markup") != nil {
            return "quote"
        }
        if referenceChild(ref, named: "mention", xmlns: "https://xabber.com/protocol/markup") != nil {
            return "mention"
        }
        if let uri = referenceChild(ref, named: "link", xmlns: "https://xabber.com/protocol/markup")?.stringValue,
           uri.starts(with: "xmpp:") {
            return "mention"
        }
        return "markup"
    } else if inlineForwardPayload(from: ref) != nil {
        return "forward"
    }
    return nil
}

func parseReferences(_ message: XMPPMessage, primary: String, jid: String, owner: String, echo: Bool = false, forwardDepth: Int = 0) -> [MessageReferenceStorageItem] {
    var out: [MessageReferenceStorageItem] = []
    let escapingBody = referenceMessageBody(message).xmlEscaping(reverse: false)
    let references = SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesXMLNS)
    
    let messageDate = getDelayedDate(message) ?? Date()
    
    let admissions = admittedMessageReferences(references, in: escapingBody, forwardDepth: forwardDepth)
    let parsedDisplayBody = displayBody(from: escapingBody, admissions: admissions)

    func displayOffset(for wireOffset: Int) -> Int? {
        guard escapingBody.prefixThroughUnicodeScalars(wireOffset) != nil else { return nil }
        return displayBody(from: escapingBody, admissions: admissions, through: wireOffset).utf16.count
    }
    
    func parse(_ admission: MessageReferenceAdmission) -> MessageReferenceStorageItem? {
        let ref = admission.reference
        guard let kind = admission.kind else {
                return nil
            }
        let wireRange = admission.range
        let begin = wireRange.flatMap { displayOffset(for: $0.begin) } ?? 0
        let end = wireRange.flatMap { displayOffset(for: $0.end) } ?? 0
        let reference = MessageReferenceStorageItem()
        
        
        reference.conversationType = conversationTypeByMessage(message)
        reference.jid = jid
        reference.owner = owner
        reference.begin = begin
        reference.end = end
        reference.kind_ = kind
        reference.sentDate = messageDate
        var metadata: [String: Any] = [:]
        switch reference.kind {
            case .forwardContactData:
                guard let card = ForwardContactDataCodec.decode(ref) else { return nil }
                metadata = ForwardContactDataCodec.metadata(for: card)
            case .voice:
                guard let voice = referenceChild(ref, named: "voice-message", xmlns: "https://xabber.com/protocol/voice-messages"),
                    let fileSharing = referenceChild(voice, named: "file-sharing", xmlns: "https://xabber.com/protocol/files"),
                    let payload = fileSharingPayload(fileSharing) else {
                        return nil
                    }
                let file = payload.file
                let uri = payload.uri
                if let encryptedElement = referenceChild(file, named: "encrypted", xmlns: "urn:xmpp:esfs:0"),
                   let encryptionKey = referenceChild(encryptedElement, named: "key")?.stringValue,
                   let iv = referenceChild(encryptedElement, named: "iv")?.stringValue {
                    metadata["encryption-key"] = encryptionKey
                    metadata["iv"] = iv
                }
                let mediaType = referenceChild(file, named: "media-type")?.stringValue ?? ""
                metadata["media-type"] = mediaType
                reference.mimeType = "audio"//MimeIcon(mediaType).value.rawValue
                metadata["name"] = referenceChild(file, named: "name")?.stringValue ?? ""
                metadata["duration"] = referenceChild(file, named: "duration")?.stringValueAsNSInteger() ?? 0
                metadata["size"] = referenceChild(file, named: "size")?.stringValueAsNSInteger() ?? 0
                metadata["hash"] = referenceChild(file, named: "hash")?.stringValue ?? ""
                let pcmRaw = referenceChild(file, named: "meters")?.stringValue ?? ""
                if pcmRaw.isNotEmpty {
                    metadata["pcm"] = pcmRaw
                }
                metadata["uri"] = uri
                reference.url = uri
            case .media:
                guard let fileSharing = referenceChild(ref, named: "file-sharing", xmlns: "https://xabber.com/protocol/files"),
                    let payload = fileSharingPayload(fileSharing) else {
                        return nil
                    }
                let file = payload.file
                let uri = payload.uri
                
                var isEncrypted: Bool = false
                
                if let encryptedElement = referenceChild(file, named: "encrypted", xmlns: "urn:xmpp:esfs:0"),
                   let encryptionKey = referenceChild(encryptedElement, named: "key")?.stringValue,
                   let iv = referenceChild(encryptedElement, named: "iv")?.stringValue {
                    metadata["encryption-key"] = encryptionKey
                    metadata["iv"] = iv
                    isEncrypted = true
                }
                
                let mediaType = referenceChild(file, named: "media-type")?.stringValue ?? ""
                metadata["media-type"] = mediaType
                reference.mimeType = MimeIcon(mediaType).value.rawValue
                metadata["name"] = referenceChild(file, named: "name")?.stringValue ?? ""
                metadata["height"] = referenceChild(file, named: "height")?.stringValueAsNSInteger() ?? 0
                metadata["width"] = referenceChild(file, named: "width")?.stringValueAsNSInteger() ?? 0
                metadata["size"] = referenceChild(file, named: "size")?.stringValueAsNSInteger() ?? 0
                metadata["desc"] = referenceChild(file, named: "desc")?.stringValue ?? ""
                metadata["duration"] = referenceChild(file, named: "duration")?.stringValueAsNSInteger() ?? 0
                metadata["hash"] = referenceChild(file, named: "hash")?.stringValue ?? ""
                metadata["orientation"] = referenceChild(file, named: "orientation")?.stringValue ?? ""
                metadata["video_duration"] = referenceChild(file, named: "video_duration")?.stringValue ?? ""
                metadata["uri"] = uri
                reference.url = uri
                
                let conversationType = reference.conversationType
                let attachment = MessageMediaAttachmentStorageItem()
                attachment.primary = MessageMediaAttachmentStorageItem.genPrimary(jid: jid, owner: owner, url: uri, messagePrimary: primary)
                attachment.url_ = uri
                attachment.jid = jid
                attachment.owner = owner
                attachment.conversationType = conversationType
                attachment.messagePrimary = primary
                attachment.archiveId = getStanzaId(message, owner: owner)
                attachment.metadata = metadata
                switch reference.mimeType {
                    case "image":
                        attachment.kind = .image
                    case "video":
                        attachment.kind = .video
                    case "audio":
                        attachment.kind = .audio
                    default:
                        attachment.kind = .file
                }
                attachment.date = messageDate
                attachment.outgoing = message.from?.bare == owner
                attachment.filename = referenceChild(file, named: "name")?.stringValue ?? ""
                attachment.isDownloaded = false
                attachment.isEncrypted = isEncrypted
                attachment.sizeBytes = referenceChild(file, named: "size")?.stringValueAsNSInteger() ?? 0
                attachment.metadata = metadata
                
                if let thumb = referenceChild(file, named: "thumbnail", xmlns: "urn:xmpp:thumbs:1")
                    ?? referenceChild(file, named: "thumbnail"),
                   let thumbnailURI = thumb.attributeStringValue(forName: "uri") {
                    if let commaIndex = thumbnailURI.firstIndex(of: ","),
                       thumbnailURI.hasPrefix("data:image/") {
                        let base64String = String(
                            thumbnailURI[thumbnailURI.index(after: commaIndex)...]
                        )
                        attachment.verySmallThumb = base64String
                        if let thumbnailMediaType =
                            MessageMediaThumbnailDataURLPolicy.mediaType(
                                fromDataURL: thumbnailURI
                            ) ?? thumb.attributeStringValue(forName: "media-type") {
                            metadata["thumbnail-media-type"] = thumbnailMediaType
                        }
                    } else if let remoteThumbnailURI = validatedHTTPThumbnailURI(
                        thumbnailURI
                    ) {
                        metadata["thumbnail-uri"] = remoteThumbnailURI
                    }
                }
                attachment.metadata = metadata

                reference.pendingMediaAttachment = attachment
            case .geoloc:
                guard let geoloc = geolocElement(from: ref),
                      let latitude = validGeolocCoordinate(
                        childText(geoloc, name: "lat"),
                        range: -90.0...90.0
                      ),
                      let longitude = validGeolocCoordinate(
                        childText(geoloc, name: "lon"),
                        range: -180.0...180.0
                      ) else {
                    return nil
                }
                let geoURI = "geo:\(latitude),\(longitude)"
                metadata["lat"] = latitude
                metadata["lon"] = longitude
                metadata["uri"] = childText(geoloc, name: "uri") ?? geoURI
                if let accuracy = validGeolocAccuracy(childText(geoloc, name: "accuracy")) {
                    metadata["accuracy"] = accuracy
                }
                if let text = childText(geoloc, name: "text") {
                    metadata["text"] = text
                }
                if let timestamp = childText(geoloc, name: "timestamp") {
                    metadata["timestamp"] = timestamp
                }
                reference.mimeType = "location"
                reference.url = geoURI
                reference.isUploaded = true
            case .contact:
                guard let contact = contactElement(from: ref),
                      let contactJID = validContactJID(contact.attributeStringValue(forName: "jid")),
                      let entity = validContactEntity(contact.attributeStringValue(forName: "entity")) else {
                    return nil
                }
                metadata["contact_jid"] = contactJID
                if let rawEntity = contact.attributeStringValue(forName: "entity")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   rawEntity.isNotEmpty {
                    metadata["entity"] = entity.rawValue
                }
                if let nickname = childText(contact, name: "nickname") {
                    metadata["nickname"] = nickname
                }
                if let name = referenceChild(contact, named: "name") {
                    if let given = childText(name, name: "given") {
                        metadata["given"] = given
                    }
                    if let family = childText(name, name: "family") {
                        metadata["family"] = family
                    }
                }
                if let avatar = referenceChild(contact, named: "avatar"),
                   let avatarInfo = referenceChild(avatar, named: "info", xmlns: avatarMetadataXMLNS) {
                    [
                        ("id", "avatar_id"),
                        ("type", "avatar_type"),
                        ("bytes", "avatar_bytes"),
                        ("url", "avatar_url"),
                        ("width", "avatar_width"),
                        ("height", "avatar_height")
                    ].forEach { sourceKey, metadataKey in
                        guard let value = avatarInfo
                            .attributeStringValue(forName: sourceKey)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              value.isNotEmpty else {
                            return
                        }
                        metadata[metadataKey] = value
                    }
                }
                reference.mimeType = "contact"
                reference.url = "xmpp:\(contactJID)"
                reference.isUploaded = true
            case .markup:
                var styles: [String] = []
                if referenceChild(ref, named: "bold", xmlns: markupXMLNS) != nil { styles.append("bold") }
                if referenceChild(ref, named: "underline", xmlns: markupXMLNS) != nil { styles.append("underline") }
                if referenceChild(ref, named: "strike", xmlns: markupXMLNS) != nil { styles.append("strike") }
                if referenceChild(ref, named: "italic", xmlns: markupXMLNS) != nil { styles.append("italic") }
                if let uri = referenceChild(ref, named: "link", xmlns: markupXMLNS)?.stringValue {
                    styles.append("uri")
                    metadata["uri"] = uri
                    reference.url = uri
                }
                if styles.isNotEmpty {
                    metadata["styles"] = styles
                } else {
                    return nil
                }
            case .mention:
                let mentionElement = referenceChild(ref, named: "mention", xmlns: "https://xabber.com/protocol/markup")
                let legacyLink = referenceChild(ref, named: "link", xmlns: "https://xabber.com/protocol/markup")
                guard let uri = mentionElement?.stringValue ?? legacyLink?.stringValue, uri.starts(with: "xmpp:") else {
                    return nil
                }
                metadata["uri"] = uri
                reference.url = uri
                if let node = mentionElement?.attributeStringValue(forName: "node"), node.isNotEmpty {
                    metadata["node"] = node
                }
                if let memberId = parseMentionMemberId(uri) {
                    metadata["memberId"] = memberId
                }
                if let groupchatJid = parseMentionGroupchat(uri) {
                    metadata["groupchatJid"] = groupchatJid
                }
                let nsBody = parsedDisplayBody
                let bodyNSString = nsBody as NSString
                if reference.end <= bodyNSString.length, reference.begin < reference.end {
                    metadata["nickname"] = bodyNSString.substring(with: reference.range)
                }
            case .quote:
                metadata["marker"] = ">".xmlEscaping(reverse: false)
            case .systemMessage:
                if let system = referenceChild(ref, named: "system-message", xmlns: "https://xabber.com/protocol/system-message"),
                   let timer = referenceChild(system, named: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeIntegerValue(forName: "timer") {
                    metadata["ephemeral-timer"] = timer
                }
            case .groupchat:
                return nil
            default: break
        }
        reference.metadata = metadata
//        print("Reference received: ", reference, ref.prettyXMLString ?? "")
        return reference
    }
    
    if let v3User = groupchatUserElement(from: message) {
        let reference = MessageReferenceStorageItem()
        reference.conversationType = conversationTypeByMessage(message)
        reference.jid = jid
        reference.owner = owner
        reference.kind_ = "groupchat"
        reference.sentDate = messageDate
        reference.metadata = groupchatMetadata(from: v3User)
        out = [reference]
    }

    out.append(contentsOf: admissions.compactMap { parse($0) })
    return out
}

private func parseMentionMemberId(_ uri: String) -> String? {
    guard let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
    let normalizedQuery = query.replacingOccurrences(of: ";", with: "&")
    return normalizedQuery
        .split(separator: "&")
        .compactMap { component -> String? in
            let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "id" else { return nil }
            return parts[1]
        }
        .first
}

private func parseMentionGroupchat(_ uri: String) -> String? {
    guard uri.starts(with: "xmpp:") else { return nil }
    let withoutScheme = String(uri.dropFirst("xmpp:".count))
    return withoutScheme.split(separator: "?", maxSplits: 1).first.map(String.init)
}

extension String {
    public func xmlEscaping(reverse: Bool) -> String {
        var out = self
        let symbols: [(String, String)] = [
            ("<", "&lt;"),
            (">", "&gt;"),
            ("\"", "&quot;"),
            ("'", "&apos;")
        ]
        if !reverse {
            out = out.replacingOccurrences(of: "&", with: "&amp;")
        }
        for (symbol, entity) in symbols {
            out = out.replacingOccurrences(of: reverse ? entity : symbol, with: reverse ? symbol : entity)
        }
        // Decode only one layer: literal `&lt;` text was encoded as `&amp;lt;`
        // and must remain literal after reversing the XML coordinate space.
        if reverse {
            out = out.replacingOccurrences(of: "&amp;", with: "&")
        }
        return out
    }

    fileprivate func prefixThroughUnicodeScalars(_ offset: Int) -> String? {
        let scalars = unicodeScalars
        guard offset >= 0, offset <= scalars.count else { return nil }
        let scalarIndex = scalars.index(scalars.startIndex, offsetBy: offset)
        // Keep the scalar boundary even when it lies inside a Character.
        return String(self[..<scalarIndex])
    }
    
    public func excludeFromBody(_ references: [DDXMLElement], groupchat: DDXMLElement?, forwardDepth: Int = 0) -> String {
        var mutatedReferences: [DDXMLElement] = references
        if let groupchatReference = groupchat {
            mutatedReferences.append(groupchatReference)
        }
        if self.isEmpty { return self }

        return displayBody(
            from: self,
            admissions: admittedMessageReferences(mutatedReferences, in: self, forwardDepth: forwardDepth)
        )
    }
}
