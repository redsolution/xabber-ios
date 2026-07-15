//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation
import UIKit

struct ChatMessageLayoutContext: Hashable {
    let width: CGFloat
    let contentSizeCategory: String
    let localeIdentifier: String
    let interfaceStyleRawValue: Int
    let messageStyle: String
    let cornerRadius: String
    let avatarMode: String

    var normalizedWidth: CGFloat {
        (max(1, width) * 100).rounded(.toNearestOrAwayFromZero) / 100
    }
}

struct ChatMessageLayoutKey: Hashable {
    let primary: String
    let revision: String
    let context: ChatMessageLayoutContext

    init(primary: String, revision: String, context: ChatMessageLayoutContext) {
        self.primary = primary
        self.revision = revision
        self.context = ChatMessageLayoutContext(
            width: context.normalizedWidth,
            contentSizeCategory: context.contentSizeCategory,
            localeIdentifier: context.localeIdentifier,
            interfaceStyleRawValue: context.interfaceStyleRawValue,
            messageStyle: context.messageStyle,
            cornerRadius: context.cornerRadius,
            avatarMode: context.avatarMode
        )
    }

    init(message: ChatViewController.Datasource, context: ChatMessageLayoutContext) {
        self.init(
            primary: message.primary,
            revision: ChatMessageLayoutRevision.revision(for: message),
            context: context
        )
    }
}

struct ChatMessageLayout: Equatable {
    var cellSize: CGSize
    var messagePrimary: String
    var avatarSize: CGSize
    var avatarPosition: AvatarPosition
    var side: MessageSide
    var messageContainerSize: CGSize
    var messageContainerMargin: UIEdgeInsets
    var messageContainerPadding: UIEdgeInsets
    var messageLabelInsets: UIEdgeInsets
    var forwardsContainerViewSize: CGSize
    var forwardsInlineViewSize: [MessageAttachmentSizes]
    var audioInlineViewSize: CGSize
    var imagesInlineViewSize: CGSize
    var videosInlineViewSize: CGSize
    var locationsInlineViewSize: CGSize
    var contactsInlineViewSize: CGSize
    var filesInlineViewSize: CGSize
    var textInlineViewSize: CGSize
    var warningInlineViewSize: CGSize
    var authorInlineSize: CGSize
    var tail: String
    var cornerRadius: String
    var tailWidth: CGFloat
    var timeMarkerSize: CGSize
    var timeMarkerIndicator: IndicatorType
    var timeMarkerRadius: CGFloat
    var timeMarkerInsets: UIEdgeInsets
    var timeMarkerWithBackplate: Bool
    var inlineContainerSizeInsets: UIEdgeInsets
    var inlineContainerSizePadding: UIEdgeInsets
    var isImageMessage: Bool

    static func empty(cellSize: CGSize) -> ChatMessageLayout {
        ChatMessageLayout(cellSize: cellSize)
    }

    /// Constant-time emergency geometry for tests and defensive recovery when
    /// a caller bypasses the atomic datasource mapping pipeline. It performs
    /// no text or media measurement and is never installed as a ready layout.
    static func fallback(
        for message: MessageType,
        width: CGFloat
    ) -> ChatMessageLayout {
        let cellWidth = max(1, width)
        let availableWidth = max(1, cellWidth - 72)
        let containerWidth = min(
            cellWidth,
            max(112, min(420, availableWidth))
        )
        var layout = ChatMessageLayout(
            cellSize: CGSize(width: cellWidth, height: 38)
        )
        layout.messagePrimary = message.primary
        layout.side = message.isOutgoing ? .right : .left
        layout.messageContainerSize = CGSize(width: containerWidth, height: 38)
        layout.messageContainerMargin = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        layout.messageContainerPadding = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        layout.messageLabelInsets = UIEdgeInsets(top: 0, left: 6, bottom: 2, right: 6)
        layout.tailWidth = CommonMessageSizeCalculator.tailWidth
        if message.reservesAvatarSpace {
            layout.avatarSize = CGSize(square: 32)
        }
        return layout
    }

    private init(cellSize: CGSize) {
        self.cellSize = cellSize
        self.messagePrimary = ""
        self.avatarSize = .zero
        self.avatarPosition = AvatarPosition(vertical: .cellBottom)
        self.side = .right
        self.messageContainerSize = .zero
        self.messageContainerMargin = .zero
        self.messageContainerPadding = .zero
        self.messageLabelInsets = .zero
        self.forwardsContainerViewSize = .zero
        self.forwardsInlineViewSize = []
        self.audioInlineViewSize = .zero
        self.imagesInlineViewSize = .zero
        self.videosInlineViewSize = .zero
        self.locationsInlineViewSize = .zero
        self.contactsInlineViewSize = .zero
        self.filesInlineViewSize = .zero
        self.textInlineViewSize = .zero
        self.warningInlineViewSize = .zero
        self.authorInlineSize = .zero
        self.tail = "none"
        self.cornerRadius = "16"
        self.tailWidth = 0
        self.timeMarkerSize = .zero
        self.timeMarkerIndicator = .none
        self.timeMarkerRadius = 2
        self.timeMarkerInsets = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        self.timeMarkerWithBackplate = false
        self.inlineContainerSizeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 2)
        self.inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 2, bottom: 0, right: 2)
        self.isImageMessage = false
    }

    init(attributes: MessagesCollectionViewLayoutAttributes) {
        self.cellSize = attributes.size
        self.messagePrimary = attributes.messagePrimary
        self.avatarSize = attributes.avatarSize
        self.avatarPosition = attributes.avatarPosition
        self.side = attributes.side
        self.messageContainerSize = attributes.messageContainerSize
        self.messageContainerMargin = attributes.messageContainerMargin
        self.messageContainerPadding = attributes.messageContainerPadding
        self.messageLabelInsets = attributes.messageLabelInsets
        self.forwardsContainerViewSize = attributes.forwardsContainerViewSize
        self.forwardsInlineViewSize = attributes.forwardsInlineViewSize
        self.audioInlineViewSize = attributes.audioInlineViewSize
        self.imagesInlineViewSize = attributes.imagesInlineViewSize
        self.videosInlineViewSize = attributes.videosInlineViewSize
        self.locationsInlineViewSize = attributes.locationsInlineViewSize
        self.contactsInlineViewSize = attributes.contactsInlineViewSize
        self.filesInlineViewSize = attributes.filesInlineViewSize
        self.textInlineViewSize = attributes.textInlineViewSize
        self.warningInlineViewSize = attributes.warningInlineViewSize
        self.authorInlineSize = attributes.authorInlineSize
        self.tail = attributes.tail
        self.cornerRadius = attributes.cornerRadius
        self.tailWidth = attributes.tailWidth
        self.timeMarkerSize = attributes.timeMarkerSize
        self.timeMarkerIndicator = attributes.timeMarkerIndicator
        self.timeMarkerRadius = attributes.timeMarkerRadius
        self.timeMarkerInsets = attributes.timeMarkerInsets
        self.timeMarkerWithBackplate = attributes.timeMarkerWithBackplate
        self.inlineContainerSizeInsets = attributes.inlineContainerSizeInsets
        self.inlineContainerSizePadding = attributes.inlineContainerSizePadding
        self.isImageMessage = attributes.isImageMessage
    }

    func apply(to attributes: MessagesCollectionViewLayoutAttributes) {
        attributes.size = cellSize
        attributes.messagePrimary = messagePrimary
        attributes.avatarSize = avatarSize
        attributes.avatarPosition = avatarPosition
        attributes.side = side
        attributes.messageContainerSize = messageContainerSize
        attributes.messageContainerMargin = messageContainerMargin
        attributes.messageContainerPadding = messageContainerPadding
        attributes.messageLabelInsets = messageLabelInsets
        attributes.forwardsContainerViewSize = forwardsContainerViewSize
        attributes.forwardsInlineViewSize = forwardsInlineViewSize
        attributes.audioInlineViewSize = audioInlineViewSize
        attributes.imagesInlineViewSize = imagesInlineViewSize
        attributes.videosInlineViewSize = videosInlineViewSize
        attributes.locationsInlineViewSize = locationsInlineViewSize
        attributes.contactsInlineViewSize = contactsInlineViewSize
        attributes.filesInlineViewSize = filesInlineViewSize
        attributes.textInlineViewSize = textInlineViewSize
        attributes.warningInlineViewSize = warningInlineViewSize
        attributes.authorInlineSize = authorInlineSize
        attributes.tail = tail
        attributes.cornerRadius = cornerRadius
        attributes.tailWidth = tailWidth
        attributes.timeMarkerSize = timeMarkerSize
        attributes.timeMarkerIndicator = timeMarkerIndicator
        attributes.timeMarkerRadius = timeMarkerRadius
        attributes.timeMarkerInsets = timeMarkerInsets
        attributes.timeMarkerWithBackplate = timeMarkerWithBackplate
        attributes.inlineContainerSizeInsets = inlineContainerSizeInsets
        attributes.inlineContainerSizePadding = inlineContainerSizePadding
        attributes.isImageMessage = isImageMessage
    }
}

struct ChatMessageLayoutSnapshot {
    static let empty = ChatMessageLayoutSnapshot(
        layoutsByKey: [:],
        activeKeyByPrimary: [:],
        orderedKeys: []
    )

    fileprivate let layoutsByKey: [ChatMessageLayoutKey: ChatMessageLayout]
    fileprivate let activeKeyByPrimary: [String: ChatMessageLayoutKey]
    fileprivate let orderedKeys: [ChatMessageLayoutKey]

    var count: Int { layoutsByKey.count }

    func key(forPrimary primary: String) -> ChatMessageLayoutKey? {
        activeKeyByPrimary[primary]
    }

    func layout(forPrimary primary: String) -> ChatMessageLayout? {
        guard let key = activeKeyByPrimary[primary] else { return nil }
        return layoutsByKey[key]
    }

    func layout(forKey key: ChatMessageLayoutKey) -> ChatMessageLayout? {
        layoutsByKey[key]
    }

    static func single(
        key: ChatMessageLayoutKey,
        layout: ChatMessageLayout
    ) -> ChatMessageLayoutSnapshot {
        ChatMessageLayoutSnapshot(
            layoutsByKey: [key: layout],
            activeKeyByPrimary: [key.primary: key],
            orderedKeys: [key]
        )
    }

    fileprivate func limited(to capacity: Int) -> ChatMessageLayoutSnapshot {
        let limit = max(0, capacity)
        guard layoutsByKey.count > limit else { return self }
        guard limit > 0 else { return .empty }
        let keptKeys = Array(orderedKeys.suffix(limit))
        let keptSet = Set(keptKeys)
        return ChatMessageLayoutSnapshot(
            layoutsByKey: layoutsByKey.filter { keptSet.contains($0.key) },
            activeKeyByPrimary: activeKeyByPrimary.filter { keptSet.contains($0.value) },
            orderedKeys: keptKeys
        )
    }
}

final class ChatMessageLayoutOperationCounter {
    struct Snapshot: Equatable {
        let lookups: Int
        let hits: Int
        let misses: Int
        let measurements: Int
        let mainThreadMeasurements: Int
        let readyLookups: Int
        let readyMisses: Int
        let evictions: Int
    }

    private let lock = NSLock()
    private var lookups = 0
    private var hits = 0
    private var misses = 0
    private var measurements = 0
    private var mainThreadMeasurements = 0
    private var readyLookups = 0
    private var readyMisses = 0
    private var evictions = 0

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            lookups: lookups,
            hits: hits,
            misses: misses,
            measurements: measurements,
            mainThreadMeasurements: mainThreadMeasurements,
            readyLookups: readyLookups,
            readyMisses: readyMisses,
            evictions: evictions
        )
    }

    func recordLookup(hit: Bool) {
        lock.lock()
        lookups += 1
        if hit { hits += 1 } else { misses += 1 }
        lock.unlock()
    }

    func recordMeasurement() {
        lock.lock()
        measurements += 1
        if Thread.isMainThread { mainThreadMeasurements += 1 }
        lock.unlock()
    }

    func recordReadyLookup(hit: Bool) {
        lock.lock()
        readyLookups += 1
        if !hit { readyMisses += 1 }
        lock.unlock()
    }

    func recordEvictions(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        evictions += count
        lock.unlock()
    }
}

enum ChatMessageLayoutPrewarmer {
    typealias Measure = (
        _ message: ChatViewController.Datasource,
        _ context: ChatMessageLayoutContext
    ) -> ChatMessageLayout

    static func prewarm(
        items: [ChatViewController.Datasource],
        context: ChatMessageLayoutContext,
        reuse: ChatMessageLayoutSnapshot,
        capacity: Int,
        operationCounter: ChatMessageLayoutOperationCounter? = nil,
        shouldContinue: (() -> Bool)? = nil,
        measure: Measure = ChatMessageLayoutCalculator.measure
    ) -> ChatMessageLayoutSnapshot {
        let limit = max(0, capacity)
        guard limit > 0, items.isNotEmpty else { return .empty }

        var layoutsByKey: [ChatMessageLayoutKey: ChatMessageLayout] = [:]
        layoutsByKey.reserveCapacity(min(items.count, limit))
        var activeKeyByPrimary: [String: ChatMessageLayoutKey] = [:]
        activeKeyByPrimary.reserveCapacity(min(items.count, limit))
        var orderedKeys: [ChatMessageLayoutKey] = []
        orderedKeys.reserveCapacity(min(items.count, limit))

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 16),
               shouldContinue?() == false {
                break
            }
            let key = ChatMessageLayoutKey(message: item, context: context)
            activeKeyByPrimary[item.primary] = key
            if layoutsByKey[key] != nil {
                operationCounter?.recordLookup(hit: true)
                continue
            }
            if let reused = reuse.layout(forKey: key) {
                layoutsByKey[key] = reused
                orderedKeys.append(key)
                operationCounter?.recordLookup(hit: true)
                continue
            }
            operationCounter?.recordLookup(hit: false)
            operationCounter?.recordMeasurement()
            layoutsByKey[key] = measure(item, context)
            orderedKeys.append(key)
        }

        let snapshot = ChatMessageLayoutSnapshot(
            layoutsByKey: layoutsByKey,
            activeKeyByPrimary: activeKeyByPrimary,
            orderedKeys: orderedKeys
        )
        let limited = snapshot.limited(to: limit)
        operationCounter?.recordEvictions(snapshot.count - limited.count)
        return limited
    }
}

final class ChatMessageLayoutCache {
    let capacity: Int
    let operationCounter: ChatMessageLayoutOperationCounter

    private let lock = NSLock()
    private var snapshot: ChatMessageLayoutSnapshot = .empty

    init(
        capacity: Int = ChatPerformanceResourceBudgets.layoutCount,
        operationCounter: ChatMessageLayoutOperationCounter = ChatMessageLayoutOperationCounter()
    ) {
        self.capacity = max(0, capacity)
        self.operationCounter = operationCounter
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.count
    }

    func install(_ newSnapshot: ChatMessageLayoutSnapshot) {
        let limited = newSnapshot.limited(to: capacity)
        operationCounter.recordEvictions(newSnapshot.count - limited.count)
        lock.lock()
        snapshot = limited
        lock.unlock()
    }

    func reuseSnapshot() -> ChatMessageLayoutSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func layout(forPrimary primary: String) -> ChatMessageLayout? {
        lock.lock()
        let layout = snapshot.layout(forPrimary: primary)
        lock.unlock()
        operationCounter.recordReadyLookup(hit: layout != nil)
        return layout
    }

    @discardableResult
    func invalidate(primary: String, revision: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = snapshot.key(forPrimary: primary),
              revision == nil || revision == key.revision else {
            return false
        }
        var layouts = snapshot.layoutsByKey
        var active = snapshot.activeKeyByPrimary
        layouts.removeValue(forKey: key)
        active.removeValue(forKey: primary)
        snapshot = ChatMessageLayoutSnapshot(
            layoutsByKey: layouts,
            activeKeyByPrimary: active,
            // Keep the bounded immutable order vector until the next install.
            // Removing a ready layout must remain O(1); stale order entries are
            // ignored because both lookup dictionaries no longer contain `key`.
            orderedKeys: snapshot.orderedKeys
        )
        return true
    }

    func handleMemoryWarning() {
        lock.lock()
        snapshot = .empty
        lock.unlock()
    }

    func invalidate() {
        handleMemoryWarning()
    }
}

private enum ChatMessageLayoutRevision {
    static func revision(for message: ChatViewController.Datasource) -> String {
        var hasher = StableHasher()
        hasher.combine(message.primary)
        hasher.combine(message.isOutgoing)
        hasher.combine(message.withAuthor)
        hasher.combine(message.withAvatar)
        hasher.combine(message.reservesAvatarSpace)
        hasher.combine(message.tailed)
        hasher.combine(String(describing: message.indicator))
        hasher.combine(message.messageWarningText)
        hasher.combine(message.editDate?.timeIntervalSinceReferenceDate)
        combine(message.kind, into: &hasher)
        combine(message.attributedAuthor, into: &hasher)
        combine(message.timeMarkerText, into: &hasher)
        message.images.forEach {
            hasher.combine($0.primary)
            hasher.combine(Double($0.size.width))
            hasher.combine(Double($0.size.height))
        }
        message.videos.forEach {
            hasher.combine($0.primary)
            hasher.combine(Double($0.size.width))
            hasher.combine(Double($0.size.height))
        }
        message.locations.forEach { hasher.combine($0.primary) }
        message.contacts.forEach { hasher.combine($0.primary) }
        message.files.forEach { hasher.combine($0.primary) }
        message.audios.forEach { hasher.combine($0.primary) }
        message.forwards.forEach { combine($0, into: &hasher) }
        return hasher.revision
    }

    private static func combine(_ kind: MessageKind, into hasher: inout StableHasher) {
        switch kind {
        case .attributedText(let text):
            hasher.combine("attributedText")
            combine(text, into: &hasher)
        case .emoji(let text):
            hasher.combine("emoji")
            hasher.combine(text)
        case .sticker(let attachment):
            hasher.combine("sticker")
            hasher.combine(attachment.primary)
            hasher.combine(Double(attachment.size.width))
            hasher.combine(Double(attachment.size.height))
        case .call(let attachment):
            hasher.combine("call")
            hasher.combine(attachment.primary)
            hasher.combine(attachment.incoming)
            hasher.combine(attachment.missed)
        case .system(let text):
            hasher.combine("system")
            combine(text, into: &hasher)
        case .initial(let text):
            hasher.combine("initial")
            combine(text, into: &hasher)
        case .skeleton(let text):
            hasher.combine("skeleton")
            combine(text, into: &hasher)
        case .date(let text):
            hasher.combine("date")
            combine(text, into: &hasher)
        case .unread(let text):
            hasher.combine("unread")
            combine(text, into: &hasher)
        }
    }

    private static func combine(_ attachment: MessageAttachment, into hasher: inout StableHasher) {
        hasher.combine(attachment.primary)
        hasher.combine(attachment.outgoing)
        combine(attachment.attributedAuthor, into: &hasher)
        combine(attachment.textMessage, into: &hasher)
        combine(attachment.timeMarker, into: &hasher)
        attachment.images.forEach {
            hasher.combine($0.primary)
            hasher.combine(Double($0.size.width))
            hasher.combine(Double($0.size.height))
        }
        attachment.videos.forEach {
            hasher.combine($0.primary)
            hasher.combine(Double($0.size.width))
            hasher.combine(Double($0.size.height))
        }
        attachment.locations.forEach { hasher.combine($0.primary) }
        attachment.contacts.forEach { hasher.combine($0.primary) }
        attachment.files.forEach { hasher.combine($0.primary) }
        attachment.audios.forEach { hasher.combine($0.primary) }
        attachment.subforwards.forEach { combine($0, into: &hasher) }
    }

    private static func combine(_ text: NSAttributedString?, into hasher: inout StableHasher) {
        guard let text else {
            hasher.combine("nil")
            return
        }
        hasher.combine(text.string)
        let range = NSRange(location: 0, length: text.length)
        guard range.length > 0 else { return }
        text.enumerateAttributes(in: range) { attributes, range, _ in
            hasher.combine(range.location)
            hasher.combine(range.length)
            if let font = attributes[.font] as? UIFont {
                hasher.combine(font.fontName)
                hasher.combine(Double(font.pointSize))
                hasher.combine(Int(font.fontDescriptor.symbolicTraits.rawValue))
            }
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                hasher.combine(Double(paragraph.lineSpacing))
                hasher.combine(Double(paragraph.paragraphSpacing))
                hasher.combine(paragraph.alignment.rawValue)
                hasher.combine(paragraph.lineBreakMode.rawValue)
            }
            if let kern = attributes[.kern] as? NSNumber {
                hasher.combine(kern.doubleValue)
            }
        }
    }

    private struct StableHasher {
        private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
        private static let prime: UInt64 = 1_099_511_628_211
        private(set) var value: UInt64 = StableHasher.offsetBasis

        var revision: String { String(value, radix: 16) }

        mutating func combine(_ value: String?) {
            guard let value else {
                combine(byte: 0xff)
                return
            }
            value.utf8.forEach { combine(byte: $0) }
            combine(byte: 0xfe)
        }

        mutating func combine(_ value: Bool) { combine(byte: value ? 1 : 0) }
        mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }
        mutating func combine(_ value: Double?) {
            guard let value else {
                combine(byte: 0xfd)
                return
            }
            combine(value.bitPattern)
        }

        private mutating func combine(_ value: UInt64) {
            var value = value
            for _ in 0..<8 {
                combine(byte: UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }

        private mutating func combine(byte: UInt8) {
            value ^= UInt64(byte)
            value = value &* StableHasher.prime
        }
    }
}
