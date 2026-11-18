import Foundation
import XMPPFramework

/// A projection of a scheduled packet onto the existing native message presentation.
struct ScheduledMessageContent {
    struct Attachment {
        let id: Int
        let reference: MessageReferenceStorageItem
    }

    let body: String
    let references: [MessageReferenceStorageItem]
    let attachments: [Attachment]

    private static let referencesNamespace = "https://xabber.com/protocol/references"
    private static let fileNamespace = "https://xabber.com/protocol/files"
    private static let voiceNamespace = "https://xabber.com/protocol/voice-messages"
    private static let bodyName = "body"
    private static let referenceType = "type"
    private static let mutableReference = "mutable"

    static func read(_ item: ScheduledMessageListItem) -> Self? {
        read(messageXML: item.messageXML, owner: item.owner, conversation: item.conversation, sourceDate: item.deliverAt)
    }

    static func read(messageXML: String, owner: String, conversation: String, sourceDate: Date? = nil) -> Self? {
        guard let message = try? XMPPMessage(xmlString: messageXML), let source = Source(message) else { return nil }
        let projection = Projection(source)
        let references = parseReferences(source.message, primary: "", jid: conversation, owner: owner, sourceDate: sourceDate)
        var fileReferences = references.filter { files.contains($0.kind) }
        let attachments = projection.files.compactMap { file -> Attachment? in
            guard let index = fileReferences.firstIndex(where: { $0.kind_ == file.kind && $0.fileSharingURI == file.uri }) else {
                return nil
            }
            return Attachment(id: file.index, reference: fileReferences.remove(at: index))
        }
        for reference in references where reference.kind == .markup || reference.kind == .mention {
            reference.begin = max(0, reference.begin - projection.leadingUTF16)
            reference.end = max(0, reference.end - projection.leadingUTF16)
        }
        return Self(body: projection.body, references: references, attachments: attachments)
    }

    static func makeMessage(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        body: String,
        references: [MessageReferenceStorageItem],
        additionalChildren: [DDXMLElement] = []
    ) -> XMPPMessage? {
        guard !conversationType.isEncrypted,
              XMPPJID(string: owner)?.bare == owner,
              XMPPJID(string: conversation)?.bare == conversation,
              references.allSatisfy({ files.contains($0.kind) ? uploadedPlainFile($0) : [.markup, .mention].contains($0.kind) }) else {
            return nil
        }
        let draft = MessageStorageItem()
        draft.owner = owner
        draft.opponent = conversation
        draft.conversationType = conversationType
        draft.legacyBody = body.nilIfBlank ?? ""
        for reference in references {
            draft.references.append(MessageReferenceStorageItem(value: reference))
        }
        draft.createLegacyBody()
        guard !draft.legacyBody.isEmpty else { return nil }
        let message = XMPPMessageScheduleManager(withOwner: owner).makePlaintextMessagePayload(
            to: conversation, body: draft.legacyBody, conversationType: conversationType,
            references: Array(draft.references), additionalChildren: additionalChildren
        )
        message.setXmlns(SCEReceivePolicy.client)
        guard (try? MessageManager.validatePreparedContentSize(message)) != nil else { return nil }
        return message
    }

    static func attachmentXML(_ references: [MessageReferenceStorageItem]) -> [String]? {
        guard references.allSatisfy(uploadedPlainFile) else { return nil }
        let draft = MessageStorageItem()
        draft.references.append(objectsIn: references.map { MessageReferenceStorageItem(value: $0) })
        return draft.createReferences().map(\.xmlString)
    }

    /// Convert only a detached packet used for native projection. The queued XML remains intact.
    static func normalizeWebRanges(_ message: XMPPMessage) -> XMPPMessage {
        Source(message)?.message ?? message
    }

    static func edited(
        _ message: XMPPMessage,
        body: String,
        retainedAttachmentIDs: [Int]?,
        addedAttachmentXML: [String]
    ) -> XMPPMessage? {
        guard let source = Source(message), !references(in: message).contains(where: isSticker) else { return nil }
        let projection = Projection(source)
        let originalFiles = projection.files
        let selected = retainedAttachmentIDs ?? originalFiles.map(\.index)
        guard Set(selected).count == selected.count else { return nil }

        var attachments: [File] = []
        for id in selected {
            guard let file = originalFiles.first(where: { $0.index == id }), !file.isProtected else { return nil }
            attachments.append(file)
        }
        for xml in addedAttachmentXML {
            guard let reference = try? DDXMLElement(xmlString: xml),
                  let file = File(index: -1, reference: reference), !file.isProtected else { return nil }
            attachments.append(file)
        }

        let newBody = body.nilIfBlank ?? ""
        let projectedText = EditableText(old: projection.body, new: newBody)
        let result = source.message
        let originalMentionTargets = markupMentionTargets(in: result)
        var raw = ""
        var outputRanges: [(reference: DDXMLElement, range: Range<Int>)] = []
        let oldReferences = references(in: result)
        let admitted = admittedMessageContentReferenceIndices(in: result)
        let mediaIDs = Set(originalFiles.map(\.index))

        // Preserve existing forwarded packets and other admitted fallback-only references.
        for (index, reference) in oldReferences.enumerated() where admitted.contains(index) && !mediaIDs.contains(index) {
            guard let range = source.range(of: reference), removesText(reference) else { continue }
            appendFallback(source.coordinates.text(in: range), reference: reference, to: &raw, mapped: &outputRanges)
        }
        if !raw.isEmpty && !newBody.isEmpty && !raw.hasSuffix("\n") { raw.append("\n") }
        let displayStart = raw.unicodeScalars.count
        raw += newBody

        guard !raw.isEmpty || !attachments.isEmpty else { return nil }
        for (index, reference) in oldReferences.enumerated() {
            if mediaIDs.contains(index) {
                reference.detach()
                continue
            }
            guard let range = source.range(of: reference), !removesText(reference) else { continue }
            let visibleRange = projection.visibleOffset(range.lowerBound)..<projection.visibleOffset(range.upperBound)
            let bindsLabel = getReferenceType(reference) == "mention" ||
                reference.element(forName: "link", xmlns: "https://xabber.com/protocol/markup") != nil
            guard let mapped = projectedText.map(visibleRange, exact: bindsLabel) else {
                reference.detach()
                continue
            }
            outputRanges.append((reference, (displayStart + mapped.lowerBound)..<(displayStart + mapped.upperBound)))
        }
        for file in attachments {
            guard let copy = file.reference.copy() as? DDXMLElement else { return nil }
            let fallback = file.fallback(in: source.coordinates) ?? file.uri
            appendFallback(fallback, reference: copy, to: &raw, mapped: &outputRanges)
            result.addChild(copy)
        }

        let output = Coordinates(raw)
        for (reference, range) in outputRanges {
            setRange(output.wire(range, as: source.dialect), on: reference)
        }
        if let current = bodies(in: result).first {
            current.stringValue = raw
        } else {
            result.addBody(raw)
        }
        removeStaleGroupMentionTargets(originalMentionTargets, from: result)
        guard (try? MessageManager.validatePreparedContentSize(result)) != nil else { return nil }
        return result
    }

    private static func markupMentionTargets(in message: XMPPMessage) -> Set<String> {
        guard case .members = GroupMessageMentionsCodec.decode(from: message) else { return [] }
        let references = parseReferences(message, primary: "", jid: message.to?.bare ?? "", owner: message.from?.bare ?? "")
        return Set(GroupMessageMentionsCodec.memberIDs(from: references))
    }

    private static func removeStaleGroupMentionTargets(_ original: Set<String>, from message: XMPPMessage) {
        guard !original.isEmpty else { return }
        let namespace = "https://xabber.com/protocol/groups"
        guard let mentions = SCEReceivePolicy.children(of: message, named: "mentions", xmlns: namespace).first else { return }
        let surviving = markupMentionTargets(in: normalizeWebRanges(message))
        let stale = original.subtracting(surviving)
        let users = SCEReceivePolicy.children(of: mentions, named: "user", xmlns: namespace)
        let removed = users.filter { $0.attributeStringValue(forName: "id").map(stale.contains) == true }
        if !removed.isEmpty && removed.count == users.count { mentions.detach() }
        else { removed.forEach { $0.detach() } }
    }

    private static let files: Set<MessageReferenceStorageItem.Kind> = [.media, .voice]

    private static func uploadedPlainFile(_ reference: MessageReferenceStorageItem) -> Bool {
        guard files.contains(reference.kind), reference.isUploaded,
              let uri = reference.fileSharingURI, isRemote(uri),
              reference.metadata?["iv"] == nil, reference.metadata?["encryption-key"] == nil else { return false }
        return true
    }

    private static func isRemote(_ uri: String) -> Bool {
        guard let url = URLComponents(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func references(in message: DDXMLElement) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesNamespace)
    }

    private static func bodies(in message: XMPPMessage) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: message, named: bodyName, xmlns: SCEReceivePolicy.client)
    }

    private static func removesText(_ reference: DDXMLElement) -> Bool {
        let kind = getReferenceType(reference)
        if ["media", "voice", "forward", "geoloc", "contact"].contains(kind ?? "") { return true }
        return kind == nil && reference.attributeStringValue(forName: referenceType) == mutableReference
            && (reference.children ?? []).allSatisfy { !($0 is DDXMLElement) }
    }

    private static func isSticker(_ reference: DDXMLElement) -> Bool {
        !SCEReceivePolicy.children(
            of: reference, named: "sticker", xmlns: "https://xabber.com/protocol/stickers"
        ).isEmpty
    }

    private static func setRange(_ range: Range<Int>, on element: DDXMLElement) {
        element.removeAttribute(forName: "begin")
        element.removeAttribute(forName: "end")
        element.addAttribute(withName: "begin", integerValue: range.lowerBound)
        element.addAttribute(withName: "end", integerValue: range.upperBound)
    }

    private static func appendFallback(
        _ fallback: String,
        reference: DDXMLElement,
        to body: inout String,
        mapped: inout [(reference: DDXMLElement, range: Range<Int>)]
    ) {
        if !body.isEmpty && !body.hasSuffix("\n") { body.append("\n") }
        let begin = body.unicodeScalars.count
        body.append(fallback)
        mapped.append((reference, begin..<(begin + fallback.unicodeScalars.count)))
    }

    private enum Dialect {
        case native
        case web
    }

    /// Boundaries in plain scalars, the native escaped scalar form, and Web escaped UTF-16.
    private struct Coordinates {
        let scalars: [Unicode.Scalar]
        private let native: [Int]
        private let web: [Int]

        init(_ string: String) {
            scalars = Array(string.unicodeScalars)
            var native = [0], web = [0]
            var scalarOffset = 0, utf16Offset = 0
            for scalar in scalars {
                let width: Int
                switch scalar {
                case "&": width = 5
                case "<", ">": width = 4
                case "\"", "'": width = 6
                default: width = 1
                }
                scalarOffset += width
                utf16Offset += width + (scalar.value > 0xFFFF ? 1 : 0)
                native.append(scalarOffset)
                web.append(utf16Offset)
            }
            self.native = native
            self.web = web
        }

        func range(of reference: DDXMLElement, as dialect: Dialect) -> Range<Int>? {
            let offsets = dialect == .native ? native : web
            guard let begin = reference.attributeStringValue(forName: "begin").flatMap(Int.init),
                  let end = reference.attributeStringValue(forName: "end").flatMap(Int.init),
                  let lower = Self.find(begin, in: offsets), let upper = Self.find(end, in: offsets),
                  lower <= upper else { return nil }
            return lower..<upper
        }

        func wire(_ range: Range<Int>, as dialect: Dialect) -> Range<Int> {
            let offsets = dialect == .native ? native : web
            return offsets[range.lowerBound]..<offsets[range.upperBound]
        }

        func text(in range: Range<Int>) -> String {
            String(String.UnicodeScalarView(scalars[range]))
        }

        private static func find(_ value: Int, in offsets: [Int]) -> Int? {
            var lower = 0, upper = offsets.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if offsets[middle] < value { lower = middle + 1 } else { upper = middle }
            }
            return lower < offsets.count && offsets[lower] == value ? lower : nil
        }
    }

    private struct File {
        let index: Int
        let reference: DDXMLElement
        let kind: String
        let uri: String
        let isProtected: Bool

        init?(index: Int, reference: DDXMLElement) {
            guard let kind = getReferenceType(reference), ["media", "voice"].contains(kind) else { return nil }
            let voice = SCEReceivePolicy.children(of: reference, named: "voice-message", xmlns: voiceNamespace).first
            guard let share = SCEReceivePolicy.children(of: voice ?? reference, named: "file-sharing", xmlns: fileNamespace).first,
                  let sources = SCEReceivePolicy.children(of: share, named: "sources", xmlns: fileNamespace).first,
                  let uri = SCEReceivePolicy.children(of: sources, named: "uri", xmlns: fileNamespace).compactMap(\.stringValue).first,
                  isRemote(uri) else { return nil }
            self.index = index
            self.reference = reference
            self.kind = kind
            self.uri = uri
            let file = SCEReceivePolicy.children(of: share, named: "file", xmlns: fileNamespace).first
            self.isProtected = file.map { !SCEReceivePolicy.children(of: $0, named: "encrypted", xmlns: "urn:xmpp:esfs:0").isEmpty } ?? false
        }

        func fallback(in coordinates: Coordinates, dialect: Dialect = .native) -> String? {
            guard let range = coordinates.range(of: reference, as: dialect) else { return nil }
            let value = coordinates.text(in: range)
            return value == uri || value.hasSuffix("\n" + uri) ? value : nil
        }
    }

    private struct Source {
        let message: XMPPMessage
        let coordinates: Coordinates
        let dialect: Dialect

        init?(_ input: XMPPMessage) {
            guard SCEReceivePolicy.matches(input, name: "message", namespace: SCEReceivePolicy.client),
                  !SCEReceivePolicy.containsOMEMO2(input), bodies(in: input).count <= 1,
                  let copy = input.copy() as? DDXMLElement else { return nil }
            let raw = bodies(in: input).first?.stringValue ?? ""
            var coordinates = Coordinates(raw)
            let detached = XMPPMessage(from: copy)
            let references = references(in: detached)
            let files = references.enumerated().compactMap { File(index: $0.offset, reference: $0.element) }
            let nativeMatches = files.filter { $0.fallback(in: coordinates, dialect: .native) != nil }.count
            let webMatches = files.filter { $0.fallback(in: coordinates, dialect: .web) != nil }.count
            // Current Web sends a minimal inner stanza without either client identity.
            // When media anchors disambiguate, they take priority over the envelope shape.
            let webEnvelope = getOriginId(input) == nil
            let dialect: Dialect = webMatches > nativeMatches || (webMatches == nativeMatches && webEnvelope) ? .web : .native
            if dialect == .web {
                for reference in references {
                    if let range = coordinates.range(of: reference, as: .web) {
                        setRange(coordinates.wire(range, as: .native), on: reference)
                    } else if reference.attributeStringValue(forName: "begin") != nil {
                        setRange(-1..<0, on: reference)
                    }
                }
            }
            if raw.isEmpty && !files.isEmpty {
                var synthesized = ""
                var mapped: [(reference: DDXMLElement, range: Range<Int>)] = []
                for file in files {
                    appendFallback(file.uri, reference: file.reference, to: &synthesized, mapped: &mapped)
                }
                coordinates = Coordinates(synthesized)
                for (reference, range) in mapped { setRange(coordinates.wire(range, as: .native), on: reference) }
                if let current = bodies(in: detached).first { current.stringValue = synthesized }
                else { detached.addBody(synthesized) }
            }
            self.message = detached
            self.coordinates = coordinates
            self.dialect = dialect
        }

        func range(of reference: DDXMLElement) -> Range<Int>? {
            coordinates.range(of: reference, as: .native)
        }
    }

    private struct Projection {
        let body: String
        let files: [File]
        let leadingUTF16: Int
        private let rawToVisible: [Int]
        private let firstVisible: Int
        private let lastVisible: Int

        init(_ source: Source) {
            let scalars = source.coordinates.scalars
            var removed = Array(repeating: false, count: scalars.count)
            var files: [File] = []
            let admitted = admittedMessageContentReferenceIndices(in: source.message)
            for (index, reference) in references(in: source.message).enumerated() where admitted.contains(index) {
                if let file = File(index: index, reference: reference) { files.append(file) }
                guard let range = source.range(of: reference) else { continue }
                if removesText(reference) {
                    for index in range { removed[index] = true }
                } else if getReferenceType(reference) == "quote" {
                    for index in range where scalars[index] == ">" { removed[index] = true }
                }
            }
            var visible: [Unicode.Scalar] = [], offsets = [0]
            for (index, scalar) in scalars.enumerated() {
                if !removed[index] { visible.append(scalar) }
                offsets.append(visible.count)
            }
            let whitespace = CharacterSet.whitespacesAndNewlines
            let first = visible.firstIndex { !whitespace.contains($0) } ?? visible.count
            let last = visible.lastIndex { !whitespace.contains($0) }.map { $0 + 1 } ?? first
            self.firstVisible = first
            self.lastVisible = last
            self.body = String(String.UnicodeScalarView(visible[first..<last]))
            self.leadingUTF16 = visible[..<first].reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
            self.rawToVisible = offsets
            self.files = files
        }

        func visibleOffset(_ raw: Int) -> Int {
            max(firstVisible, min(lastVisible, rawToVisible[raw])) - firstVisible
        }
    }

    private struct EditableText {
        private struct Change {
            let old: Range<Int>
            let new: Range<Int>
        }

        let old: [Unicode.Scalar]
        let new: [Unicode.Scalar]
        let edited: String
        let prefix: Int
        let suffix: Int
        private let changes: [Change]

        init(old: String, new: String) {
            self.old = Array(old.unicodeScalars)
            self.new = Array(new.unicodeScalars)
            self.edited = new
            prefix = zip(self.old, self.new).prefix { $0 == $1 }.count
            suffix = zip(self.old.dropFirst(prefix).reversed(), self.new.dropFirst(prefix).reversed())
                .prefix { $0 == $1 }.count
            changes = Self.changedSpans(
                self.old[prefix..<(self.old.count - suffix)],
                self.new[prefix..<(self.new.count - suffix)]
            )
        }

        func map(_ range: Range<Int>, exact: Bool) -> Range<Int>? {
            guard !range.isEmpty else { return nil }
            if range.upperBound <= prefix { return range }
            let delta = new.count - old.count
            if range.lowerBound >= old.count - suffix {
                return (range.lowerBound + delta)..<(range.upperBound + delta)
            }
            // Preserve an unchanged label within the modified region only when its placement is unambiguous.
            let needle = String(String.UnicodeScalarView(old[range]))
            if let match = edited.range(of: needle, options: .literal),
               edited.range(of: needle, options: .literal, range: match.upperBound..<edited.endIndex) == nil {
                let begin = edited[..<match.lowerBound].unicodeScalars.count
                return begin..<(begin + range.count)
            }
            let begin = mappedBoundary(range.lowerBound, isEnd: false)
            let end = mappedBoundary(range.upperBound, isEnd: true)
            guard begin < end else { return nil }
            let mapped = begin..<end
            // A changed link or mention label may no longer identify the original target.
            return !exact || old[range].elementsEqual(new[mapped]) ? mapped : nil
        }

        private func mappedBoundary(_ index: Int, isEnd: Bool) -> Int {
            var displacement = 0
            for change in changes {
                if index < change.old.lowerBound { break }
                if index <= change.old.upperBound {
                    if change.old.isEmpty {
                        return isEnd ? change.new.lowerBound : change.new.upperBound
                    }
                    let distance = (index - change.old.lowerBound) * change.new.count / change.old.count
                    return change.new.lowerBound + distance
                }
                displacement = change.new.upperBound - change.old.upperBound
            }
            return index + displacement
        }

        private static func changedSpans(
            _ old: ArraySlice<Unicode.Scalar>,
            _ new: ArraySlice<Unicode.Scalar>
        ) -> [Change] {
            guard !old.isEmpty || !new.isEmpty else { return [] }
            // Typical edits diff only the interior after equal prefix/suffix.
            // Bound work when a very large body is replaced in one edit.
            guard old.count <= 2048, new.count <= 2048 else {
                return [Change(old: old.startIndex..<old.endIndex, new: new.startIndex..<new.endIndex)]
            }
            let diff = new.difference(from: old)
            func offset(_ change: CollectionDifference<Unicode.Scalar>.Change) -> Int {
                switch change {
                case .insert(let offset, _, _), .remove(let offset, _, _): return offset
                }
            }
            let removed = Set(diff.removals.map(offset)), inserted = Set(diff.insertions.map(offset))
            var x = 0, y = 0, startX = 0, startY = 0
            var changes: [Change] = []
            func recordGap() {
                if x != startX || y != startY {
                    changes.append(Change(old: (old.startIndex + startX)..<(old.startIndex + x),
                                          new: (new.startIndex + startY)..<(new.startIndex + y)))
                }
            }
            while x < old.count && y < new.count {
                if removed.contains(x) { x += 1; continue }
                if inserted.contains(y) { y += 1; continue }
                recordGap()
                x += 1
                y += 1
                startX = x
                startY = y
            }
            x = old.count
            y = new.count
            recordGap()
            return changes
        }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
