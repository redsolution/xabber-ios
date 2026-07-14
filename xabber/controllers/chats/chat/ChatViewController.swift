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

import UIKit
import RealmSwift
import RxSwift
import RxRealm
import RxCocoa
import Kingfisher
import AudioToolbox
import DeepDiff
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import AVFoundation
import XMPPFramework.XMPPJID

enum ChatHistoryPagingConfiguration {
    static let pageSize: Int = 250
}

enum ChatInitialFirstFrameHistoryConfiguration {
    static let pageSize: Int = 80
}

struct ChatSearchActivationRequest: Equatable {
    let activateKeyboard: Bool
    let animated: Bool
    let initialQuery: String?

    init(
        activateKeyboard: Bool,
        animated: Bool,
        initialQuery: String?
    ) {
        self.activateKeyboard = activateKeyboard
        self.animated = animated
        let normalizedQuery = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialQuery = normalizedQuery?.isEmpty == false ? normalizedQuery : nil
    }
}

struct ChatInChatSearchQueryContext: Equatable {
    let queryId: String
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let text: String

    var requiresRemoteArchiveSearch: Bool {
        Self.requiresRemoteArchiveSearch(conversationType: conversationType)
    }

    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func requiresRemoteArchiveSearch(
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> Bool {
        !conversationType.isEncrypted
    }

    func matchesSearchScope(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        text: String
    ) -> Bool {
        self.owner == owner &&
        self.jid == jid &&
        self.conversationType == conversationType &&
        self.text == Self.normalizedText(text)
    }

    func accepts(_ item: MessageStorageItem) -> Bool {
        item.owner == owner &&
        item.opponent == jid &&
        item.conversationType == conversationType &&
        !item.isDeleted &&
        item.messageType != MessageStorageItem.MessageDisplayType.system.rawValue
    }
}

enum ChatSearchResultNavigationState: Equatable {
    case idle
    case positioning(index: Int)
    case loadingContext(index: Int)
    case pending(index: Int, scrollDirection: ChatViewController.ChatDirection)

    var currentIndex: Int? {
        switch self {
        case .idle:
            return nil
        case .positioning(let index),
             .loadingContext(let index),
             .pending(let index, _):
            return index
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle:
            return false
        case .positioning, .loadingContext, .pending:
            return true
        }
    }
}

struct ChatSearchPendingNavigation: Equatable {
    let index: Int
    let scrollDirection: ChatViewController.ChatDirection
}

final class ChatSearchInputBarView: UIView, UITextViewDelegate {
    static let inputAccessibilityIdentifier = "chat_search_input"
    static let submitAccessibilityIdentifier = "chat_search_submit"
    static let maximumTextHeight: CGFloat = 130

    var onSubmit: ((String?) -> Void)?
    var onTextChanged: ((String?) -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?
    private var measuredHeight: CGFloat = NativeGlassBarStyle.minimumHeight

    let surfaceView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))
        view.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)
        view.isUserInteractionEnabled = true
        view.contentView.isUserInteractionEnabled = true
        return view
    }()

    let textView: InputTextView = {
        let view = InputTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = inputAccessibilityIdentifier
        view.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
        view.placeholderTextColor = .placeholderText
        view.backgroundColor = .clear
        view.layer.borderWidth = 0
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(
            top: 7,
            left: 4,
            bottom: 9,
            right: 8
        )
        view.placeholderLabelInsets = view.textContainerInset
        view.returnKeyType = .search
        view.enablesReturnKeyAutomatically = false
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .systemBlue
        view.isScrollEnabled = false
        view.isImagePasteEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }()

    let submitButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = submitAccessibilityIdentifier
        button.accessibilityLabel = "Search".localizeString(id: "search", arguments: [])
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: imageLiteral("magnifyingglass", dimension: NativeGlassBarStyle.iconSize)
        )
        return button
    }()

    var text: String? {
        get { textView.text }
        set {
            textView.text = newValue ?? ""
            refreshPlaceholderVisibility()
            updateMeasuredHeight(notify: true)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    @discardableResult
    func becomeInputFirstResponder() -> Bool {
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshPlaceholderVisibility()
        updateMeasuredHeight(notify: true)
        onTextChanged?(textView.text)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            submitCurrentText()
            return false
        }

        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMeasuredHeight(notify: false)
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self

        addSubview(surfaceView)
        surfaceView.contentView.addSubview(textView)
        addSubview(submitButton)

        submitButton.addTarget(self, action: #selector(onSubmitButtonTouchUp), for: .touchUpInside)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(
                equalTo: submitButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),

            submitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            submitButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            submitButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            submitButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),

            textView.leadingAnchor.constraint(
                equalTo: surfaceView.contentView.leadingAnchor,
                constant: NativeGlassBarStyle.contentInset
            ),
            textView.trailingAnchor.constraint(
                equalTo: surfaceView.contentView.trailingAnchor,
                constant: -NativeGlassBarStyle.contentInset
            ),
            textView.topAnchor.constraint(equalTo: surfaceView.contentView.topAnchor, constant: 4),
            textView.bottomAnchor.constraint(equalTo: surfaceView.contentView.bottomAnchor, constant: -4)
        ])
    }

    @objc
    private func onSubmitButtonTouchUp() {
        submitCurrentText()
    }

    private func submitCurrentText() {
        textView.resignFirstResponder()
        onSubmit?(textView.text)
    }

    private func updateMeasuredHeight(notify: Bool) {
        let height = calculatedHeight()
        guard abs(height - measuredHeight) > 0.5 else { return }

        measuredHeight = height
        invalidateIntrinsicContentSize()
        textView.isScrollEnabled = height >= Self.maximumTextHeight
        if notify {
            onHeightChanged?(height)
        }
    }

    private func calculatedHeight() -> CGFloat {
        let fittingWidth = textView.bounds.width > 0
            ? textView.bounds.width
            : fallbackTextViewWidth
        let fittingHeight = measuredTextHeight(forWidth: fittingWidth)
        let rawHeight = fittingHeight + 8
        if rawHeight <= NativeGlassBarStyle.minimumHeight + 4 {
            return NativeGlassBarStyle.minimumHeight
        }

        return min(
            max(NativeGlassBarStyle.minimumHeight, rawHeight),
            Self.maximumTextHeight
        )
    }

    private func measuredTextHeight(forWidth fittingWidth: CGFloat) -> CGFloat {
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let inset = textView.textContainerInset
        let textWidth = max(
            1,
            fittingWidth
                - inset.left
                - inset.right
                - textView.textContainer.lineFragmentPadding * 2
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let rawText = textView.text ?? ""
        let measuredTextHeight: CGFloat
        if rawText.isEmpty {
            measuredTextHeight = font.lineHeight
        } else {
            measuredTextHeight = (rawText as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: font,
                    .paragraphStyle: paragraphStyle
                ],
                context: nil
            ).height
        }

        return ceil(measuredTextHeight + inset.top + inset.bottom)
    }

    private var fallbackTextViewWidth: CGFloat {
        let width = bounds.width > 0 ? bounds.width : 358
        return max(
            NativeGlassBarStyle.buttonSize,
            width
                - NativeGlassBarStyle.buttonSize
                - NativeGlassBarStyle.interItemSpacing
                - NativeGlassBarStyle.contentInset * 2
        )
    }

    private func refreshPlaceholderVisibility() {
        textView.placeholderLabel.isHidden = !textView.text.isEmpty
    }
}

enum ChatConnectionStatusTextPolicy {
    static var waitingForNetworkText: String {
        "Waiting for network...".localizeString(id: "waiting_for_network", arguments: [])
    }

    static var connectingText: String {
        "Connecting...".localizeString(id: "application_state_connecting", arguments: [])
    }

    static func text(
        actionText: String?,
        isAccountConnecting: Bool,
        sendReadinessSnapshot: AccountSendReadinessSnapshot?,
        isNetworkPathSatisfied: Bool?,
        fallbackStatus: String?
    ) -> String {
        if let actionText, actionText.isNotEmpty {
            return actionText
        }
        guard isAccountConnecting else {
            return fallbackStatus ?? " "
        }
        guard isNetworkPathSatisfied != false else {
            return waitingForNetworkText
        }
        guard let phase = sendReadinessSnapshot?.phase else {
            return connectingText
        }

        switch phase {
        case .connecting, .tlsNegotiating, .authenticating, .binding, .enablingStreamManagement,
             .resuming, .suspectedStale, .streamError, .streamManagementFailed:
            return connectingText
        case .disconnected, .backgroundSuspended, .ready(_):
            return fallbackStatus ?? " "
        }
    }
}

struct ChatHistoryLoadActivityKey: Hashable {
    let owner: String
    let jid: String
    let conversationTypeRawValue: String
    let reason: String

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        reason: String
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationTypeRawValue = conversationType.rawValue
        self.reason = reason
    }
}

enum ChatHistoryLoadActivityRegistry {
    private static let lock = NSLock()
    private static var activeCounts: [ChatHistoryLoadActivityKey: Int] = [:]

    static var hasActiveHistoryLoad: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCounts.values.contains { $0 > 0 }
    }

    static func begin(_ key: ChatHistoryLoadActivityKey) {
        lock.lock()
        activeCounts[key, default: 0] += 1
        lock.unlock()
    }

    static func end(_ key: ChatHistoryLoadActivityKey) {
        lock.lock()
        if let count = activeCounts[key], count > 1 {
            activeCounts[key] = count - 1
        } else {
            activeCounts.removeValue(forKey: key)
        }
        lock.unlock()
    }

    static func resetForTests() {
        lock.lock()
        activeCounts.removeAll()
        lock.unlock()
    }
}

enum ChatInitialBootstrapArchivePageSizePolicy {
    static func requestPageSize(
        initialFirstFramePageSize: Int,
        datasourcePageSize: Int
    ) -> Int {
        max(1, min(initialFirstFramePageSize, datasourcePageSize))
    }
}

enum ChatOpenMessageRequestSource: String {
    case mentionNotification = "mention-notification"
    case pushNotification = "push-notification"
    case search = "search"
    case external = "external"
    case voicePlayer = "voice-player"
    case composerReferencePreview = "composer-reference-preview"
    case composerEditPreview = "composer-edit-preview"
    case pinnedMessage = "pinned-message"
    case initialUnreadBoundary = "initial-unread-boundary"
    case savedVisiblePosition = "saved-visible-position"
    case directOpenAtMessage = "direct-open-at-message"
    case mediaGallery = "media-gallery"

    var usesTransientHighlight: Bool {
        switch self {
        case .voicePlayer, .composerReferencePreview, .composerEditPreview, .pinnedMessage, .mediaGallery:
            return true
        case .mentionNotification, .pushNotification, .search, .external, .initialUnreadBoundary, .savedVisiblePosition, .directOpenAtMessage:
            return false
        }
    }
}

enum ChatOpenMessageTargetResolution: Equatable {
    case anchor
    case firstIncomingAfterBoundary(String)
}

struct ChatMessageAnchorRef: Equatable {
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let bodyFingerprint: String?
    let sourceDate: Date
}

struct ChatOpenMessageRequest: Equatable {
    let chatJid: String
    let owner: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let anchor: ChatMessageAnchorRef
    let highlight: Bool
    let markReadOnVisible: Bool
    let source: ChatOpenMessageRequestSource
    let targetResolution: ChatOpenMessageTargetResolution

    init(
        chatJid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        anchor: ChatMessageAnchorRef,
        highlight: Bool,
        markReadOnVisible: Bool,
        source: ChatOpenMessageRequestSource,
        targetResolution: ChatOpenMessageTargetResolution = .anchor
    ) {
        self.chatJid = chatJid
        self.owner = owner
        self.conversationType = conversationType
        self.anchor = anchor
        self.highlight = highlight
        self.markReadOnVisible = markReadOnVisible
        self.source = source
        self.targetResolution = targetResolution
    }

    static func openAtMessage(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        stanzaId: String,
        sourceDate: Date = Date()
    ) -> ChatOpenMessageRequest? {
        guard let archivedId = normalizedIdentifier(stanzaId) else {
            return nil
        }

        return ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: sourceDate
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .directOpenAtMessage
        )
    }

    private static func normalizedIdentifier(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum ChatScrollDownButtonVisibilityPolicy {
    static let contentOffsetThreshold: CGFloat = 44

    static func shouldShow(
        contentOffsetY: CGFloat,
        isNearBottom: Bool,
        isSearchMode: Bool
    ) -> Bool {
        contentOffsetY > contentOffsetThreshold && !isNearBottom && !isSearchMode
    }
}

enum ChatScrollDownTargetPolicy {
    enum Target: Equatable {
        case unreadBoundary(String)
        case latest
    }

    struct ChatState: Equatable {
        let unread: Int
        let syncUnreadCount: Int
        let syncUnreadAfterId: String?
        let lastReadId: String?
    }

    struct VisibleMessage {
        let archivedId: String?
        let rowKind: ChatVisiblePositionPolicy.RowKind
        let isFakeMessage: Bool
    }

    static func target(
        chat: ChatState,
        visibleMessages: [VisibleMessage]
    ) -> Target {
        guard chat.unread > 0,
              chat.syncUnreadCount > 0,
              let boundaryId = normalizedPositiveNumericBoundary(chat.syncUnreadAfterId)
                ?? normalizedPositiveNumericBoundary(chat.lastReadId),
              let boundaryValue = Double(boundaryId) else {
            return .latest
        }

        let realVisibleMessages = visibleMessages.filter {
            $0.rowKind == .message && !$0.isFakeMessage
        }
        guard realVisibleMessages.isNotEmpty else {
            return .unreadBoundary(boundaryId)
        }

        var maxVisibleValue: Double?
        for message in realVisibleMessages {
            guard let archivedId = message.archivedId,
                  let visibleValue = Double(archivedId),
                  visibleValue.isFinite else {
                return .latest
            }
            maxVisibleValue = max(maxVisibleValue ?? visibleValue, visibleValue)
        }

        guard let maxVisibleValue else {
            return .unreadBoundary(boundaryId)
        }
        return boundaryValue > maxVisibleValue ? .unreadBoundary(boundaryId) : .latest
    }

    private static func normalizedPositiveNumericBoundary(_ value: String?) -> String? {
        guard let normalized = ChatInitialPositionPolicy.normalizedId(value),
              let numericValue = Double(normalized),
              numericValue.isFinite,
              numericValue > 0 else {
            return nil
        }
        return normalized
    }
}

enum ChatViewportReadBoundaryPolicy {
    struct OrderedMessage {
        let primary: String
        let orderIndex: Int
        let isOutgoing: Bool
        let isRead: Bool
        let rowKind: ChatVisiblePositionPolicy.RowKind
        let isFakeMessage: Bool
    }

    static func nextVisibleIncomingTarget(
        visiblePrimaries: Set<String>,
        orderedMessages: [OrderedMessage],
        currentBoundaryIndex: Int?
    ) -> OrderedMessage? {
        newestEligibleTarget(
            orderedMessages.filter {
                visiblePrimaries.contains($0.primary) &&
                isViewportReadCandidate($0)
            },
            currentBoundaryIndex: currentBoundaryIndex,
            allowsCurrentBoundary: false
        )
    }

    static func newestPendingTarget(
        pendingPrimaries: Set<String>,
        orderedMessages: [OrderedMessage],
        currentBoundaryIndex: Int?
    ) -> OrderedMessage? {
        newestEligibleTarget(
            orderedMessages.filter {
                pendingPrimaries.contains($0.primary) &&
                isViewportReadCandidate($0)
            },
            currentBoundaryIndex: currentBoundaryIndex,
            allowsCurrentBoundary: true
        )
    }

    static func resolvedDisplayedMarkerTarget(
        primary: String,
        orderedMessages: [OrderedMessage],
        currentBoundaryIndex: Int?
    ) -> OrderedMessage? {
        guard let candidate = orderedMessages.first(where: { $0.primary == primary }),
              isIncomingRealMessage(candidate) else {
            return nil
        }
        return newestEligibleTarget(
            [candidate],
            currentBoundaryIndex: currentBoundaryIndex,
            allowsCurrentBoundary: false
        )
    }

    private static func newestEligibleTarget(
        _ candidates: [OrderedMessage],
        currentBoundaryIndex: Int?,
        allowsCurrentBoundary: Bool
    ) -> OrderedMessage? {
        candidates
            .filter { candidate in
                guard let currentBoundaryIndex else {
                    return true
                }
                return allowsCurrentBoundary
                    ? candidate.orderIndex >= currentBoundaryIndex
                    : candidate.orderIndex > currentBoundaryIndex
            }
            .max { $0.orderIndex < $1.orderIndex }
    }

    private static func isViewportReadCandidate(_ message: OrderedMessage) -> Bool {
        isIncomingRealMessage(message) && !message.isRead
    }

    private static func isIncomingRealMessage(_ message: OrderedMessage) -> Bool {
        message.rowKind == .message &&
        !message.isFakeMessage &&
        !message.isOutgoing
    }
}

enum ChatBackgroundLastChatsKeyPolicy {
    static func primaryKey(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> String {
        LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
    }
}

struct ChatSavedVisiblePosition: Equatable {
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let sourceDate: Date

    var hasAnchor: Bool {
        messagePrimary?.isNotEmpty == true
            || archivedId?.isNotEmpty == true
            || messageId?.isNotEmpty == true
    }
}

enum ChatNavigationTransitionMutationPolicy {
    static func shouldDeferMutation(
        isTransitionActive: Bool,
        isCriticalForFirstFrame: Bool
    ) -> Bool {
        isTransitionActive && !isCriticalForFirstFrame
    }

    static func shouldAnimateMutation(
        requestedAnimated: Bool,
        isTransitionActive: Bool,
        isPreparingFirstFrame: Bool
    ) -> Bool {
        requestedAnimated && !isTransitionActive && !isPreparingFirstFrame
    }

    static func shouldDeferOpenMessageRequest(
        isTransitionActive: Bool,
        hasPendingRequest: Bool
    ) -> Bool {
        isTransitionActive && hasPendingRequest
    }
}

enum ChatOpenTimingPolicy {
    static func shouldLogFirstMessagesPrepared(
        hasActiveSession: Bool,
        didLogPrepared: Bool,
        realMessageCount: Int,
        sectionCount: Int
    ) -> Bool {
        hasActiveSession &&
            !didLogPrepared &&
            realMessageCount > 0 &&
            sectionCount > 0
    }

    static func shouldLogFirstMessagesVisible(
        hasActiveSession: Bool,
        didLogVisible: Bool,
        realMessageCount: Int,
        sectionCount: Int,
        visibleItemCount: Int,
        isViewVisible: Bool
    ) -> Bool {
        hasActiveSession &&
            !didLogVisible &&
            realMessageCount > 0 &&
            sectionCount > 0 &&
            visibleItemCount > 0 &&
            isViewVisible
    }

    static func milliseconds(from start: Date?, to end: Date) -> Int? {
        guard let start else {
            return nil
        }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }
}

struct ChatOpenTimingSession {
    let id: String
    let trigger: String
    let startedAt: Date
    var viewWillAppearAt: Date?
    var initialDatasourceLoadScheduledAt: Date?
    var initialDatasourceLoadDequeuedAt: Date?
    var initialDatasourceLoadStartedAt: Date?
    var viewDidAppearAt: Date?
    var firstMessagesPreparedAt: Date?
    var firstMessagesVisibleAt: Date?
    var firstDatasourceApplyStartedAt: Date?
    var didLogInitialDatasourceLoadFinish: Bool = false
    var didLogFirstMessagesPrepared: Bool = false
    var didLogFirstMessagesVisible: Bool = false
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

private extension UIEdgeInsets {
    func isApproximatelyEqual(to other: UIEdgeInsets, tolerance: CGFloat = 0.5) -> Bool {
        abs(top - other.top) <= tolerance
            && abs(left - other.left) <= tolerance
            && abs(bottom - other.bottom) <= tolerance
            && abs(right - other.right) <= tolerance
    }
}

struct ChatFloatingHeaderLayoutPolicy {
    static let composerMessageSpacing: CGFloat = 8
    static let floatingStackTopSpacing: CGFloat = 8
    static let floatingStackBottomSpacing: CGFloat = 8

    static func visibleStackHeight(visibleBubbleHeights: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !visibleBubbleHeights.isEmpty else {
            return 0
        }
        return visibleBubbleHeights.reduce(0, +) + CGFloat(visibleBubbleHeights.count - 1) * spacing
    }

    static func collectionInsets(
        composerHeight: CGFloat,
        navigationVisualHeight: CGFloat,
        floatingBubblesHeight: CGFloat,
        contentHeight: CGFloat = 0,
        viewportHeight: CGFloat = 0
    ) -> UIEdgeInsets {
        let floatingReservedHeight = floatingBubblesHeight > 0
            ? floatingStackTopSpacing + floatingBubblesHeight + floatingStackBottomSpacing
            : 0
        let baseInsets = UIEdgeInsets(
            top: navigationVisualHeight + floatingReservedHeight,
            left: 0,
            bottom: composerHeight + composerMessageSpacing,
            right: 0
        )
        let extraTopInset = bottomAlignmentExtraTopInset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            baseInsets: baseInsets
        )
        return UIEdgeInsets(
            top: baseInsets.top + extraTopInset,
            left: 0,
            bottom: baseInsets.bottom,
            right: 0
        )
    }

    static func scrollIndicatorInsets(
        composerHeight: CGFloat,
        navigationVisualHeight: CGFloat,
        floatingBubblesHeight: CGFloat
    ) -> UIEdgeInsets {
        let floatingReservedHeight = floatingBubblesHeight > 0
            ? floatingStackTopSpacing + floatingBubblesHeight + floatingStackBottomSpacing
            : 0
        return UIEdgeInsets(
            top: navigationVisualHeight + floatingReservedHeight,
            left: 0,
            bottom: composerHeight + composerMessageSpacing,
            right: 0
        )
    }

    static func bottomAlignmentExtraTopInset(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        baseInsets: UIEdgeInsets
    ) -> CGFloat {
        guard viewportHeight > 0 else {
            return 0
        }
        let availableHeight = viewportHeight - baseInsets.top - baseInsets.bottom
        guard availableHeight > 0 else {
            return 0
        }
        return max(0, availableHeight - contentHeight)
    }
}

struct ChatBottomScrollAlignmentPolicy {
    static let contentOffsetTolerance: CGFloat = 0.5

    static func targetContentOffsetY(
        targetMaxY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        contentInsets: UIEdgeInsets
    ) -> CGFloat {
        guard viewportHeight > 0 else {
            return -contentInsets.top
        }

        let normalizedContentHeight = max(0, contentHeight)
        let normalizedTargetMaxY = min(max(0, targetMaxY), normalizedContentHeight)
        let minOffsetY = -contentInsets.top
        let maxOffsetY = max(
            minOffsetY,
            normalizedContentHeight - viewportHeight + contentInsets.bottom
        )
        let requestedOffsetY = normalizedTargetMaxY - viewportHeight + contentInsets.bottom
        return min(max(requestedOffsetY, minOffsetY), maxOffsetY)
    }

    static func isAligned(
        currentOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        tolerance: CGFloat = contentOffsetTolerance
    ) -> Bool {
        abs(currentOffsetY - targetOffsetY) <= tolerance
    }
}

enum ChatSubscriptionStatusText: Equatable {
    case notInContacts
    case incomingSubscriptionRequest
    case inContacts
    case subscriptionRequestPending
    case receivesPresenceUpdates

    var localizedString: String {
        switch self {
        case .notInContacts:
            return "Not in your contacts"
                .localizeString(id: "contact_state_not_in_contact_list", arguments: [])
        case .incomingSubscriptionRequest:
            return "Incoming subscription request"
                .localizeString(id: "incoming_subscription_request", arguments: [])
        case .inContacts:
            return "In your contacts"
                .localizeString(id: "contact_state_in_contact_list", arguments: [])
        case .subscriptionRequestPending:
            return "Subscription request pending..."
                .localizeString(id: "chat_subscription_request_pending", arguments: [])
        case .receivesPresenceUpdates:
            return "Receives your presence updates"
                .localizeString(id: "chat_receives_presence_updates", arguments: [])
        }
    }
}

struct ChatSubscriptionPresentationInput: Equatable {
    let hasRosterItem: Bool
    let subscribtion: RosterStorageItem.Subsccribtion
    let ask: RosterStorageItem.Ask
    let conversationType: ClientSynchronizationManager.ConversationType
    let isServerJID: Bool
    let isSavedChat: Bool
    let isBlocked: Bool
    let isContact: Bool
}

struct ChatSubscriptionPresentation: Equatable {
    enum StatusMode: Equatable {
        case unchanged
        case fixed(ChatSubscriptionStatusText)
        case normalPresence
    }

    enum TopPanelKind: Equatable {
        case none
        case addContact
        case contactRequest
        case requestSubscription
        case allowSubscription
    }

    enum Action: Equatable {
        case addContact
        case requestSubscription
        case allowSubscription
        case block
        case close
    }

    let statusMode: StatusMode
    let topPanelKind: TopPanelKind
    let actions: [Action]
    let showsNormalPresenceStatus: Bool
}

enum ChatSubscriptionPresentationPolicy {
    static func presentation(
        rosterItem: RosterStorageItem?,
        conversationType: ClientSynchronizationManager.ConversationType,
        isServerJID: Bool,
        isSavedChat: Bool,
        isBlocked: Bool
    ) -> ChatSubscriptionPresentation {
        presentation(for: ChatSubscriptionPresentationInput(
            hasRosterItem: rosterItem != nil,
            subscribtion: rosterItem?.subscribtion ?? .undefined,
            ask: rosterItem?.ask ?? .none,
            conversationType: conversationType,
            isServerJID: isServerJID,
            isSavedChat: isSavedChat,
            isBlocked: isBlocked,
            isContact: rosterItem?.isContact ?? true
        ))
    }

    static func presentation(for input: ChatSubscriptionPresentationInput) -> ChatSubscriptionPresentation {
        guard applies(to: input) else {
            return ChatSubscriptionPresentation(
                statusMode: .unchanged,
                topPanelKind: .none,
                actions: [],
                showsNormalPresenceStatus: false
            )
        }

        let subscribtion: RosterStorageItem.Subsccribtion = input.hasRosterItem ? input.subscribtion : .undefined

        switch subscribtion {
        case .undefined:
            switch input.ask {
            case .none:
                return fixed(.notInContacts, panel: .addContact, actions: [.addContact, .block, .close])
            case .in, .both:
                return fixed(.incomingSubscriptionRequest, panel: .contactRequest, actions: [.addContact, .block, .close])
            case .out:
                return fixed(.subscriptionRequestPending)
            }
        case .none:
            switch input.ask {
            case .none:
                return fixed(.inContacts)
            case .in:
                return fixed(.inContacts, panel: .allowSubscription, actions: [.allowSubscription, .block, .close])
            case .out:
                return fixed(.subscriptionRequestPending)
            case .both:
                return fixed(.subscriptionRequestPending, panel: .allowSubscription, actions: [.allowSubscription, .block, .close])
            }
        case .to:
            switch input.ask {
            case .in, .both:
                return normal(panel: .allowSubscription, actions: [.allowSubscription, .block, .close])
            case .none, .out:
                return normal()
            }
        case .from:
            switch input.ask {
            case .out, .both:
                return fixed(.subscriptionRequestPending)
            case .none, .in:
                return fixed(.receivesPresenceUpdates)
            }
        case .both:
            return normal()
        }
    }

    private static func applies(to input: ChatSubscriptionPresentationInput) -> Bool {
        guard !input.isSavedChat,
              !input.isServerJID,
              !input.isBlocked,
              input.isContact else {
            return false
        }
        return input.conversationType == .regular || input.conversationType.isEncrypted
    }

    private static func fixed(
        _ status: ChatSubscriptionStatusText,
        panel: ChatSubscriptionPresentation.TopPanelKind = .none,
        actions: [ChatSubscriptionPresentation.Action] = []
    ) -> ChatSubscriptionPresentation {
        ChatSubscriptionPresentation(
            statusMode: .fixed(status),
            topPanelKind: panel,
            actions: actions,
            showsNormalPresenceStatus: false
        )
    }

    private static func normal(
        panel: ChatSubscriptionPresentation.TopPanelKind = .none,
        actions: [ChatSubscriptionPresentation.Action] = []
    ) -> ChatSubscriptionPresentation {
        ChatSubscriptionPresentation(
            statusMode: .normalPresence,
            topPanelKind: panel,
            actions: actions,
            showsNormalPresenceStatus: true
        )
    }
}

enum ChatPinnedMessageBarHeightPolicy {
    static let minimumHeight: CGFloat = NativeGlassBarStyle.minimumHeight
    static let maximumHeight: CGFloat = 88

    static func visualHeight(forFittingHeight fittingHeight: CGFloat) -> CGFloat {
        min(max(fittingHeight, minimumHeight), maximumHeight)
    }
}

final class ChatPinnedMessagePanelView: UIControl {
    enum Metrics {
        static let height = ChatPinnedMessageBarHeightPolicy.minimumHeight
        static let iconSize = NativeGlassBarStyle.iconSize
        static let unpinButtonSize = NativeGlassBarStyle.buttonSize
        static let horizontalSpacing = NativeGlassBarStyle.interItemSpacing
        static let verticalTextSpacing: CGFloat = 1
    }

    let pinIconView: UIImageView = {
        let imageView = UIImageView(frame: .zero)
        imageView.image = UIImage(systemName: "pin.fill")?.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = .tintColor
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }()

    let titleLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    let previewLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = .label
        label.numberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    let unpinButton: UIButton = {
        let button = UIButton(type: .system)
        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: .secondaryLabel,
            image: UIImage(systemName: "pin.slash.fill") ?? UIImage(systemName: "xmark"),
            prefersNativeGlass: false
        )
        button.accessibilityLabel = "Unpin message".localizeString(
            id: "group_chat__pinned_message__tooltip_unpin",
            arguments: []
        )
        return button
    }()

    private let textStack: UIStackView = {
        let stack = UIStackView(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = Metrics.verticalTextSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        return stack
    }()

    private var textTrailingToUnpinConstraint: NSLayoutConstraint?
    private var textTrailingToTrailingConstraint: NSLayoutConstraint?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        accessibilityTraits.insert(.button)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(previewLabel)

        addSubview(pinIconView)
        addSubview(textStack)
        addSubview(unpinButton)

        let textTrailingToUnpin = unpinButton.leadingAnchor.constraint(
            equalTo: textStack.trailingAnchor,
            constant: Metrics.horizontalSpacing
        )
        let textTrailingToTrailing = textStack.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.textTrailingToUnpinConstraint = textTrailingToUnpin
        self.textTrailingToTrailingConstraint = textTrailingToTrailing

        NSLayoutConstraint.activate([
            pinIconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            pinIconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            textStack.leadingAnchor.constraint(equalTo: pinIconView.trailingAnchor, constant: Metrics.horizontalSpacing),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            textTrailingToUnpin,
            unpinButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            unpinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            unpinButton.widthAnchor.constraint(equalToConstant: Metrics.unpinButtonSize),
            unpinButton.heightAnchor.constraint(equalToConstant: Metrics.unpinButtonSize)
        ])
        textTrailingToTrailing.isActive = false
    }

    func configure(title: NSAttributedString?, preview: String, showsUnpinButton: Bool) {
        titleLabel.attributedText = title
        titleLabel.isHidden = title?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        previewLabel.text = preview
        unpinButton.isHidden = !showsUnpinButton
        unpinButton.isUserInteractionEnabled = showsUnpinButton
        textTrailingToUnpinConstraint?.isActive = showsUnpinButton
        textTrailingToTrailingConstraint?.isActive = !showsUnpinButton
        accessibilityLabel = titleLabel.isHidden ? preview : "\(titleLabel.text ?? ""), \(preview)"
    }

    func preferredContentHeight(width: CGFloat) -> CGFloat {
        guard width > 0 else {
            return ChatPinnedMessageBarHeightPolicy.minimumHeight
        }
        let size = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ChatPinnedMessageBarHeightPolicy.visualHeight(forFittingHeight: size.height)
    }
}

final class ChatFloatingGlassBubbleView: UIView {
    private enum Metrics {
        static let cornerRadius: CGFloat = NativeGlassBarStyle.cornerRadius
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 0
    }

    private let blurView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private var hostedView: UIView?
    private var hostedViewConstraints: [NSLayoutConstraint] = []
    private var heightConstraint: NSLayoutConstraint?
    private var contentHeight: CGFloat
    private let verticalPadding: CGFloat

    init(contentHeight: CGFloat, verticalPadding: CGFloat = Metrics.verticalPadding) {
        self.contentHeight = contentHeight
        self.verticalPadding = verticalPadding
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.contentHeight = 44
        self.verticalPadding = Metrics.verticalPadding
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        layer.shadowColor = nil
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.shadowPath = nil
        NativeGlassBarStyle.applySurface(to: blurView, cornerStyle: .capsule, interactive: true)

        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        heightConstraint = heightAnchor.constraint(equalToConstant: contentHeight + verticalPadding * 2)
        heightConstraint?.isActive = true
        isHidden = true
    }

    func setHostedView(_ view: UIView?, contentHeight: CGFloat) {
        let newHeight = contentHeight + verticalPadding * 2
        if hostedView === view {
            self.contentHeight = contentHeight
            if abs((heightConstraint?.constant ?? newHeight) - newHeight) > 0.5 {
                heightConstraint?.constant = newHeight
                setNeedsLayout()
            }
            return
        }

        NSLayoutConstraint.deactivate(hostedViewConstraints)
        hostedViewConstraints = []
        hostedView?.removeFromSuperview()
        hostedView = view
        self.contentHeight = contentHeight
        heightConstraint?.constant = newHeight

        guard let view else {
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(view)
        hostedViewConstraints = [
            view.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: Metrics.horizontalPadding),
            view.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -Metrics.horizontalPadding),
            view.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: verticalPadding),
            view.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -verticalPadding)
        ]
        NSLayoutConstraint.activate(hostedViewConstraints)
    }

    func measuredHeight() -> CGFloat {
        heightConstraint?.constant ?? (contentHeight + verticalPadding * 2)
    }
}

final class ChatFloatingActionPanelView: UIView {
    private enum Metrics {
        static let height: CGFloat = NativeGlassBarStyle.minimumHeight
        static let iconSize: CGFloat = NativeGlassBarStyle.iconSize
        static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
    }

    private let iconView: UIImageView = {
        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .tintColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView(frame: .zero)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    let closeButton: UIButton = {
        let button = UIButton(type: .system)
        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: .secondaryLabel,
            image: UIImage(systemName: "xmark"),
            prefersNativeGlass: false
        )
        return button
    }()

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height)
    }

    init(icon: UIImage?, tintColor: UIColor, showsCloseButton: Bool = true) {
        super.init(frame: .zero)
        setup(icon: icon, tintColor: tintColor, showsCloseButton: showsCloseButton)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(icon: nil, tintColor: .tintColor, showsCloseButton: true)
    }

    private func setup(icon: UIImage?, tintColor: UIColor, showsCloseButton: Bool) {
        backgroundColor = .clear
        isOpaque = false
        layer.borderWidth = 0
        layer.borderColor = nil
        layer.shadowColor = nil
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.shadowPath = nil
        iconView.image = icon?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = tintColor
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(contentStack)
        addSubview(closeButton)

        closeButton.isHidden = !showsCloseButton

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            contentStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize)
        ])
    }

    func addCloseTarget(_ target: Any?, action: Selector) {
        closeButton.addTarget(target, action: action, for: .touchUpInside)
    }

    func setContentViews(_ views: [UIView]) {
        contentStack.removeAllArrangedSubviews()
        views.forEach {
            if let button = $0 as? UIButton {
                button.titleLabel?.lineBreakMode = .byTruncatingTail
            }
            contentStack.addArrangedSubview($0)
        }
    }
}

class ChatViewController: MessagesViewController {
    static let staleDatasourceFallbackPrimary = "stale-datasource-fallback"

    struct ChangesetItem: Hashable, Equatable {
        let index: Int
        let primary: String
        
    }
    
    final class ChatTimelineInteractionState {
        var isLoading: Bool = false
        var locked: Bool = false

        var isUnlocked: Bool {
            !locked
        }

        @discardableResult
        func performLocked(autoUnlock: Bool = true, _ work: () -> Void) -> Bool {
            if locked {
                return false
            }
            locked = true
            work()
            if autoUnlock {
                unlock()
            }
            return true
        }

        func unlock() {
            locked = false
        }
    }
    
    struct ChangesWithIndexSet {
        let inserts: IndexSet
        let deletes: IndexSet
        var replaces: IndexSet
        let moves: [(from: IndexPath, to: IndexPath)]
    }
    
    enum ChatDirection: Equatable {
        case up
        case down
    }
    
    enum TopPanelState: String {
        case none = "none"
        case pinnedMessage = "pinned"
        case addContact = "add_contact"
        case requestSubscribtion = "request_subscribtion"
        case allowSubscribtion = "allow_subscribtion"
        case requestedVerification = "requested_verification"
        case enterCodeVerification = "enter_code_verification"
        case requestingVerification = "requesting_verification"
        case shouldRequestVerification = "should_request_verification"
        case acceptedVerification = "accepted_verification"
        case audioPlayer = "audio_player"

        var isSubscriptionPanel: Bool {
            switch self {
            case .addContact, .requestSubscribtion, .allowSubscribtion:
                return true
            case .none, .pinnedMessage, .requestedVerification, .enterCodeVerification,
                    .requestingVerification, .shouldRequestVerification, .acceptedVerification,
                    .audioPlayer:
                return false
            }
        }
    }
    
    enum InputBarState {
        case short
        case normal
        case selection
    }
    
    enum NavigationBarStyle {
        case normal
        case selection
    }
    
    enum BackgroundColor: String, CaseIterable {
        case purple = "purple"
        case darkRed = "darkRed"
        case lightRed = "lightRed"
        case yellowOrange = "yellowOrange"
        case yellowBlue = "yellowBlue"
        case lightGreen = "lightGreen"
        case greenBlue = "greenBlue"
        case lightBlue = "lightBlue"
    }
    
    struct PlayingAudioCell {
        let indexPath: IndexPath
        let isForward: Bool
        let index: Int?
        let messageId: String?
        let isPlaying: Bool
    }
    
    struct Datasource: MessageType, DiffAware {
        
        var diffId: String {
            get {
                return primary
            }
        }
        
        var primary: String
        var jid: String
        var owner: String
        var outgoing: Bool
        var sender: Sender
        var messageId: String
        var sentDate: Date
        var editDate: Date?
        var kind: MessageKind
        var withAuthor: Bool
        var withAvatar: Bool
        var reservesAvatarSpace: Bool = false
        var error: Bool
        var errorType: String
        var canPinMessage: Bool
        var canEditMessage: Bool
        var canDeleteMessage: Bool
        var forwards: [MessageAttachment]
        var isOutgoing: Bool
        var isEdited: Bool
        var groupchatAuthorRole: String
        var groupchatAuthorId: String
        var groupchatAuthorNickname: String
        var groupchatAuthorBadge: String
        var isHasAttachedMessages: Bool
        var isDownloaded: Bool
        var state: MessageStorageItem.MessageSendingState
        var searchString: String?
        var errorMetadata: [String: Any]? = nil
        var messageWarningText: String? = nil
        var burnDate: Double
        var afterburnInterval: Double
        var archivedId:  String?
        var queryIds: String?
        var isRead: Bool
        var selectedSearchResultId: String? = nil
        var isHadHistoryGap: Bool = false
        var tailed: Bool = false
        var isFakeMessage: Bool = false
        
        var images: [ImageAttachment]
        var videos: [VideoAttachment]
        var locations: [LocationAttachment] = []
        var contacts: [ContactAttachment] = []
        var files:  [FileAttachment]
        var audios: [AudioAttachment]
        
        var timeMarkerText: NSAttributedString
        
        var indicator: IndicatorType
        
        var avatarUrl: String?
        var attributedAuthor: NSAttributedString? = nil
        
        static func compareContent(_ a: ChatViewController.Datasource, _ b: ChatViewController.Datasource) -> Bool {
            return a.primary == b.primary &&
                a.sentDate == b.sentDate &&
                a.isEdited == b.isEdited &&
                a.state == b.state &&
                a.groupchatAuthorId == b.groupchatAuthorId &&
                a.groupchatAuthorNickname == b.groupchatAuthorNickname &&
                a.groupchatAuthorBadge == b.groupchatAuthorBadge &&
                a.withAuthor == b.withAuthor &&
                a.withAvatar == b.withAvatar &&
                a.reservesAvatarSpace == b.reservesAvatarSpace &&
                a.isDownloaded == b.isDownloaded &&
                a.searchString == b.searchString &&
                a.burnDate == b.burnDate &&
                a.archivedId == b.archivedId &&
                a.isRead == b.isRead &&
                ChatViewController.Datasource.iconForMetadata(for: a.errorMetadata) == ChatViewController.Datasource.iconForMetadata(for: b.errorMetadata) &&
                a.messageWarningText == b.messageWarningText &&
                a.selectedSearchResultId == b.selectedSearchResultId &&
                a.queryIds == b.queryIds &&
//                a.tailed == b.tailed &&
                a.indicator == b.indicator &&
                a.editDate == b.editDate &&
                a.avatarUrl == b.avatarUrl
        }
        
        static func iconForMetadata(for meta: [String: Any]?) -> String? {
            guard let meta = meta else {
                return nil
            }
            let keys = [
                "certValid",
                "certConfirmed",
                "signed",
                "signDecrypted",
                "signValid"]
            var result = true
            keys.forEach {
                key in
                if let value = meta[key] as? Bool,
                   value == false {
                    result = false
                }
            }
            if result {
                return "shield.checkered"
            } else {
                return "exclamationmark.triangle.fill"
            }
        }
    }
        
    let datasourcePageSize: Int = ChatHistoryPagingConfiguration.pageSize
    let initialFirstFramePageSize: Int = ChatInitialFirstFrameHistoryConfiguration.pageSize
    var initialBootstrapArchiveRequestPageSize: Int {
        ChatInitialBootstrapArchivePageSizePolicy.requestPageSize(
            initialFirstFramePageSize: self.initialFirstFramePageSize,
            datasourcePageSize: self.datasourcePageSize
        )
    }
        
    var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular

    var timelineInteractionState = ChatTimelineInteractionState()
    var residentDatasetWindow: ChatDatasetWindow = .empty
    
    var chatScrollDirection: ChatDirection? = nil
    var previousContentOffsetY: CGFloat = .zero
    
    var unreadMessagePositionId: Int? = nil
    
    var messageCorner: MessageStyleConfig.MessageBubbleContainer.CodingKeys = .noTail
    var avatarVerticalPosition: String = "bottom"
    var cornerRadius: String = "16"
    
// datasource
    var timelineSession: ChatTimelineSession?
    var datasource: [Datasource] = [] {
        didSet {
            rebuildScrollResidentMetadata()
        }
    }
    var datasourceSnapshot: ChatDatasourceSnapshot = .empty
    var scrollResidentMetadata: ChatScrollResidentMetadata = .empty
    var scrollResidentMetadataGeneration: UInt64 = 0
    internal let scrollFrameOperationCounter = ChatRenderOperationCounter(
        isEnabled: _isDebugAssertConfiguration()
    )
    internal lazy var scrollFramePlanner = ChatScrollFramePlanner(
        operationCounter: scrollFrameOperationCounter
    )
    var observerRefreshGenerationCoalescer = ChatObserverRefreshGenerationCoalescer()
    var pendingOutgoingAutoScrollRequest: ChatOutgoingAutoScrollRequest? = nil
    private(set) var chatObserversRegistered: Bool = false
    internal var chatNotificationCenter: NotificationCenter = .default
    private var detachedVirtualTimelineState: ChatVirtualTimelineState = .empty
    private var detachedBoundedTimelineWindowState: ChatBoundedTimelineWindowState = .empty
    var virtualTimelineState: ChatVirtualTimelineState {
        get {
            self.timelineSession?.snapshot.state ?? self.detachedVirtualTimelineState
        }
        set {
            guard let session = self.timelineSession else {
                self.detachedVirtualTimelineState = newValue
                return
            }
            let current = session.snapshot
            _ = session.commit(
                ChatTimelineSnapshot(
                    items: current.items,
                    state: newValue,
                    loadingState: current.loadingState,
                    loadDecision: current.loadDecision,
                    anchorRestore: current.anchorRestore,
                    localOlderCandidateCount: current.localOlderCandidateCount,
                    pageSize: current.pageSize,
                    shortLocalRemainderRemoteFirst: current.shortLocalRemainderRemoteFirst
                )
            )
        }
    }
    var boundedTimelineWindowState: ChatBoundedTimelineWindowState {
        get {
            self.timelineSession.map { ChatBoundedTimelineWindowState(virtualState: $0.snapshot.state) }
                ?? self.detachedBoundedTimelineWindowState
        }
        set {
            guard self.timelineSession == nil else { return }
            self.detachedBoundedTimelineWindowState = newValue
        }
    }
    var scrollBoundaryAvailabilityCache: ChatScrollBoundaryAvailabilityCache = .empty
    var displayModelCache: ChatDisplayModelCache = ChatDisplayModelCache(capacity: 512)
    
    
    var sharedPlayerPaneldelegae: SharedAudioPlayerPanelDelegate? = nil
// rx
    var bag: DisposeBag = DisposeBag()
    
// senders
    var opponentSender: Sender = Sender(id: "", displayName: "")
    var ownerSender: Sender = Sender(id: "", displayName: "")
    
    var isInSelectionMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
// skeleton
    var showSkeletonObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    var initialHistoryAppearancePending: Bool = true
    var hasRenderedStableInitialHistory: Bool = false
    var hasCompletedInitialHistoryViewAppearance: Bool = false
    var initialLatestOpenStabilizationState: ChatInitialLatestOpenStabilizationState = .inactive
    var initialLocalFirstFramePhase: ChatLocalFirstFramePhase = .idle
    var initialLocalFirstFrameCompletions: [() -> Void] = []
    var initialLocalFirstFrameShouldPerformPendingRequest: Bool = false
    var initialFirstContentApplyCount: Int = 0
    var pendingArchiveObserverRefresh: Bool = false
    var archiveObserverRefreshWorkItem: DispatchWorkItem? = nil
    var activeChatHistoryLoadActivityKeys: Set<ChatHistoryLoadActivityKey> = []
    var activeHistoryLoadingUIActivityReason: String? = nil
    var isApplyingBootstrapAnchorWindow: Bool = false
    var pendingForceLatestOpen: Bool = false
    var pendingForceLatestOpenAnimated: Bool = false

    var showLoadingIndicator: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var accountPallete: MDCPalette = MDCPalette.blue

    var contactStatus: String? = nil
    
// gallery
    var isAccessToPhotoGranted: Bool? = nil
    var chatAttachmentFlowCoordinator: ChatAttachmentFlowCoordinating? = nil
    
// Status
    var statusTextObserver: BehaviorRelay<String> = BehaviorRelay(value: " ")
    var shouldShowNormalStatus: Bool = false
    internal var navigationAvatarBag: DisposeBag = DisposeBag()
    internal var navigationAvatarRequestKey: String? = nil
    internal var navigationAvatarGeneration = UUID()
    internal var navigationAvatarItem: UIBarButtonItem? = nil

// Pin message bar
    internal var pinnedMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var canUnpinMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var currentPinnedMessageId: String? = nil
    internal var settedPinnedMessageId: String? = nil
    internal var scrollItemIndexPath: IndexPath? = nil

// draft
    var draftMessageText: BehaviorRelay<String?> = BehaviorRelay<String?>(value: nil)
    var scheduledMessageService: ChatScheduledMessageServicing = AccountChatScheduledMessageService()
    var sendOptionsContextMenu: ContextMenu?
    private var scheduledMessagesComposerButtonToken: NotificationToken?
    
// ForwardedMessages
    var forwardedIds: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    var attachedMessagesIds: BehaviorRelay<[String]> = BehaviorRelay(value: [])
    var inTypingMode: BehaviorRelay<Bool?> = BehaviorRelay(value: nil)
    var revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    
// edit messages
    var editMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
// ChatStates
    var refreshChatStateTimer: Timer? = nil

// signature and encrypted
    var omemoDeviceListTimer: Timer? = nil
    var watchSignatureTimer: Timer? = nil
    var certificateUpdateTimer: Timer? = nil
    var contactWithSigningCertificate: Bool = false
    var blockInputFieldByTimeSignature: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    var isTimeSignatureBlockingPanelopen: Bool = false
    var isTrustedDevicesBlockingPanelopen: Bool = false
// burn
    var selectedAfterburnId: Int = 0
// panel
    var topPanelShowed: Bool = false
    var topPanelState: BehaviorRelay<TopPanelState> = BehaviorRelay(value: .none)
// search
    var searchPresentationState: ChatSearchPresentationState = .inactive
    var searchSession: ChatSearchSession = ChatSearchSession()
    var searchSessionDebounceWorkItem: DispatchWorkItem? = nil
    var searchSessionDebounceGeneration: UInt64? = nil
    var searchSessionGenerationByQueryId: [String: UInt64] = [:]
    var searchMessagesQueue: [MessageStorageItem] = []
    var searchResultPresentations: [ChatSearchResult] = []
    var searchTextObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var currentSearchQueryId: String? = nil
    var currentInChatSearchQueryContext: ChatInChatSearchQueryContext? = nil
    var searchResultNavigationState: ChatSearchResultNavigationState = .idle
    var pendingOpenMessageRequest: ChatOpenMessageRequest? = nil
    internal var backgroundPresentationMode: ChatBackgroundPresentationMode = .automatic
    internal var isNavigationTransitionActive: Bool = false
    internal var isPreparingStackedNavigationPresentation: Bool = false
    internal var shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion: Bool = false
    internal var didDeferOpenMessageRequestForNavigationTransition: Bool = false
    private var pendingNavigationTransitionWork: [() -> Void] = []
    internal var didScheduleNavigationDisappearanceCleanup: Bool = false
    internal var didRunNavigationDisappearanceCleanup: Bool = false
    var activeAnchorExecutionState: ChatAnchorExecutionState? = nil
    var activeAnchorExecutionHooks: ChatAnchorExecutionHooks? = nil
    var isExecutingOpenMessageRequest: Bool = false
    var isMessageAnchorNavigationInFlight: Bool = false
    var searchAnchorNavigationWasScrollEnabled: Bool? = nil
    var hasRequestedMentionUsersRefresh: Bool = false
    internal var pendingLocalHistoryPagingIntent: ChatLocalHistoryPagingIntent? = nil
    internal var pendingLocalHistoryPagingReleaseWhenPrepared: Bool = false
    internal var pendingPreparedLocalHistoryPage: ChatPreparedLocalHistoryPage? = nil
    internal var pendingDeferredRemoteHistoryDirection: ChatHistoryPageDirection? = nil
    internal var pendingDeferredRemoteHistoryPreparation: ChatInteractiveHistoryPagingPreparation? = nil
    internal var interactiveRemoteArchiveRequestDispatcher: ChatInteractiveRemoteArchiveRequestDispatching = AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher()
    internal let remoteHistoryQueryCoordinator = ChatRemoteHistoryQueryCoordinator()
    var interactiveHistoryPageLoadContext: ChatInteractiveHistoryPageLoadContext? = nil
    var interactiveHistoryCompletionRetryWorkItem: DispatchWorkItem? = nil
    var remoteHistoryFinishingQueryId: String? = nil
    internal var remoteHistoryEndPageDispatcherTokens: [String: MessageArchiveEndPageDispatcher.Token] = [:]
    internal var remoteHistoryFailureDispatcherTokens: [String: MessageArchiveRequestFailureDispatcher.Token] = [:]
    internal var completedRemoteHistoryEndPageQueryIds: Set<String> = []
    internal var abortedRemoteHistoryQueryIds: Set<String> = []
    internal var remoteHistoryRequestStartedAtByQueryId: [String: Date] = [:]
    internal var chatArchiveMainStallProbeWorkItem: DispatchWorkItem?
    internal var chatArchiveMainStallProbeLastBeat: Date?
    internal var chatArchiveMainStallProbeQueryId: String?
    internal var chatArchiveMainStallProbeOperation: String?
    internal var chatOpenTimingSession: ChatOpenTimingSession?
    private var chatOpenFirstFrameSignpost: ChatPerformanceSignposts.Interval?
    private var pendingSendToLocalRowSignpost: ChatPerformanceSignposts.Interval?
    internal lazy var scrollWorkScheduler = ChatScrollWorkScheduler { [weak self] request in
        self?.performCoalescedScrollWork(request)
    }
    internal lazy var collectionPrefetchCoordinator: ChatCollectionPrefetchCoordinator = {
        ChatCollectionPrefetchCoordinator(
            itemProvider: { [weak self] indexPath in
                self?.chatCollectionPrefetchItem(at: indexPath)
            },
            contextProvider: { [weak self] in
                guard let self else {
                    return .empty(
                        conversationKey: ChatCollectionPrefetchConversationKey(
                            owner: "",
                            jid: "",
                            conversationType: ClientSynchronizationManager.ConversationType.regular.rawValue
                        )
                    )
                }
                return self.chatCollectionPrefetchContext()
            },
            prefetcher: ChatCollectionContentPrefetcher(
                pageWarmupLimit: self.datasourcePageSize
            )
        )
    }()
    var initialBootstrapQueryId: String? = nil
    var isInitialBootstrapInFlight: Bool = false
    var didReceiveInitialBootstrapEndPage: Bool = false
    var initialBootstrapPageEndState: MessageArchivePageEndState? = nil
    var initialBootstrapResultCount: Int? = nil
    var initialBootstrapPersistedMessageCount: Int? = nil
    var initialBootstrapPersistedRowsForQuery: Int? = nil
    var initialBootstrapVisibleRowsForConversation: Int? = nil
    var didEnterInitialBootstrapObserverSettlePhase: Bool = false
    var didObserveInitialBootstrapPostIdleTick: Bool = false
    var initialBootstrapTimeoutWorkItem: DispatchWorkItem? = nil
    var initialBootstrapLocalHistoryFallbackWorkItem: DispatchWorkItem? = nil
    var allowsStaleLocalHistoryDuringInitialBootstrap: Bool = false
    var allowsBootstrapFailureFallback: Bool = false
    var hasConfirmedArchiveEndThisSession: Bool = false
    var hasUsedArchiveEndVerificationProbe: Bool = false
    var inSearchMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    var pendingSearchActivationRequest: ChatSearchActivationRequest? = nil
    var searchSeekDirection: ChatDirection? = nil
    var selectedSearchResultId: String? = nil
// floating date
//    var indexPathOfPinnedDate: IndexPath? = nil
//    var dateViews: [FloatDateView] = []
//    var originalFrames: [CGRect] = []
//    var pinnedDateFrame: CGRect = .zero
//    var pinnedDateIndex: Int? = nil
//    var nextPinnedDateIndex: Int? = nil
    
    internal var updateFloatingDateObserverSignal: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var hideFloatingDateObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var showFloatingDateObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var preventHidingDate: Bool = false
    
    internal var shouldShowInitialMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var canLoadDatasource: Bool = false
    internal var loadDatasourceObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    internal var historyLoadingGeneration: Int = 0
    
    internal var messagesToReadObserver: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set())
    private var detachedViewportReadBoundaryPrimary: String?
    private var detachedViewportReadBoundaryIndex: Int?
    private var detachedViewportReadBoundaryPosition: ChatTimelinePositionKey?
    
    internal let pinnedDateView: FloatDateView = {
        let view = FloatDateView(frame: .zero)
        
        return view
    }()

    internal func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    internal func beginNavigationTransitionDeferralIfNeeded() {
        guard let coordinator = self.transitionCoordinator else {
            return
        }
        self.isNavigationTransitionActive = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.completeNavigationTransitionDeferral(cancelled: context.isCancelled)
        }
    }

    private func completeNavigationTransitionDeferral(cancelled: Bool) {
        self.isNavigationTransitionActive = false
        self.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = false
        guard !cancelled else {
            self.pendingNavigationTransitionWork.removeAll()
            self.didDeferOpenMessageRequestForNavigationTransition = false
            return
        }
        self.flushPendingNavigationTransitionWork()
    }

    @discardableResult
    internal func deferUntilNavigationTransitionCompletesIfNeeded(_ work: @escaping () -> Void) -> Bool {
        guard self.isNavigationTransitionActive
                || self.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion else {
            return false
        }
        self.pendingNavigationTransitionWork.append(work)
        return true
    }

    internal func flushPendingNavigationTransitionWork() {
        let work = self.pendingNavigationTransitionWork
        self.pendingNavigationTransitionWork.removeAll()
        work.forEach { $0() }
    }

    internal var shouldDeferOpenMessageRequestsForNavigationTransition: Bool {
        ChatNavigationTransitionMutationPolicy.shouldDeferOpenMessageRequest(
            isTransitionActive: self.isNavigationTransitionActive
                || self.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion,
            hasPendingRequest: self.pendingOpenMessageRequest != nil
        )
    }

    internal func setLoadingIndicatorVisible(_ isVisible: Bool) {
        self.performOnMain {
            self.showLoadingIndicator.accept(isVisible)
        }
    }

    internal func setSkeletonVisible(_ isVisible: Bool) {
        self.performOnMain {
            self.showSkeletonObserver.accept(isVisible)
        }
    }

    internal func setFloatingDateVisible(_ isVisible: Bool) {
        self.performOnMain {
            self.showFloatingDateObserver.accept(isVisible)
        }
    }

    internal func setFloatingDateHidden(_ isHidden: Bool) {
        self.performOnMain {
            self.hideFloatingDateObserver.accept(isHidden)
        }
    }

    internal func setDatasourceLoadingEnabled(_ isEnabled: Bool) {
        self.performOnMain {
            self.canLoadDatasource = isEnabled
            self.loadDatasourceObserver.accept(isEnabled)
        }
    }

    internal func beginChatHistoryLoadActivity(reason: String) {
        let key = ChatHistoryLoadActivityKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            reason: reason
        )
        guard !self.activeChatHistoryLoadActivityKeys.contains(key) else {
            return
        }
        self.activeChatHistoryLoadActivityKeys.insert(key)
        ChatHistoryLoadActivityRegistry.begin(key)
        ChatArchiveDebugTrace.log("historyLoadActivityBegin", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("reason", reason),
            ("activeLocalCount", self.activeChatHistoryLoadActivityKeys.count)
        ])
    }

    internal func endChatHistoryLoadActivity(reason: String) {
        let key = ChatHistoryLoadActivityKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            reason: reason
        )
        guard self.activeChatHistoryLoadActivityKeys.remove(key) != nil else {
            return
        }
        ChatHistoryLoadActivityRegistry.end(key)
        ChatArchiveDebugTrace.log("historyLoadActivityEnd", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("reason", reason),
            ("activeLocalCount", self.activeChatHistoryLoadActivityKeys.count)
        ])
    }

    internal func endAllChatHistoryLoadActivities(reason cleanupReason: String) {
        let keys = self.activeChatHistoryLoadActivityKeys
        self.activeChatHistoryLoadActivityKeys.removeAll()
        self.activeHistoryLoadingUIActivityReason = nil
        keys.forEach {
            ChatHistoryLoadActivityRegistry.end($0)
        }
        if !keys.isEmpty {
            ChatArchiveDebugTrace.log("historyLoadActivityEndAll", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("reason", cleanupReason),
                ("endedCount", keys.count)
            ])
        }
    }

    private func scheduleHistoryLoadingWatchdog(generation: Int, startedAt: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatHistoryLoadingTimeoutPolicy.checkInterval) {
            guard self.historyLoadingGeneration == generation, self.timelineInteractionState.isLoading else {
                return
            }

            if self.interactiveHistoryPageLoadContext == nil {
                self.endHistoryLoadingUI(unlockPage: true)
                return
            }

            if self.tryFinishInteractiveHistoryPageLoadIfReady() {
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            guard !ChatHistoryLoadingTimeoutPolicy.shouldAbortInteractivePageLoad(elapsed: elapsed) else {
                self.abortInteractiveHistoryPageLoad()
                return
            }

            self.scheduleHistoryLoadingWatchdog(generation: generation, startedAt: startedAt)
        }
    }

    internal func beginChatOpenTimingSessionIfNeeded(
        trigger: String,
        targetBounds: CGRect? = nil
    ) {
        let now = Date()
        if let session = self.chatOpenTimingSession {
            var fields = self.chatOpenTimingBaseFields(session: session, now: now)
            fields.append(("nextTrigger", trigger))
            if let targetBounds {
                fields.append(("targetWidth", Int(targetBounds.width)))
                fields.append(("targetHeight", Int(targetBounds.height)))
            }
            ChatArchiveDebugTrace.log("chatOpenTimingContinue", fields)
            return
        }

        let session = ChatOpenTimingSession(
            id: UUID().uuidString,
            trigger: trigger,
            startedAt: now
        )
        ChatUIResponsivenessGate.shared.activate(
            reason: .chatOpen,
            duration: ChatUIResponsivenessGate.chatOpenHoldDuration
        )
        self.chatOpenTimingSession = session
        ChatPerformanceSignposts.event(.openRequest)
        self.chatOpenFirstFrameSignpost = ChatPerformanceSignposts.begin(.chatOpenToFirstFrame)
        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        if let targetBounds {
            fields.append(("targetWidth", Int(targetBounds.width)))
            fields.append(("targetHeight", Int(targetBounds.height)))
        }
        ChatArchiveDebugTrace.log("chatOpenTimingStart", fields)
    }

    internal func recordChatOpenTimingViewWillAppear() {
        self.beginChatOpenTimingSessionIfNeeded(trigger: "viewWillAppear")
        guard var session = self.chatOpenTimingSession,
              session.viewWillAppearAt == nil else {
            return
        }
        let now = Date()
        session.viewWillAppearAt = now
        self.chatOpenTimingSession = session
        ChatArchiveDebugTrace.log(
            "chatOpenTimingViewWillAppear",
            self.chatOpenTimingBaseFields(session: session, now: now)
        )
        self.recordChatOpenTimingFirstMessagesPreparedIfNeeded(
            reason: "viewWillAppearExistingDatasource",
            modeDescription: "existingDatasource",
            appliedItemCount: self.datasource.count,
            realMessageCount: self.chatOpenTimingRealMessageCount(in: self.datasource),
            applyStartedAt: nil,
            applyDurationMs: nil,
            layoutMs: nil,
            animated: false,
            invalidateLayout: false
        )
        self.scheduleChatOpenTimingFirstMessagesVisibleCheck(
            reason: "viewWillAppearExistingDatasource",
            modeDescription: "existingDatasource"
        )
    }

    internal func recordChatOpenTimingInitialDatasourceLoadScheduled(
        performPendingOpenMessageRequest: Bool
    ) {
        self.beginChatOpenTimingSessionIfNeeded(trigger: "initialDatasourceSchedule")
        guard var session = self.chatOpenTimingSession,
              session.initialDatasourceLoadScheduledAt == nil else {
            return
        }
        let now = Date()
        session.initialDatasourceLoadScheduledAt = now
        self.chatOpenTimingSession = session
        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("performPendingOpenMessageRequest", performPendingOpenMessageRequest))
        ChatArchiveDebugTrace.log("chatOpenTimingInitialDatasourceLoadScheduled", fields)
    }

    internal func recordChatOpenTimingInitialDatasourceLoadDequeued(
        performPendingOpenMessageRequest: Bool
    ) {
        guard var session = self.chatOpenTimingSession,
              session.initialDatasourceLoadDequeuedAt == nil else {
            return
        }
        let now = Date()
        session.initialDatasourceLoadDequeuedAt = now
        self.chatOpenTimingSession = session
        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("performPendingOpenMessageRequest", performPendingOpenMessageRequest))
        fields.append(("mainAsyncWaitMs", ChatOpenTimingPolicy.milliseconds(
            from: session.initialDatasourceLoadScheduledAt,
            to: now
        )))
        ChatArchiveDebugTrace.log("chatOpenTimingInitialDatasourceLoadDequeued", fields)
    }

    internal func recordChatOpenTimingInitialDatasourceLoadStarted(
        performPendingOpenMessageRequest: Bool
    ) {
        self.beginChatOpenTimingSessionIfNeeded(trigger: "initialDatasourceLoad")
        guard var session = self.chatOpenTimingSession,
              session.initialDatasourceLoadStartedAt == nil else {
            return
        }
        let now = Date()
        session.initialDatasourceLoadStartedAt = now
        self.chatOpenTimingSession = session
        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("performPendingOpenMessageRequest", performPendingOpenMessageRequest))
        ChatArchiveDebugTrace.log("chatOpenTimingInitialDatasourceLoadStart", fields)
    }

    internal func recordChatOpenTimingInitialDatasourceLoadFinished(
        bootstrapState: ChatBootstrapViewState,
        performPendingOpenMessageRequest: Bool
    ) {
        guard var session = self.chatOpenTimingSession,
              !session.didLogInitialDatasourceLoadFinish else {
            return
        }
        let now = Date()
        session.didLogInitialDatasourceLoadFinish = true
        self.chatOpenTimingSession = session
        ChatPerformanceSignposts.event(.localSnapshotReady)
        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("bootstrapState", "\(bootstrapState)"))
        fields.append(("performPendingOpenMessageRequest", performPendingOpenMessageRequest))
        fields.append(("loadDurationMs", ChatOpenTimingPolicy.milliseconds(
            from: session.initialDatasourceLoadStartedAt,
            to: now
        )))
        ChatArchiveDebugTrace.log("chatOpenTimingInitialDatasourceLoadFinish", fields)
    }

    internal func recordChatOpenTimingInitialDatasourceLoadFailed(_ error: Error) {
        guard let session = self.chatOpenTimingSession else {
            return
        }
        var fields = self.chatOpenTimingBaseFields(session: session, now: Date())
        fields.append(("error", error.localizedDescription))
        ChatArchiveDebugTrace.log("chatOpenTimingInitialDatasourceLoadFailure", fields)
    }

    internal func recordChatOpenTimingViewDidAppear() {
        self.beginChatOpenTimingSessionIfNeeded(trigger: "viewDidAppear")
        guard var session = self.chatOpenTimingSession,
              session.viewDidAppearAt == nil else {
            return
        }
        let now = Date()
        session.viewDidAppearAt = now
        self.chatOpenTimingSession = session
        ChatArchiveDebugTrace.log(
            "chatOpenTimingViewDidAppear",
            self.chatOpenTimingBaseFields(session: session, now: now)
        )
    }

    internal func recordChatOpenTimingFirstMessagesPreparedIfNeeded(
        reason: String,
        modeDescription: String,
        appliedItemCount: Int,
        realMessageCount: Int,
        applyStartedAt: Date?,
        applyDurationMs: Int?,
        layoutMs: Int?,
        animated: Bool,
        invalidateLayout: Bool
    ) {
        guard var session = self.chatOpenTimingSession,
              ChatOpenTimingPolicy.shouldLogFirstMessagesPrepared(
                hasActiveSession: true,
                didLogPrepared: session.didLogFirstMessagesPrepared,
                realMessageCount: realMessageCount,
                sectionCount: self.chatOpenTimingSectionCount
              ) else {
            return
        }

        let now = Date()
        session.didLogFirstMessagesPrepared = true
        session.firstMessagesPreparedAt = now
        session.firstDatasourceApplyStartedAt = applyStartedAt
        self.chatOpenTimingSession = session
        ChatPerformanceSignposts.event(.firstContentCommitted)

        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("reason", reason))
        fields.append(("mode", modeDescription))
        fields.append(("appliedItemCount", appliedItemCount))
        fields.append(("appliedRealMessageCount", realMessageCount))
        fields.append(("applyDurationMs", applyDurationMs))
        fields.append(("layoutMs", layoutMs))
        fields.append(("applyStartedToPreparedMs", ChatOpenTimingPolicy.milliseconds(
            from: applyStartedAt,
            to: now
        )))
        fields.append(("animated", animated))
        fields.append(("invalidateLayout", invalidateLayout))
        ChatArchiveDebugTrace.log("chatOpenTimingFirstMessagesPrepared", fields)
    }

    internal func scheduleChatOpenTimingFirstMessagesVisibleCheck(
        reason: String,
        modeDescription: String
    ) {
        guard let sessionId = self.chatOpenTimingSession?.id,
              self.chatOpenTimingSession?.didLogFirstMessagesVisible == false else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.chatOpenTimingSession?.id == sessionId else {
                return
            }
            self.recordChatOpenTimingFirstMessagesVisibleIfPossible(
                reason: reason,
                modeDescription: modeDescription
            )
        }
    }

    internal func recordChatOpenTimingFirstMessagesVisibleIfPossible(
        reason: String,
        modeDescription: String
    ) {
        guard var session = self.chatOpenTimingSession else {
            return
        }
        let realMessageCount = self.chatOpenTimingRealMessageCount(in: self.datasource)
        let sectionCount = self.chatOpenTimingSectionCount
        let visibleRealMessageCount = self.chatOpenTimingVisibleRealMessageCount
        guard ChatOpenTimingPolicy.shouldLogFirstMessagesVisible(
            hasActiveSession: true,
            didLogVisible: session.didLogFirstMessagesVisible,
            realMessageCount: realMessageCount,
            sectionCount: sectionCount,
            visibleItemCount: visibleRealMessageCount,
            isViewVisible: self.chatOpenTimingIsViewVisible
        ) else {
            return
        }

        let now = Date()
        session.didLogFirstMessagesVisible = true
        session.firstMessagesVisibleAt = now
        self.chatOpenTimingSession = session
        self.chatOpenFirstFrameSignpost?.end()
        self.chatOpenFirstFrameSignpost = nil
        ChatPerformanceSignposts.event(.firstStableFrame)

        var fields = self.chatOpenTimingBaseFields(session: session, now: now)
        fields.append(("reason", reason))
        fields.append(("mode", modeDescription))
        fields.append(("preparedToVisibleMs", ChatOpenTimingPolicy.milliseconds(
            from: session.firstMessagesPreparedAt,
            to: now
        )))
        ChatArchiveDebugTrace.log("chatOpenTimingFirstMessagesVisible", fields)
    }

    internal func finishChatOpenTimingSession(reason: String) {
        guard let session = self.chatOpenTimingSession else {
            return
        }
        var fields = self.chatOpenTimingBaseFields(session: session, now: Date())
        fields.append(("reason", reason))
        fields.append(("didLogFirstMessagesPrepared", session.didLogFirstMessagesPrepared))
        fields.append(("didLogFirstMessagesVisible", session.didLogFirstMessagesVisible))
        ChatArchiveDebugTrace.log("chatOpenTimingEnd", fields)
        self.chatOpenFirstFrameSignpost?.end()
        self.chatOpenFirstFrameSignpost = nil
        self.chatOpenTimingSession = nil
    }

    internal func beginSendToLocalRowSignpost() {
        self.pendingSendToLocalRowSignpost?.end()
        self.pendingSendToLocalRowSignpost = ChatPerformanceSignposts.begin(.sendToLocalRow)
    }

    internal func finishSendToLocalRowSignpostIfNeeded(
        request: ChatOutgoingAutoScrollRequest?,
        items: [Datasource]
    ) {
        guard ChatOutgoingAutoScrollPolicy.didInsertLocalOutgoingRow(request: request, items: items) else {
            return
        }

        self.pendingSendToLocalRowSignpost?.end()
        self.pendingSendToLocalRowSignpost = nil
    }

    internal func chatOpenTimingRealMessageCount(in items: [Datasource]) -> Int {
        items.filter { !$0.isFakeMessage }.count
    }

    private var chatOpenTimingSectionCount: Int {
        guard self.isViewLoaded else {
            return self.datasource.count
        }
        return self.messagesCollectionView.numberOfSections
    }

    private var chatOpenTimingVisibleItemCount: Int {
        guard self.isViewLoaded else {
            return 0
        }
        return self.messagesCollectionView.indexPathsForVisibleItems.count
    }

    private var chatOpenTimingVisibleRealMessageCount: Int {
        guard self.isViewLoaded else {
            return 0
        }
        return self.messagesCollectionView.indexPathsForVisibleItems.filter {
            self.datasourceItem(atSection: $0.section)?.isFakeMessage == false
        }.count
    }

    private var chatOpenTimingIsViewVisible: Bool {
        self.isViewLoaded &&
            self.view.window != nil &&
            self.hasCompletedInitialHistoryViewAppearance
    }

    private func chatOpenTimingBaseFields(
        session: ChatOpenTimingSession,
        now: Date
    ) -> [(String, Any?)] {
        [
            ("sessionId", session.id),
            ("trigger", session.trigger),
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("sinceStartMs", ChatOpenTimingPolicy.milliseconds(from: session.startedAt, to: now)),
            ("sinceViewWillAppearMs", ChatOpenTimingPolicy.milliseconds(from: session.viewWillAppearAt, to: now)),
            ("sinceInitialLoadScheduledMs", ChatOpenTimingPolicy.milliseconds(from: session.initialDatasourceLoadScheduledAt, to: now)),
            ("sinceInitialLoadDequeuedMs", ChatOpenTimingPolicy.milliseconds(from: session.initialDatasourceLoadDequeuedAt, to: now)),
            ("sinceInitialLoadStartedMs", ChatOpenTimingPolicy.milliseconds(from: session.initialDatasourceLoadStartedAt, to: now)),
            ("sinceViewDidAppearMs", ChatOpenTimingPolicy.milliseconds(from: session.viewDidAppearAt, to: now)),
            ("sinceFirstMessagesPreparedMs", ChatOpenTimingPolicy.milliseconds(from: session.firstMessagesPreparedAt, to: now)),
            ("datasourceCount", self.datasource.count),
            ("realMessageCount", self.chatOpenTimingRealMessageCount(in: self.datasource)),
            ("sectionCount", self.chatOpenTimingSectionCount),
            ("visibleItemCount", self.chatOpenTimingVisibleItemCount),
            ("visibleRealMessageCount", self.chatOpenTimingVisibleRealMessageCount),
            ("contentHeight", self.isViewLoaded ? Int(self.messagesCollectionView.contentSize.height) : nil),
            ("boundsHeight", self.isViewLoaded ? Int(self.messagesCollectionView.bounds.height) : nil),
            ("viewWidth", self.isViewLoaded ? Int(self.view.bounds.width) : nil),
            ("viewHeight", self.isViewLoaded ? Int(self.view.bounds.height) : nil),
            ("isViewLoaded", self.isViewLoaded),
            ("isViewVisible", self.chatOpenTimingIsViewVisible),
            ("isShowingBootstrapPlaceholder", self.isShowingBootstrapPlaceholder),
            ("hasPendingOpenMessageRequest", self.pendingOpenMessageRequest != nil),
            ("hasActiveAnchorExecution", self.activeAnchorExecutionState != nil),
            ("isNavigationTransitionActive", self.isNavigationTransitionActive),
            ("isPreparingStackedNavigationPresentation", self.isPreparingStackedNavigationPresentation)
        ]
    }

    private func startChatArchiveMainStallProbe(queryId: String?, operation: String) {
        self.chatArchiveMainStallProbeWorkItem?.cancel()
        self.chatArchiveMainStallProbeQueryId = queryId
        self.chatArchiveMainStallProbeOperation = operation
        self.chatArchiveMainStallProbeLastBeat = Date()
        ChatArchiveDebugTrace.log("mainStallProbeStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId ?? "-"),
            ("operation", operation)
        ])
        self.scheduleChatArchiveMainStallProbe(queryId: queryId, operation: operation)
    }

    private func scheduleChatArchiveMainStallProbe(queryId: String?, operation: String) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.timelineInteractionState.isLoading,
                  self.chatArchiveMainStallProbeQueryId == queryId,
                  self.chatArchiveMainStallProbeOperation == operation else {
                return
            }

            let now = Date()
            if let lastBeat = self.chatArchiveMainStallProbeLastBeat {
                let gapMs = ChatArchiveDebugTrace.milliseconds(since: lastBeat)
                if gapMs > 1000 {
                    ChatArchiveDebugTrace.log("mainStallProbeGap", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("queryId", queryId ?? "-"),
                        ("operation", operation),
                        ("gapMs", gapMs),
                        ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                        ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                        ("datasourceCount", self.datasource.count),
                        ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count)
                    ])
                }
            }
            self.chatArchiveMainStallProbeLastBeat = now
            self.scheduleChatArchiveMainStallProbe(queryId: queryId, operation: operation)
        }
        self.chatArchiveMainStallProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func stopChatArchiveMainStallProbe(reason: String) {
        guard self.chatArchiveMainStallProbeWorkItem != nil ||
              self.chatArchiveMainStallProbeQueryId != nil else {
            return
        }
        self.chatArchiveMainStallProbeWorkItem?.cancel()
        ChatArchiveDebugTrace.log("mainStallProbeStop", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", self.chatArchiveMainStallProbeQueryId ?? "-"),
            ("operation", self.chatArchiveMainStallProbeOperation ?? "-"),
            ("reason", reason)
        ])
        self.chatArchiveMainStallProbeWorkItem = nil
        self.chatArchiveMainStallProbeLastBeat = nil
        self.chatArchiveMainStallProbeQueryId = nil
        self.chatArchiveMainStallProbeOperation = nil
    }

    internal func beginHistoryLoadingUI(queryId: String? = nil) {
        self.performOnMain {
            self.historyLoadingGeneration += 1
            let generation = self.historyLoadingGeneration
            let startedAt = Date()
            if let activeHistoryLoadingUIActivityReason = self.activeHistoryLoadingUIActivityReason {
                self.endChatHistoryLoadActivity(reason: activeHistoryLoadingUIActivityReason)
            }
            let activityReason = queryId.map { "remote:\($0)" } ?? "remote:generation:\(generation)"
            self.activeHistoryLoadingUIActivityReason = activityReason
            self.beginChatHistoryLoadActivity(reason: activityReason)

            self.timelineInteractionState.isLoading = true
            self.setLoadingIndicatorVisible(true)
            self.setArchiveLoading(true)
            if ChatHistoryLoadingOverlayPolicy.shouldDisableCollectionInteraction {
                self.messagesCollectionView.isUserInteractionEnabled = false
            }

            self.startChatArchiveMainStallProbe(queryId: queryId, operation: "remoteHistoryLoading")
            self.scheduleHistoryLoadingWatchdog(generation: generation, startedAt: startedAt)
        }
    }

    internal func endHistoryLoadingUI(unlockPage: Bool) {
        self.performOnMain {
            self.stopChatArchiveMainStallProbe(reason: "endHistoryLoadingUI")
            if let activeHistoryLoadingUIActivityReason = self.activeHistoryLoadingUIActivityReason {
                self.endChatHistoryLoadActivity(reason: activeHistoryLoadingUIActivityReason)
                self.activeHistoryLoadingUIActivityReason = nil
            }
            self.timelineInteractionState.isLoading = false
            self.setLoadingIndicatorVisible(false)
            self.setArchiveLoading(false)
            if ChatHistoryLoadingOverlayPolicy.shouldDisableCollectionInteraction {
                self.messagesCollectionView.isUserInteractionEnabled = true
            }
            self.setDatasourceLoadingEnabled(true)
            if unlockPage {
                self.timelineInteractionState.unlock()
            }
            self.flushPendingArchiveObserverRefreshIfPossible(reason: "historyLoadingEnded")
        }
    }

    internal func setStatusText(_ text: String) {
        self.performOnMain {
            self.statusTextObserver.accept(text)
        }
    }

    internal func setTopPanelState(_ state: TopPanelState) {
        self.performOnMain {
            self.topPanelState.accept(state)
        }
    }

    internal func chatSubscriptionPresentation(
        rosterItem: RosterStorageItem?,
        realm: Realm
    ) -> ChatSubscriptionPresentation {
        let isBlocked = realm.object(
            ofType: BlockStorageItem.self,
            forPrimaryKey: [self.jid, self.owner].prp()
        ) != nil
        return ChatSubscriptionPresentationPolicy.presentation(
            rosterItem: rosterItem,
            conversationType: self.conversationType,
            isServerJID: XMPPJID(string: self.jid)?.isServer ?? false,
            isSavedChat: self.conversationType == .saved,
            isBlocked: isBlocked
        )
    }

    internal func applyChatSubscriptionPresentation(_ presentation: ChatSubscriptionPresentation) {
        switch presentation.statusMode {
        case .unchanged:
            break
        case .fixed(let status):
            self.shouldShowNormalStatus = false
            self.contactStatus = status.localizedString
            self.updateStatusText()
        case .normalPresence:
            self.shouldShowNormalStatus = true
        }

        switch presentation.topPanelKind {
        case .none:
            if self.topPanelState.value.isSubscriptionPanel {
                self.setTopPanelState(.none)
            }
        case .addContact, .contactRequest:
            self.setTopPanelState(.addContact)
        case .requestSubscription:
            self.setTopPanelState(.requestSubscribtion)
        case .allowSubscription:
            self.setTopPanelState(.allowSubscribtion)
        }
    }

    internal func connectionAwareStatusText(fallbackStatus: String?) -> String {
        let account = AccountManager.shared.find(for: self.owner)
        return ChatConnectionStatusTextPolicy.text(
            actionText: CommonChatStatesManager.shared.actionText(for: self.jid, owner: self.owner),
            isAccountConnecting: account != nil && AccountManager.shared.connectingUsers.value.contains(self.owner),
            sendReadinessSnapshot: account?.sendReadiness.snapshot,
            isNetworkPathSatisfied: account?.connectionResilience.healthSnapshot.isNetworkPathSatisfied,
            fallbackStatus: fallbackStatus
        )
    }

    internal func applyNormalPresenceStatus(realm: Realm) {
        let results = realm
            .objects(ResourceStorageItem.self)
            .filter("owner == %@ AND jid == %@", self.owner, self.jid)
            .sorted(by: [
                SortDescriptor(keyPath: "timestamp", ascending: false),
                SortDescriptor(keyPath: "priority", ascending: false)
            ])
        let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
        let status = (results.first?.statusMessage.isEmpty ?? true)
            ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
            : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
        self.titleLabel.attributedText = self.updateTitle()
        let statusStr = self.connectionAwareStatusText(fallbackStatus: status)
        if self.statusLabel.text == " " {
            self.statusLabel.text = statusStr
        }
        if self.shouldShowNormalStatus {
            self.setStatusText(statusStr)
            self.contactStatus = status
            self.statusLabel.layoutIfNeeded()
        }
        self.titleLabel.sizeToFit()
        self.titleLabel.layoutIfNeeded()
    }

    internal func setShouldShowInitialMessage(_ shouldShow: Bool) {
        self.performOnMain {
            self.shouldShowInitialMessage.accept(shouldShow)
        }
    }
    
    internal lazy var skeletonMessages: [NSAttributedString] = {
        return (0..<30).compactMap {
            _ in
            return NSAttributedString(string: Lorem.words(Int.random(in: (18..<84))))
        }
    }()
    internal var activeHistoryBoundaryPlaceholder: ChatHistoryBoundaryPlaceholderPosition?
    
    internal let updateQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.chat.updater",
            qos: .userInteractive,
            attributes: [],// [.concurrent],
            autoreleaseFrequency: .never,
            target: nil
        )
        return queue
    }()

    internal let datasetMappingQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.chat.dataset.mapping",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        return queue
    }()
    internal let remoteHistoryApplyQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.chat.remote-history.apply",
            qos: .userInteractive,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        return queue
    }()
    internal var datasetMappingGeneration: Int = 0
    
    let sectionsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        
        return formatter
    }()
    
    let messageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "HH:mm"
        
        return formatter
    }()

    internal let initialMessageOverlayView: InitialMessageOverlayView = {
        let view = InitialMessageOverlayView(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    var titleButton: UIButton = {
        let button = UIButton(frame: .zero)

        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            configuration.background.backgroundColor = .clear
            configuration.baseBackgroundColor = .clear
            configuration.baseForegroundColor = .label
            button.configuration = configuration
        }
        
        return button
    }()
    
    var titleStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        
        return stack
    }()
    
    var titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body).bold()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()
    
    var statusLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .darkText
        }
        
        return label
    }()
    
//    var bottomSearchBar: SearchBar = {
//        let bar = SearchBar()
//        
//        bar.barStyle = .default
////        bar.backgroundImage = nil
//        
//        return bar
//    }()
    
//    let recordingPanel: RecordingPanel = {
//        let view = RecordingPanel(frame: .zero)
//        
//        view.isHidden = true
//        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
//        
//        return view
//    }()
    
    let cancelSelectionBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .cancel, target: nil, action: nil)
        
        return button
    }()
    
    
    let deleteSelectionBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Delete", style: .done, target: nil, action: nil)
        
        return button
    }()
    
    let selectionCountLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        
        return label
    }()
    
    internal lazy var searchInputBar: ChatSearchInputBarView = {
        let view = ChatSearchInputBarView()
        view.onSubmit = { [weak self] text in
            self?.submitSearchTextFromSearchInput(text)
        }
        view.onTextChanged = { [weak self] text in
            self?.searchBar.text = text
            self?.searchTextObserver.accept(text)
        }
        view.onHeightChanged = { [weak self] height in
            self?.updateSearchInputOverlayHeight(height)
        }
        return view
    }()
    internal var searchInputBarHeightConstraint: NSLayoutConstraint?
    internal var searchInputBarTopConstraint: NSLayoutConstraint?
    internal var searchInputBarConstraints: [NSLayoutConstraint] = []

    internal var searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
        return bar
    }()
    
    internal let chatViewLoadingOverlay: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        view.isUserInteractionEnabled = ChatHistoryLoadingOverlayPolicy.isOverlayUserInteractionEnabled
        
        let indicator = UIActivityIndicatorView(style: .large)
        
        indicator.startAnimating()
        
        let indicatorBackground = UIView(frame: CGRect(square: 128))
        indicatorBackground.layer.cornerRadius = 24
        indicatorBackground.layer.masksToBounds = true
        indicatorBackground.addSubview(indicator)
        indicator.centerInSuperview()
        view.addSubview(indicatorBackground)
        
        indicatorBackground.centerInSuperview()
        indicatorBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: indicatorBackground.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: indicatorBackground.centerYAnchor),
            indicatorBackground.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            indicatorBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicatorBackground.widthAnchor.constraint(equalToConstant: 128),
            indicatorBackground.heightAnchor.constraint(equalToConstant: 128),
        ])
        
        view.isHidden = true
        
        return view
    }()
    
    internal var shouldShowScrollDownButton: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var shouldShowUnreadMentionsNavigator: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var contentOffsetObserver: BehaviorRelay<CGFloat> = BehaviorRelay(value: 0)
    internal var unreadMentionItems: [ChatUnreadMentionItem] = []
    internal var unreadMentionsState: ChatUnreadMentionsState = .empty
    internal var isUnreadMentionNavigationInFlight: Bool = false
    internal var pendingUnreadMentionNavigationRequest: ChatUnreadMentionNavigationRequest? = nil
    internal var currentUnreadMentionNotificationPrimary: String? = nil
    internal var visibleUnreadMentionReconciliationWorkItem: DispatchWorkItem? = nil
    
    internal var currentPlayingView: InlineAudiosGridView.AudioView? = nil
    internal var voiceMessageStateObserverToken: UUID? = nil

    internal enum FloatingControlsLayoutPolicy {
        static let trailingInset: CGFloat = 4
        static let bottomInset: CGFloat = 14
        static let verticalSpacing: CGFloat = NativeGlassBarStyle.interItemSpacing
        static let scrollButtonSize: CGFloat = NativeGlassBarStyle.buttonSize

        static func lowerSlotY(
            viewHeight: CGFloat,
            controlHeight: CGFloat,
            inputHeight: CGFloat
        ) -> CGFloat {
            viewHeight - controlHeight - bottomInset - inputHeight
        }

        static func trailingX(
            viewWidth: CGFloat,
            controlWidth: CGFloat
        ) -> CGFloat {
            viewWidth - controlWidth - trailingInset
        }

        static func scrollButtonVisibleFrame(sendButtonFrame: CGRect) -> CGRect? {
            guard isValidSendButtonFrame(sendButtonFrame) else {
                return nil
            }
            let size = CGSize(square: scrollButtonSize)
            return CGRect(
                origin: CGPoint(
                    x: sendButtonFrame.midX - scrollButtonSize / 2,
                    y: sendButtonFrame.minY - verticalSpacing - scrollButtonSize
                ),
                size: size
            )
        }

        static func scrollButtonHiddenFrame(
            sendButtonFrame: CGRect,
            viewHeight: CGFloat
        ) -> CGRect? {
            guard let visibleFrame = scrollButtonVisibleFrame(sendButtonFrame: sendButtonFrame),
                  viewHeight.isFinite,
                  viewHeight > 0 else {
                return nil
            }
            return CGRect(
                origin: CGPoint(
                    x: visibleFrame.minX,
                    y: viewHeight + scrollButtonSize + 24
                ),
                size: visibleFrame.size
            )
        }

        static func mentionIndicatorOriginY(
            viewHeight: CGFloat,
            mentionHeight: CGFloat,
            inputHeight: CGFloat,
            scrollButtonFrame: CGRect?,
            showsScrollDownButton: Bool
        ) -> CGFloat {
            let lowerSlot = lowerSlotY(
                viewHeight: viewHeight,
                controlHeight: mentionHeight,
                inputHeight: inputHeight
            )
            guard showsScrollDownButton, let scrollButtonFrame else {
                return lowerSlot
            }
            return scrollButtonFrame.minY - verticalSpacing - mentionHeight
        }

        static func mentionIndicatorFrame(
            sendButtonFrame: CGRect,
            viewHeight: CGFloat,
            mentionSize: CGSize,
            inputHeight: CGFloat,
            scrollButtonFrame: CGRect?,
            showsScrollDownButton: Bool
        ) -> CGRect? {
            guard isValidSendButtonFrame(sendButtonFrame),
                  isValidControlSize(mentionSize),
                  viewHeight.isFinite,
                  viewHeight > 0,
                  inputHeight.isFinite,
                  inputHeight >= 0 else {
                return nil
            }

            let originY = mentionIndicatorOriginY(
                viewHeight: viewHeight,
                mentionHeight: mentionSize.height,
                inputHeight: inputHeight,
                scrollButtonFrame: scrollButtonFrame,
                showsScrollDownButton: showsScrollDownButton
            )
            guard originY.isFinite else {
                return nil
            }

            return CGRect(
                origin: CGPoint(
                    x: sendButtonFrame.midX - mentionSize.width / 2,
                    y: originY
                ),
                size: mentionSize
            )
        }

        private static func isValidSendButtonFrame(_ frame: CGRect) -> Bool {
            frame.width > 0 &&
            frame.height > 0 &&
            frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite
        }

        private static func isValidControlSize(_ size: CGSize) -> Bool {
            size.width > 0 &&
            size.height > 0 &&
            size.width.isFinite &&
            size.height.isFinite
        }
    }

    internal enum ScrollDownButtonStartupVisibilityPolicy {
        static let suppressionInterval: TimeInterval = 2.0

        static func isSuppressed(now: Date = Date(), until suppressedUntil: Date?) -> Bool {
            guard let suppressedUntil else {
                return false
            }
            return now < suppressedUntil
        }
    }
    
    internal let scrollDownButton: UIButton = {
        let button = UIButton(frame: CGRect(square: NativeGlassBarStyle.buttonSize))
        button.setImage(imageLiteral("chevron.down", dimension: NativeGlassBarStyle.iconSize), for: .normal)
        button.tintColor = .secondaryLabel
        NativeGlassBarStyle.applyDetachedIconButtonStyle(to: button)
        button.isHidden = true
        button.isUserInteractionEnabled = false
        
        return button
    }()
    private var hasPositionedScrollDownButton = false
    private var scrollDownButtonVisibilitySuppressedUntil: Date? = nil
    private var scrollDownButtonVisibilitySuppressionWorkItem: DispatchWorkItem? = nil

    internal let unreadMentionsNavigatorView: UnreadMentionsNavigatorView = {
        let view = UnreadMentionsNavigatorView(frame: .zero)
        view.isHidden = true
        return view
    }()
    
    internal let dateListContainerView: UIView = {
        let view = UIView()
        
        view.isUserInteractionEnabled = false
        
        return view
    }()
    
//    internal let navbarOverlayView: UIView = {
//        let view = UIView()
//        
//        view.backgroundColor = .systemBackground
//        view.isUserInteractionEnabled = false
//        
//        return view
//    }()
    
    internal var xabberInputView: ModernXabberInputView!
    internal var xabberInputViewBottomConstraint: NSLayoutConstraint?
    internal var xabberInputViewKeyboardTopConstraint: NSLayoutConstraint?
    internal var lastAppliedChatKeyboardLayoutSignature: ChatKeyboardLayoutUpdateSignature?
    
    internal var shouldRequestChatInfo: Bool = false
    
    open var lastChatsDisplayDelegate: LastChatsDisplayDelegate? = nil
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil

    internal let floatingBubblesStackView: UIStackView = {
        let stack = UIStackView(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = ChatFloatingHeaderLayoutPolicy.floatingStackTopSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    internal let topPanelBubbleView = ChatFloatingGlassBubbleView(contentHeight: 44)
    internal let pinnedMessageBubbleView = ChatFloatingGlassBubbleView(contentHeight: ChatPinnedMessageBarHeightPolicy.minimumHeight)
    internal var pinnedMessagePanelView: ChatPinnedMessagePanelView? = nil
    internal var sharedAudioPlayerHeightConstraint: NSLayoutConstraint? = nil
    internal var floatingBubblesHeight: CGFloat = 0
    
    internal let sharedAudioPlayerPanel: AudioPlayerBarView? = {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return nil
        }
        let view = AudioPlayerBarView(frame: .zero)
        view.isHidden = true
        
        return view
    }()
    
    @objc
    internal func showInfo() {
        let vc: BaseViewController
        if self.conversationType == .group {
            vc = GroupchatInfoViewController()
            (vc as! GroupchatInfoViewController).footerView.chatsDelegate = self
            (vc as! GroupchatInfoViewController).chatStateDelegate = self
        } else {
            vc = ContactInfoViewController()
            (vc as! ContactInfoViewController).footerView.chatsDelegate = self
            (vc as! ContactInfoViewController).conversationType = self.conversationType
            (vc as! ContactInfoViewController).chatStateDelegate = self
        }
        vc.owner = self.owner
        vc.jid = self.jid
        (vc as? ContactInfoViewController)?.leftMenuDelegate = self.leftMenuDelegate
        (vc as? GroupchatInfoViewController)?.leftMenuDelegate = self.leftMenuDelegate
        showModal(vc, parent: self)
        self.removeObservers()
    }
    
    @objc
    internal func onScrollDownChatButtonTouchUpInside(_ sender: UIButton) {
        self.requestScrollDownButtonHide(animated: true)

        switch self.scrollDownButtonTarget() {
        case .unreadBoundary(let boundaryId):
            let request = self.makeScrollDownUnreadBoundaryRequest(boundaryId: boundaryId)
            self.queueOpenMessageRequest(
                request,
                hooks: ChatAnchorExecutionHooks(
                    direction: .down,
                    animatedScroll: true,
                    onFailed: { [weak self] in
                        self?.scrollToLatestFromScrollDownButton(animated: true)
                    },
                    onPositioned: { [weak self] in
                        self?.requestScrollDownButtonHide(animated: true)
                    }
                )
            )
        case .latest:
            self.scrollToLatestFromScrollDownButton(animated: true)
        }
    }

    internal func suppressScrollDownButtonVisibilityAfterAppearance() {
        self.scrollDownButtonVisibilitySuppressionWorkItem?.cancel()

        let suppressedUntil = Date().addingTimeInterval(ScrollDownButtonStartupVisibilityPolicy.suppressionInterval)
        self.scrollDownButtonVisibilitySuppressedUntil = suppressedUntil
        self.scrollDownButton.isHidden = true
        self.scrollDownButton.isUserInteractionEnabled = false
        self.updateScrollDownButtonFrame(animated: false)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.scrollDownButtonVisibilitySuppressedUntil = nil
            self.scrollDownButtonVisibilitySuppressionWorkItem = nil
            self.updateScrollDownButtonFrame(animated: true)
        }
        self.scrollDownButtonVisibilitySuppressionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScrollDownButtonStartupVisibilityPolicy.suppressionInterval,
            execute: workItem
        )
    }

    internal func floatingControlsInputHeight() -> CGFloat {
        var inputHeight: CGFloat = ModernXabberInputView.defaultBarHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        if self.xabberInputView?.isRecordingLockOverlayVisible == true {
            inputHeight += 52
        }

        return inputHeight
    }

    internal func updateScrollDownButtonAppearance() {
        let image = imageLiteral("chevron.down", dimension: NativeGlassBarStyle.iconSize)
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: self.scrollDownButton,
            tintColor: self.accountPallete.tint600,
            image: image
        )
    }

    internal func scrollDownButtonTrailingActionFrameInView(ensureLayout: Bool = true) -> CGRect? {
        guard self.isViewLoaded,
              let xabberInputView = self.xabberInputView,
              xabberInputView.superview != nil else {
            return nil
        }

        if ensureLayout {
            xabberInputView.layoutIfNeeded()
        }
        guard let frame = xabberInputView.trailingActionFrame(in: self.view) else {
            return nil
        }
        return FloatingControlsLayoutPolicy.scrollButtonVisibleFrame(sendButtonFrame: frame) == nil ? nil : frame
    }

    internal func scrollDownButtonVisibleFrame() -> CGRect? {
        self.scrollDownButtonVisibleFrame(
            trailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func scrollDownButtonVisibleFrame(trailingActionFrame: CGRect?) -> CGRect? {
        guard let sendButtonFrame = trailingActionFrame else {
            return nil
        }
        return FloatingControlsLayoutPolicy.scrollButtonVisibleFrame(sendButtonFrame: sendButtonFrame)
    }

    internal func scrollDownButtonHiddenFrame() -> CGRect? {
        self.scrollDownButtonHiddenFrame(
            trailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func scrollDownButtonHiddenFrame(trailingActionFrame: CGRect?) -> CGRect? {
        guard let sendButtonFrame = trailingActionFrame else {
            return nil
        }
        return FloatingControlsLayoutPolicy.scrollButtonHiddenFrame(
            sendButtonFrame: sendButtonFrame,
            viewHeight: self.view.frame.height
        )
    }

    internal func updateScrollDownButtonFrame(animated: Bool) {
        self.updateScrollDownButtonFrame(
            animated: animated,
            resolvedTrailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func updateScrollDownButtonFrame(
        animated: Bool,
        resolvedTrailingActionFrame: CGRect?
    ) {
        let requestedShowButton = ChatUnreadMentionFloatingControlPolicy.shouldShowScrollDownButton(
            requested: self.shouldShowScrollDownButton.value,
            navigatorVisible: self.shouldShowUnreadMentionsNavigator.value
        )
        let isVisibilitySuppressed = ScrollDownButtonStartupVisibilityPolicy.isSuppressed(
            until: self.scrollDownButtonVisibilitySuppressedUntil
        )
        let shouldShowButton = requestedShowButton && !isVisibilitySuppressed

        guard self.view.bounds.width > 0, self.view.bounds.height > 0 else {
            self.hasPositionedScrollDownButton = false
            self.scrollDownButton.isHidden = true
            self.scrollDownButton.isUserInteractionEnabled = false
            return
        }

        guard let visibleFrame = self.scrollDownButtonVisibleFrame(
            trailingActionFrame: resolvedTrailingActionFrame
        ), let hiddenFrame = self.scrollDownButtonHiddenFrame(
            trailingActionFrame: resolvedTrailingActionFrame
        ) else {
            self.hasPositionedScrollDownButton = false
            self.scrollDownButton.isHidden = true
            self.scrollDownButton.isUserInteractionEnabled = false
            return
        }

        let frame = shouldShowButton ? visibleFrame : hiddenFrame
        let shouldAnimate = self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: animated) &&
            self.hasPositionedScrollDownButton &&
            !isVisibilitySuppressed
        let updates = {
            self.scrollDownButton.frame = frame
        }

        self.hasPositionedScrollDownButton = true
        self.scrollDownButton.isUserInteractionEnabled = shouldShowButton

        if shouldAnimate {
            self.scrollDownButton.isHidden = false
            UIView.animate(withDuration: 0.33, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.8, options: [.curveEaseIn]) {
                updates()
            } completion: { _ in
                self.scrollDownButton.isHidden = !shouldShowButton
            }
        } else {
            updates()
            self.scrollDownButton.isHidden = !shouldShowButton
        }
    }

    internal func requestScrollDownButtonHide(animated: Bool) {
        if self.shouldShowScrollDownButton.value {
            self.shouldShowScrollDownButton.accept(false)
        } else {
            self.updateScrollDownButtonFrame(animated: animated)
        }
    }

    internal func scrollDownButtonTarget() -> ChatScrollDownTargetPolicy.Target {
        ChatOpenMessageRequestHandlingPolicy.effectiveScrollDownTarget(
            ChatScrollDownTargetPolicy.target(
                chat: self.scrollDownButtonChatState(),
                visibleMessages: self.scrollDownButtonVisibleMessages()
            )
        )
    }

    internal func scrollDownButtonChatState() -> ChatScrollDownTargetPolicy.ChatState {
        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
            guard let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) else {
                return ChatScrollDownTargetPolicy.ChatState(
                    unread: 0,
                    syncUnreadCount: 0,
                    syncUnreadAfterId: nil,
                    lastReadId: nil
                )
            }
            return ChatScrollDownTargetPolicy.ChatState(
                unread: chat.unread,
                syncUnreadCount: chat.syncUnreadCount,
                syncUnreadAfterId: chat.syncUnreadAfterId,
                lastReadId: chat.lastReadId
            )
        } catch {
            DDLogDebug("ChatViewController.scrollDownButtonChatState: \(error.localizedDescription)")
            return ChatScrollDownTargetPolicy.ChatState(
                unread: 0,
                syncUnreadCount: 0,
                syncUnreadAfterId: nil,
                lastReadId: nil
            )
        }
    }

    internal func scrollDownButtonVisibleMessages() -> [ChatScrollDownTargetPolicy.VisibleMessage] {
        self.messagesCollectionView.indexPathsForVisibleItems
            .sorted {
                if $0.section != $1.section {
                    return $0.section < $1.section
                }
                return $0.item < $1.item
            }
            .compactMap { indexPath in
                guard let item = self.datasourceItem(at: indexPath) else { return nil }
                return ChatScrollDownTargetPolicy.VisibleMessage(
                    archivedId: item.archivedId,
                    rowKind: ChatVisiblePositionPolicy.rowKind(for: item.kind),
                    isFakeMessage: item.isFakeMessage
                )
            }
    }

    internal func makeScrollDownUnreadBoundaryRequest(boundaryId: String) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: boundaryId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: ChatInitialPositionPolicy.archiveDate(from: boundaryId) ?? Date()
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .initialUnreadBoundary,
            targetResolution: .firstIncomingAfterBoundary(boundaryId)
        )
    }

    internal var isInitialLatestOpenStabilizing: Bool {
        self.initialLatestOpenStabilizationState != .inactive
    }

    internal func beginInitialLatestOpenStabilizationIfNeeded() {
        guard ChatInitialLatestOpenStabilizationPolicy.shouldStart(
            forceLatestOpen: ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen()
        ) else {
            return
        }

        if self.initialLatestOpenStabilizationState == .inactive {
            self.initialLatestOpenStabilizationState = .active
        }
    }

    internal func markInitialLatestOpenBottomAlignedIfNeeded() {
        self.initialLatestOpenStabilizationState = ChatInitialLatestOpenStabilizationPolicy.stateAfterBottomAlignment(
            current: self.initialLatestOpenStabilizationState,
            hasRealMessages: self.datasource.contains { !$0.isFakeMessage }
        )
        self.completeInitialLatestOpenStabilizationIfPossible()
    }

    internal func completeInitialLatestOpenStabilizationIfPossible() {
        guard ChatInitialLatestOpenStabilizationPolicy.shouldComplete(
            state: self.initialLatestOpenStabilizationState,
            hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance
        ) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  ChatInitialLatestOpenStabilizationPolicy.shouldComplete(
                    state: self.initialLatestOpenStabilizationState,
                    hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance
                  ) else {
                return
            }

            self.initialLatestOpenStabilizationState = .inactive
        }
    }

    internal func newestRealDatasourcePrimary() -> String? {
        self.datasource.last(where: { !$0.isFakeMessage })?.primary
    }

    internal func newestLocalMessagePrimaryForLatestOpen() -> String? {
        self.timelineSession?.latestMessage()?.primary
    }

    internal func shouldSkipInitialLatestForcedContentRender(forceRender: Bool) -> Bool {
        ChatInitialLatestOpenStabilizationPolicy.shouldSkipForcedContentRender(
            state: self.initialLatestOpenStabilizationState,
            forceRender: forceRender,
            hasRealDatasource: self.datasource.contains { !$0.isFakeMessage },
            newestLocalPrimary: self.newestLocalMessagePrimaryForLatestOpen(),
            datasourceNewestPrimary: self.newestRealDatasourcePrimary()
        )
    }

    internal func initialLatestObserverRefreshAction(baseShouldOpenLatest: Bool) -> ChatInitialLatestOpenStabilizationPolicy.ObserverRefreshAction {
        ChatInitialLatestOpenStabilizationPolicy.observerRefreshAction(
            state: self.initialLatestOpenStabilizationState,
            baseShouldOpenLatest: baseShouldOpenLatest,
            newestLocalPrimary: self.newestLocalMessagePrimaryForLatestOpen(),
            datasourceNewestPrimary: self.newestRealDatasourcePrimary()
        )
    }

    internal func shouldAnimateDuringInitialLatestStabilization(requestedAnimated: Bool) -> Bool {
        ChatInitialLatestOpenStabilizationPolicy.shouldAnimateAuxiliaryUpdate(
            state: self.initialLatestOpenStabilizationState,
            requestedAnimated: requestedAnimated
        )
    }

    internal func scrollToLatestTimeline(animated: Bool) {
        let isStabilizing = self.isInitialLatestOpenStabilizing
        self.mapAndApplyTimelineLatest(
            mode: .windowReload(),
            animated: false,
            invalidateLayout: true,
            limit: isStabilizing ? self.initialFirstFramePageSize : nil,
            suppressDefaultBottomScroll: isStabilizing,
            forceBottomAlignmentTarget: isStabilizing ? .newestRealMessage : nil,
            completion: { [weak self] in
                guard let self else {
                    return
                }
                self.finishLatestBottomScroll(
                    animated: isStabilizing ? false : animated,
                    consumePendingForceLatest: true
                )
            },
            cancelledCompletion: { [weak self] in
                guard let self else {
                    return
                }
                self.finishLatestBottomScroll(
                    animated: isStabilizing ? false : animated,
                    consumePendingForceLatest: true
                )
            }
        )
    }

    internal func requestForceLatestOpen(animated: Bool = false) {
        guard ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() else {
            return
        }

        self.beginInitialLatestOpenStabilizationIfNeeded()
        self.clearSuppressedOpenMessageRequestState()
        self.pendingForceLatestOpen = true
        self.pendingForceLatestOpenAnimated = self.pendingForceLatestOpenAnimated || animated

        guard self.isViewLoaded else {
            return
        }

        self.applyForcedLatestOpenIfPossible(reason: "requestForceLatestOpen")
    }

    internal func applyForcedLatestOpenIfPossible(reason: String) {
        guard ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen(),
              self.pendingForceLatestOpen,
              self.isViewLoaded else {
            return
        }

        let animated = self.pendingForceLatestOpenAnimated && !self.initialHistoryAppearancePending
        ChatArchiveDebugTrace.log("forceLatestOpenApply", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("reason", reason),
            ("animated", animated)
        ])
        self.scrollToLatestTimeline(animated: animated)
    }

    internal func finishLatestBottomScroll(animated: Bool, consumePendingForceLatest: Bool) {
        guard self.isViewLoaded else {
            return
        }

        let isStabilizing = self.isInitialLatestOpenStabilizing
        self.view.layoutIfNeeded()
        self.updateChatCollectionInsets()
        self.messagesCollectionView.layoutIfNeeded()
        guard self.datasource.isNotEmpty else {
            self.setFloatingDateVisible(true)
            return
        }

        let shouldSkipScroll = isStabilizing &&
            self.initialLatestOpenStabilizationState == .bottomAligned &&
            self.isNearBottom(threshold: 1)
        if !shouldSkipScroll {
            self.scrollToBottom(animated: isStabilizing ? false : animated)
        }
        self.scheduleSavedVisiblePositionFlushAfterBottomScroll(animated: isStabilizing ? false : animated)
        self.setFloatingDateVisible(true)
        self.markInitialLatestOpenBottomAlignedIfNeeded()

        if consumePendingForceLatest {
            self.pendingForceLatestOpen = false
            self.pendingForceLatestOpenAnimated = false
        }
    }

    internal func scrollToLatestFromScrollDownButton(animated: Bool) {
        self.scrollToLatestTimeline(animated: animated)
    }

    internal func unreadMentionsNavigatorVisibleFrame() -> CGRect? {
        self.unreadMentionsNavigatorVisibleFrame(
            trailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func unreadMentionsNavigatorVisibleFrame(trailingActionFrame: CGRect?) -> CGRect? {
        let inputHeight = self.floatingControlsInputHeight()
        let size = self.unreadMentionsNavigatorView.preferredSize
        guard let sendButtonFrame = trailingActionFrame else {
            return nil
        }
        let requestedShowsScrollDownButton = ChatUnreadMentionFloatingControlPolicy.shouldShowScrollDownButton(
            requested: self.shouldShowScrollDownButton.value,
            navigatorVisible: self.shouldShowUnreadMentionsNavigator.value
        )
        let showsScrollDownButton = requestedShowsScrollDownButton &&
            !ScrollDownButtonStartupVisibilityPolicy.isSuppressed(until: self.scrollDownButtonVisibilitySuppressedUntil)
        let scrollButtonFrame = showsScrollDownButton
            ? self.scrollDownButtonVisibleFrame(trailingActionFrame: sendButtonFrame)
            : nil
        return FloatingControlsLayoutPolicy.mentionIndicatorFrame(
            sendButtonFrame: sendButtonFrame,
            viewHeight: self.view.frame.height,
            mentionSize: size,
            inputHeight: inputHeight,
            scrollButtonFrame: scrollButtonFrame,
            showsScrollDownButton: showsScrollDownButton
        )
    }

    internal func unreadMentionsNavigatorHiddenFrame() -> CGRect {
        self.unreadMentionsNavigatorHiddenFrame(
            trailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func unreadMentionsNavigatorHiddenFrame(trailingActionFrame: CGRect?) -> CGRect {
        let size = self.unreadMentionsNavigatorView.preferredSize
        let originX: CGFloat
        if let sendButtonFrame = trailingActionFrame {
            originX = sendButtonFrame.midX - size.width / 2
        } else {
            originX = FloatingControlsLayoutPolicy.trailingX(
                viewWidth: self.view.frame.width,
                controlWidth: size.width
            )
        }
        return CGRect(
            origin: CGPoint(
                x: originX,
                y: self.view.frame.height + size.height + 24
            ),
            size: size
        )
    }

    internal func updateUnreadMentionsNavigatorFrame(animated: Bool) {
        self.updateUnreadMentionsNavigatorFrame(
            animated: animated,
            resolvedTrailingActionFrame: self.scrollDownButtonTrailingActionFrameInView()
        )
    }

    private func updateUnreadMentionsNavigatorFrame(
        animated: Bool,
        resolvedTrailingActionFrame: CGRect?
    ) {
        let shouldShowNavigator = self.shouldShowUnreadMentionsNavigator.value
        let frame: CGRect
        if shouldShowNavigator {
            guard let visibleFrame = self.unreadMentionsNavigatorVisibleFrame(
                trailingActionFrame: resolvedTrailingActionFrame
            ) else {
                self.unreadMentionsNavigatorView.isUserInteractionEnabled = false
                self.unreadMentionsNavigatorView.isHidden = true
                return
            }
            frame = visibleFrame
        } else {
            frame = self.unreadMentionsNavigatorHiddenFrame(
                trailingActionFrame: resolvedTrailingActionFrame
            )
        }
        let shouldAnimate = self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: animated)
        let updates = {
            self.unreadMentionsNavigatorView.frame = frame
        }

        self.unreadMentionsNavigatorView.isUserInteractionEnabled = shouldShowNavigator
        self.unreadMentionsNavigatorView.isHidden = false

        if shouldAnimate {
            UIView.animate(withDuration: 0.33, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.8, options: [.curveEaseIn]) {
                updates()
            } completion: { _ in
                self.unreadMentionsNavigatorView.isHidden = !shouldShowNavigator
            }
        } else {
            updates()
            self.unreadMentionsNavigatorView.isHidden = !shouldShowNavigator
        }
    }

    internal func updateFloatingControlsFrames(
        animated: Bool,
        ensureComposerLayout: Bool = true
    ) {
        let trailingActionFrame = self.scrollDownButtonTrailingActionFrameInView(
            ensureLayout: ensureComposerLayout
        )
        self.updateUnreadMentionsNavigatorFrame(
            animated: animated,
            resolvedTrailingActionFrame: trailingActionFrame
        )
        self.updateScrollDownButtonFrame(
            animated: animated,
            resolvedTrailingActionFrame: trailingActionFrame
        )
    }

    internal func isNearBottom(threshold: CGFloat = 80) -> Bool {
        let collectionView = self.messagesCollectionView
        let adjustedInsets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - adjustedInsets.top - adjustedInsets.bottom

        if collectionView.contentSize.height <= visibleHeight + threshold {
            return true
        }

        let offsetY = collectionView.contentOffset.y + adjustedInsets.top
        return offsetY + visibleHeight >= collectionView.contentSize.height - threshold
    }

    internal func scrollToBottom(animated: Bool) {
        guard self.datasource.isNotEmpty else {
            return
        }
        self.scrollToBottomAligned(targetIndexPath: nil, animated: animated)
    }

    internal func scrollToBottomAligned(targetIndexPath: IndexPath?, animated: Bool) {
        guard self.datasource.isNotEmpty else {
            return
        }

        self.messagesCollectionView.layoutIfNeeded()
        self.updateChatCollectionInsets()

        let targetMaxY = self.bottomAlignmentTargetMaxY(for: targetIndexPath)
            ?? self.messagesCollectionView.contentSize.height
        let targetOffsetY = ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
            targetMaxY: targetMaxY,
            contentHeight: self.messagesCollectionView.contentSize.height,
            viewportHeight: self.messagesCollectionView.bounds.height,
            contentInsets: self.messagesCollectionView.contentInset
        )

        guard !ChatBottomScrollAlignmentPolicy.isAligned(
            currentOffsetY: self.messagesCollectionView.contentOffset.y,
            targetOffsetY: targetOffsetY
        ) else {
            return
        }

        self.messagesCollectionView.setContentOffset(
            CGPoint(x: self.messagesCollectionView.contentOffset.x, y: targetOffsetY),
            animated: animated
        )
    }

    private func bottomAlignmentTargetMaxY(for indexPath: IndexPath?) -> CGFloat? {
        guard let indexPath,
              indexPath.section >= 0,
              indexPath.section < self.messagesCollectionView.numberOfSections,
              indexPath.item >= 0,
              indexPath.item < self.messagesCollectionView.numberOfItems(inSection: indexPath.section) else {
            return nil
        }

        return self.messagesCollectionView.layoutAttributesForItem(at: indexPath)?.frame.maxY
            ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame.maxY
    }

    @objc
    func clearAttachments() {
        self.forwardedIds.accept(Set<String>())
        self.attachedMessagesIds.accept([])
        self.editMessageId.accept(nil)
    }
    
    internal func configureMessagesPanel() {
        self.xabberInputView.contextPreviewPanel.delegate = self
    }
    
    internal func configureSelectionPanel() {
        self.xabberInputView.selectionPanel.delegate = self
        self.cancelSelectionBarButton.target = self
        self.cancelSelectionBarButton.action = #selector(onCancelSelection)
        self.deleteSelectionBarButton.target = self
        self.deleteSelectionBarButton.action = #selector(onDeleteMessagesButtonTouchDown)
    }
        

    
    internal let cancelSearchBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Cancel", style: .plain, target: nil, action: nil)
        if #available(iOS 26.0, *) {
            button.hidesSharedBackground = true
        }
        return button
    }()
    
    static func getUsernamePalette(for jid: String) -> MDCPalette {
        let palettes: [MDCPalette] = [
            .red,
            .pink,
            .purple,
            .deepPurple,
            .indigo,
            .blue,
            .lightBlue,
            .cyan,
            .teal,
            .green,
            .lightGreen,
            .lime,
            .yellow,
            .amber,
            .orange,
            .deepOrange,
            .brown,
            .grey,
            .blueGrey
        ]
        
        let hash = jid.utf8.reduce(0) { (result, char) in
            return ((result << 5) &+ result) ^ Int(char)
        }
        
        let index = abs(hash) % palettes.count
        
        return palettes[index]
    }
    
    func configureSearchBar(activateKeyboard: Bool = true, animated: Bool = true) {
        let shouldAnimate = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: animated,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )
        self.invalidateNavigationAvatarItem()

        let inputBar = self.searchInputBar
        inputBar.text = self.searchBar.text
        self.installSearchInputOverlayIfNeeded()
        self.updateSearchInputOverlayHeight(inputBar.intrinsicContentSize.height)

        NavigationBarItemOwnership.apply(
            to: self.navigationItem,
            left: NavigationBarItemOwnership.Assignment.none,
            right: NavigationBarItemOwnership.Assignment.none,
            animated: shouldAnimate
        )
        self.navigationItem.titleView = nil
        self.searchBar.delegate = self
        self.navigationItem.setHidesBackButton(true, animated: shouldAnimate)

        if activateKeyboard {
            inputBar.becomeInputFirstResponder()
        }

        self.applySearchResultsPanelState()
        self.xabberInputView.changeState(to: .search)
        let inputHeight = self.updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: 0
        )
        self.updateChatCollectionInsets(inputHeight: inputHeight)
    }

    internal func installSearchInputOverlayIfNeeded() {
        guard self.searchInputBar.superview == nil else {
            self.searchInputBar.isHidden = false
            self.bringSearchInputOverlayToFront()
            return
        }

        NSLayoutConstraint.deactivate(self.searchInputBarConstraints)
        self.searchInputBarConstraints.removeAll()

        let inputBar = self.searchInputBar
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.isHidden = false
        self.view.addSubview(inputBar)

        let heightConstraint = inputBar.heightAnchor.constraint(equalToConstant: inputBar.intrinsicContentSize.height)
        let topConstraint = inputBar.topAnchor.constraint(
            equalTo: self.view.safeAreaLayoutGuide.topAnchor,
            constant: self.searchInputOverlayTopOffset()
        )
        self.searchInputBarHeightConstraint = heightConstraint
        self.searchInputBarTopConstraint = topConstraint
        let constraints = [
            inputBar.leadingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.leadingAnchor,
                constant: NativeGlassBarStyle.horizontalInset
            ),
            inputBar.trailingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.trailingAnchor,
                constant: -NativeGlassBarStyle.horizontalInset
            ),
            topConstraint,
            heightConstraint
        ]
        self.searchInputBarConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        self.bringSearchInputOverlayToFront()
    }

    internal func updateSearchInputOverlayHeight(_ height: CGFloat) {
        self.searchInputBarHeightConstraint?.constant = max(NativeGlassBarStyle.minimumHeight, height)
        self.searchInputBarTopConstraint?.constant = self.searchInputOverlayTopOffset()
        self.searchInputBar.setNeedsLayout()
        self.view.setNeedsLayout()
    }

    internal func hideSearchInputOverlay() {
        NSLayoutConstraint.deactivate(self.searchInputBarConstraints)
        self.searchInputBarConstraints.removeAll()
        self.searchInputBar.isHidden = true
        self.searchInputBar.removeFromSuperview()
        self.searchInputBarHeightConstraint = nil
        self.searchInputBarTopConstraint = nil
    }

    internal func bringSearchInputOverlayToFront() {
        guard self.searchInputBar.superview != nil else { return }
        self.view.bringSubviewToFront(self.searchInputBar)
    }

    private func searchInputOverlayTopOffset() -> CGFloat {
        let navBarHeight = self.navigationController?.navigationBar.frame.height ?? NativeGlassBarStyle.minimumHeight
        return -max(NativeGlassBarStyle.minimumHeight, navBarHeight)
    }
    
    public func onSearchPanelChangeConversationType(_ oldConversationType: ClientSynchronizationManager.ConversationType) {
        let vc = ChatViewController()
        vc.owner = self.owner
        vc.jid = self.jid
        switch oldConversationType {
            case .regular: vc.conversationType = .omemo
            case .omemo: vc.conversationType = .regular
            default: vc.conversationType = self.conversationType
        }
        if let rootVc = self.navigationController?.viewControllers[0] {
            self.navigationController?.setViewControllers([rootVc, vc], animated: true)
        } else {
            self.navigationController?.pushViewController(vc, animated: true)
        }
        vc.activateSearchModeFromExternalRoute()
    }
    
    func initStatus() {
        if conversationType == .saved {
            let usersCount = AccountManager.shared.users.count
            
            if usersCount > 1 {
                self.contactStatus = self.owner
                self.statusLabel.text = self.contactStatus
            }
            
            return
            
        } else if (XMPPJID(string: self.jid)?.isServer ?? false) {
            self.contactStatus = "Server"
            self.statusLabel.text = self.contactStatus
            return
            
        }
        
        do {
            let realm = try WRealm.safe()
            let rosterItem = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)
            )
            let presentation = self.chatSubscriptionPresentation(rosterItem: rosterItem, realm: realm)
            self.applyChatSubscriptionPresentation(presentation)
            guard presentation.showsNormalPresenceStatus else {
                return
            }
            self.applyNormalPresenceStatus(realm: realm)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

    }
    

    
    override var disablesAutomaticKeyboardDismissal: Bool {
        get {
            return true
        }
    }
    
    internal let gradient = CAGradientLayer()
    internal let backgroundView = UIView()
    internal let backgroundImage = UIImageView()
    internal let gradientView = UIView()
    private let localChatBackdropView = ChatBackgroundBackdropView()
    
    var audioIsInLoading: Bool = false
    
    
    internal var recordedReferenceObject: MessageReferenceStorageItem? = nil {
        didSet {
            if recordedReferenceObject == nil {
                print(1)
            }
        }
    }
    internal var activeAudioRecordingSessionID: UUID? = nil
    internal var recordedReferenceSessionID: UUID? = nil
    internal var currentPlayingUrl: URL? = nil
    
    internal func showSharedAudioPanel() {
        guard let sharedAudioPlayerPanel else {
            return
        }
        let wasHidden = sharedAudioPlayerPanel.isHidden
        sharedAudioPlayerPanel.delegate = self
        sharedAudioPlayerPanel.isHidden = false
        guard wasHidden else {
            return
        }
        let updates = {
            self.updateFloatingBubblesVisibility(animated: false)
        }
        if ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: true,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        ) {
            UIView.animate(withDuration: 0.1, animations: updates)
        } else {
            UIView.performWithoutAnimation(updates)
        }
        
    }
    
    internal func hideSharedAudioPanel() {
        guard let sharedAudioPlayerPanel, !sharedAudioPlayerPanel.isHidden else {
            return
        }
        sharedAudioPlayerPanel.isHidden = true
        let updates = {
            self.updateFloatingBubblesVisibility(animated: false)
        }
        if ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: true,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        ) {
            UIView.animate(withDuration: 0.1, animations: updates)
        } else {
            UIView.performWithoutAnimation(updates)
        }
        
    }
    
    internal func configureSharedAudioPanel() {
        if let snapshot = VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot {
            self.sharedAudioPlayerPanel?.delegate = self
            self.sharedAudioPlayerPanel?.render(snapshot: snapshot)
            self.showSharedAudioPanel()
            return
        }
        self.sharedAudioPlayerPanel?.render(
            title: AudioManager.shared.currentPlayingTitle,
            subtitle: AudioManager.shared.currentPlayingSubtitle,
            state: .playing,
            currentTime: AudioManager.shared.player?.currentTime ?? 0,
            duration: AudioManager.shared.player?.duration ?? 0
        )
        self.sharedAudioPlayerPanel?.delegate = self
        self.showSharedAudioPanel()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateNavbarTitleWidth()
        updateFloatingControlsFrames(animated: false, ensureComposerLayout: false)
        updateInitialMessageOverlayFrame()
        updateFloatingBubblesVisibility(animated: false)
        recordChatOpenTimingFirstMessagesVisibleIfPossible(
            reason: "viewDidLayoutSubviews",
            modeDescription: "layout"
        )
//        updateInsets()  // Recompute and apply as above
    }
    
    private func configure() {
        restorationIdentifier = "CHAT_VIEW_CONTROLLER_RID_\(self.jid)\(self.owner)"
        self.initSender()
        
        self.dateListContainerView.frame = self.view.bounds
                
        accountPallete = AccountColorManager.shared.palette(for: owner)
        self.messagesCollectionView.prefetchDataSource = self
        self.messagesCollectionView.messagesDataSource = self
        self.messagesCollectionView.messageCellDelegate = self
//        self.messagesCollectionView.messagesDisplayDelegate = self
        self.messagesCollectionView.messagesLayoutDelegate = self
        
        if #available(iOS 11.0, *) {
            messagesCollectionView.contentInsetAdjustmentBehavior = .never
        } else {
            automaticallyAdjustsScrollViewInsets = false
        }

        self.messagesCollectionView.scrollsToTop = false
        self.scrollsToBottomOnKeybordBeginsEditing = false
        self.maintainPositionOnKeyboardFrameChanged = true
        self.view.addSubview(self.dateListContainerView)
        
        messagesCollectionView.accountPalette = accountPallete
        self.updateScrollDownButtonAppearance()
        
        var inputHeight: CGFloat = ModernXabberInputView.defaultBarHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
//        self.navbarOverlayView.frame = CGRect(
//            width: self.view.bounds.width,
//            height: navbarHeight
//        )
        
//        inputHeight: CGFloat = ModernXabberInputView.defaultBarHeight
//        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
//            inputHeight += bottomInset
//        }
        
        let horizontalInset = ModernXabberInputView.edgeHorizontalInset
        let leadingInset = self.view.safeAreaInsets.left + horizontalInset
        let trailingInset = self.view.safeAreaInsets.right + horizontalInset
        let frame = CGRect(
            origin: CGPoint(x: leadingInset, y: self.view.bounds.height - inputHeight),
            size: CGSize(width: max(0, self.view.bounds.width - leadingInset - trailingInset), height: inputHeight)
        )
        self.xabberInputView = ModernXabberInputView(frame: frame)
        self.xabberInputView.accountPalette = accountPallete
        self.xabberInputView.delegate = self
        
        self.view.addSubview(self.scrollDownButton)
        self.view.addSubview(xabberInputView)
        self.view.addSubview(self.unreadMentionsNavigatorView)
        self.view.bringSubviewToFront(xabberInputView)
        self.view.bringSubviewToFront(self.unreadMentionsNavigatorView)
        self.setupFloatingGlassBubbles()
        
        xabberInputView.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = xabberInputView.heightAnchor.constraint(equalToConstant: inputHeight)
        let bottomConstraint = xabberInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let keyboardTopConstraint = xabberInputView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        keyboardTopConstraint.isActive = false
        self.xabberInputViewBottomConstraint = bottomConstraint
        self.xabberInputViewKeyboardTopConstraint = keyboardTopConstraint
        NSLayoutConstraint.activate([
            xabberInputView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ModernXabberInputView.edgeHorizontalInset),
            xabberInputView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -ModernXabberInputView.edgeHorizontalInset),
            bottomConstraint,
            heightConstraint
        ])
        xabberInputView.heightConstraint = heightConstraint
        
        self.messagesCollectionView.keyboardDismissMode = .interactive
        self.updateChatCollectionInsets(inputHeight: inputHeight)
        
        
        
        self.configureBackground()
        self.configureNavbar()
        if self.inSearchMode.value {
            self.configureSearchModeForCurrentActivation(
                defaultActivateKeyboard: !self.isPreparingStackedNavigationPresentation,
                defaultAnimated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                    requestedAnimated: true,
                    isTransitionActive: self.isNavigationTransitionActive,
                    isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                )
            )
        } else {
            self.searchTextObserver.accept(nil)
        }
        self.configureInputBar()
        self.configureSelectionPanel()
        self.configureMessagesPanel()
        self.configureCertificateUpdateTimer()
        self.configureDataset()
        self.previousFrame = self.view.bounds
        self.view.addSubview(self.chatViewLoadingOverlay)
        self.chatViewLoadingOverlay.fillSuperview()
        if self.inSearchMode.value {
            self.bringSearchInputOverlayToFront()
        }
//        self.view.addSubview(self.navbarOverlayView)
//        self.view.addSubview(floatingDateView)
        self.scrollDownButton.addTarget(self, action: #selector(self.onScrollDownChatButtonTouchUpInside), for: .touchUpInside)
        self.unreadMentionsNavigatorView.onBadgeTap = { [weak self] in
            self?.navigateToNextUnreadMention()
        }
        self.view.addSubview(self.messageLoadingActivityIndicator)
        self.messageLoadingActivityIndicator.startAnimating()
        self.messageLoadingActivityIndicator.isHidden = true
        if self.sharedAudioPlayerPanel != nil {
            AudioManager.shared.addMulticastDelegate(self.sharedAudioPlayerPanel)
        }
        self.configureVoiceMessagePlaybackCoordinator()
//    case avatarChatPosition = "avatar_chat_vertical_position"
//    case avatarCornerStyle = "avatar_corner_style"
        self.updateCornerStyle()
        
//        self.navigationItem.title = "Chat"
//        self.navigationController?.navigationBar
//        if #available(iOS 26.0, *) {
//            let button = UIBarButtonItem(image: imageLiteral("person"), style: .prominent, target: nil, action: nil)
//            self.navigationItem.setRightBarButton(button, animated: true)
//        } else {
            // Fallback on earlier versions
//        }
        
//        self.self.navigationController?.navigationBar.isTranslucent = true
        //        button./
        self.view.addSubview(self.pinnedDateView)
    }
    
    @objc
    internal func updateCornerStyle() {
        let cornerRaw = SettingManager.shared.getString(for: "message_corner_style") ?? "no_tail"
        self.cornerRadius = SettingManager.shared.getString(for: "message_corner_radius") ?? "16"
        self.messageCorner = MessageStyleConfig.MessageBubbleContainer.nameFromVerbose(cornerRaw)
        self.avatarVerticalPosition = SettingManager.shared.getString(for: "avatar_chat_vertical_position")?.lowercased() ?? "bottom"
    }
    
//    @objc
//    interna;
    
    var previousFrame: CGRect = .zero
    
    
    
    final func configureDataset() {
        self.timelineSession?.cancelInitialFramePreparations()
        self.timelineSession?.cancelLocalPagePreparations()
        self.clearPendingLocalHistoryPagingPreparation()
        self.initialLocalFirstFramePhase = .idle
        self.initialLocalFirstFrameCompletions.removeAll(keepingCapacity: false)
        self.initialLocalFirstFrameShouldPerformPendingRequest = false
        self.initialFirstContentApplyCount = 0
        let store = RealmChatTimelineSessionStore(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: self.datasourcePageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            ),
            archiveState: self.loadChatArchiveStateSnapshot()
        )
        session.onSnapshot = { [weak self, weak session] snapshot in
            let applySnapshot = {
                guard let self, let session, self.timelineSession === session else { return }
                if snapshot.cause == .storeChange,
                   self.hasRenderedStableInitialHistory {
                    self.handleTimelineSessionRefresh()
                }
            }
            if Thread.isMainThread {
                applySnapshot()
            } else {
                DispatchQueue.main.async(execute: applySnapshot)
            }
        }
        self.timelineSession = session
        self.unreadMentionItems = []
        self.unreadMentionsState = .empty
    }
    
    final func configureBackground() {
        if backgroundPresentationMode == .sharedSplitBackdrop {
            backgroundView.removeFromSuperview()
            localChatBackdropView.removeFromSuperview()
            messagesCollectionView.backgroundColor = .clear
            view.backgroundColor = .clear
            view.isOpaque = false
            return
        }

        if backgroundPresentationMode == .localChatBackdrop {
            backgroundView.removeFromSuperview()
            localChatBackdropView.frame = view.bounds
            localChatBackdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            localChatBackdropView.reloadFromSettings()
            if localChatBackdropView.superview !== view {
                view.addSubview(localChatBackdropView)
            }
            view.sendSubviewToBack(localChatBackdropView)
            messagesCollectionView.backgroundColor = .clear
            view.backgroundColor = .systemBackground
            view.isOpaque = true
            return
        }

        if ContinuousSplitBackgroundExperiment.isActive {
            backgroundView.removeFromSuperview()
            localChatBackdropView.removeFromSuperview()
            messagesCollectionView.backgroundColor = .clear
            view.backgroundColor = .clear
            view.isOpaque = false
            return
        }

        localChatBackdropView.removeFromSuperview()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        backgroundView.frame = self.view.bounds
        backgroundImage.frame = self.backgroundView.bounds
        
        gradientView.frame = self.backgroundView.bounds
        gradient.frame = self.gradientView.bounds
        gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        
        updateBackground()
        
//        self.navigationController?.navigationBar
        
        gradientView.layer.addSublayer(gradient)
        backgroundView.addSubview(gradientView)
        backgroundView.addSubview(backgroundImage)
        backgroundView.bringSubviewToFront(backgroundImage)
        self.messagesCollectionView.backgroundColor = .clear
        self.view.addSubview(backgroundView)
        self.view.sendSubviewToBack(backgroundView)
    }
    
    final func configureNavbar() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.configureNavbar()
            }
            return
        }
        setupNavigationBar()
    }

    private func setupNavigationBar() {
        NavigationBarItemOwnership.clear(self.navigationItem, animated: false)
        NativeSectionNavigationBarPolicy.apply(to: self)
        edgesForExtendedLayout = [.top, .bottom]
        extendedLayoutIncludesOpaqueBars = true

        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.setHidesBackButton(false, animated: false)
        navigationItem.leftItemsSupplementBackButton = true

        setupNavigationTitleView()
        setupNavigationAvatarItem()

        titleLabel.attributedText = updateTitle()
        initStatus()
        updateNavbarTitleWidth()
    }

    private func setupNavigationTitleView() {
        if titleStack.arrangedSubviews.isEmpty {
            titleStack.addArrangedSubview(titleLabel)
            titleStack.addArrangedSubview(statusLabel)
        }
        if titleStack.superview !== titleButton {
            titleButton.addSubview(titleStack)
            titleStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                titleStack.leadingAnchor.constraint(equalTo: titleButton.leadingAnchor),
                titleStack.trailingAnchor.constraint(equalTo: titleButton.trailingAnchor),
                titleStack.topAnchor.constraint(greaterThanOrEqualTo: titleButton.topAnchor),
                titleStack.bottomAnchor.constraint(lessThanOrEqualTo: titleButton.bottomAnchor),
                titleStack.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor)
            ])
        }

        titleStack.isUserInteractionEnabled = false
        titleStack.alignment = .fill
        titleLabel.textAlignment = .center
        statusLabel.textAlignment = .center
        titleButton.contentHorizontalAlignment = .center
        titleButton.contentVerticalAlignment = .center
        
        titleButton.removeTarget(self, action: #selector(onTitleButtonTouchUp(_:)), for: .touchUpInside)
        titleButton.addTarget(self, action: #selector(onTitleButtonTouchUp(_:)), for: .touchUpInside)
        navigationItem.titleView = titleButton
    }

    private func setupNavigationAvatarItem() {
        invalidateNavigationAvatarItem()

        let item = ChatNavigationAvatarItemFactory.makeItem(
            image: currentNavigationAvatarPlaceholderImage(),
            target: self,
            action: #selector(showInfo)
        )
        navigationAvatarItem = item
        NavigationBarItemOwnership.set(.item(item), on: navigationItem, side: .right, animated: false)
        startNavigationAvatarObservation()
        refreshNavigationAvatarImage()
    }

    private func updateNavbarTitleWidth() {
        guard navigationItem.titleView === titleButton else { return }
        let navBarWidth = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        let leftReserved: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 120 : 88
        let rightReserved: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 120 : 88
        let sideReserve = max(leftReserved, rightReserved)
        let targetFrame = CGRect(x: 0, y: 0, width: max(140, navBarWidth - sideReserve * 2), height: 42)
        if !titleButton.frame.isApproximatelyEqual(to: targetFrame) {
            titleButton.frame = targetFrame
        }
    }

    internal func setupFloatingGlassBubbles() {
        guard floatingBubblesStackView.superview == nil else {
            return
        }

        floatingBubblesStackView.addArrangedSubview(topPanelBubbleView)
        floatingBubblesStackView.addArrangedSubview(pinnedMessageBubbleView)
        if let sharedAudioPlayerPanel {
            floatingBubblesStackView.addArrangedSubview(sharedAudioPlayerPanel)
            sharedAudioPlayerHeightConstraint = sharedAudioPlayerPanel.heightAnchor.constraint(equalToConstant: AudioPlayerBarView.Metrics.height)
            sharedAudioPlayerHeightConstraint?.isActive = true
        }

        topPanelBubbleView.isHidden = true
        pinnedMessageBubbleView.isHidden = true
        sharedAudioPlayerPanel?.isHidden = true

        view.addSubview(floatingBubblesStackView)
        NSLayoutConstraint.activate([
            floatingBubblesStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ChatFloatingHeaderLayoutPolicy.floatingStackTopSpacing),
            floatingBubblesStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            floatingBubblesStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])
    }

    internal func showTopPanelBubble(with view: UIView, contentHeight: CGFloat = 44) {
        topPanelBubbleView.setHostedView(view, contentHeight: contentHeight)
        topPanelBubbleView.isHidden = false
        updateFloatingBubblesVisibility(animated: true)
    }

    internal func hideTopPanelBubble(animated: Bool) {
        topPanelBubbleView.isHidden = true
        updateFloatingBubblesVisibility(animated: animated)
    }

    internal func showForwardPanel() {
        xabberInputView?.showForwardPanel()
        updateFloatingBubblesVisibility(animated: true)
    }

    internal func showEditPanel() {
        xabberInputView?.showEditPanel()
        updateFloatingBubblesVisibility(animated: true)
    }

    internal func hideMessagePanelBubble(animated: Bool = true) {
        xabberInputView?.hideForwardPanel()
        xabberInputView?.hideEditPanel()
        updateFloatingBubblesVisibility(animated: animated)
    }

    internal func updateFloatingBubblesVisibility(animated: Bool = false) {
        guard floatingBubblesStackView.superview != nil else {
            return
        }

        let visibleHeights = floatingBubblesStackView.arrangedSubviews
            .filter { !$0.isHidden }
            .map { view -> CGFloat in
                if let bubble = view as? ChatFloatingGlassBubbleView {
                    return bubble.measuredHeight()
                }
                if view is AudioPlayerBarView {
                    return AudioPlayerBarView.Metrics.height
                }
                return view.bounds.height
            }
        let height = ChatFloatingHeaderLayoutPolicy.visibleStackHeight(
            visibleBubbleHeights: visibleHeights,
            spacing: floatingBubblesStackView.spacing
        )
        let shouldHideStack = visibleHeights.isEmpty
        let visibilityChanged = floatingBubblesStackView.isHidden != shouldHideStack
        let heightChanged = abs(floatingBubblesHeight - height) > 0.5
        let shouldAnimate = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: animated),
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )

        let updates = {
            if visibilityChanged {
                self.floatingBubblesStackView.isHidden = shouldHideStack
            }
            if heightChanged {
                self.floatingBubblesHeight = height
            }
            if visibilityChanged || heightChanged {
                self.updateChatCollectionInsets()
            }
            if shouldAnimate {
                self.view.layoutIfNeeded()
            }
        }

        if shouldAnimate, visibilityChanged || heightChanged {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: updates,
                completion: nil
            )
        } else {
            updates()
        }
    }

    internal func updateChatCollectionInsets(inputHeight: CGFloat? = nil) {
        let composerHeight = inputHeight ?? xabberInputView?.bounds.height ?? ModernXabberInputView.defaultBarHeight
        let navigationHeight = currentNavigationVisualHeight()
        let indicatorInsets = ChatFloatingHeaderLayoutPolicy.scrollIndicatorInsets(
            composerHeight: composerHeight,
            navigationVisualHeight: navigationHeight,
            floatingBubblesHeight: floatingBubblesHeight
        )
        let insets = ChatFloatingHeaderLayoutPolicy.collectionInsets(
            composerHeight: composerHeight,
            navigationVisualHeight: navigationHeight,
            floatingBubblesHeight: floatingBubblesHeight,
            contentHeight: messagesCollectionView.contentSize.height,
            viewportHeight: messagesCollectionView.bounds.height
        )
        if !messagesCollectionView.contentInset.isApproximatelyEqual(to: insets) {
            messagesCollectionView.contentInset = insets
        }
        if !messagesCollectionView.scrollIndicatorInsets.isApproximatelyEqual(to: indicatorInsets) {
            messagesCollectionView.scrollIndicatorInsets = indicatorInsets
        }
    }

    internal var isChatSearchInputKeyboardOwned: Bool {
        inSearchMode.value
    }

    internal func reconcileChatInputViewStateWithSearchModeIfNeeded() {
        guard isViewLoaded,
              let inputView = xabberInputView else {
            return
        }

        if inSearchMode.value {
            if inputView.state != .search {
                inputView.changeState(to: .search)
            }
        } else if inputView.state == .search {
            inputView.changeState(to: .normal)
        }
    }

    internal func updateChatInputKeyboardLayoutMode() {
        guard xabberInputViewBottomConstraint != nil,
              xabberInputViewKeyboardTopConstraint != nil else {
            return
        }

        let shouldUseKeyboardGuide = isChatSearchInputKeyboardOwned
        if xabberInputViewBottomConstraint?.isActive == shouldUseKeyboardGuide {
            xabberInputViewBottomConstraint?.isActive = !shouldUseKeyboardGuide
        }
        if xabberInputViewKeyboardTopConstraint?.isActive != shouldUseKeyboardGuide {
            xabberInputViewKeyboardTopConstraint?.isActive = shouldUseKeyboardGuide
        }
    }

    internal func inputKeyboardHeightForCurrentChatInputMode(
        visibleKeyboardHeight: CGFloat
    ) -> CGFloat {
        isChatSearchInputKeyboardOwned ? 0 : visibleKeyboardHeight
    }

    @discardableResult
    internal func updateChatInputViewForCurrentKeyboardLayout(
        visibleKeyboardHeight: CGFloat
    ) -> CGFloat {
        guard let inputView = self.xabberInputView else {
            return 0
        }

        self.reconcileChatInputViewStateWithSearchModeIfNeeded()
        self.updateChatInputKeyboardLayoutMode()
        let inputKeyboardHeight = self.inputKeyboardHeightForCurrentChatInputMode(
            visibleKeyboardHeight: visibleKeyboardHeight
        )
        let screenHeight = self.view.bounds.height > 0 ? self.view.bounds.height : UIScreen.main.bounds.height
        inputView.update(
            screenHeight: screenHeight,
            keyboardHeight: inputKeyboardHeight,
            includeBottomSafeAreaWhenKeyboardHidden: !self.isChatSearchInputKeyboardOwned
        )
        return inputView.bounds.height
    }

    private func currentNavigationVisualHeight() -> CGFloat {
        if view.safeAreaInsets.top > 0 {
            return view.safeAreaInsets.top
        }

        var navbarHeight = navigationController?.navigationBar.frame.height ?? 44
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
        return navbarHeight
    }
    
    final func configureInputBar() {
        if self.conversationType.isEncrypted {
            self.xabberInputView.shouldHideTimer = false
            self.xabberInputView.timerButton.isHidden = self.xabberInputView.shouldHideTimer
            self.xabberInputView.timerButton.isEnabled = true
        } else {
            self.xabberInputView.shouldHideTimer = true
            self.xabberInputView.timerButton.isHidden = true
            self.xabberInputView.timerButton.isEnabled = false
        }
        _ = self.updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: self.xabberInputView.keyboardHeight
        )
        self.xabberInputView.searchPanel.conversationType = self.conversationType
        self.xabberInputView.searchPanel.onChangeConversationTypeCallback = onSearchPanelChangeConversationType
        self.xabberInputView.searchPanel.onSeekUpCallback = self.onSearchPanelSeekUp
        self.xabberInputView.searchPanel.onSeekDownCallback = self.onSearchPanelSeekDown
        self.xabberInputView.searchPanel.onChangeViewStateCallback = self.onSearchPanelChangeChatViewState
        self.xabberInputView.searchPanel.onCancelCallback = { [weak self] in
            self?.cancelSearchModeFromSearchUI()
        }
        self.xabberInputView.mentionConversationType = self.conversationType
        self.xabberInputView.mentionCandidatesProvider = { [weak self] query in
            self?.mentionCandidates(for: query) ?? []
        }
        self.xabberInputView.mentionMembersCountProvider = { [weak self] in
            self?.currentMentionMembersCount() ?? 0
        }
        self.xabberInputView.mentionUsersReloadHandler = { [weak self] in
            self?.requestMentionUsersIfNeeded()
        }
    }

    internal func mentionCandidates(for query: String) -> [ComposerMentionCandidate] {
        guard self.conversationType == .group else { return [] }
        do {
            let realm = try WRealm.safe()
            let items = self.mentionUsersResults(in: realm)

            let normalizedQuery = self.normalizeMentionSearchValue(query)
            let filtered = items.filter { item in
                guard item.userId.isNotEmpty else { return false }
                if normalizedQuery.isEmpty { return true }
                let nickname = self.normalizeMentionSearchValue(item.nickname)
                let jid = self.normalizeMentionSearchValue(item.jid)
                let username = self.normalizeMentionSearchValue(item.jid.split(separator: "@").first.map(String.init) ?? "")
                return nickname.contains(normalizedQuery) || jid.contains(normalizedQuery) || username.contains(normalizedQuery)
            }

            var seenMemberIds: Set<String> = []

            return filtered
                .map { item in
                    let nickname = item.nickname.isEmpty
                        ? (item.jid.split(separator: "@").first.map(String.init) ?? item.userId)
                        : item.nickname
                    guard nickname.isNotEmpty || item.jid.isNotEmpty else {
                        return nil
                    }
                    guard seenMemberIds.insert(item.userId).inserted else {
                        return nil
                    }
                    let uri = "xmpp:\(self.jid)?members;id=\(item.userId)"
                    return ComposerMentionCandidate(
                        memberId: item.userId,
                        nickname: nickname,
                        uri: uri,
                        node: "https://xabber.com/protocol/groupchat",
                        jid: item.jid.isEmpty ? nil : item.jid,
                        secondaryText: item.jid.isEmpty ? item.userId : item.jid
                    )
                }
                .compactMap { $0 }
                .sorted(by: { lhs, rhs in
                    let lhsPrefix = self.normalizeMentionSearchValue(lhs.nickname).hasPrefix(normalizedQuery)
                    let rhsPrefix = self.normalizeMentionSearchValue(rhs.nickname).hasPrefix(normalizedQuery)
                    if lhsPrefix != rhsPrefix {
                        return lhsPrefix && !rhsPrefix
                    }
                    return lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending
                })
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    internal func currentMentionMembersCount() -> Int {
        guard self.conversationType == .group else { return 0 }
        do {
            let realm = try WRealm.safe()
            return self.mentionUsersResults(in: realm).count
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return 0
        }
    }

    internal func mentionUsersResults(in realm: Realm) -> Results<GroupchatUserStorageItem> {
        let groupchatId = [self.jid, self.owner].prp()
        return realm.objects(GroupchatUserStorageItem.self)
            .filter(
                "groupchatId == %@ AND isBlocked == false AND isKicked == false AND isHidden == false",
                groupchatId
            )
    }

    internal func requestMentionUsersIfNeeded() {
        guard self.conversationType == .group, !self.hasRequestedMentionUsersRefresh else { return }
        self.hasRequestedMentionUsersRefresh = true
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.requestUsers(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.requestUsers(stream, groupchat: self.jid)
            }
        }
    }

    private func normalizeMentionSearchValue(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        if previousFrame == self.view.bounds {
            return
        }
        let wasNearBottom = self.isNearBottom()
        let visibleAnchor = wasNearBottom ? nil : self.capturePagingAnchorIfNeeded(direction: .older)

        var navbarHeight: CGFloat = 50
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
        
        if AudioManager.shared.player != nil {
            self.configureSharedAudioPanel()
        } else {
            self.hideSharedAudioPanel()
        }
        self.setTopPanelState(self.topPanelState.value)
        self.refreshPinnedMessagePanelIfNeeded()
        previousFrame = self.view.bounds
        backgroundView.frame = CGRect(
            origin: CGPoint(x: 0, y: 0),//((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) + (self.navigationController?.navigationBar.frame.height ?? 0)),
            size: self.view.bounds.size
        )
        backgroundImage.frame = self.view.bounds
        
        gradientView.frame = self.view.bounds
        
        gradient.frame = self.view.bounds
        
        
//        self.navbarOverlayView.frame = CGRect(
//            width: self.view.bounds.width,
//            height: navbarHeight
//        )
//        
        self.messageLoadingActivityIndicator.frame = CGRect(width: 64, height: 64)
        self.messageLoadingActivityIndicator.center = CGPoint(x: self.view.center.x, y: navbarHeight + 32)
        
        let inputHeight = self.updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: self.xabberInputView.keyboardHeight
        )
        
        let horizontalInset = ModernXabberInputView.edgeHorizontalInset
        let leadingInset = self.view.safeAreaInsets.left + horizontalInset
        let trailingInset = self.view.safeAreaInsets.right + horizontalInset
        let frame = CGRect(
            origin: CGPoint(x: leadingInset, y: self.view.bounds.height - inputHeight),
            size: CGSize(width: max(0, self.view.bounds.width - leadingInset - trailingInset), height: inputHeight)
        )
        self.xabberInputView.setupFrames(frame)
        self.xabberInputView.heightConstraint?.constant = inputHeight
        self.applyChatComposerFrameUpdate(
            inputHeight: inputHeight,
            source: .containerBounds,
            wasNearBottom: wasNearBottom,
            visibleAnchor: visibleAnchor
        )
        self.updateFloatingControlsFrames(animated: false)
    }

    internal func applyChatComposerFrameUpdate(
        inputHeight: CGFloat,
        source: ChatComposerFrameUpdateSource,
        wasNearBottom: Bool,
        visibleAnchor: ChatHistoryPageAnchor?
    ) {
        let collectionUpdates = {
            var layoutSignpost = ChatPerformanceSignposts.begin(.layoutApply)
            defer {
                layoutSignpost.end()
            }
            let anchorRestoration: ChatComposerFrameAnchorRestoration
            if source == .keyboardFrame {
                anchorRestoration = ChatKeyboardFrameViewportPolicy.anchorRestoration(
                    wasNearBottom: wasNearBottom
                )
            } else if wasNearBottom {
                anchorRestoration = .bottom
            } else if visibleAnchor != nil {
                anchorRestoration = .visibleAnchor
            } else {
                anchorRestoration = .none
            }
            let actions = ChatComposerFrameUpdatePlanner.actions(
                for: ChatComposerFrameUpdateRequest(
                    source: source,
                    hasMessages: !self.datasource.isEmpty,
                    previousInputHeight: self.messagesCollectionView.contentInset.bottom,
                    inputHeight: inputHeight,
                    anchorRestoration: anchorRestoration
                )
            )
            for action in actions {
                self.performChatComposerFrameUpdateAction(
                    action,
                    source: source,
                    visibleAnchor: visibleAnchor
                )
            }
        }
        if self.isNavigationTransitionActive || self.isPreparingStackedNavigationPresentation {
            UIView.performWithoutAnimation(collectionUpdates)
        } else {
            collectionUpdates()
        }
    }

    private func performChatComposerFrameUpdateAction(
        _ action: ChatComposerFrameUpdateAction,
        source: ChatComposerFrameUpdateSource,
        visibleAnchor: ChatHistoryPageAnchor?
    ) {
        switch action {
        case .updateInsets(let inputHeight):
            self.updateChatCollectionInsets(inputHeight: inputHeight)
        case .updateInitialMessageOverlayFrame:
            self.updateInitialMessageOverlayFrame()
        case .invalidateLayoutCache:
            (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                .cache.invalidate()
        case .invalidateLayout:
            self.messagesCollectionView.collectionViewLayout.invalidateLayout()
        case .reloadData:
            assertionFailure("Composer frame changes must not reload chat data")
        case .layoutIfNeeded:
            if source == .keyboardFrame {
                self.view.layoutIfNeeded()
            } else {
                self.messagesCollectionView.layoutIfNeeded()
            }
        case .scrollToBottom:
            self.scrollToBottom(animated: false)
        case .alignBottomToCurrentInsets:
            self.alignChatBottomToCurrentInsets()
        case .restoreVisibleAnchor:
            if let visibleAnchor {
                self.restorePagingAnchor(visibleAnchor)
            }
        }
    }

    private func alignChatBottomToCurrentInsets() {
        guard self.datasource.isNotEmpty else {
            return
        }

        let targetOffsetY = ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
            targetMaxY: self.messagesCollectionView.contentSize.height,
            contentHeight: self.messagesCollectionView.contentSize.height,
            viewportHeight: self.messagesCollectionView.bounds.height,
            contentInsets: self.messagesCollectionView.contentInset
        )

        guard !ChatBottomScrollAlignmentPolicy.isAligned(
            currentOffsetY: self.messagesCollectionView.contentOffset.y,
            targetOffsetY: targetOffsetY
        ) else {
            return
        }

        self.messagesCollectionView.setContentOffset(
            CGPoint(x: self.messagesCollectionView.contentOffset.x, y: targetOffsetY),
            animated: false
        )
    }
    
    private func unsubscribe() {
        NotifyManager.shared.currentDialog = nil
        self.cancelPendingArchiveObserverRefresh(reason: "unsubscribe")
        self.endAllChatHistoryLoadActivities(reason: "unsubscribe")
        self.bag = DisposeBag()
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.clearRemoteHistoryEndPageDispatchers()
        self.remoteHistoryQueryCoordinator.cancelAll(reason: .cancelled)
        self.stopChatArchiveMainStallProbe(reason: "unsubscribe")
        self.finishChatOpenTimingSession(reason: "unsubscribe")
        VoiceMessagePlaybackCoordinator.shared.removeObserver(self.voiceMessageStateObserverToken)
        self.voiceMessageStateObserverToken = nil
    }

    internal func orderedViewportReadMessages() -> [ChatViewportReadBoundaryPolicy.OrderedMessage] {
        let residentIndex = self.timelineSession?.snapshot.residentIndex
        return self.datasource.enumerated().map { offset, item in
            ChatViewportReadBoundaryPolicy.OrderedMessage(
                primary: item.primary,
                orderIndex: residentIndex?.index(primary: item.primary) ?? offset,
                isOutgoing: item.isOutgoing,
                isRead: item.isRead,
                rowKind: ChatVisiblePositionPolicy.rowKind(for: item.kind),
                isFakeMessage: item.isFakeMessage
            )
        }
    }

    internal func currentViewportReadBoundaryIndex(
        in orderedMessages: [ChatViewportReadBoundaryPolicy.OrderedMessage]
    ) -> Int? {
        if let snapshot = self.timelineSession?.snapshot,
           let boundary = snapshot.readBoundary {
            if let residentIndex = snapshot.residentIndex.index(primary: boundary.primary) {
                return residentIndex
            }
            let precedingResidentIndex = snapshot.items.enumerated().last(where: {
                ChatTimelinePositionKey(message: $0.element) <= boundary.position
            })?.offset
            return precedingResidentIndex ?? -1
        }
        if let primary = self.detachedViewportReadBoundaryPrimary {
            if let residentIndex = self.timelineSession?.snapshot.residentIndex.index(primary: primary) {
                return residentIndex
            }
            if let orderedIndex = orderedMessages.first(where: { $0.primary == primary })?.orderIndex {
                return orderedIndex
            }
        }
        return self.detachedViewportReadBoundaryIndex
    }

    internal func currentViewportReadBoundaryPosition() -> ChatTimelinePositionKey? {
        self.timelineSession?.snapshot.readBoundary?.position
            ?? self.detachedViewportReadBoundaryPosition
    }

    internal func setViewportReadBoundaryTarget(_ target: ChatViewportReadBoundaryPolicy.OrderedMessage) {
        if let session = self.timelineSession {
            _ = session.advanceReadBoundary(toPrimary: target.primary)
        } else {
            self.detachedViewportReadBoundaryPrimary = target.primary
            self.detachedViewportReadBoundaryIndex = target.orderIndex
            self.detachedViewportReadBoundaryPosition = self.scrollResidentMetadata.position(
                primary: target.primary
            )
        }
    }

    @discardableResult
    internal func advanceReadBoundary(to target: ChatScrollVisibleRow) -> Bool {
        let didAdvance: Bool
        if let session = self.timelineSession {
            didAdvance = session.advanceReadBoundary(toPrimary: target.primary)
        } else {
            guard self.detachedViewportReadBoundaryPosition.map({ target.position > $0 }) ?? true else {
                return false
            }
            self.detachedViewportReadBoundaryPrimary = target.primary
            self.detachedViewportReadBoundaryIndex = target.section
            self.detachedViewportReadBoundaryPosition = target.position
            didAdvance = true
        }
        guard didAdvance else {
            return false
        }
        self.messagesToReadObserver.accept([target.primary])
        return true
    }

    @discardableResult
    internal func advanceReadBoundaryFromVisibleMessages(indexPaths: [IndexPath]) -> Bool {
        let visible = self.scrollResidentMetadata.capture(indexPaths: indexPaths)
        let request = ChatScrollWorkRequest(
            contentOffsetY: self.messagesCollectionView.contentOffset.y,
            gestureTranslationY: 0,
            isUserScrolling: false,
            visibleIndexPaths: indexPaths,
            visibleMetadata: visible,
            work: [.advanceReadBoundary]
        )
        guard let target = ChatScrollFramePlanner().plan(
            request: request,
            currentReadPosition: self.currentViewportReadBoundaryPosition()
        ).readTarget else {
            return false
        }
        return self.advanceReadBoundary(to: target)
    }

    @discardableResult
    internal func flushPendingVisibleReadTarget() -> Bool {
        let orderedMessages = self.orderedViewportReadMessages()
        let currentBoundaryIndex = self.currentViewportReadBoundaryIndex(in: orderedMessages)
        guard let target = ChatViewportReadBoundaryPolicy.newestPendingTarget(
            pendingPrimaries: self.messagesToReadObserver.value,
            orderedMessages: orderedMessages,
            currentBoundaryIndex: currentBoundaryIndex
        ) else {
            return false
        }

        self.setViewportReadBoundaryTarget(target)
        self.messagesToReadObserver.accept(Set<String>())
        AccountManager.shared.find(for: self.owner)?.messages.readMessage(target.primary, last: false)
        self.rebuildUnreadMentionItems()
        self.refreshUnreadMentionsNavigatorState(animated: true)
        return true
    }

    internal func runNavigationDisappearanceCleanupIfNeeded() {
        guard !self.didRunNavigationDisappearanceCleanup else {
            return
        }
        self.didRunNavigationDisappearanceCleanup = true
        self.didScheduleNavigationDisappearanceCleanup = false
        AccountManager.shared.find(for: owner)?.mam.allowHistoryFixTask = false
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.mam.allowHistoryFixTask = false
        })
        LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
        self.timelineSession?.cancelInitialFramePreparations()
        self.timelineSession?.cancelLocalPagePreparations()
        self.clearPendingLocalHistoryPagingPreparation()
        self.flushPendingVisibleReadTarget()
        self.saveCurrentVisibleMessagePositionIfNeeded(reason: .viewWillDisappear)

        unsubscribe()
        removeObservers()
        XMPPUIActionManager.shared.mam?.endLoadHistory(jid: self.jid, conversationType: conversationType)
        AccountManager.shared.find(for: self.owner)?.mam.endLoadHistory(jid: self.jid, conversationType: conversationType)
    }
    
    
    
    override public func addObservers() {
        guard !self.chatObserversRegistered else {
            return
        }
        self.lastAppliedChatKeyboardLayoutSignature = nil
        self.chatObserversRegistered = true
        super.addObservers()
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(self.didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: UIApplication.shared
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(reloadDatasource),
            name: .newMaskSelected,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(reloadDatasource),
            name: .chatInterfaceChanged,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(updateBackground),
            name: .chatBackgroundChanged,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(self.keyboardWillShowNotification(_:)),
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(self.keyboardWillHideNotification(_:)),
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(self.keyboardWillChangeFrameNotification(_:)),
            name: UIWindow.keyboardWillChangeFrameNotification,
            object: nil
        )
        chatNotificationCenter.addObserver(
            self,
            selector: #selector(self.onMeteringLevelDidUpdate(_:)),
            name: .recorderDidUpdateMeteringLevelNotification,
            object: nil
        )
    }
    
    var recordedPCM: [Float] = []
    
    @objc
    internal func willEnterForeground() {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        AccountManager.shared.find(for: self.owner)?.chatMarkers.updateDeleteEphemeralMessagesTimer()
    }
    
    @objc
    private func didEnterBackground() {
        handleApplicationDidEnterBackground()
    }

    internal func handleApplicationDidEnterBackground() {
        NotifyManager.shared.currentDialog = nil
        self.cancelActiveAudioRecordingForLifecycle()
        self.flushPendingVisibleReadTarget()
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: ChatBackgroundLastChatsKeyPolicy.primaryKey(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                )
            ) {
                try realm.write {
                    instance.isPrereaded = false
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func removeObservers() {
        guard self.chatObserversRegistered else {
            return
        }
        self.lastAppliedChatKeyboardLayoutSignature = nil
        self.chatObserversRegistered = false
        super.removeObservers()
//        NotificationCenter.default.removeObserver(self)
        
        
        chatNotificationCenter.removeObserver(
            self,
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
        chatNotificationCenter.removeObserver(
            self,
            name: UIApplication.didEnterBackgroundNotification,
            object: UIApplication.shared
        )
        chatNotificationCenter.removeObserver(
            self,
            name: .newMaskSelected,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: .chatInterfaceChanged,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: .chatBackgroundChanged,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: UIWindow.keyboardWillChangeFrameNotification,
            object: nil
        )
        chatNotificationCenter.removeObserver(
            self,
            name: .recorderDidUpdateMeteringLevelNotification,
            object: nil
        )
    }
    
//    internal func addMeteringObservers() {
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(didUpdateMeteringLevel),
//                                               name: .recorderDidUpdateMeteringLevelNotification,
//                                               object: AudioRecorder.shared)
//    }
    
    internal func removeMeteringObservers() {
        NotificationCenter.default.removeObserver(self,
                                                  name: .recorderDidUpdateMeteringLevelNotification,
                                                  object: UIApplication.shared)
    }
    
    private final func initSender() {
        self.ownerSender = Sender(
            id: self.owner,
            displayName: self.owner//AccountManager.shared.find(for: owner)?.username ?? ""
        )
        self.opponentSender = Sender(
            id: jid,
            displayName: jid
        )
    }
    
    internal let messageLoadingActivityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
    }
    
    @objc func updateBackground() {
        localChatBackdropView.reloadFromSettings()
        let backgroundResourceName = SettingManager.shared.getString(for: "chat_chooseBackground") ?? "None"
        if backgroundResourceName != "None" {
            backgroundImage.image = UIImage(named: backgroundResourceName.lowercased())?
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: UIEdgeInsets.zero,
                                resizingMode: .tile)
            backgroundImage.tintColor = .systemBackground
            backgroundImage.alpha = 0.1
            backgroundImage.contentMode = .scaleAspectFill
        } else {
            backgroundImage.image = nil
        }
        
        if conversationType.isEncrypted {
            gradient.colors = [
                CGColor(red: 253/255, green: 216/255, blue: 25/255, alpha: 1.0),
                CGColor(red: 232/255, green: 5/255, blue: 5/255, alpha: 1.0)
            ]
        } else {
            let backgroundResourceColor = SettingManager.shared.getString(for: "chat_chooseBackgroundColor") ?? "None"
            gradient.colors = ChatViewController.getColorsForGradient(forColor: BackgroundColor(rawValue: backgroundResourceColor) ?? .purple)
        }
    }
    
    override func reloadDatasource() {
        updateCornerStyle()
        self.applyChatDatasource(self.datasource, mode: .fullReload())
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.beginNavigationTransitionDeferralIfNeeded()
        self.recordChatOpenTimingViewWillAppear()
        self.refreshScrollBoundaryAvailabilityCache(reason: "viewWillAppear")
        self.didRunNavigationDisappearanceCleanup = false
        self.didScheduleNavigationDisappearanceCleanup = false
        do {
            try self.subscribe()
            if self.conversationType == .group {
                try self.groupSubscribtions()
            }
            if self.conversationType.isEncrypted {
                try self.encryptedSubscribtions()
            }
            self.addObservers()
            self.configureVoiceMessagePlaybackCoordinator()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        self.shouldChangeFrame()
        var inputHeight: CGFloat = ModernXabberInputView.defaultBarHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.updateChatCollectionInsets(inputHeight: inputHeight)

        self.lowPrioritySubscribtions()
        self.observeScheduledMessagesForComposerButton()
        self.setupEncryptedChat()
        self.initialHistoryAppearancePending = ChatInitialHistoryAppearancePolicy.shouldStart(
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
        self.hasRenderedStableInitialHistory = false
        self.hasCompletedInitialHistoryViewAppearance = false
        if self.datasource.isEmpty || self.pendingOpenMessageRequest != nil || self.activeAnchorExecutionState != nil {
            self.scheduleInitialDatasourceLoadAfterNavigationStart(
                performPendingOpenMessageRequest: !self.shouldDeferOpenMessageRequestsForNavigationTransition
            )
        }
        UIView.performWithoutAnimation {
            self.configureNavbar()
        }
        if self.inSearchMode.value {
            self.configureSearchModeForCurrentActivation(
                defaultActivateKeyboard: !self.isNavigationTransitionActive,
                defaultAnimated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                    requestedAnimated: true,
                    isTransitionActive: self.isNavigationTransitionActive,
                    isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                )
            )
        } else {
            self.searchTextObserver.accept(nil)
        }
    }

    internal func scheduleInitialDatasourceLoadAfterNavigationStart(
        performPendingOpenMessageRequest: Bool
    ) {
        self.recordChatOpenTimingInitialDatasourceLoadScheduled(
            performPendingOpenMessageRequest: performPendingOpenMessageRequest
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recordChatOpenTimingInitialDatasourceLoadDequeued(
                performPendingOpenMessageRequest: performPendingOpenMessageRequest
            )
            self.setFloatingDateVisible(false)
            self.loadInitialDatasource(
                performPendingOpenMessageRequest: performPendingOpenMessageRequest
            )
        }
    }
    
    
    internal func setupEncryptedChat() {
        if self.conversationType.isEncrypted {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                if CommonConfigManager.shared.config.required_time_signature_for_messages {
                    user.x509Manager.retrieveCert(stream, for: self.jid)
                }
            })
            AccountManager.shared.find(for: self.owner)?.omemo.prepareSecretChat(wit: self.jid, success: {
                
            }, fail: {
                DispatchQueue.main.async {
//                    self.showToast(error: "Can`t find any OMEMO device".localizeString(id: "message_manager_error_no_omemo", arguments: []))
                }
            })
            self.startWatchingSignatureTimer()
            if SignatureManager.shared.isSignatureSetted {
                self.onUpdateTimeSignatureBlockState(!SignatureManager.shared.isSignatureValid())
            }
        }
        self.setFloatingDateVisible(false)
        self.pinnedDateView.hide(withoutAnimation: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.isNavigationTransitionActive = false
        self.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = false
        self.flushPendingNavigationTransitionWork()
        if self.inSearchMode.value {
            self.configureSearchModeForCurrentActivation(
                defaultActivateKeyboard: true,
                defaultAnimated: false
            )
        } else {
            self.refreshNavigationAvatarImage()
        }
        self.suppressScrollDownButtonVisibilityAfterAppearance()
        self.hasCompletedInitialHistoryViewAppearance = true
        self.recordChatOpenTimingViewDidAppear()
        AccountManager.shared.find(for: self.owner)?
            .requestForegroundConnectionRecovery(trigger: .uiActionOpen)
        self.finishInitialHistoryAppearanceIfPossible()
        self.completeInitialLatestOpenStabilizationIfPossible()
        self.performPendingOpenMessageRequestIfNeeded()
        self.shouldChangeFrame()
        self.willUpdateFloatingDate()
        self.setFloatingDateHidden(true)
        self.setFloatingDateVisible(false)
        self.pinnedDateView.hide(withoutAnimation: true)
        self.addObservers()
        self.recordChatOpenTimingFirstMessagesVisibleIfPossible(
            reason: "viewDidAppear",
            modeDescription: "appearance"
        )
//        self.topPanelState.accept(.audioPlayer)
        
//        DispatchQueue.main.async {
//                guard self.messagesCollectionView.numberOfSections > 0,
//                      let lastIndexPath = self.messagesCollectionView.indexPathsForVisibleItems.max(by: { $0.section < $1.section || ($0.section == $1.section && $0.item < $1.item) }),
//                      self.messagesCollectionView.contentSize.height > self.messagesCollectionView.bounds.height else { return }
//                
//                // Scroll to visual bottom (last message) with flip: negative y offset
//                let bottomOffset = CGPoint(
//                    x: 0,
//                    y: -(self.messagesCollectionView.contentSize.height - self.messagesCollectionView.bounds.height)
//                )
//                self.messagesCollectionView.setContentOffset(bottomOffset, animated: false)
//            }
    }
    
    
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.flushPendingScrollWork()
        self.collectionPrefetchCoordinator.cancelAll()
        self.beginNavigationTransitionDeferralIfNeeded()
        if self.isMovingFromParent || self.isBeingDismissed || self.navigationController?.isBeingDismissed == true {
            self.invalidateNavigationAvatarItem()
            NavigationBarItemOwnership.clear(self.navigationItem, sides: [.right], animated: false)
        }
        self.cancelActiveAudioRecordingForLifecycle()
        omemoDeviceListTimer?.invalidate()
        omemoDeviceListTimer = nil

        if let coordinator = self.transitionCoordinator {
            self.didScheduleNavigationDisappearanceCleanup = true
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }
                self.isNavigationTransitionActive = false
                guard !context.isCancelled else {
                    self.didScheduleNavigationDisappearanceCleanup = false
                    return
                }
                self.runNavigationDisappearanceCleanupIfNeeded()
            }
        } else {
            self.runNavigationDisappearanceCleanupIfNeeded()
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !self.didScheduleNavigationDisappearanceCleanup {
            self.runNavigationDisappearanceCleanupIfNeeded()
        }
    }
    
    static func getColorsForGradient(forColor color: BackgroundColor) -> [CGColor] {
        switch color {
        case .purple:
            return [
                CGColor(red: 255/255, green: 122/255, blue: 245/255, alpha: 1),
                CGColor(red: 81/255, green: 49/255, blue: 98/255, alpha: 1)
            ]
            
        case .darkRed:
            return [
                CGColor(red: 205/255, green: 92/255, blue: 92/255, alpha: 0.5),
                CGColor(red: 220/255, green: 20/255, blue: 60/255, alpha: 1)
            ]
            
        case .lightRed:
            return [
                CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 0.5),
                CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 1)
            ]
            
        case .yellowOrange:
            return [
                CGColor(red: 255/255, green: 215/255, blue: 0/255, alpha: 1),
                CGColor(red: 255/255, green: 69/255, blue: 0/255, alpha: 1)
            ]
            
        case .yellowBlue:
            return [
                CGColor(red: 255/255, green: 215/255, blue: 0/255, alpha: 0.5),
                CGColor(red: 30/255, green: 144/255, blue: 255/255, alpha: 0.5)
            ]
            
        case .lightGreen:
            return [
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5),
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5)
            ]
            
        case .greenBlue:
            return [
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5),
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
            ]
            
        case .lightBlue:
            return [
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5),
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
            ]
        }
    }
    
    deinit {
        self.timelineSession?.cancelLocalPagePreparations()
        self.scheduledMessagesComposerButtonToken?.invalidate()
        self.unsubscribe()
        self.removeObservers()
        self.clearMemoryCache()
    }
}

extension ChatViewController {
    internal func refreshScheduledMessagesComposerButtonState() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshScheduledMessagesComposerButtonState()
            }
            return
        }
        guard let inputView = self.xabberInputView else { return }
        let hasScheduledMessages: Bool
        do {
            let realm = try WRealm.safe()
            hasScheduledMessages = ScheduledMessagesComposerButtonModel.hasRows(
                owner: self.owner,
                conversation: self.jid,
                conversationType: self.conversationType,
                realm: realm
            )
        } catch {
            hasScheduledMessages = false
        }
        inputView.hasScheduledMessagesForCurrentChat = hasScheduledMessages
        inputView.refreshComposerChrome()
    }

    private func observeScheduledMessagesForComposerButton() {
        self.scheduledMessagesComposerButtonToken?.invalidate()
        guard let realm = try? WRealm.safe() else {
            self.xabberInputView?.hasScheduledMessagesForCurrentChat = false
            return
        }
        let results = ScheduledMessagesComposerButtonModel.results(
            owner: self.owner,
            conversation: self.jid,
            conversationType: self.conversationType,
            realm: realm
        )
        self.refreshScheduledMessagesComposerButtonState()
        self.scheduledMessagesComposerButtonToken = results.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .initial, .update:
                self.refreshScheduledMessagesComposerButtonState()
            case .error:
                self.xabberInputView?.hasScheduledMessagesForCurrentChat = false
            }
        }
    }
}

extension ChatViewController {
    internal func configureVoiceMessagePlaybackCoordinator() {
        VoiceMessagePlaybackCoordinator.shared.removeObserver(self.voiceMessageStateObserverToken)
        self.voiceMessageStateObserverToken = VoiceMessagePlaybackCoordinator.shared.addObserver { [weak self] change in
            DispatchQueue.main.async {
                self?.handleVoiceMessageStateChange(change)
            }
        }
        self.updateVisibleVoiceMessageQueue()
        if VoiceMessagePlaybackCoordinator.shared.hasActivePlayback {
            self.configureSharedAudioPanel()
        }
    }

    private func handleVoiceMessageStateChange(_ change: VoiceMessageStateChange) {
        if change.containerMessagePrimary.isNotEmpty {
            self.updateVisibleMessageContent(primary: change.containerMessagePrimary)
        }

        switch change.state {
        case .playing:
            self.configureSharedAudioPanel()
            self.sharedPlayerPaneldelegae?.shouldShow()
            self.sharedPlayerPaneldelegae?.shouldPlay()
        case .paused:
            self.configureSharedAudioPanel()
            self.sharedPlayerPaneldelegae?.shouldShow()
            self.sharedPlayerPaneldelegae?.shouldPause()
        default:
            if change.previousState?.isActivePlayback == true,
               !VoiceMessagePlaybackCoordinator.shared.hasActivePlayback {
                self.hideSharedAudioPanel()
                self.sharedPlayerPaneldelegae?.shouldHide()
            }
        }
    }

    internal func updateVisibleVoiceMessageQueue() {
        let visible = self.scrollResidentMetadata.capture(
            indexPaths: self.messagesCollectionView.indexPathsForVisibleItems
        )
        guard let descriptors = self.scrollFramePlanner.voiceDescriptorsIfChanged(in: visible) else {
            return
        }
        VoiceMessagePlaybackCoordinator.shared.setVisibleVoiceMessages(descriptors)
    }

    internal func voiceMessageDescriptor(referencePrimary: String) -> VoiceMessageDescriptor? {
        for item in datasource {
            if let descriptor = voiceMessageDescriptor(referencePrimary: referencePrimary, in: item) {
                return descriptor
            }
        }
        return voiceMessageDescriptorFromRealm(referencePrimary: referencePrimary, containerPrimary: nil, sentDate: Date.distantPast)
    }

    internal func visibleVoiceMessageDescriptors() -> [VoiceMessageDescriptor] {
        self.scrollResidentMetadata
            .capture(indexPaths: messagesCollectionView.indexPathsForVisibleItems)
            .rows
            .flatMap(\.voiceDescriptors)
    }

    private func voiceMessageDescriptor(referencePrimary: String, in item: Datasource) -> VoiceMessageDescriptor? {
        if let audio = item.audios.first(where: { $0.primary == referencePrimary }) {
            return voiceMessageDescriptor(audio: audio, containerPrimary: item.primary, sentDate: item.sentDate)
        }
        return ChatPreparedVoiceTraversal.prepare(
            roots: item.forwards,
            budget: ChatPreparedVoiceTraversalBudget(maxDepth: 6, maxVisitedNodes: 64),
            children: \.subforwards,
            descriptors: { attachment in
                guard let audio = attachment.audios.first(where: { $0.primary == referencePrimary }),
                      let descriptor = voiceMessageDescriptor(
                        audio: audio,
                        containerPrimary: item.primary,
                        sentDate: item.sentDate
                      ) else {
                    return []
                }
                return [descriptor]
            }
        ).descriptors.first
    }

    internal func voiceMessageDescriptor(
        audio: AudioAttachment,
        containerPrimary: String,
        sentDate: Date
    ) -> VoiceMessageDescriptor? {
        let fallback = VoiceMessageDescriptor(
            referencePrimary: audio.primary,
            containerMessagePrimary: containerPrimary,
            remoteURL: nil,
            decodedURL: audio.url,
            duration: TimeInterval(audio.duration),
            downloaded: audio.downloaded || audio.url != nil,
            pcm: audio.pcm,
            sentDate: sentDate
        )
        return voiceMessageDescriptorFromRealm(
            referencePrimary: audio.primary,
            containerPrimary: containerPrimary,
            sentDate: sentDate,
            fallback: fallback
        )
    }

    private func voiceMessageDescriptorFromRealm(
        referencePrimary: String,
        containerPrimary: String?,
        sentDate: Date,
        fallback: VoiceMessageDescriptor? = nil
    ) -> VoiceMessageDescriptor? {
        do {
            let realm = try WRealm.safe()
            guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) else {
                return fallback
            }
            let decodedURL = reference.decodedUrl ?? fallback?.decodedURL
            let downloaded = reference.isDownloaded || decodedURL != nil || fallback?.downloaded == true
            return VoiceMessageDescriptor(
                referencePrimary: reference.primary,
                containerMessagePrimary: containerPrimary ?? reference.messageId,
                remoteURL: reference.downloadUrl,
                decodedURL: decodedURL,
                duration: TimeInterval(reference.duration ?? Int(fallback?.duration ?? 0)),
                downloaded: downloaded,
                pcm: reference.meteringLevels ?? fallback?.pcm ?? [],
                sentDate: sentDate == Date.distantPast ? reference.sentDate : sentDate
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return fallback
        }
    }
}

extension ChatViewController: StackedNavigationPresentationPreparing, AsyncStackedNavigationPresentationPreparing {
    func prepareForStackedNavigationPresentation(targetBounds: CGRect?) {
        self.prepareForStackedNavigationPresentation(
            targetBounds: targetBounds,
            completion: {}
        )
    }

    func prepareForStackedNavigationPresentation(
        targetBounds: CGRect?,
        completion: @escaping () -> Void
    ) {
        self.beginChatOpenTimingSessionIfNeeded(
            trigger: "stackedNavigationPreparation",
            targetBounds: targetBounds
        )
        self.isPreparingStackedNavigationPresentation = true
        self.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = true
        self.loadViewIfNeeded()

        if let targetBounds,
           targetBounds.width > 0,
           targetBounds.height > 0 {
            self.view.frame = CGRect(origin: .zero, size: targetBounds.size)
            UIView.performWithoutAnimation {
                self.configureBackground()
            }
        }

        var shouldLoadInitialDatasource = false
        UIView.performWithoutAnimation {
            self.configureNavbar()
            self.initialHistoryAppearancePending = ChatInitialHistoryAppearancePolicy.shouldStart(
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
            )
            self.hasRenderedStableInitialHistory = false
            self.hasCompletedInitialHistoryViewAppearance = false
            self.updateChatCollectionInsets()
            self.setFloatingDateVisible(false)
            shouldLoadInitialDatasource = ChatStackedNavigationPreparationPolicy.shouldLoadInitialDatasource(
                isDatasourceEmpty: self.datasource.isEmpty,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
            )
        }

        guard shouldLoadInitialDatasource else {
            self.isPreparingStackedNavigationPresentation = false
            completion()
            return
        }
        self.loadInitialDatasource(performPendingOpenMessageRequest: false) { [weak self] in
            self?.isPreparingStackedNavigationPresentation = false
            completion()
        }
    }
}

protocol TappedPhotoInMediaGalleryDelegate {
    func didTapPhotoFromChat(primary: String)
    func didTapPhotoFromGallery(primary: String)
    func showInputBar()
}

extension ChatViewController: TappedPhotoInMediaGalleryDelegate {
    
    func showInputBar() {
        
    }
    
    func didTapPhotoFromChat(primary: String) {
        
    }
    
    func didTapPhotoFromGallery(primary: String) {
        navigationController?.popViewController(animated: true)
    }
    
}
