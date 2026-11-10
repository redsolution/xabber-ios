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
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import DeepDiff
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import XMPPFramework.XMPPJID
import AVFoundation

enum LastChatsNotificationAuthorizationPromptPolicy {
    static func shouldRequest(
        isLastChatsVisible: Bool,
        applicationState: UIApplication.State,
        sceneActivationState: UIScene.ActivationState?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard isLastChatsVisible,
              applicationState == .active,
              sceneActivationState == .foregroundActive,
              environment[
                AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey
              ] == nil else {
            return false
        }

        #if DEBUG || CHAT_PERFORMANCE_LAB
        guard ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: environment
        ) == nil else {
            return false
        }
        #endif

        return true
    }
}

enum LastChatsNavigationTransitionMutationPolicy {
    static func shouldDeferMutation(
        isTransitionActive: Bool,
        isCriticalForFirstFrame: Bool
    ) -> Bool {
        isTransitionActive && !isCriticalForFirstFrame
    }

    static func shouldAnimateMutation(
        requestedAnimated: Bool,
        isTransitionActive: Bool
    ) -> Bool {
        requestedAnimated && !isTransitionActive
    }

}

enum LastChatsBootstrapDatasetUpdatePolicy {
    enum DeferredDatasetUpdateAction: Equatable {
        case none
        case flush
        case drop
    }

    static let coalescingDelay: TimeInterval = 0.18

    static func isDatasetUpdatePressureActive(
        isAccountSyncBootstrapActive: Bool,
        isChatHistoryLoadActive: Bool,
        isChatUIResponsivenessGateActive: Bool = false
    ) -> Bool {
        isAccountSyncBootstrapActive || isChatHistoryLoadActive || isChatUIResponsivenessGateActive
    }

    static func shouldDeferDatasetUpdateForNavigationTransition(
        isBootstrapActive: Bool,
        isNavigationTransitionActive: Bool
    ) -> Bool {
        isBootstrapActive && isNavigationTransitionActive
    }

    static func shouldCoalesceDatasetUpdate(
        isBootstrapActive: Bool,
        hasScheduledUpdate: Bool
    ) -> Bool {
        isBootstrapActive && !hasScheduledUpdate
    }

    static func shouldCoalesceDatasetUpdate(
        isDatasetUpdatePressureActive: Bool,
        hasScheduledUpdate: Bool
    ) -> Bool {
        isDatasetUpdatePressureActive && !hasScheduledUpdate
    }

    static func shouldAnimateDatasetMutation(
        requestedAnimated: Bool,
        isBootstrapActive: Bool
    ) -> Bool {
        requestedAnimated && !isBootstrapActive
    }

    static func shouldAnimateDatasetMutation(
        requestedAnimated: Bool,
        isDatasetUpdatePressureActive: Bool
    ) -> Bool {
        requestedAnimated && !isDatasetUpdatePressureActive
    }

    static func shouldSkipVisibleRowReconfigure(isBootstrapActive: Bool) -> Bool {
        isBootstrapActive
    }

    static func shouldSkipVisibleRowReconfigure(isDatasetUpdatePressureActive: Bool) -> Bool {
        isDatasetUpdatePressureActive
    }

    static func deferredDatasetUpdateAction(
        cancelled: Bool,
        hasPendingUpdate: Bool
    ) -> DeferredDatasetUpdateAction {
        guard hasPendingUpdate else {
            return .none
        }
        // A cancelled navigation transition invalidates captured UI closures,
        // but the latest Realm-backed dataset still needs one fresh render.
        return .flush
    }
}

enum LastChatsFirstDatasetApplyOwnershipPolicy {
    static func pendingAfterCycle(
        wasPending: Bool,
        didCommitDatasetApply: Bool
    ) -> Bool {
        wasPending && !didCommitDatasetApply
    }
}

enum LastChatsProjectionInvalidation: Hashable {
    case roster
    case resource
    case vCard(String)
}

/// Batches presentation-only Realm/notification invalidations. Roster and
/// resource writes often accompany the same persisted vCard, so treating
/// their observers as independent dataset requests needlessly remaps and
/// diffs the entire chat list more than once for one visible state change.
struct LastChatsProjectionRefreshCoalescer {
    struct Registration: Equatable {
        let shouldRescheduleQuietFlush: Bool
        let shouldScheduleDeadline: Bool
    }

    static let quietDelay: TimeInterval = 0.45
    static let maximumDelay: TimeInterval = 2.0

    private var pendingInvalidations = Set<LastChatsProjectionInvalidation>()
    private var hasScheduledDeadline = false

    var pendingInvalidationCount: Int {
        pendingInvalidations.count
    }

    mutating func register(
        _ invalidation: LastChatsProjectionInvalidation
    ) -> Registration {
        pendingInvalidations.insert(invalidation)
        let shouldScheduleDeadline = !hasScheduledDeadline
        hasScheduledDeadline = true
        return Registration(
            shouldRescheduleQuietFlush: true,
            shouldScheduleDeadline: shouldScheduleDeadline
        )
    }

    mutating func flush() -> Set<LastChatsProjectionInvalidation> {
        let invalidations = pendingInvalidations
        pendingInvalidations.removeAll(keepingCapacity: true)
        hasScheduledDeadline = false
        return invalidations
    }

    mutating func cancel() {
        pendingInvalidations.removeAll(keepingCapacity: true)
        hasScheduledDeadline = false
    }
}

enum LastChatsDatasourceApplyPolicy: Equatable {
    case detachedSnapshot
    case incrementalDiff

    static func resolve(isTableAttachedToWindow: Bool) -> Self {
        isTableAttachedToWindow ? .incrementalDiff : .detachedSnapshot
    }
}

enum LastChatsTableStylePolicy {
    static func style(for _: UIUserInterfaceSizeClass) -> UITableView.Style {
        .insetGrouped
    }
}

enum LastChatsSelectionReturnPolicy {
    static func shouldClearSelectedChat(route: StackedNavigationRoute) -> Bool {
        route == .currentNavigationPush
    }
}

struct LastChatsNavigationSingleFlightCoordinator {
    /// The destination owns the 450-ms first-frame fallback. This outer guard
    /// must run later; scheduling both at the same deadline lets the source
    /// cancel the handle immediately before it commits skeleton and pushes.
    static let defaultPreparationTimeout: TimeInterval =
        StackedNavigationPresentationTimingPolicy
            .asynchronousPreparationFallbackDelay + 0.55

    struct Target: Equatable {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }

    enum Phase: Equatable {
        case preparing
        case pushing
        case presented
    }

    struct State: Equatable {
        let token: UUID
        let target: Target
        var phase: Phase
    }

    enum RequestDecision: Equatable {
        case started(UUID)
        case coalesced(UUID)
        case ignored(UUID)
    }

    private(set) var state: State?

    mutating func request(target: Target, token: UUID = UUID()) -> RequestDecision {
        guard let state else {
            self.state = State(token: token, target: target, phase: .preparing)
            return .started(token)
        }

        switch state.phase {
        case .preparing:
            guard state.target != target else {
                return .coalesced(state.token)
            }
            self.state = State(token: token, target: target, phase: .preparing)
            return .started(token)
        case .pushing, .presented:
            return .ignored(state.token)
        }
    }

    func isPreparing(token: UUID, target: Target) -> Bool {
        guard let state else {
            return false
        }
        return state.token == token && state.target == target && state.phase == .preparing
    }

    @discardableResult
    mutating func markPushing(token: UUID, target: Target) -> Bool {
        guard isPreparing(token: token, target: target) else {
            return false
        }
        state?.phase = .pushing
        return true
    }

    @discardableResult
    mutating func markPresented(token: UUID, target: Target) -> Bool {
        guard let state,
              state.token == token,
              state.target == target,
              state.phase == .pushing else {
            return false
        }
        self.state?.phase = .presented
        return true
    }

    @discardableResult
    mutating func cancel(token: UUID) -> Bool {
        guard state?.token == token else {
            return false
        }
        state = nil
        return true
    }

    mutating func reset() {
        state = nil
    }
}

struct LastChatsRetainedCompactChatNavigationDestination {
    let token: UUID
    let target: LastChatsNavigationSingleFlightCoordinator.Target
    let controller: ChatViewController
    let accountEpoch: LastChatsChatNavigationAccountEpoch?
}

private struct LastChatsNavigationReturnTransitionCompletion {
    let token: UUID
    let cancelled: Bool
}

enum ChatOpenNavigationSource: Equatable {
    case standard
    case notification
}

enum LastChatsResolvedChatOpenIntent: Equatable {
    case message(ChatOpenMessageRequest)
    case latest
}

struct LastChatsChatOpenIntentOwnership {
    let target: LastChatsNavigationSingleFlightCoordinator.Target
    let destinationIdentifier: ObjectIdentifier
    let intent: LastChatsResolvedChatOpenIntent
    var navigationSource: ChatOpenNavigationSource
}

struct LastChatsChatNavigationAccountEpoch: Equatable {
    let accountIdentifier: ObjectIdentifier?
    let isPresent: Bool
    let isEnabled: Bool

    init(
        accountIdentifier: ObjectIdentifier?,
        isPresent: Bool? = nil,
        isEnabled: Bool
    ) {
        self.accountIdentifier = accountIdentifier
        self.isPresent = isPresent ?? (accountIdentifier != nil)
        self.isEnabled = isEnabled
    }

    var isValidForChatNavigation: Bool {
        accountIdentifier != nil && isPresent && isEnabled
    }

    func isExactValidMatch(
        for currentEpoch: LastChatsChatNavigationAccountEpoch
    ) -> Bool {
        isValidForChatNavigation &&
            currentEpoch.isValidForChatNavigation &&
            self == currentEpoch
    }
}

struct LastChatsExpandedSplitSecondarySnapshot {
    let container: UIViewController?
    let topViewController: UIViewController?
}

struct LastChatsExpandedSplitPresentationState: Equatable {
    let hasActiveTransition: Bool
    let hasPresentedModal: Bool

    static let stable = LastChatsExpandedSplitPresentationState(
        hasActiveTransition: false,
        hasPresentedModal: false
    )
}

struct LastChatsExpandedSplitEligibilityFingerprint: Equatable {
    let route: StackedNavigationRoute
    let accountEpoch: LastChatsChatNavigationAccountEpoch
    let isApplicationActive: Bool
    let windowIdentifier: ObjectIdentifier?
    let isWindowVisible: Bool
    let isKeyWindow: Bool
    let isForegroundActiveScene: Bool
    let supplementaryContainerIdentifier: ObjectIdentifier?
    let supplementaryTopIdentifier: ObjectIdentifier?
    let secondaryContainerIdentifier: ObjectIdentifier?
    let secondaryTopIdentifier: ObjectIdentifier?
    let hasActiveTransition: Bool
    let presentedControllerIdentifier: ObjectIdentifier?
}

/// Adapts the existing compact Last Chats push transaction to an off-screen
/// navigation stack. Last Chats remains the owner of preparation, account
/// epoch validation, single-flight state, and the destination push; the caller
/// only validates and atomically installs the already-topped stack.
final class LastChatsCompactActivationContext {
    let navigationController: UINavigationController
    let validateBeforePush: () -> Bool
    let prepareNavigationControllerForPush: () -> Bool
    let installPreparedNavigationController: (
        _ destination: ChatViewController,
        _ completion: @escaping (Bool) -> Void
    ) -> Void
    let fallback: () -> Void

    init(
        navigationController: UINavigationController,
        validateBeforePush: @escaping () -> Bool,
        prepareNavigationControllerForPush: @escaping () -> Bool,
        installPreparedNavigationController: @escaping (
            _ destination: ChatViewController,
            _ completion: @escaping (Bool) -> Void
        ) -> Void,
        fallback: @escaping () -> Void
    ) {
        self.navigationController = navigationController
        self.validateBeforePush = validateBeforePush
        self.prepareNavigationControllerForPush =
            prepareNavigationControllerForPush
        self.installPreparedNavigationController =
            installPreparedNavigationController
        self.fallback = fallback
    }
}

/// Describes an off-screen Last Chats column that may be installed only after
/// the destination chat has finished preparing its first frame. The closures
/// deliberately capture their owners weakly; the transaction must not retain a
/// detached split root while an asynchronous preparation is outstanding.
final class LastChatsExpandedSplitActivationContext {
    weak var splitViewController: UISplitViewController?
    weak var presentationPresenter: UIViewController?
    let expectedSupplementaryContainerIdentifier: ObjectIdentifier?
    let expectedSupplementaryTopViewControllerIdentifier: ObjectIdentifier?
    let validate: () -> Bool
    let commit: () -> Bool
    let validateAfterPresentation: ((ChatViewController) -> Bool)?
    let validationFailure: (() -> Void)?

    init(
        splitViewController: UISplitViewController,
        presentationPresenter: UIViewController,
        expectedSupplementaryContainerIdentifier: ObjectIdentifier?,
        expectedSupplementaryTopViewControllerIdentifier: ObjectIdentifier?,
        validate: @escaping () -> Bool,
        commit: @escaping () -> Bool,
        validateAfterPresentation: ((ChatViewController) -> Bool)? = nil,
        validationFailure: (() -> Void)? = nil
    ) {
        self.splitViewController = splitViewController
        self.presentationPresenter = presentationPresenter
        self.expectedSupplementaryContainerIdentifier =
            expectedSupplementaryContainerIdentifier
        self.expectedSupplementaryTopViewControllerIdentifier =
            expectedSupplementaryTopViewControllerIdentifier
        self.validate = validate
        self.commit = commit
        self.validateAfterPresentation = validateAfterPresentation
        self.validationFailure = validationFailure
    }
}

struct LastChatsExpandedSplitChatNavigationTransaction {
    enum Phase: Equatable {
        case preparing
        case waitingForEligibility
        case presenting
        case presented
    }

    let token: UUID
    let target: LastChatsNavigationSingleFlightCoordinator.Target
    let destination: ChatViewController
    let previousVisibleDetail: ChatViewController?
    let previousSecondarySnapshot: LastChatsExpandedSplitSecondarySnapshot
    let accountEpoch: LastChatsChatNavigationAccountEpoch
    let navigationSource: ChatOpenNavigationSource
    let expectedSupplementaryContainerIdentifier: ObjectIdentifier?
    let expectedSupplementaryTopViewControllerIdentifier: ObjectIdentifier?
    var activationContext: LastChatsExpandedSplitActivationContext?
    var preparationHandle: StackedNavigationPresentationPreparationHandle?
    var phase: Phase
    var lastRejectedEligibilityFingerprint:
        LastChatsExpandedSplitEligibilityFingerprint?
    var permitsOneUnchangedEligibilityRetry: Bool

    func replacingNavigationSource(
        _ navigationSource: ChatOpenNavigationSource
    ) -> LastChatsExpandedSplitChatNavigationTransaction {
        LastChatsExpandedSplitChatNavigationTransaction(
            token: token,
            target: target,
            destination: destination,
            previousVisibleDetail: previousVisibleDetail,
            previousSecondarySnapshot: previousSecondarySnapshot,
            accountEpoch: accountEpoch,
            navigationSource: navigationSource,
            expectedSupplementaryContainerIdentifier:
                expectedSupplementaryContainerIdentifier,
            expectedSupplementaryTopViewControllerIdentifier:
                expectedSupplementaryTopViewControllerIdentifier,
            activationContext: activationContext,
            preparationHandle: preparationHandle,
            phase: phase,
            lastRejectedEligibilityFingerprint:
                lastRejectedEligibilityFingerprint,
            permitsOneUnchangedEligibilityRetry:
                permitsOneUnchangedEligibilityRetry
        )
    }

    func replacingAccountEpoch(
        _ accountEpoch: LastChatsChatNavigationAccountEpoch
    ) -> LastChatsExpandedSplitChatNavigationTransaction {
        LastChatsExpandedSplitChatNavigationTransaction(
            token: token,
            target: target,
            destination: destination,
            previousVisibleDetail: previousVisibleDetail,
            previousSecondarySnapshot: previousSecondarySnapshot,
            accountEpoch: accountEpoch,
            navigationSource: navigationSource,
            expectedSupplementaryContainerIdentifier:
                expectedSupplementaryContainerIdentifier,
            expectedSupplementaryTopViewControllerIdentifier:
                expectedSupplementaryTopViewControllerIdentifier,
            activationContext: activationContext,
            preparationHandle: preparationHandle,
            phase: phase,
            lastRejectedEligibilityFingerprint:
                lastRejectedEligibilityFingerprint,
            permitsOneUnchangedEligibilityRetry:
                permitsOneUnchangedEligibilityRetry
        )
    }

    func replacingSupplementaryIdentity(
        containerIdentifier: ObjectIdentifier?,
        topViewControllerIdentifier: ObjectIdentifier?
    ) -> LastChatsExpandedSplitChatNavigationTransaction {
        LastChatsExpandedSplitChatNavigationTransaction(
            token: token,
            target: target,
            destination: destination,
            previousVisibleDetail: previousVisibleDetail,
            previousSecondarySnapshot: previousSecondarySnapshot,
            accountEpoch: accountEpoch,
            navigationSource: navigationSource,
            expectedSupplementaryContainerIdentifier: containerIdentifier,
            expectedSupplementaryTopViewControllerIdentifier:
                topViewControllerIdentifier,
            activationContext: activationContext,
            preparationHandle: preparationHandle,
            phase: phase,
            lastRejectedEligibilityFingerprint:
                lastRejectedEligibilityFingerprint,
            permitsOneUnchangedEligibilityRetry:
                permitsOneUnchangedEligibilityRetry
        )
    }
}

typealias LastChatsExpandedSplitChatPresentationHandler = (
    _ destination: ChatViewController,
    _ presenter: UIViewController,
    _ commitPresentation: @escaping () -> Bool,
    _ completion: @escaping (Bool) -> Void
) -> StackedNavigationPresentationPreparationHandle

enum LastChatsChatOpenAcknowledgementPolicy {
    static func shouldAcknowledge(
        navigationSource: ChatOpenNavigationSource,
        request: ChatOpenMessageRequest?,
        isStableVisibleDestination: Bool,
        hasStableTargetAcknowledgement: Bool
    ) -> Bool {
        guard navigationSource == .notification else {
            return true
        }
        return isStableVisibleDestination && hasStableTargetAcknowledgement
    }

    static func shouldAcknowledge(
        request: ChatOpenMessageRequest?,
        isStableVisibleDestination: Bool,
        hasStableTargetAcknowledgement: Bool = false
    ) -> Bool {
        shouldAcknowledge(
            navigationSource: request?.source == .pushNotification
                ? .notification
                : .standard,
            request: request,
            isStableVisibleDestination: isStableVisibleDestination,
            hasStableTargetAcknowledgement: hasStableTargetAcknowledgement
        )
    }
}

enum LastChatsNavigationPreparationCancellationReason {
    case presentationGuardRejected
    case preparationTimedOut
}

enum LastChatsNavigationPresenterIdentityPolicy {
    static func shouldCommit(
        expectedNavigationController: UINavigationController?,
        currentNavigationController: UINavigationController?,
        isPresenterTopViewController: Bool,
        isPresenterVisibleInWindow: Bool,
        isPresenterInSelectedTabHierarchy: Bool,
        isForegroundActiveScene: Bool,
        isCurrentNavigationPushRoute: Bool,
        presenterHasPresentedViewController: Bool,
        navigationControllerHasPresentedViewController: Bool
    ) -> Bool {
        guard let expectedNavigationController,
              let currentNavigationController,
              expectedNavigationController === currentNavigationController else {
            return false
        }
        return isPresenterTopViewController &&
            isPresenterVisibleInWindow &&
            isPresenterInSelectedTabHierarchy &&
            isForegroundActiveScene &&
            isCurrentNavigationPushRoute &&
            !presenterHasPresentedViewController &&
            !navigationControllerHasPresentedViewController
    }
}

enum LastChatsNavigationPresenterHierarchyPolicy {
    static func isInSelectedTabHierarchy(_ presenter: UIViewController) -> Bool {
        guard let tabBarController = presenter.tabBarController else {
            return true
        }
        guard let selectedViewController = tabBarController.selectedViewController else {
            return false
        }

        var current: UIViewController? = presenter
        while let candidate = current {
            if candidate === selectedViewController {
                return true
            }
            current = candidate.parent
        }
        return false
    }
}

public final class ChangesWithIndexPath {
    public let insertedSections: IndexSet
    public let deletedSections: IndexSet
    public let inserts: [IndexPath]
    public let deletes: [IndexPath]
    public var replaces: [IndexPath]
    public let moves: [(from: IndexPath, to: IndexPath)]

    public init(
        insertedSections: IndexSet = IndexSet(),
        deletedSections: IndexSet = IndexSet(),
        inserts: [IndexPath],
        deletes: [IndexPath],
        replaces: [IndexPath],
        moves: [(from: IndexPath, to: IndexPath)]
    ) {
        self.insertedSections = insertedSections
        self.deletedSections = deletedSections
        self.inserts = inserts
        self.deletes = deletes
        self.replaces = replaces
        self.moves = moves
    }
}

protocol SharedAudioPlayerPanelDelegate: AnyObject {
    func shouldShow()
    func shouldHide()
    func shouldPlay()
    func shouldPause()
}

enum AudioPlayerBarEffectFactory {
    static var fallbackBlurStyle: UIBlurEffect.Style {
        XabberGlassStyle.fallbackBlurStyle(for: .audioPlayer)
    }

    static func makeEffect(prefersNativeGlass: Bool = true) -> UIVisualEffect {
        XabberGlassStyle.makeEffect(
            role: .audioPlayer,
            interactive: true,
            prefersNativeGlass: prefersNativeGlass
        )
    }
}

enum AudioPlayerBarIconButtonStyle {
    static let buttonSize: CGFloat = 44
    static let contentInset: CGFloat = 8
    static let adjacentSpacing: CGFloat = 4
    static let compactXmarkPointSize: CGFloat = 13
    static let tintColor: UIColor = .label

    static func makeButton(accessibilityLabel: String? = nil) -> UIButton {
        let button = UIButton(type: .system)
        apply(to: button)
        button.accessibilityLabel = accessibilityLabel
        return button
    }

    static func apply(to button: UIButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = tintColor
        button.backgroundColor = .clear
        button.configuration = nil
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.adjustsImageWhenHighlighted = true
        button.adjustsImageWhenDisabled = true
    }

    static func setSystemIcon(named iconName: String, on button: UIButton) {
        setTemplateIcon(UIImage(systemName: iconName), on: button)
    }

    static func setSystemIcon(named iconName: String, pointSize: CGFloat, on button: UIButton) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        setTemplateIcon(UIImage(systemName: iconName, withConfiguration: configuration), on: button)
    }

    static func setTemplateIcon(_ image: UIImage?, on button: UIButton) {
        apply(to: button)
        button.setImage(image?.withRenderingMode(.alwaysTemplate), for: .normal)
    }
}

protocol AudioPlayerBarViewDelegate: AnyObject {
    func audioPlayerBarViewDidTapClose(_ view: AudioPlayerBarView)
    func audioPlayerBarViewDidTapPlayPause(_ view: AudioPlayerBarView)
    func audioPlayerBarViewDidTapTitle(_ view: AudioPlayerBarView)
}

enum LastChatsPinnedVoicePlayerInsetPolicy {
    static func adjustedContentOffsetY(
        currentY: CGFloat,
        insetDelta: CGFloat,
        minimumY: CGFloat,
        maximumY: CGFloat
    ) -> CGFloat {
        let proposedY = currentY - insetDelta
        return min(max(proposedY, minimumY), maximumY)
    }
}

final class AudioPlayerBarView: UIView {
    enum Metrics {
        static let height: CGFloat = 44
        static let horizontalInset: CGFloat = 12
        static let topOffset: CGFloat = 4
        static let bottomGap: CGFloat = 8
        static let reservedTopInset: CGFloat = height + topOffset + bottomGap
        static let buttonSize: CGFloat = AudioPlayerBarIconButtonStyle.buttonSize
        static let contentInset: CGFloat = AudioPlayerBarIconButtonStyle.contentInset
    }

    let effectView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: AudioPlayerBarEffectFactory.makeEffect())
        view.translatesAutoresizingMaskIntoConstraints = false
        XabberGlassStyle.applySurface(
            to: view,
            role: .audioPlayer,
            cornerStyle: .capsule,
            interactive: true
        )
        return view
    }()

    let playPauseButton: UIButton = {
        AudioPlayerBarIconButtonStyle.makeButton(accessibilityLabel: L10n.text("last_chats__accessibility__play_or_pause_voice_message", fallback: "Play or pause voice message"))
    }()

    let titleControl: UIControl = {
        let control = UIControl(frame: .zero)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.accessibilityTraits.insert(.button)
        return control
    }()

    private let titleStack: UIStackView = {
        let stack = UIStackView(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 1
        stack.isUserInteractionEnabled = false
        return stack
    }()

    let titleLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    let subtitleLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    let timeLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    let closeButton: UIButton = {
        AudioPlayerBarIconButtonStyle.makeButton(accessibilityLabel: L10n.text("last_chats__accessibility__close_voice_player", fallback: "Close voice player"))
    }()

    weak var delegate: AudioPlayerBarViewDelegate?
    private(set) var renderedPlayPauseIconName: String = "play.fill"
    private(set) var state: PlayState = .paused

    enum PlayState {
        case playing
        case paused
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        render(snapshot: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(snapshot: VoiceMessagePlaybackSnapshot?) {
        guard let snapshot else {
            isHidden = true
            titleLabel.text = nil
            subtitleLabel.text = nil
            timeLabel.text = "0:00 / 0:00"
            setPlayPauseIcon(named: "play.fill")
            return
        }

        isHidden = false
        titleLabel.text = snapshot.title ?? L10n.text("chat_list__attachment_preview__voice_message", fallback: "Voice message")
        subtitleLabel.text = snapshot.subtitle ?? L10n.text("chat_list__attachment_preview__voice_message", fallback: "Voice message")
        titleControl.accessibilityLabel = [titleLabel.text, subtitleLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")

        let playbackTimes = Self.playbackTimes(for: snapshot.state)
        let duration = playbackTimes.duration > 0 ? playbackTimes.duration : 0
        let currentTime = min(max(playbackTimes.currentTime, 0), duration)
        timeLabel.text = "\(currentTime.minuteFormatedString) / \(duration.minuteFormatedString)"

        switch snapshot.state {
        case .playing:
            swapState(to: .playing)
        default:
            swapState(to: .paused)
        }
    }

    func render(
        title: String?,
        subtitle: String?,
        state: PlayState,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        isHidden: Bool = false
    ) {
        self.isHidden = isHidden
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleControl.accessibilityLabel = [title, subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")

        let safeDuration = max(duration, 0)
        let safeCurrentTime = min(max(currentTime, 0), safeDuration)
        timeLabel.text = "\(safeCurrentTime.minuteFormatedString) / \(safeDuration.minuteFormatedString)"
        swapState(to: state)
    }

    func refreshAppearance() {
        effectView.effect = AudioPlayerBarEffectFactory.makeEffect()
        effectView.layer.borderColor = UIColor.separator.withAlphaComponent(0.32).cgColor
    }

    func swapState(to newState: PlayState? = nil) {
        if let newState {
            state = newState
        } else {
            state = state == .playing ? .paused : .playing
        }
        switch state {
        case .playing:
            setPlayPauseIcon(named: "pause.fill")
        case .paused:
            setPlayPauseIcon(named: "play.fill")
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false

        addSubview(effectView)
        let contentView = effectView.contentView
        contentView.addSubview(playPauseButton)
        contentView.addSubview(titleControl)
        contentView.addSubview(timeLabel)
        contentView.addSubview(closeButton)
        titleControl.addSubview(titleStack)
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)

        playPauseButton.addTarget(self, action: #selector(onPlayPauseButtonTouchUpInside), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(onCloseButtonTouchUpInside), for: .touchUpInside)
        titleControl.addTarget(self, action: #selector(onTitleTouchUpInside), for: .touchUpInside)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            playPauseButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Metrics.contentInset),
            playPauseButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            playPauseButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Metrics.contentInset),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            timeLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -AudioPlayerBarIconButtonStyle.adjacentSpacing),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),

            titleControl.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: AudioPlayerBarIconButtonStyle.adjacentSpacing),
            titleControl.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            titleControl.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleControl.heightAnchor.constraint(equalToConstant: 34),

            titleStack.leadingAnchor.constraint(equalTo: titleControl.leadingAnchor),
            titleStack.trailingAnchor.constraint(equalTo: titleControl.trailingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: titleControl.centerYAnchor)
        ])

        setPlayPauseIcon(named: "play.fill")
        AudioPlayerBarIconButtonStyle.setSystemIcon(named: "xmark", on: closeButton)
    }

    private func setPlayPauseIcon(named iconName: String) {
        renderedPlayPauseIconName = iconName
        AudioPlayerBarIconButtonStyle.setSystemIcon(named: iconName, on: playPauseButton)
    }

    private static func playbackTimes(for state: VoiceMessagePlaybackState) -> (currentTime: TimeInterval, duration: TimeInterval) {
        switch state {
        case .playing(let currentTime, let duration),
             .paused(let currentTime, let duration):
            return (currentTime, duration)
        default:
            return (0, 0)
        }
    }

    @objc
    private func onPlayPauseButtonTouchUpInside() {
        delegate?.audioPlayerBarViewDidTapPlayPause(self)
    }

    @objc
    private func onCloseButtonTouchUpInside() {
        delegate?.audioPlayerBarViewDidTapClose(self)
    }

    @objc
    private func onTitleTouchUpInside() {
        delegate?.audioPlayerBarViewDidTapTitle(self)
    }
}

extension AudioPlayerBarView: MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String {
        return "audio_player_bar_view_smid"
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
    }
    
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
    }
    
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
    }
}

struct AvatarStructItem: Equatable {
    let jid: String
    let owner: String
    let name: String
    let url: String?
    let isGroup: Bool
    let uuid: String
}

enum LastChatsRowUpdateClassification: Equatable {
    case contentOnly
    case structuralReload
}

enum LastChatsRowUpdatePolicy {
    static func classify(
        old oldItem: LastChatsViewController.Datasource,
        new newItem: LastChatsViewController.Datasource,
        oldShowsSkeleton: Bool = false,
        newShowsSkeleton: Bool = false
    ) -> LastChatsRowUpdateClassification {
        guard oldShowsSkeleton == newShowsSkeleton else {
            return .structuralReload
        }
        guard oldItem.jid == newItem.jid,
              oldItem.owner == newItem.owner,
              oldItem.conversationType == newItem.conversationType else {
            return .structuralReload
        }
        guard oldItem.specialMessageKind == newItem.specialMessageKind else {
            return .structuralReload
        }
        guard rowHeight(for: oldItem, showsSkeleton: oldShowsSkeleton) == rowHeight(for: newItem, showsSkeleton: newShowsSkeleton) else {
            return .structuralReload
        }
        return .contentOnly
    }

    static func rowHeight(for item: LastChatsViewController.Datasource, showsSkeleton: Bool = false) -> CGFloat {
        if showsSkeleton {
            return 84
        }
        switch item.specialMessageKind {
        case .none:
            return 84
        case .contact, .invite:
            return 48
        }
    }
}

enum SavedMessagesChatListPresentationPolicy {
    static var title: String {
        L10n.text("saved_messages__header", fallback: "Saved messages")
    }
    static let avatarIconName = XMPPFavoritesManagerStorageItem.imageName
    static let leftMenuIconName = "bookmark"
    static var singleAccountPlaceholder: String {
        L10n.text(
            "saved_messages__placeholder__save_messages_here",
            fallback: "Save messages here"
        )
    }
    static let status: ResourceStatus = .offline
    static let entity: RosterItemEntity? = nil

    static func previewText(
        lastMessageText: String?,
        owner: String,
        enabledAccountCount: Int
    ) -> String {
        if let text = lastMessageText?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.isNotEmpty {
            return text
        }

        return enabledAccountCount > 1 ? owner : singleAccountPlaceholder
    }
}

enum LastChatsIdentityTitlePolicy {
    static func title(
        rosterDisplayName: String?,
        synchronizedVCardTitle: String?,
        jid: String
    ) -> String {
        [rosterDisplayName, synchronizedVCardTitle]
            .compactMap { value -> String? in
                let normalized = value?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                return normalized.isNotEmpty ? normalized : nil
            }
            .first ?? jid
    }
}

/// Coalesces a visible row's cooldown into one delayed retry. Visibility is
/// evaluated at the deadline, so scrolling a row away produces no IQ.
internal final class VCardVisibleRetryScheduler {
    private struct Entry {
        let token: UUID
        let workItem: DispatchWorkItem
    }

    private let queue: DispatchQueue
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [VCardPresentationIdentity: Entry] = [:]

    init(
        queue: DispatchQueue = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.now = now
    }

    var pendingCount: Int {
        lock.lock()
        let count = entries.count
        lock.unlock()
        return count
    }

    func schedule(
        identity: VCardPresentationIdentity,
        proof: VCardVisibleRetryProof,
        deadline: Date,
        isStillVisible: @escaping () -> Bool,
        retry: @escaping (VCardPresentationIdentity, VCardVisibleRetryProof) -> Void
    ) {
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.takeEntry(identity: identity, token: token) else {
                return
            }
            guard isStillVisible() else { return }
            retry(identity, proof)
        }

        lock.lock()
        let replaced = entries.updateValue(
            Entry(token: token, workItem: workItem),
            forKey: identity
        )
        lock.unlock()
        replaced?.workItem.cancel()

        queue.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSince(now())),
            execute: workItem
        )
    }

    func cancel(identity: VCardPresentationIdentity) {
        lock.lock()
        let entry = entries.removeValue(forKey: identity)
        lock.unlock()
        entry?.workItem.cancel()
    }

    func cancelAll() {
        lock.lock()
        let staleEntries = Array(entries.values)
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        staleEntries.forEach { $0.workItem.cancel() }
    }

    private func takeEntry(
        identity: VCardPresentationIdentity,
        token: UUID
    ) -> Bool {
        lock.lock()
        guard entries[identity]?.token == token else {
            lock.unlock()
            return false
        }
        entries.removeValue(forKey: identity)
        lock.unlock()
        return true
    }
}

enum LastChatMessagePreviewPolicy {
    struct Preview: Equatable {
        let text: String
        let isItalic: Bool
    }

    /// A persisted freshness hint cannot replace content that is already
    /// available for this row, including a cold materialized/list-only preview.
    static func shouldShowEmptyEncryptedPlaceholder(
        for chat: LastChatsStorageItem,
        message: MessageStorageItem?,
        synchronizedProjection: LastChatListSyncPreviewProjection? = nil
    ) -> Bool {
        chat.conversationType.isEncrypted &&
            chat.isFreshNotEmptyEncryptedChat &&
            message == nil && synchronizedProjection == nil
    }

    static func preview(
        for message: MessageStorageItem?,
        synchronizedProjection: LastChatListSyncPreviewProjection? = nil,
        blankMessageText: String
    ) -> Preview {
        guard let message else {
            if let synchronizedProjection,
               synchronizedProjection.text.isNotEmpty {
                return Preview(
                    text: synchronizedProjection.text,
                    isItalic: synchronizedProjection.isSystemMessage
                )
            }
            return Preview(text: blankMessageText, isItalic: false)
        }

        if let placeholder = message.localReportPlaceholderText {
            return Preview(text: placeholder, isItalic: false)
        }

        let visibleReferences = message.references.toArray().filter { !$0.isLocallyHiddenByReport }

        if visibleReferences.contains(where: { $0.kind == .geoloc }) {
            return Preview(text: MessageStorageItem.locationDisplayText, isItalic: true)
        }

        if let contactReference = visibleReferences.first(where: { $0.kind == .contact }),
           let contactTitle = contactDisplayTitle(for: contactReference) {
            return Preview(text: contactDisplayText(contactTitle), isItalic: true)
        }

        let fallbackURIs = Set(message.references.toArray().compactMap { reference in
            nonEmptyContactText(reference.url) ??
                nonEmptyContactText(reference.metadata?["uri"])
        })
        if let caption = LastChatAttachmentPreviewFormatter.normalizedCaption(
            message.userVisibleBody,
            fallbackURIs: fallbackURIs
        ) {
            return Preview(text: caption, isItalic: false)
        }

        let attachmentKinds = visibleReferences.compactMap { reference in
            LastChatAttachmentPreviewFormatter.kind(
                referenceKindRaw: reference.kind_,
                mimeType: reference.mimeType,
                mediaType: reference.metadata?["media-type"] as? String
            )
        }
        if let attachmentText = LastChatAttachmentPreviewFormatter.text(
            for: attachmentKinds
        ) {
            return Preview(text: attachmentText, isItalic: false)
        }

        let text = message.displayedBody()
        return Preview(
            text: text.isEmpty ? blankMessageText : text,
            isItalic: false
        )
    }

    private static func contactDisplayText(_ title: String) -> String {
        "Contact: %@".localizeString(id: "recent_chat__last_message__contact", arguments: [title])
    }

    private static func contactDisplayTitle(for reference: MessageReferenceStorageItem) -> String? {
        guard let metadata = reference.metadata else { return nil }

        if let nickname = nonEmptyContactText(metadata["nickname"]) {
            return nickname
        }

        let fullName = [
            nonEmptyContactText(metadata["given"]),
            nonEmptyContactText(metadata["family"])
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fullName.isNotEmpty {
            return fullName
        }

        return nonEmptyContactText(metadata["contact_jid"])
    }

    private static func nonEmptyContactText(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Resolves a locally stored preview for an unlinked recents row without
/// materializing a message or granting history authority.
enum LastChatMaterializedPreviewResolver {
    private struct ConversationKey: Hashable {
        let owner: String
        let jid: String
        let type: ClientSynchronizationManager.ConversationType
    }

    static func resolve(
        in realm: Realm,
        for chats: [LastChatsStorageItem]
    ) -> [String: MessageStorageItem] {
        let unresolved = chats.filter { $0.lastMessage == nil && $0.lastMessageId.isNotEmpty }
        let chatsByID = Dictionary(grouping: unresolved, by: \.lastMessageId)
        let messages = realm.objects(MessageStorageItem.self)
        var resolved: [String: MessageStorageItem] = [:]

        for (id, matchingChats) in chatsByID {
            let keys = Set(matchingChats.map {
                ConversationKey(owner: $0.owner, jid: $0.jid, type: $0.conversationType)
            })
            // A single indexed equality avoids the broad mixed-column OR query.
            // Exact message IDs always outrank archive IDs for the same route.
            let exact = preferredMessages(messages.filter("messageId == %@", id), in: keys)
            let missing = keys.subtracting(exact.keys)
            let archived = missing.isEmpty
                ? [:]
                : preferredMessages(messages.filter("archivedId == %@", id), in: missing)

            for chat in matchingChats {
                let key = ConversationKey(owner: chat.owner, jid: chat.jid, type: chat.conversationType)
                resolved[chat.primary] = exact[key] ?? archived[key]
            }
        }
        return resolved
    }

    private static func preferredMessages(
        _ candidates: Results<MessageStorageItem>,
        in keys: Set<ConversationKey>
    ) -> [ConversationKey: MessageStorageItem] {
        var preferred: [ConversationKey: MessageStorageItem] = [:]
        for message in candidates where !message.isDeleted {
            let key = ConversationKey(owner: message.owner, jid: message.opponent, type: message.conversationType)
            guard keys.contains(key) else { continue }
            if let existing = preferred[key],
               MessageHistoryOrderKey(message: existing) >= MessageHistoryOrderKey(message: message) {
                continue
            }
            preferred[key] = message
        }
        return preferred
    }
}

/// Numeric-only work evidence for deterministic projection regressions. No logging.
final class LastChatsProjectionWorkCounter {
    enum Operation { case fullDatasetBuild, rowBuild, candidateQuery, candidateHit, datasetHit, rowHit, resourceQuery }
    struct Snapshot {
        var fullDatasetBuilds = 0, rowBuilds = 0, candidateQueries = 0
        var candidateHits = 0, datasetHits = 0, rowHits = 0, resourceQueries = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func record(_ operation: Operation, count: Int = 1) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        switch operation {
        case .fullDatasetBuild: value.fullDatasetBuilds += count
        case .rowBuild: value.rowBuilds += count
        case .candidateQuery: value.candidateQueries += count
        case .candidateHit: value.candidateHits += count
        case .datasetHit: value.datasetHits += count
        case .rowHit: value.rowHits += count
        case .resourceQuery: value.resourceQueries += count
        }
        #endif
    }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func reset() { lock.lock(); value = Snapshot(); lock.unlock() }
}

/// Retains identities, never live/frozen message objects. One immutable Realm
/// version scopes positive and negative results; a different file/version drops
/// them before lookup. This also covers new candidates and same-ID edits.
final class LastChatsMaterializedPreviewCache {
    private struct Key: Hashable {
        let owner: String, jid: String, type: String, primary: String, lastMessageID: String
        init(_ chat: LastChatsStorageItem) {
            owner = chat.owner; jid = chat.jid; type = chat.conversationType_
            primary = chat.primary; lastMessageID = chat.lastMessageId
        }
    }
    private struct Entry { let messagePrimary: String? }
    private let capacity: Int
    private var snapshot: Realm?
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    init(capacity: Int = 512) { self.capacity = min(512, max(1, capacity)) }
    var entryCount: Int { entries.count }
    var retainedSnapshotCount: Int { snapshot == nil ? 0 : 1 }
    func removeAll() { snapshot = nil; entries.removeAll(); order.removeAll() }
    func resolve(in realm: Realm, for chats: [LastChatsStorageItem],
        counter: LastChatsProjectionWorkCounter) -> [String: MessageStorageItem] {
        if snapshot != realm { removeAll(); snapshot = realm }
        let unresolved = chats.filter { $0.lastMessage == nil && $0.lastMessageId.isNotEmpty }
        let misses = unresolved.filter { entries[Key($0)] == nil }
        var out: [String: MessageStorageItem] = [:]
        for chat in unresolved where entries[Key(chat)] != nil {
            counter.record(.candidateHit)
            if let primary = entries[Key(chat)]?.messagePrimary,
               let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                out[chat.primary] = message
            }
        }
        if misses.isNotEmpty {
            counter.record(.candidateQuery)
            let found = LastChatMaterializedPreviewResolver.resolve(in: realm, for: misses)
            for chat in misses {
                if entries.count >= capacity, let first = order.first {
                    entries.removeValue(forKey: first); order.removeFirst()
                }
                let key = Key(chat)
                entries[key] = Entry(messagePrimary: found[chat.primary]?.primary)
                order.append(key)
            }
            out.merge(found, uniquingKeysWith: { _, new in new })
        }
        return out
    }
}

enum SavedMessagesAvailabilityPolicy {
    static func favoritesNodesByOwner(in realm: Realm, enabledOwners: [String]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: realm
                .objects(XMPPFavoritesManagerStorageItem.self)
                .filter("owner IN %@", enabledOwners)
                .compactMap { item -> (String, String)? in
                    guard item.node.isNotEmpty else { return nil }
                    return (item.owner, item.node)
                }
        )
    }

    static func visibleSavedLastChatsPredicate(
        enabledOwners: [String],
        favoritesNodesByOwner: [String: String]
    ) -> NSPredicate {
        let savedTypePredicate = NSPredicate(
            format: "conversationType_ == %@",
            ClientSynchronizationManager.ConversationType.saved.rawValue
        )
        let availableOwnerNodePredicates = enabledOwners.compactMap { owner -> NSPredicate? in
            guard let node = favoritesNodesByOwner[owner], node.isNotEmpty else { return nil }
            return NSPredicate(format: "owner == %@ AND jid == %@", owner, node)
        }

        guard availableOwnerNodePredicates.isNotEmpty else {
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                savedTypePredicate,
                NSPredicate(format: "owner == %@", "__xabber_saved_messages_unavailable__")
            ])
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            savedTypePredicate,
            NSCompoundPredicate(orPredicateWithSubpredicates: availableOwnerNodePredicates)
        ])
    }

    static func visibleSavedLastChats(
        in realm: Realm,
        enabledOwners: [String],
        favoritesNodesByOwner: [String: String]? = nil
    ) -> Results<LastChatsStorageItem> {
        let nodesByOwner = favoritesNodesByOwner ?? self.favoritesNodesByOwner(
            in: realm,
            enabledOwners: enabledOwners
        )
        return realm
            .objects(LastChatsStorageItem.self)
            .filter(visibleSavedLastChatsPredicate(
                enabledOwners: enabledOwners,
                favoritesNodesByOwner: nodesByOwner
            ))
    }
}

class LastChatsViewController: BaseViewController, LeftMenuFirstPresentationQuieting {
    static let nativeChatBackAccessibilityIdentifier =
        "last_chats_native_chat_back_button"

    #if DEBUG || CHAT_PERFORMANCE_LAB
    internal var performanceChatRowAccessibilityIdentifierProvider:
        ((Datasource) -> String?)?
    internal var performanceChatRowSelectionObserver:
        ((Datasource, IndexPath, ChatOpenMessageRequest?) -> Void)?
    #endif
    
    enum Filter: Int {
        case chats
        case unread
        case archived
        case saved
    }

    internal struct BottomBarPresentation: Equatable {
        let actions: FloatingBottomBarView.ActionPresentation
        let isActionBarHidden: Bool
    }

    internal static func bottomBarPresentation(
        unreadChatsCount: Int,
        hasConnectingEnabledAccounts: Bool,
        filter: Filter,
        shouldShowBottomBar: Bool,
        hidesUnderlyingActions: Bool
    ) -> BottomBarPresentation {
        let routeSupportsUnreadActions = shouldShowBottomBar && (filter == .chats || filter == .unread)
        let hasUnreadActions = routeSupportsUnreadActions && unreadChatsCount > 0

        return BottomBarPresentation(
            actions: FloatingBottomBarView.ActionPresentation(
                isLeftVisible: routeSupportsUnreadActions,
                isCenterVisible: hasUnreadActions && !hasConnectingEnabledAccounts
            ),
            isActionBarHidden: hidesUnderlyingActions || !routeSupportsUnreadActions
        )
    }
    
    enum SpecialMessageKind: Equatable {
        case none
        case contact
        case invite

        var diffKey: String {
            switch self {
            case .none:
                return "chat"
            case .contact:
                return "special-contact"
            case .invite:
                return "special-invite"
            }
        }
    }

    enum DatasourceSectionKind: Equatable {
        case specialMessages
        case chats
    }

    struct DatasourceSection {
        let kind: DatasourceSectionKind
        let rows: [Datasource]
    }

    struct SelectedChatIdentity: Equatable {
        let jid: String
        let owner: String
        let conversationType: ClientSynchronizationManager.ConversationType

        init(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
            self.jid = jid
            self.owner = owner
            self.conversationType = conversationType
        }

        init(item: Datasource) {
            self.init(jid: item.jid, owner: item.owner, conversationType: item.conversationType)
        }

        func matches(_ item: Datasource) -> Bool {
            item.specialMessageKind == .none
                && item.jid == jid
                && item.owner == owner
                && item.conversationType == conversationType
        }
    }
    
    struct Datasource: DiffAware {
        var diffId: String {
            get {
                return [specialMessageKind.diffKey, jid, owner, conversationType.rawValue].prp()
            }
        }

        let jid: String
        let owner: String
        let username: String
        let attributedUsername: NSAttributedString?
        let message: String
        let date: Date?
        let state: MessageStorageItem.MessageSendingState?
        let isMute: Bool
        let isSynced: Bool
        let status: ResourceStatus
        let entity: RosterItemEntity?
        let conversationType: ClientSynchronizationManager.ConversationType
        let unread: Int
        let unreadString: String?
        let hasUnreadMention: Bool
        let color: UIColor
        let isDraft: Bool
        let hasAttachment: Bool
        let userNickname: String?
        var userColorKey: String? = nil
        let isSystemMessage: Bool
        let isPinned: Bool
        let subRequest: Bool
        let isEncrypted: Bool
        let avatarUrl: String?
        let hasErrorInChat: Bool
        let updateTS: Double
        let isVerificationActionRequired: Bool
        let specialMessageKind: SpecialMessageKind
        let avatars: [AvatarStructItem]
        
        
        
        static func compareContent(_ a: LastChatsViewController.Datasource, _ b: LastChatsViewController.Datasource) -> Bool {
            return a.jid == b.jid
                    && a.owner == b.owner
                    && a.username == b.username
                    && attributedStringsEqual(a.attributedUsername, b.attributedUsername)
                    && a.message == b.message
                    && a.date == b.date
                    && a.state == b.state
                    && a.isMute == b.isMute
                    && a.isSynced == b.isSynced
                    && a.status == b.status
                    && a.entity == b.entity
                    && a.conversationType == b.conversationType
                    && a.unread == b.unread
                    && a.unreadString == b.unreadString
                    && a.hasUnreadMention == b.hasUnreadMention
                    && a.color == b.color
                    && a.isDraft == b.isDraft
                    && a.hasAttachment == b.hasAttachment
                    && a.userNickname == b.userNickname
                    && a.userColorKey == b.userColorKey
                    && a.isSystemMessage == b.isSystemMessage
                    && a.isPinned == b.isPinned
                    && a.subRequest == b.subRequest
                    && a.isEncrypted == b.isEncrypted
                    && a.avatarUrl == b.avatarUrl
                    && a.hasErrorInChat == b.hasErrorInChat
                    && a.updateTS == b.updateTS
                    && a.isVerificationActionRequired == b.isVerificationActionRequired
                    && a.specialMessageKind == b.specialMessageKind
                    && a.avatars == b.avatars
        }

        private static func attributedStringsEqual(_ lhs: NSAttributedString?, _ rhs: NSAttributedString?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return lhs.isEqual(to: rhs)
            default:
                return false
            }
        }
        
    }
    
    struct DatasourceChangeset {
        public let needReload: Bool
        public let deleted: [Int]
        public let inserted: [Int]
        public let updated: [Int]
    }
    
    open weak var leftMenuSelectRootCategoryDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal lazy var tableView: UITableView = {
        let style = LastChatsTableStylePolicy.style(for: traitCollection.horizontalSizeClass)
        let view = UITableView(frame: .zero, style: style)
        
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        view.register(ArchivedCell.self, forCellReuseIdentifier: ArchivedCell.cellName)
        view.register(SkeletonCell.self, forCellReuseIdentifier: SkeletonCell.cellName)
        view.register(SpecialMessageTableViewCell.self, forCellReuseIdentifier: SpecialMessageTableViewCell.cellName)
        view.contentInsetAdjustmentBehavior = .scrollableAxes
        
        view.backgroundColor = .clear
        view.isOpaque = false
//        view.allowsMultipleSelection = false
//        view.allowsMultipleSelectionDuringEditing = false
//        view.cellLayoutMarginsFollowReadableWidth = false
        
        return view
    }()
    
    private let chatBackgroundBackdropView = ChatBackgroundBackdropView()

    internal let emptyView: EmptyView = {
        let view = EmptyView()
        
        return view
    }()
        
    internal let securityButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "security"), style: UIBarButtonItem.Style.plain, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
    internal let unreadAllMessagesButton: UIButton = {
        let button = UIButton()
        
        button.tintColor = .white
        button.layer.cornerRadius = 18
        button.setTitle("Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: []), for: .normal)
        button.isHidden = true
        
        return button
    }()
    
    internal let accountNavButton: AccountNavButton = {
        let button = AccountNavButton(frame: CGRect(width: 44, height: 44))
        
//        button.isUserInteractionEnabled = false
        
        return button
    }()

    internal lazy var accountBarButton: UIBarButtonItem = {
        UIBarButtonItem(customView: accountNavButton)
    }()

    internal lazy var chatsTabsAddBarButton: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: "plus")?
                .upscale(dimension: 24)
                .withRenderingMode(.alwaysTemplate),
            style: .plain,
            target: self,
            action: #selector(onAddButtonTouchUpInside)
        )
    }()

    internal lazy var chatsSplitSidebarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: imageLiteral("sidebar.left"),
            style: .plain,
            target: self,
            action: #selector(onSidebarButtonTouchUp)
        )
        button.accessibilityIdentifier = "chats_sidebar_menu_button"
        return button
    }()

    internal lazy var chatsSplitAddBarButton: UIBarButtonItem = {
        UIBarButtonItem(
            image: imageLiteral("plus"),
            style: .plain,
            target: self,
            action: #selector(onAddButtonTouchUpInside)
        )
    }()

    internal lazy var chatsBackButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: imageLiteral("chevron.left"),
            style: .plain,
            target: self,
            action: #selector(onBackButtonTouchUpInside)
        )
        button.accessibilityIdentifier = "chats_back_to_chats_button"
        return button
    }()
    
    internal let refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        
        control.attributedTitle = nil
        control.tintColor = .clear
        
        return control
    }()
    
    internal let chatSearchResultsController = ChatSearchResultsController()

    internal lazy var searchController: UISearchController = {
        InPlaceSearchHostHelper.makeSearchController(updater: chatSearchResultsController)
    }()

    internal let bottomSearchHostView = BottomSearchHostView(frame: .zero)
    internal var pendingBottomSearchDismissalAfterRoute = false
    internal let bottomOverlayInsetCoordinator = BottomOverlayInsetCoordinator()
    
    internal let pullDownTableHeaderView: PullDownTableHeaderView = {
        let view = PullDownTableHeaderView(frame: .zero)
        
        view.alpha = 0.0
        
        return view
    }()
    
    internal let bottomBar: BottomBarView = {
        let view = BottomBarView(frame: .zero)
        
        return view
    }()

    private let floatingBottomBarView: FloatingBottomBarView = {
        let view = FloatingBottomBarView(frame: .zero)
        let title = "Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: [])

        view.leftButton.accessibilityIdentifier = "last_chats_filter_button"
        view.leftButton.accessibilityLabel = L10n.text("last_chats__accessibility__unread_chats_filter", fallback: "Unread chats filter")
        view.setCenterButtonTitle(
            title,
            accessibilityIdentifier: "last_chats_mark_all_read_button",
            accessibilityLabel: title
        )
        return view
    }()

    private var unreadCounterBag: DisposeBag = DisposeBag()
    internal private(set) var unreadChatsCount: Int = 0
    
    internal var isFirstLayout: Bool = false
    
    internal var isAppeared: Bool = false
    private var rootChatActivationGeneration: UInt = 0
    private var rootChatActivationTarget: LastChatsNavigationSingleFlightCoordinator.Target?
    private var pendingRootChatActivation: (
        generation: UInt,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        activate: () -> Void
    )?
    private var hasCompletedCurrentAppearance: Bool = false
    internal var isNavigationTransitionActive: Bool = false
    private var pendingNavigationTransitionWork: [() -> Void] = []
    private var pendingDatasetUpdateAfterNavigationTransition: Bool = false
    private var pendingNavigationChromeRefreshAfterNavigationTransition: Bool = false
    private var navigationDatasetMutationGeneration: UInt = 0
    private var shouldSuppressNextDatasetAnimation: Bool = false
    private var outgoingChatOpenNavigationDeferralToken: UUID?
    private var outgoingChatOpenNavigationPreparationToken: UUID?
    private var outgoingChatOpenNavigationPreparationHandle: StackedNavigationPresentationPreparationHandle?
    private var chatNavigationPreparationTimeoutWorkItem: DispatchWorkItem?
    private var shouldResetChatNavigationTransactionOnNextAppearance: Bool = false
    private var completedChatNavigationReturnTransition:
        LastChatsNavigationReturnTransitionCompletion?
    private var pendingChatNavigationTransitionCompletionTokens: Set<UUID> = []
    private var bootstrapDatasetUpdateWorkItem: DispatchWorkItem?
    private var pendingDatasetUpdateAfterBootstrapCoalescing: Bool = false
    private var isExecutingBootstrapCoalescedDatasetUpdate: Bool = false
    private var projectionRefreshCoalescer = LastChatsProjectionRefreshCoalescer()
    private var projectionRefreshQuietWorkItem: DispatchWorkItem?
    private var projectionRefreshDeadlineWorkItem: DispatchWorkItem?
    private var projectionRefreshQuietGeneration: UInt64 = 0
    private var projectionRefreshDeadlineGeneration: UInt64 = 0
    private let visibleVCardRetryScheduler = VCardVisibleRetryScheduler()
    
    #if DEBUG
    /// Deterministic test barrier only; nil in ordinary execution.
    internal var projectionMappingDidPrepareForTesting: (() -> Void)?
    #endif
    internal let syncLatencyWorkCounter = LastChatsProjectionWorkCounter()
    private let projectionCacheLock = NSRecursiveLock()
    private let materializedPreviewCache = LastChatsMaterializedPreviewCache()
    private var cachedDatasetRealm: Realm?
    private var cachedDatasetContext = ""
    private var mappingDeferredForSyncPage = false
    private struct ProjectionReadRevision {
        let owners: Set<String>
        let filter: Int
        let batches: [String: UInt64]
        let previews: [String: UInt64]
    }
    private var mappingReadRevision: ProjectionReadRevision?
    private var projectionCacheEvictionWorkItem: DispatchWorkItem?
    private var projectionCacheEvictionGeneration: UInt64 = 0
    private var projectionCacheRetentionDeadline = Date.distantPast
    private var projectionLifecycleEpoch = UUID()
    private var cachedDataset: [Datasource] = []
    private var cachedDatasetExpiry = Date.distantPast
    private var rowRenderCache: [String: (fingerprint: Int, row: Datasource, bytes: Int)] = [:]
    private var rowRenderOrder: [String] = []
    private var rowRenderBytes = 0
    private var rowRenderOwners: Set<String>?
    private var observedTypingStates: [String: Int] = [:]
    private var deferredSyncPageRefresh = false
    private var previewMessageObservationBag = DisposeBag()
    private var previewMessageObservationKeys = Set<PreviewMessageKey>()

    internal var datasource: [Datasource] = []
    internal var datasourceIndexByKey: [String: Int] = [:]
    internal var datasourceSections: [DatasourceSection] = [DatasourceSection(kind: .chats, rows: [])]
    internal var datasourceIndexPathByKey: [String: IndexPath] = [:]
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasetBag: DisposeBag = DisposeBag()
    internal var dismissedCanonicalInviteBannerPrimaries: Set<String> = []
    internal var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .chats)
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    
    internal var enabledAccounts: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
//    internal var showArchivedSection: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var isArchivedSectionShowed: Bool = false
    
    internal var editedIndexPath: IndexPath? = nil
    internal var datasourceShowsSkeleton: Bool = false

    public var archivedMode: Bool = false
    
    internal var showSkeleton: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var topAccountJid: String = ""
    
    internal let updateQueue: DispatchQueue = DispatchQueue(label: "com.xabber.background.lastchats", qos: .background)
    internal var isDatasetUpdateInFlight: Bool = false
    internal var needsDatasetRefresh: Bool = false
    internal var skeletonItemsCount: Int = 10
    
    #if DEBUG
    internal var startupRecentsSyncPendingForTesting: ((String) -> Bool)?
    #endif
    
    open var splitDelegate: SplitViewControllerDelegate? = nil
    
    open var currentChatVC: ChatViewController? = nil
    internal var chatNavigationSingleFlight = LastChatsNavigationSingleFlightCoordinator()
    internal private(set) var retainedCompactChatNavigationDestination:
        LastChatsRetainedCompactChatNavigationDestination?
    internal private(set) var expandedSplitChatNavigationTransaction:
        LastChatsExpandedSplitChatNavigationTransaction?
    private var expandedSplitAccountRegistryMutationObserver: NSObjectProtocol?
    internal private(set) var chatOpenIntentOwnership:
        LastChatsChatOpenIntentOwnership?
    internal var chatOpenMessageRequestResolverOverride:
        ((LastChatsNavigationSingleFlightCoordinator.Target, ChatOpenMessageRequest?) -> ChatOpenMessageRequest?)?
    internal var chatOpenIntentDeliveryHandler:
        (LastChatsResolvedChatOpenIntent, ChatViewController) -> Void = {
            intent,
            destination in
            switch intent {
            case .message(let request):
                destination.queueOpenMessageRequest(request)
            case .latest:
                if destination.pendingOpenMessageRequest != nil ||
                    destination.activeAnchorExecutionState != nil {
                    destination.performPendingOpenMessageRequestIfNeeded()
                } else if !destination.pendingForceLatestOpen,
                          ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
                    destination.requestForceLatestOpen(animated: false)
                }
            }
        }
    internal var chatNavigationRouteResolver: (UIViewController) -> StackedNavigationRoute = {
        stackedNavigationRoute(for: $0)
    }
    internal var chatNavigationAccountEpochResolver:
        (LastChatsNavigationSingleFlightCoordinator.Target) -> LastChatsChatNavigationAccountEpoch = {
            target in
            let account = AccountManager.shared.find(for: target.owner)
            let accountStorage: AccountStorageItem?
            let isEnabled: Bool
            do {
                accountStorage = try WRealm.safe()
                    .object(ofType: AccountStorageItem.self, forPrimaryKey: target.owner)
                isEnabled = accountStorage?.enabled == true
            } catch {
                accountStorage = nil
                isEnabled = false
            }
            return LastChatsChatNavigationAccountEpoch(
                accountIdentifier: account.map(ObjectIdentifier.init),
                isPresent: account != nil && accountStorage != nil,
                isEnabled: isEnabled
            )
        }
    internal var expandedSplitStableVisibilityOverride: ((ChatViewController) -> Bool)?
    internal var expandedSplitPresentationStateOverride:
        ((UIViewController?, UIViewController?) -> LastChatsExpandedSplitPresentationState)?
    internal var expandedSplitTransitionOwnerOverride:
        (([UIViewController]) -> UIViewController?)?
    internal var compactChatDestinationFactory: () -> ChatViewController = {
        ChatViewController()
    }
    internal var expandedSplitChatDestinationFactory: () -> ChatViewController = {
        ChatViewController()
    }
    internal var expandedSplitChatPresentationHandler:
        LastChatsExpandedSplitChatPresentationHandler = {
            destination,
            presenter,
            commitPresentation,
            completion in
            showStacked(
                destination,
                in: presenter,
                using: .splitDetailReplacement,
                commitPresentation: commitPresentation,
                completion: completion
            )
        }
    internal var expandedSplitPreparedChatPresentationHandler:
        LastChatsExpandedSplitChatPresentationHandler = {
            destination,
            presenter,
            commitPresentation,
            completion in
            showStacked(
                destination,
                in: presenter,
                using: .splitDetailReplacement,
                destinationIsPrepared: true,
                commitPresentation: commitPresentation,
                completion: completion
            )
        }
    internal var expandedSplitPresentationAttemptObserver:
        ((ChatViewController, Bool) -> Void)?
    internal var pendingMessageNotificationRouteRetryHandler: () -> Bool = {
        AppRootCoordinator.active?
            .retryPendingMessageNotificationChatRouteIfPossible() ?? false
    }
    internal var pendingMessageNotificationTransitionRegistrar:
        (UIViewController, @escaping (Bool) -> Void) -> Bool = {
            owner,
            completion in
            guard let coordinator = owner.transitionCoordinator else {
                return false
            }
            return coordinator.animate(
                alongsideTransition: nil,
                completion: { completion($0.isCancelled) }
            )
        }
    internal var pendingMessageNotificationAsyncScheduler: (@escaping () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }
    private var pendingMessageNotificationRetryGeneration: UInt = 0
    internal private(set) var isPendingMessageNotificationRetryScheduled = false
    internal var hasActiveOutgoingChatOpenNavigationDeferral: Bool {
        outgoingChatOpenNavigationDeferralToken != nil
    }
    internal var hasActiveOutgoingChatOpenNavigationPreparation: Bool {
        outgoingChatOpenNavigationPreparationHandle != nil
    }
    internal var hasPendingChatNavigationPreparationTimeout: Bool {
        guard let workItem = chatNavigationPreparationTimeoutWorkItem else {
            return false
        }
        return !workItem.isCancelled
    }
    internal var selectedChatIdentity: SelectedChatIdentity? = nil
    internal var voiceMessageStateObserverToken: UUID? = nil
    internal var pinnedVoicePlayerHeightConstraint: NSLayoutConstraint? = nil
    
    
    let playerViewToolbar: AudioPlayerBarView = {
        let view = AudioPlayerBarView(frame: .zero)
        
        view.isHidden = false
        
        return view
    }()

    let pinnedVoicePlayerView: AudioPlayerBarView = {
        let view = AudioPlayerBarView(frame: .zero)

        view.isHidden = true

        return view
    }()

    internal func beginNavigationTransitionDeferralIfNeeded() {
        guard let coordinator = self.transitionCoordinator ??
                self.navigationController?.transitionCoordinator else {
            return
        }
        let chatNavigationToken = chatNavigationSingleFlight.state?.token
        if let chatNavigationToken {
            pendingChatNavigationTransitionCompletionTokens.insert(
                chatNavigationToken
            )
        }
        if !self.isNavigationTransitionActive {
            self.navigationDatasetMutationGeneration &+= 1
        }
        self.isNavigationTransitionActive = true
        if self.isDatasetUpdateInFlight {
            self.pendingDatasetUpdateAfterNavigationTransition = true
        }
        self.accountNavButton.setRenderingFrozen(true)
        let registered = coordinator.animate(
            alongsideTransition: nil
        ) { [weak self] context in
            guard let self else {
                return
            }
            if let chatNavigationToken {
                self.pendingChatNavigationTransitionCompletionTokens.remove(
                    chatNavigationToken
                )
            }
            self.completeNavigationTransitionDeferral(
                cancelled: context.isCancelled
            )
            if let chatNavigationToken {
                _ = self.completeChatNavigationReturnTransition(
                    token: chatNavigationToken,
                    cancelled: context.isCancelled
                )
            }
        }
        if !registered, let chatNavigationToken {
            pendingChatNavigationTransitionCompletionTokens.remove(
                chatNavigationToken
            )
        }
    }

    internal func retainCompactChatNavigationDestination(
        _ controller: ChatViewController,
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        accountEpoch: LastChatsChatNavigationAccountEpoch? = nil
    ) {
        retainedCompactChatNavigationDestination = .init(
            token: token,
            target: target,
            controller: controller,
            accountEpoch: accountEpoch
        )
    }

    internal func retainedCompactChatNavigationDestination(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target
    ) -> ChatViewController? {
        guard let destination = retainedCompactChatNavigationDestination,
              destination.token == token,
              destination.target == target else {
            return nil
        }
        if let accountEpoch = destination.accountEpoch,
           !accountEpoch.isExactValidMatch(
            for: chatNavigationAccountEpochResolver(target)
           ) {
            return nil
        }
        return destination.controller
    }

    internal func clearRetainedCompactChatNavigationDestination(token: UUID? = nil) {
        guard token == nil || retainedCompactChatNavigationDestination?.token == token else {
            return
        }
        retainedCompactChatNavigationDestination = nil
    }

    internal func installExpandedSplitChatNavigationTransaction(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        previousVisibleDetail: ChatViewController?,
        previousSecondarySnapshot: LastChatsExpandedSplitSecondarySnapshot,
        accountEpoch: LastChatsChatNavigationAccountEpoch,
        navigationSource: ChatOpenNavigationSource,
        activationContext: LastChatsExpandedSplitActivationContext?,
        expectedSupplementaryContainerIdentifier: ObjectIdentifier? = nil,
        expectedSupplementaryTopViewControllerIdentifier: ObjectIdentifier? = nil
    ) {
        stopExpandedSplitAccountRegistryMutationObservation()
        expandedSplitChatNavigationTransaction = .init(
            token: token,
            target: target,
            destination: destination,
            previousVisibleDetail: previousVisibleDetail,
            previousSecondarySnapshot: previousSecondarySnapshot,
            accountEpoch: accountEpoch,
            navigationSource: navigationSource,
            expectedSupplementaryContainerIdentifier:
                expectedSupplementaryContainerIdentifier,
            expectedSupplementaryTopViewControllerIdentifier:
                expectedSupplementaryTopViewControllerIdentifier,
            activationContext: activationContext,
            preparationHandle: nil,
            phase: .preparing,
            lastRejectedEligibilityFingerprint: nil,
            permitsOneUnchangedEligibilityRetry: false
        )
        startExpandedSplitAccountRegistryMutationObservationIfNeeded()
    }

    /// Account materialization can complete while a cached Last Chats controller
    /// is not installed and therefore has no dataset subscription. Observation is
    /// owned by the exact pending navigation transaction instead of visibility.
    private func startExpandedSplitAccountRegistryMutationObservationIfNeeded() {
        guard expandedSplitAccountRegistryMutationObserver == nil,
              let transaction = expandedSplitChatNavigationTransaction,
              transaction.navigationSource == .notification,
              transaction.phase != .presented else {
            return
        }
        expandedSplitAccountRegistryMutationObserver = NotificationCenter.default
            .addObserver(
                forName: AccountManagerRegistryMutationSignal.notification,
                object: nil,
                queue: .main,
                using: { [weak self] notification in
                    guard notification.object == nil,
                          notification.userInfo == nil,
                          let self,
                          let transaction = self
                            .expandedSplitChatNavigationTransaction,
                          transaction.navigationSource == .notification,
                          transaction.phase != .presented else {
                        return
                    }
                    self
                        .retryPendingMessageNotificationRouteOnLifecycleStability()
                }
            )
    }

    private func stopExpandedSplitAccountRegistryMutationObservation() {
        guard let observer = expandedSplitAccountRegistryMutationObserver else {
            return
        }
        NotificationCenter.default.removeObserver(observer)
        expandedSplitAccountRegistryMutationObserver = nil
    }

    @discardableResult
    internal func registerExpandedSplitChatNavigationPreparation(
        _ handle: StackedNavigationPresentationPreparationHandle,
        token: UUID
    ) -> Bool {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token else {
            handle.cancel()
            return false
        }
        guard transaction.phase == .preparing else {
            handle.cancel()
            return transaction.phase == .waitingForEligibility ||
                transaction.phase == .presenting ||
                transaction.phase == .presented
        }
        transaction.preparationHandle = handle
        expandedSplitChatNavigationTransaction = transaction
        return true
    }

    internal func promoteExpandedSplitChatNavigationSourceToNotification(
        token: UUID
    ) {
        guard let transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.navigationSource != .notification else {
            return
        }
        expandedSplitChatNavigationTransaction = transaction
            .replacingNavigationSource(.notification)
        startExpandedSplitAccountRegistryMutationObservationIfNeeded()
    }

    @discardableResult
    internal func retainExpandedSplitChatNavigationForEligibilityWakeup(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        fingerprint: LastChatsExpandedSplitEligibilityFingerprint,
        permitsOneUnchangedEligibilityRetry: Bool = false
    ) -> Bool {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              (transaction.phase == .preparing ||
                transaction.phase == .presenting) else {
            return false
        }
        transaction.phase = .waitingForEligibility
        transaction.preparationHandle = nil
        transaction.lastRejectedEligibilityFingerprint = fingerprint
        transaction.permitsOneUnchangedEligibilityRetry =
            permitsOneUnchangedEligibilityRetry
        expandedSplitChatNavigationTransaction = transaction
        return true
    }

    /// A repeated retained notification route is an observed eligibility wake.
    /// While first-frame preparation is still outstanding it may adopt exactly
    /// the current valid account epoch. The later commit continues to require
    /// an exact match, so a second unobserved replacement remains blocked.
    @discardableResult
    internal func adoptExpandedSplitChatNavigationAccountEpochDuringPreparation(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        currentAccountEpoch: LastChatsChatNavigationAccountEpoch
    ) -> Bool {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              transaction.phase == .preparing,
              transaction.navigationSource == .notification,
              currentAccountEpoch.isValidForChatNavigation else {
            return false
        }
        guard transaction.accountEpoch != currentAccountEpoch else {
            return true
        }
        transaction = transaction.replacingAccountEpoch(currentAccountEpoch)
        expandedSplitChatNavigationTransaction = transaction
        return true
    }

    @discardableResult
    internal func prepareRetainedExpandedSplitChatNavigationForRetry(
        token: UUID,
        currentAccountEpoch: LastChatsChatNavigationAccountEpoch,
        currentFingerprint: LastChatsExpandedSplitEligibilityFingerprint
    ) -> LastChatsExpandedSplitChatNavigationTransaction? {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.phase == .waitingForEligibility,
              currentAccountEpoch.isValidForChatNavigation else {
            return nil
        }

        let accountEpochChanged = currentAccountEpoch != transaction.accountEpoch
        if accountEpochChanged {
            transaction = transaction.replacingAccountEpoch(
                currentAccountEpoch
            )
        }
        guard transaction.lastRejectedEligibilityFingerprint !=
                currentFingerprint || accountEpochChanged ||
                transaction.permitsOneUnchangedEligibilityRetry else {
            return nil
        }
        transaction.phase = .preparing
        transaction.preparationHandle = nil
        transaction.permitsOneUnchangedEligibilityRetry = false
        expandedSplitChatNavigationTransaction = transaction
        return transaction
    }

    @discardableResult
    internal func markExpandedSplitChatNavigationPresenting(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController
    ) -> Bool {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              transaction.phase == .preparing else {
            return false
        }
        if let splitViewController {
            let supplementary = splitViewController.viewController(
                for: .supplementary
            )
            let supplementaryTop = (supplementary as? UINavigationController)?
                .topViewController ?? supplementary
            transaction = transaction.replacingSupplementaryIdentity(
                containerIdentifier:
                    supplementary.map(ObjectIdentifier.init),
                topViewControllerIdentifier:
                    supplementaryTop.map(ObjectIdentifier.init)
            )
        }
        transaction.phase = .presenting
        transaction.preparationHandle = nil
        expandedSplitChatNavigationTransaction = transaction
        return true
    }

    @discardableResult
    internal func completeExpandedSplitChatNavigationPresentation(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        transitionOwner: UIViewController
    ) -> Bool {
        guard var transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              transaction.phase == .presenting else {
            return false
        }
        if let validateAfterPresentation = transaction.activationContext?
            .validateAfterPresentation {
            guard let splitViewController,
                  chatNavigationRouteResolver(self) ==
                    .splitDetailReplacement,
                  transaction.accountEpoch.isExactValidMatch(
                    for: chatNavigationAccountEpochResolver(target)
                  ) else {
                return false
            }
            let supplementary = splitViewController.viewController(
                for: .supplementary
            )
            let supplementaryTop =
                (supplementary as? UINavigationController)?
                    .topViewController ?? supplementary
            let secondary = splitViewController.viewController(for: .secondary)
            let secondaryTop = (secondary as? UINavigationController)?
                .topViewController ?? secondary
            let window = splitViewController.viewIfLoaded?.window
            guard supplementaryTop === self,
                  secondaryTop === destination,
                  destination.navigationController?.topViewController ===
                    destination,
                  UIApplication.shared.applicationState == .active,
                  window != nil,
                  window?.isHidden == false,
                  (window?.alpha ?? 0) > 0,
                  window?.isKeyWindow == true,
                  window?.windowScene?.activationState == .foregroundActive,
                  splitViewController.presentedViewController == nil,
                  supplementary?.presentedViewController == nil,
                  supplementaryTop?.presentedViewController == nil,
                  secondary?.presentedViewController == nil,
                  secondaryTop?.presentedViewController == nil,
                  validateAfterPresentation(destination) else {
                return false
            }
        }
        transaction.phase = .presented
        transaction.preparationHandle = nil
        transaction.activationContext = nil
        expandedSplitChatNavigationTransaction = transaction
        stopExpandedSplitAccountRegistryMutationObservation()
        currentChatVC = destination
        playerViewToolbar.delegate = destination
        if chatOpenIntentOwnership?.navigationSource == .standard {
            clearChatOpenIntentOwnership(destination: destination)
        }
        schedulePendingMessageNotificationRouteRetryOrEnqueue(
            after: transitionOwner
        )
        return true
    }

    internal func resetExpandedSplitChatNavigationTransaction(
        restorePreviousDetail: Bool,
        preserveIntentOwnership: Bool = false
    ) {
        stopExpandedSplitAccountRegistryMutationObservation()
        guard let transaction = expandedSplitChatNavigationTransaction else {
            return
        }
        transaction.preparationHandle?.cancel()
        if restorePreviousDetail,
           currentChatVC == nil || currentChatVC === transaction.destination {
            currentChatVC = transaction.previousVisibleDetail
            playerViewToolbar.delegate = transaction.previousVisibleDetail
        }
        expandedSplitChatNavigationTransaction = nil
        if !preserveIntentOwnership {
            clearChatOpenIntentOwnership(destination: transaction.destination)
        }
    }

    @discardableResult
    internal func completeChatNavigationPresentation(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController
    ) -> Bool {
        guard chatNavigationSingleFlight.markPresented(
            token: token,
            target: target
        ) else {
            return false
        }
        clearRetainedCompactChatNavigationDestination(token: token)
        if chatOpenIntentOwnership?.navigationSource == .standard {
            clearChatOpenIntentOwnership(destination: destination)
        }
        schedulePendingMessageNotificationRouteRetryOrEnqueue(
            after: destination
        )
        return true
    }

    /// Transition ownership can disappear between eligibility inspection and
    /// UIKit registration. Every call site uses this helper so that race keeps
    /// one coalesced async wake instead of silently dropping the pending route.
    internal func schedulePendingMessageNotificationRouteRetryOrEnqueue(
        after destination: UIViewController
    ) {
        if !schedulePendingMessageNotificationRouteRetry(after: destination) {
            enqueuePendingMessageNotificationRouteWakeup()
        }
    }

    internal func enqueuePendingMessageNotificationRouteWakeup() {
        guard !isPendingMessageNotificationRetryScheduled else {
            return
        }
        isPendingMessageNotificationRetryScheduled = true
        pendingMessageNotificationRetryGeneration &+= 1
        let generation = pendingMessageNotificationRetryGeneration
        pendingMessageNotificationAsyncScheduler { [weak self] in
            guard let self,
                  self.isPendingMessageNotificationRetryScheduled,
                  self.pendingMessageNotificationRetryGeneration == generation else {
                return
            }
            self.isPendingMessageNotificationRetryScheduled = false
            _ = self.pendingMessageNotificationRouteRetryHandler()
        }
    }

    @discardableResult
    internal func schedulePendingMessageNotificationRouteRetry(
        after destination: UIViewController
    ) -> Bool {
        guard !isPendingMessageNotificationRetryScheduled else {
            return true
        }
        isPendingMessageNotificationRetryScheduled = true
        pendingMessageNotificationRetryGeneration &+= 1
        let generation = pendingMessageNotificationRetryGeneration

        let retry: () -> Void = { [weak self] in
            guard let self,
                  self.isPendingMessageNotificationRetryScheduled,
                  self.pendingMessageNotificationRetryGeneration == generation else {
                return
            }
            self.isPendingMessageNotificationRetryScheduled = false
            _ = self.pendingMessageNotificationRouteRetryHandler()
        }

        let registered = pendingMessageNotificationTransitionRegistrar(
            destination,
            { [weak self] _ in
                guard let self,
                      self.pendingMessageNotificationRetryGeneration == generation else {
                    return
                }
                // Cancellation does not consume the notification route. UIKit
                // has nevertheless completed this transition epoch, so retry.
                self.pendingMessageNotificationAsyncScheduler(retry)
            }
        )
        guard registered else {
            if pendingMessageNotificationRetryGeneration == generation {
                isPendingMessageNotificationRetryScheduled = false
            }
            return false
        }
        return true
    }

    internal func cancelPendingMessageNotificationRouteRetry() {
        pendingMessageNotificationRetryGeneration &+= 1
        isPendingMessageNotificationRetryScheduled = false
    }

    internal func retryPendingMessageNotificationRouteOnLifecycleStability() {
        enqueuePendingMessageNotificationRouteWakeup()
    }

    internal func updateChatOpenIntentOwnershipIfNeeded(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destinationIdentifier: ObjectIdentifier,
        intent: LastChatsResolvedChatOpenIntent,
        navigationSource: ChatOpenNavigationSource
    ) {
        guard chatOpenIntentOwnership?.target != target ||
                chatOpenIntentOwnership?.destinationIdentifier != destinationIdentifier ||
                chatOpenIntentOwnership?.intent != intent ||
                chatOpenIntentOwnership?.navigationSource != navigationSource else {
            return
        }
        chatOpenIntentOwnership = LastChatsChatOpenIntentOwnership(
            target: target,
            destinationIdentifier: destinationIdentifier,
            intent: intent,
            navigationSource: navigationSource
        )
    }

    internal func clearChatOpenIntentOwnership(
        destination: ChatViewController? = nil
    ) {
        guard destination == nil ||
                chatOpenIntentOwnership?.destinationIdentifier == destination.map(ObjectIdentifier.init) else {
            return
        }
        destination?.chatOpenStableVisibilityAcknowledgementHandler = nil
        chatOpenIntentOwnership = nil
    }

    internal func beginOutgoingChatOpenNavigationDeferral(
        token: UUID? = nil,
        preparationTimeout: TimeInterval = LastChatsNavigationSingleFlightCoordinator.defaultPreparationTimeout
    ) {
        if self.navigationItem.backButtonDisplayMode != .minimal {
            self.navigationItem.backButtonDisplayMode = .minimal
        }
        let nativeBackAccessibilityLabel = "Back".localizeString(
            id: "chat_attachment_action_back",
            arguments: []
        )
        let nativeBackChevron = Self.makeImmediateNativeBackChevron()
        if let navigationBar = self.navigationController?.navigationBar {
            if navigationBar.backIndicatorImage == nil {
                navigationBar.backIndicatorImage = nativeBackChevron
            }
            if navigationBar.backIndicatorTransitionMaskImage == nil {
                navigationBar.backIndicatorTransitionMaskImage = nativeBackChevron
            }
        }
        if self.navigationItem.backBarButtonItem == nil {
            // On iOS 26 an implicit Back can be replaced by a non-interactive
            // portal snapshot of this controller's account item during an
            // animated push. Supplying the source back item up front keeps
            // rendering and activation in UINavigationController ownership;
            // an empty title keeps the native indicator visually minimal.
            let backItem = UIBarButtonItem(
                title: "",
                style: .plain,
                target: nil,
                action: nil
            )
            backItem.accessibilityIdentifier =
                Self.nativeChatBackAccessibilityIdentifier
            backItem.accessibilityLabel = nativeBackAccessibilityLabel
            self.navigationItem.backBarButtonItem = backItem
        }
        if let backItem = self.navigationItem.backBarButtonItem {
            if backItem.title != "" {
                backItem.title = ""
            }
            if backItem.image != nil {
                backItem.image = nil
            }
            backItem.target = nil
            backItem.action = nil
            backItem.accessibilityIdentifier =
                Self.nativeChatBackAccessibilityIdentifier
            backItem.accessibilityLabel = nativeBackAccessibilityLabel
        }
        let replacesPendingPreparation = outgoingChatOpenNavigationDeferralToken != nil
        if let previousToken = outgoingChatOpenNavigationDeferralToken,
           previousToken != token {
            _ = cancelOutgoingChatOpenNavigationPreparation(token: previousToken)
        }
        if !self.isNavigationTransitionActive {
            self.navigationDatasetMutationGeneration &+= 1
        }
        self.isNavigationTransitionActive = true
        if self.isDatasetUpdateInFlight {
            self.pendingDatasetUpdateAfterNavigationTransition = true
        }
        self.accountNavButton.setRenderingFrozen(true)
        self.shouldSuppressNextDatasetAnimation = true
        if replacesPendingPreparation {
            DDLogDebug("LAST_CHATS_NAVIGATION event=preparationRetargeted")
        } else {
            DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=outgoingChatOpenDeferralBegin")
        }

        guard let token else {
            return
        }

        chatNavigationPreparationTimeoutWorkItem?.cancel()
        outgoingChatOpenNavigationDeferralToken = token
        let timeout = preparationTimeout.isFinite
            ? max(0, preparationTimeout)
            : LastChatsNavigationSingleFlightCoordinator.defaultPreparationTimeout
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleChatNavigationPreparationTimeout(token: token)
        }
        chatNavigationPreparationTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
    }

    /// Materializes UIKit's one navigation-bar indicator before the push
    /// starts. The source `backBarButtonItem` deliberately stays image-free:
    /// giving it the same artwork would render a second chevron beside this
    /// system-owned indicator.
    private static func makeImmediateNativeBackChevron() -> UIImage {
        let size = CGSize(width: 12, height: 20)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let rasterized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 9.5, y: 2))
            path.addLine(to: CGPoint(x: 3, y: 10))
            path.addLine(to: CGPoint(x: 9.5, y: 18))
            path.lineWidth = 2.25
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            UIColor.black.setStroke()
            path.stroke()
        }
        return rasterized.withRenderingMode(.alwaysTemplate)
    }

    @discardableResult
    internal func registerOutgoingChatOpenNavigationPreparation(
        _ handle: StackedNavigationPresentationPreparationHandle,
        token: UUID
    ) -> Bool {
        guard outgoingChatOpenNavigationDeferralToken == token,
              chatNavigationSingleFlight.state?.token == token,
              chatNavigationSingleFlight.state?.phase == .preparing else {
            handle.cancel()
            return false
        }
        if let existingHandle = outgoingChatOpenNavigationPreparationHandle,
           existingHandle !== handle {
            existingHandle.cancel()
        }
        outgoingChatOpenNavigationPreparationToken = token
        outgoingChatOpenNavigationPreparationHandle = handle
        return true
    }

    @discardableResult
    private func cancelOutgoingChatOpenNavigationPreparation(token: UUID) -> Bool {
        guard outgoingChatOpenNavigationPreparationToken == token,
              let handle = outgoingChatOpenNavigationPreparationHandle else {
            return false
        }
        outgoingChatOpenNavigationPreparationToken = nil
        outgoingChatOpenNavigationPreparationHandle = nil
        handle.cancel()
        return true
    }

    private func releaseOutgoingChatOpenNavigationPreparation(token: UUID) {
        guard outgoingChatOpenNavigationPreparationToken == token else {
            return
        }
        outgoingChatOpenNavigationPreparationToken = nil
        outgoingChatOpenNavigationPreparationHandle = nil
    }

    @discardableResult
    internal func cancelChatNavigationPreparation(
        token: UUID,
        reason: LastChatsNavigationPreparationCancellationReason
    ) -> Bool {
        guard outgoingChatOpenNavigationDeferralToken == token,
              chatNavigationSingleFlight.state?.phase == .preparing,
              chatNavigationSingleFlight.cancel(token: token),
              endOutgoingChatOpenNavigationDeferral(token: token, cancelled: true) else {
            return false
        }
        clearRetainedCompactChatNavigationDestination(token: token)
        switch reason {
        case .presentationGuardRejected:
            DDLogDebug("LAST_CHATS_NAVIGATION event=preparationCancelled reason=guardRejected")
        case .preparationTimedOut:
            DDLogDebug("LAST_CHATS_NAVIGATION event=preparationCancelled reason=timeout")
        }
        return true
    }

    @discardableResult
    internal func handleChatNavigationPreparationTimeout(token: UUID) -> Bool {
        guard outgoingChatOpenNavigationDeferralToken == token,
              chatNavigationSingleFlight.state?.token == token,
              chatNavigationSingleFlight.state?.phase == .preparing else {
            return false
        }
        return cancelChatNavigationPreparation(
            token: token,
            reason: .preparationTimedOut
        )
    }

    @discardableResult
    internal func commitChatNavigationPush(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target
    ) -> Bool {
        guard outgoingChatOpenNavigationDeferralToken == token,
              chatNavigationSingleFlight.markPushing(
                token: token,
                target: target
              ) else {
            return false
        }
        chatNavigationPreparationTimeoutWorkItem?.cancel()
        chatNavigationPreparationTimeoutWorkItem = nil
        releaseOutgoingChatOpenNavigationPreparation(token: token)
        DDLogDebug("LAST_CHATS_NAVIGATION event=pushing phase=pushing")
        return true
    }

    @discardableResult
    private func endOutgoingChatOpenNavigationDeferral(
        token: UUID,
        cancelled: Bool
    ) -> Bool {
        guard outgoingChatOpenNavigationDeferralToken == token else {
            return false
        }
        if cancelled {
            _ = cancelOutgoingChatOpenNavigationPreparation(token: token)
        } else {
            releaseOutgoingChatOpenNavigationPreparation(token: token)
        }
        outgoingChatOpenNavigationDeferralToken = nil
        chatNavigationPreparationTimeoutWorkItem?.cancel()
        chatNavigationPreparationTimeoutWorkItem = nil
        completeNavigationTransitionDeferral(cancelled: cancelled)
        DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=outgoingChatOpenDeferralEnd")
        return true
    }

    internal func resetChatNavigationTransaction(cancelled: Bool) {
        let hadOutgoingDeferral = outgoingChatOpenNavigationDeferralToken != nil
        let hadTransaction = chatNavigationSingleFlight.state != nil
        let retainedDestination = retainedCompactChatNavigationDestination?.controller
        if let preparationToken = outgoingChatOpenNavigationPreparationToken {
            _ = cancelOutgoingChatOpenNavigationPreparation(token: preparationToken)
        }
        chatNavigationPreparationTimeoutWorkItem?.cancel()
        chatNavigationPreparationTimeoutWorkItem = nil
        outgoingChatOpenNavigationDeferralToken = nil
        shouldResetChatNavigationTransactionOnNextAppearance = false
        completedChatNavigationReturnTransition = nil
        pendingChatNavigationTransitionCompletionTokens.removeAll()
        chatNavigationSingleFlight.reset()
        clearRetainedCompactChatNavigationDestination()
        if let retainedDestination {
            clearChatOpenIntentOwnership(destination: retainedDestination)
        }
        if cancelled {
            cancelPendingMessageNotificationRouteRetry()
        }
        if hadTransaction {
            DDLogDebug("LAST_CHATS_NAVIGATION event=reset phase=idle")
        }

        if hadOutgoingDeferral || isNavigationTransitionActive {
            completeNavigationTransitionDeferral(cancelled: cancelled)
        } else {
            flushPendingNavigationTransitionWork()
        }
    }

    internal func markChatNavigationPresenterWillDisappear() {
        guard chatNavigationSingleFlight.state != nil else {
            return
        }
        completedChatNavigationReturnTransition = nil
        shouldResetChatNavigationTransactionOnNextAppearance = true
    }

    /// Accepts only the native terminal callback for the exact navigation
    /// token. A cancelled push can structurally restore Last Chats and invoke
    /// `viewDidAppear` before the transition coordinator publishes terminal;
    /// that temporary hierarchy must not unlock another chat open.
    @discardableResult
    internal func completeChatNavigationReturnTransition(
        token: UUID,
        cancelled: Bool,
        scheduleLifecycleRetry: Bool = true
    ) -> Bool {
        guard shouldResetChatNavigationTransactionOnNextAppearance,
              chatNavigationSingleFlight.state?.token == token else {
            return false
        }
        let sourceIsCurrentNavigationTop = navigationController == nil ||
            navigationController?.topViewController === self
        guard sourceIsCurrentNavigationTop else {
            return false
        }
        guard hasCompletedCurrentAppearance else {
            completedChatNavigationReturnTransition = .init(
                token: token,
                cancelled: cancelled
            )
            return false
        }

        completedChatNavigationReturnTransition = nil
        resetChatNavigationTransaction(cancelled: cancelled)
        if scheduleLifecycleRetry {
            retryPendingMessageNotificationRouteOnLifecycleStability()
        }
        return true
    }

    /// Returns true while this reconciliation owns the lifecycle retry. The
    /// caller must not enqueue a second retry in that case.
    @discardableResult
    internal func reconcileChatNavigationTransactionOnDidAppear(
        scheduleLifecycleRetry: Bool = false
    ) -> Bool {
        hasCompletedCurrentAppearance = true
        let preservesProgrammaticPreparation =
            chatNavigationSingleFlight.state?.phase == .preparing &&
            !shouldResetChatNavigationTransactionOnNextAppearance
        guard !preservesProgrammaticPreparation else {
            DDLogDebug("LAST_CHATS_NAVIGATION event=preparationPreserved reason=firstAppearance")
            return false
        }
        guard let state = chatNavigationSingleFlight.state else {
            shouldResetChatNavigationTransactionOnNextAppearance = false
            completedChatNavigationReturnTransition = nil
            return false
        }
        if !shouldResetChatNavigationTransactionOnNextAppearance {
            shouldResetChatNavigationTransactionOnNextAppearance = true
        }
        if let completion = completedChatNavigationReturnTransition,
           completion.token == state.token {
            return completeChatNavigationReturnTransition(
                token: completion.token,
                cancelled: completion.cancelled,
                scheduleLifecycleRetry: scheduleLifecycleRetry
            )
        }
        if completedChatNavigationReturnTransition != nil {
            completedChatNavigationReturnTransition = nil
        }
        if pendingChatNavigationTransitionCompletionTokens.contains(
            state.token
        ) {
            return true
        }
        if self.transitionCoordinator != nil ||
            navigationController?.transitionCoordinator != nil {
            return true
        }
        return completeChatNavigationReturnTransition(
            token: state.token,
            cancelled: false,
            scheduleLifecycleRetry: scheduleLifecycleRetry
        )
    }

    /// Resolves the source-side navigation barrier. This is internal so the
    /// exact cancellation callback path can be exercised deterministically in
    /// hosted tests where UIKit defers custom interactive transition contexts.
    internal func completeNavigationTransitionDeferral(cancelled: Bool) {
        let sourceIsTopAndAppeared = self.navigationController?.topViewController === self
            && self.hasCompletedCurrentAppearance
        if self.outgoingChatOpenNavigationDeferralToken != nil,
           !sourceIsTopAndAppeared {
            // A successful push and a cancelled interactive pop both leave
            // Last Chats hidden. Keep every source mutation frozen until an
            // actual return makes this controller top and appeared.
            if cancelled {
                // Closures captured while UIKit temporarily exposed the
                // source hierarchy belong to the cancelled transition and
                // must never replay on a later pop. Request fresh,
                // Realm-backed chrome and dataset work instead.
                self.pendingNavigationTransitionWork.removeAll()
                self.pendingNavigationChromeRefreshAfterNavigationTransition = true
                self.pendingDatasetUpdateAfterNavigationTransition = true
                self.shouldSuppressNextDatasetAnimation = true
            }
            self.isNavigationTransitionActive = true
            return
        }

        self.isNavigationTransitionActive = false
        self.flushPendingNavigationTransitionWork(
            replayCapturedWork: !cancelled
        )
    }

    internal func cancelPendingRootChatActivation() {
        rootChatActivationGeneration &+= 1
        rootChatActivationTarget = nil
        pendingRootChatActivation = nil
    }

    /// A newly installed compact list is not yet a valid chat presenter. Keep
    /// its exact root intent until UIKit attaches and finishes its appearance;
    /// the ordinary stackNewChat admission guards still own the eventual push.
    @discardableResult
    internal func deferRootChatActivationIfNeeded(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        activate: @escaping () -> Void
    ) -> Bool {
        cancelPendingRootChatActivation()
        guard !hasCompletedCurrentAppearance || !isAppeared ||
                viewIfLoaded?.window == nil || isNavigationTransitionActive else {
            return false
        }
        rootChatActivationTarget = target
        pendingRootChatActivation = (rootChatActivationGeneration, target, activate)
        flushPendingRootChatActivationAfterAppearance()
        return true
    }

    private func flushPendingRootChatActivationAfterAppearance() {
        guard hasCompletedCurrentAppearance, isAppeared,
              viewIfLoaded?.window != nil,
              let pending = pendingRootChatActivation else { return }
        pendingRootChatActivation = nil
        let activate = { [weak self] in
            guard let self,
                  self.rootChatActivationGeneration == pending.generation,
                  self.rootChatActivationTarget == pending.target else { return }
            self.rootChatActivationTarget = nil
            pending.activate()
        }
        if !deferUntilNavigationTransitionCompletesIfNeeded(activate) {
            activate()
        }
    }

    @discardableResult
    internal func deferUntilNavigationTransitionCompletesIfNeeded(_ work: @escaping () -> Void) -> Bool {
        guard LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
            isTransitionActive: self.isNavigationTransitionActive,
            isCriticalForFirstFrame: false
        ) else {
            return false
        }
        self.pendingNavigationTransitionWork.append(work)
        return true
    }

    internal func flushPendingNavigationTransitionWork() {
        flushPendingNavigationTransitionWork(replayCapturedWork: true)
    }

    private func flushPendingNavigationTransitionWork(replayCapturedWork: Bool) {
        guard !self.isNavigationTransitionActive else {
            return
        }
        let work = self.pendingNavigationTransitionWork
        let shouldRefreshDataset = self.pendingDatasetUpdateAfterNavigationTransition
        let shouldRefreshNavigationChrome =
            self.pendingNavigationChromeRefreshAfterNavigationTransition
        self.pendingNavigationTransitionWork.removeAll()
        self.pendingDatasetUpdateAfterNavigationTransition = false
        self.pendingNavigationChromeRefreshAfterNavigationTransition = false

        if replayCapturedWork {
            work.forEach { $0() }
        }
        if shouldRefreshNavigationChrome {
            UIView.performWithoutAnimation {
                self.configureBars(updateNavigationItems: true)
            }
        }
        self.accountNavButton.setRenderingFrozen(false)
        if shouldRefreshDataset {
            self.runDatasetUpdateTask()
        } else {
            self.shouldSuppressNextDatasetAnimation = false
        }
    }
    
    override func resetState() {
        cancelPendingRootChatActivation()
        super.resetState()
        self.resetExpandedSplitChatNavigationTransaction(
            restorePreviousDetail: false
        )
        self.currentChatVC = nil
        self.resetChatNavigationTransaction(cancelled: true)
        self.selectedChatIdentity = nil
    }
    
    internal func configurePlayerView() {
        self.setupPinnedVoicePlayerIfNeeded()
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }
    
    
    internal func showPlayerViewIfNeeded() {
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }

    internal func configureVoiceMessagePlaybackCoordinatorObserver() {
        VoiceMessagePlaybackCoordinator.shared.removeObserver(voiceMessageStateObserverToken)
        voiceMessageStateObserverToken = VoiceMessagePlaybackCoordinator.shared.addObserver { [weak self] change in
            DispatchQueue.main.async {
                self?.handleVoiceMessageStateChange(change)
            }
        }
    }

    private func handleVoiceMessageStateChange(_ change: VoiceMessageStateChange) {
        if self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
            self?.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
        }) {
            return
        }
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }

    private func setupPinnedVoicePlayerIfNeeded() {
        guard self.pinnedVoicePlayerView.superview == nil else {
            self.view.bringSubviewToFront(self.pinnedVoicePlayerView)
            self.updateTableInsetsForPinnedVoicePlayer()
            return
        }

        self.pinnedVoicePlayerView.delegate = self
        self.view.addSubview(self.pinnedVoicePlayerView)
        let heightConstraint = self.pinnedVoicePlayerView.heightAnchor.constraint(equalToConstant: AudioPlayerBarView.Metrics.height)
        self.pinnedVoicePlayerHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            self.pinnedVoicePlayerView.topAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.topAnchor,
                constant: AudioPlayerBarView.Metrics.topOffset
            ),
            self.pinnedVoicePlayerView.leadingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.leadingAnchor,
                constant: AudioPlayerBarView.Metrics.horizontalInset
            ),
            self.pinnedVoicePlayerView.trailingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.trailingAnchor,
                constant: -AudioPlayerBarView.Metrics.horizontalInset
            ),
            heightConstraint
        ])

        self.view.bringSubviewToFront(self.pinnedVoicePlayerView)
        self.updateTableInsetsForPinnedVoicePlayer()
    }

    private func renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackSnapshot?) {
        self.setupPinnedVoicePlayerIfNeeded()
        self.pinnedVoicePlayerView.render(snapshot: snapshot)
        if snapshot != nil {
            self.view.bringSubviewToFront(self.pinnedVoicePlayerView)
        }
        self.updateTableInsetsForPinnedVoicePlayer()
    }

    internal func updateTableInsetsForPinnedVoicePlayer() {
        let topInset = self.pinnedVoicePlayerView.superview != nil && !self.pinnedVoicePlayerView.isHidden
            ? AudioPlayerBarView.Metrics.reservedTopInset
            : 0
        let previousTopInset = self.tableView.contentInset.top
        let insetDelta = topInset - previousTopInset
        let previousContentOffsetY = self.tableView.contentOffset.y

        if abs(insetDelta) > 0.5 {
            self.tableView.contentInset.top = topInset
            let minimumY = -self.tableView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                self.tableView.contentSize.height + self.tableView.adjustedContentInset.bottom - self.tableView.bounds.height
            )
            self.tableView.contentOffset.y = LastChatsPinnedVoicePlayerInsetPolicy.adjustedContentOffsetY(
                currentY: previousContentOffsetY,
                insetDelta: insetDelta,
                minimumY: minimumY,
                maximumY: maximumY
            )
        }
        if self.tableView.verticalScrollIndicatorInsets.top != topInset {
            self.tableView.verticalScrollIndicatorInsets.top = topInset
        }
    }

    private func openActiveVoiceMessageRoute() {
        guard let route = VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot?.route else {
            return
        }
        self.stackNewChat(
            owner: route.owner,
            jid: route.jid,
            conversationType: route.conversationType,
            openMessageRequest: Self.voicePlayerOpenRequest(route: route)
        )
    }

    internal func sharedVoiceDescriptor(referencePrimary: String) -> VoiceMessageDescriptor? {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) else {
                return nil
            }
            return VoiceMessageDescriptor(
                referencePrimary: reference.primary,
                containerMessagePrimary: reference.messageId,
                remoteURL: reference.downloadUrl,
                decodedURL: reference.decodedUrl,
                duration: TimeInterval(reference.duration ?? 0),
                downloaded: reference.isDownloaded || reference.decodedUrl != nil,
                pcm: reference.meteringLevels ?? [],
                sentDate: reference.sentDate,
                encryptedAttachment: ChatEncryptedAttachmentDescriptor(metadata: reference.metadata,
                    url: reference.downloadUrl, owner: reference.owner, referenceIdentity: reference.primary),
                authenticatedAttachmentCacheIdentity: reference.metadata?["authenticated-media-cache-identity"] as? String
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }
    
    internal let navigationTitleView = LastChatsNavigationTitleView(frame: .zero)

    internal func updateTitle(_ value: Filter) {
        guard !self.isNavigationTransitionActive else {
            self.pendingNavigationChromeRefreshAfterNavigationTransition = true
            return
        }
        self.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
        navigationTitleView.titleLabel.text = self.title
    }
    
    private final func scrollTableViewToTop(animated: Bool) {
        let offset = CGPoint(
            x: tableView.contentOffset.x,
            y: -tableView.adjustedContentInset.top
        )
        tableView.setContentOffset(offset, animated: animated)
    }

    internal func updateDatasource(_ value: Filter) {
        do {
            let realm = try  WRealm.safe()
            let jids = Array(realm.objects(AccountStorageItem.self).filter("enabled == true").map(\.jid))
            let predicate: NSPredicate
            switch value {
            case .chats:
                predicate = NSPredicate(
                    format: "isArchived == false AND owner IN %@",
                    argumentArray: [Array(enabledAccounts.value)]
                )
            case .unread:
//                showArchivedSection.accept(false)
                predicate = NSPredicate(format: "isArchived == %@ AND unread > %@ AND owner IN %@",
                                        argumentArray: [false,
                                                        0,
                                                        Array(enabledAccounts.value)])
                scrollTableViewToTop(animated: false)
            case .archived:
                predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [true, Array(enabledAccounts.value)])
            case .saved:
                let enabledOwners = Array(enabledAccounts.value)
                predicate = SavedMessagesAvailabilityPolicy.visibleSavedLastChatsPredicate(
                    enabledOwners: enabledOwners,
                    favoritesNodesByOwner: SavedMessagesAvailabilityPolicy.favoritesNodesByOwner(
                        in: realm,
                        enabledOwners: enabledOwners
                    )
                )
            }
            let chats = realm
                .objects(LastChatsStorageItem.self)
                .filter(predicate)
            
            datasetBag = DisposeBag()
            updateStartupRecentsSkeleton(for: value)

            self.showSkeleton
                .asObservable()
//                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { _ in
                    
//                    print(#function, "show skeleton")
                    self.runDatasetUpdateTask()
                }
                .disposed(by: self.datasetBag)
            
            
            let requests = realm
                .objects(UINotificationStorageItem.self)
                .filter("owner IN %@ AND isRead == %@ AND kind_ == %@", jids, false, UINotificationStorageItem.Kind.contactRequest.rawValue)
            
            Observable
                .collection(from: requests)
                .skip(1)
                .debounce(.milliseconds(800), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.runDatasetUpdateTask()
                }
                .disposed(by: self.datasetBag)

            let incomingInvites = PublishSubject<[GroupInviteRecord]>()
            incomingInvites
                .skip(1)
                .debounce(.milliseconds(900), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] _ in
                    self?.runDatasetUpdateTask()
                })
                .disposed(by: self.datasetBag)
            let inviteObservation = GroupRepository(realm: realm).observeIncomingInvites(
                owners: jids
            ) { invites in
                incomingInvites.onNext(invites)
            }
            Disposables.create { inviteObservation.invalidate() }
                .disposed(by: datasetBag)
            
            observeChats(chats, in: realm, function: #function)

            let enabledOwners = Array(enabledAccounts.value)
            Observable
                .collection(from: realm.objects(RosterStorageItem.self).filter("owner IN %@", enabledOwners))
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe(onNext: { _ in
                    self.scheduleProjectionRefresh(.roster)
                })
                .disposed(by: datasetBag)

            Observable
                .collection(from: realm.objects(ResourceStorageItem.self).filter("owner IN %@", enabledOwners))
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe(onNext: { _ in
                    self.scheduleProjectionRefresh(.resource)
                })
                .disposed(by: datasetBag)

            canUpdateDataset = true
            runDatasetUpdateTask()
            
            Observable
                .collection(from: chats)
                .subscribe(onNext: { (results) in
                    if self.filter.value == .unread {
                        LeftMenuFirstPresentationPolicy.animate(
                            withDuration: 0.1,
                            isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
                        ) {
                            self.unreadAllMessagesButton.isHidden = self.filter.value == .unread ? results.filter{ $0.unread != 0 }.isEmpty : false
                            self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                            self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                        }

                    } else {
                        self.unreadAllMessagesButton.isHidden = true
                    }
                    self.updateBottomTitle()
                })
                .disposed(by: datasetBag)
            
        } catch {
            DDLogDebug("cant change filter for last chats")
        }
    }
    
    var unreadedJids: [String] = []
    
    internal final func datasourceKey(jid: String, owner: String) -> String {
        [jid, owner].prp()
    }
    
    internal static func makeDatasourceSections(
        from datasource: [Datasource],
        showsSkeleton: Bool
    ) -> [DatasourceSection] {
        let specialRows = showsSkeleton
            ? []
            : datasource.filter { $0.specialMessageKind != .none }
        let chatRows = datasource.filter { $0.specialMessageKind == .none }

        var sections: [DatasourceSection] = []
        if specialRows.isNotEmpty {
            sections.append(DatasourceSection(kind: .specialMessages, rows: specialRows))
        }
        sections.append(DatasourceSection(kind: .chats, rows: chatRows))
        return sections
    }

    internal static func item(at indexPath: IndexPath, in sections: [DatasourceSection]) -> Datasource? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row) else {
            return nil
        }
        return sections[indexPath.section].rows[indexPath.row]
    }

    internal static func sectionIndex(
        of kind: DatasourceSectionKind,
        in sections: [DatasourceSection]
    ) -> Int? {
        sections.firstIndex { $0.kind == kind }
    }

    internal static func indexPathForChat(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in sections: [DatasourceSection]
    ) -> IndexPath? {
        guard let section = sectionIndex(of: .chats, in: sections) else { return nil }
        guard let row = sections[section].rows.firstIndex(where: {
            $0.specialMessageKind == .none
                && $0.jid == jid
                && $0.owner == owner
                && $0.conversationType == conversationType
        }) else {
            return nil
        }
        return IndexPath(row: row, section: section)
    }

    internal static func indexPathForChat(
        _ identity: SelectedChatIdentity,
        in sections: [DatasourceSection]
    ) -> IndexPath? {
        indexPathForChat(
            jid: identity.jid,
            owner: identity.owner,
            conversationType: identity.conversationType,
            in: sections
        )
    }

    internal final func isSelectedChat(_ item: Datasource) -> Bool {
        selectedChatIdentity?.matches(item) ?? false
    }

    internal final func setSelectedChat(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        animated: Bool,
        scrollPosition: UITableView.ScrollPosition = .none
    ) {
        let previousIdentity = selectedChatIdentity
        let currentIdentity = SelectedChatIdentity(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        selectedChatIdentity = currentIdentity
        updateVisibleSelectionRows(
            previousIdentity: previousIdentity,
            currentIdentity: currentIdentity,
            animated: animated,
            scrollPosition: scrollPosition
        )
    }

    internal final func syncSelectedChatSelection(
        animated: Bool = false,
        scrollPosition: UITableView.ScrollPosition = .none
    ) {
        let selectedIndexPath = selectedChatIdentity.flatMap {
            Self.indexPathForChat($0, in: datasourceSections)
        }

        tableView.indexPathsForSelectedRows?
            .filter { indexPath in
                selectedIndexPath.map { indexPath != $0 } ?? true
            }
            .forEach { tableView.deselectRow(at: $0, animated: false) }

        guard let selectedIndexPath else {
            return
        }

        tableView.selectRow(at: selectedIndexPath, animated: animated, scrollPosition: scrollPosition)
        reconfigureVisibleRow(at: selectedIndexPath)
    }

    internal final func clearSelectedChatSelectionOnReturnIfNeeded(
        route: StackedNavigationRoute,
        animated: Bool
    ) {
        guard LastChatsSelectionReturnPolicy.shouldClearSelectedChat(route: route) else {
            return
        }
        clearSelectedChatSelection(animated: animated)
    }

    internal final func clearSelectedChatSelection(animated: Bool) {
        let selectedIndexPath = selectedChatIdentity.flatMap {
            Self.indexPathForChat($0, in: datasourceSections)
        } ?? tableView.indexPathForSelectedRow

        selectedChatIdentity = nil

        if let tableSelectedIndexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: tableSelectedIndexPath, animated: animated)
        } else if let selectedIndexPath {
            tableView.deselectRow(at: selectedIndexPath, animated: animated)
        }

        guard let selectedIndexPath else {
            return
        }
        reconfigureVisibleSelectionRow(at: selectedIndexPath, animated: animated)
    }

    private final func reconfigureVisibleSelectionRow(at indexPath: IndexPath, animated: Bool) {
        guard !showSkeleton.value,
              let item = item(at: indexPath),
              let cell = tableView.cellForRow(at: indexPath) as? ChatListTableViewCell else {
            return
        }

        let update = {
            self.configureChatCell(cell, with: item)
        }

        guard animated else {
            UIView.performWithoutAnimation(update)
            return
        }

        UIView.transition(
            with: cell,
            duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: update
        )
    }

    private final func updateVisibleSelectionRows(
        previousIdentity: SelectedChatIdentity?,
        currentIdentity: SelectedChatIdentity?,
        animated: Bool,
        scrollPosition: UITableView.ScrollPosition
    ) {
        let previousIndexPath = previousIdentity.flatMap {
            Self.indexPathForChat($0, in: datasourceSections)
        }
        let currentIndexPath = currentIdentity.flatMap {
            Self.indexPathForChat($0, in: datasourceSections)
        }

        if let previousIndexPath,
           currentIndexPath.map({ previousIndexPath != $0 }) ?? true {
            tableView.deselectRow(at: previousIndexPath, animated: false)
        }
        if let currentIndexPath {
            tableView.selectRow(at: currentIndexPath, animated: animated, scrollPosition: scrollPosition)
        }

        Set([previousIndexPath, currentIndexPath].compactMap { $0 })
            .forEach { reconfigureVisibleRow(at: $0) }
    }

    internal func item(at indexPath: IndexPath) -> Datasource? {
        Self.item(at: indexPath, in: datasourceSections)
    }

    internal func sectionKind(at section: Int) -> DatasourceSectionKind? {
        guard datasourceSections.indices.contains(section) else { return nil }
        return datasourceSections[section].kind
    }

    internal final func setDatasource(
        _ newDatasource: [Datasource],
        sections newSections: [DatasourceSection],
        showsSkeleton: Bool
    ) {
        self.datasource = newDatasource
        self.datasourceSections = newSections
        self.datasourceShowsSkeleton = showsSkeleton
        self.datasourceIndexByKey = Dictionary(
            newDatasource.enumerated().map { (index, item) in
                (self.datasourceKey(jid: item.jid, owner: item.owner), index)
            },
            uniquingKeysWith: { _, new in new }
        )
        self.datasourceIndexPathByKey = Dictionary(
            newSections.enumerated().flatMap { sectionIndex, section in
                section.rows.enumerated().map { rowIndex, item in
                    (
                        self.datasourceKey(jid: item.jid, owner: item.owner),
                        IndexPath(row: rowIndex, section: sectionIndex)
                    )
                }
            },
            uniquingKeysWith: { _, new in new }
        )
        self.refreshEmptyStateVisibility()
        self.updateUnreadChatsCounter()
    }

    internal static func hasStructuralTableChanges(_ changes: ChangesWithIndexPath) -> Bool {
        return !changes.deletedSections.isEmpty
            || !changes.insertedSections.isEmpty
            || changes.deletes.isNotEmpty
            || changes.inserts.isNotEmpty
            || changes.moves.isNotEmpty
    }

    internal static func shouldReloadStructuralTableChanges(
        _ changes: ChangesWithIndexPath,
        isQuietModeActive: Bool
    ) -> Bool {
        return isQuietModeActive && hasStructuralTableChanges(changes)
    }

    internal final var floatingBottomBarTitle: String? {
        floatingBottomBarView.centerButton.title(for: .normal)
    }

    internal final var isFloatingBottomBarHidden: Bool {
        floatingBottomBarView.isHidden
    }

    internal final var floatingBottomBarFilterButton: UIButton {
        floatingBottomBarView.leftButton
    }

    internal final var markAllReadButton: UIButton {
        floatingBottomBarView.centerButton
    }

    internal var hasConnectingEnabledAccounts: Bool {
        !AccountManager.shared.connectingUsers.value.isDisjoint(with: self.enabledAccounts.value)
    }

    @discardableResult
    private func updateStartupRecentsSkeleton(for filter: Filter) -> Bool {
        let isRecentsFilter = filter == .chats || filter == .unread
        let shouldShowSkeleton = isRecentsFilter && enabledAccounts.value.contains { owner in
            #if DEBUG
            if let startupRecentsSyncPendingForTesting {
                return startupRecentsSyncPendingForTesting(owner)
            }
            #endif
            return AccountManager.shared.find(for: owner)?.syncManager.isAwaitingStartupRecentsSyncResponse() == true
        }
        guard showSkeleton.value != shouldShowSkeleton else { return false }
        showSkeleton.accept(shouldShowSkeleton)
        return true
    }

    internal struct UnreadChatReadCandidate: Equatable {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let isArchived: Bool
        let unread: Int
        let lastMessagePrimary: String?
        let lastMessageId: String
    }

    internal struct UnreadChatReadTarget: Equatable {
        let owner: String
        let messageTarget: MessageManager.LastChatReadTarget
    }

    internal static func unreadChatReadTargets(
        from candidates: [UnreadChatReadCandidate],
        enabledAccounts: Set<String>
    ) -> [UnreadChatReadTarget] {
        candidates.compactMap { candidate in
            guard enabledAccounts.contains(candidate.owner),
                  !candidate.isArchived,
                  candidate.unread > 0 else {
                return nil
            }

            return UnreadChatReadTarget(
                owner: candidate.owner,
                messageTarget: MessageManager.LastChatReadTarget(
                    jid: candidate.jid,
                    conversationType: candidate.conversationType,
                    lastMessagePrimary: candidate.lastMessagePrimary,
                    lastMessageId: candidate.lastMessageId
                )
            )
        }
    }

    internal var hasVisibleAccountSyncBootstrapInProgress: Bool {
        enabledAccounts.value.contains { jid in
            AccountManager.shared.find(for: jid)?.syncManager.isInitialChatListSynchronizationInProgress() == true
        }
    }

    internal var hasVisibleDatasetUpdatePressureInProgress: Bool {
        LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
            isAccountSyncBootstrapActive: self.hasVisibleAccountSyncBootstrapInProgress,
            isChatHistoryLoadActive: ChatHistoryLoadActivityRegistry.hasActiveHistoryLoad,
            isChatUIResponsivenessGateActive: ChatUIResponsivenessGate.shared.isActive
        )
    }

    internal final func reloadTableViewOrDeferForActiveSwipe() {
        if self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
            self?.reloadTableViewOrDeferForActiveSwipe()
        }) {
            return
        }
        UIView.performWithoutAnimation {
            tableView.reloadData()
            syncSelectedChatSelection()
        }
    }

    @discardableResult
    internal final func reconfigureVisibleRow(at indexPath: IndexPath) -> Bool {
        if LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(
            isDatasetUpdatePressureActive: self.hasVisibleDatasetUpdatePressureInProgress
        ) {
            DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=skipVisibleReconfigure count=1")
            return false
        }
        guard !self.showSkeleton.value,
              let item = self.item(at: indexPath),
              let cell = self.tableView.cellForRow(at: indexPath) else {
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        UIView.performWithoutAnimation {
            switch item.specialMessageKind {
            case .none:
                guard let chatCell = cell as? ChatListTableViewCell else { return }
                self.configureChatCell(chatCell, with: item)
            case .contact, .invite:
                guard let specialCell = cell as? SpecialMessageTableViewCell else { return }
                self.configureSpecialMessageCell(specialCell, with: item)
            }
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
        }
        UIView.setAnimationsEnabled(wereAnimationsEnabled)
        CATransaction.commit()
        return true
    }

    internal final func reconfigureVisibleRows(at indexPaths: [IndexPath]) {
        indexPaths.forEach { self.reconfigureVisibleRow(at: $0) }
    }

    internal static func shouldShowEmptyState(
        filter: Filter,
        isLoading: Bool,
        isSearchActive: Bool,
        datasourceIsEmpty: Bool
    ) -> Bool {
        guard datasourceIsEmpty, !isLoading, !isSearchActive else {
            return false
        }

        switch filter {
        case .chats, .unread, .archived:
            return true
        case .saved:
            return false
        }
    }

    internal final func refreshEmptyStateVisibility(isSearchActive: Bool? = nil) {
        let shouldShow = Self.shouldShowEmptyState(
            filter: filter.value,
            isLoading: showSkeleton.value,
            isSearchActive: isSearchActive ?? searchController.isActive,
            datasourceIsEmpty: datasource.isEmpty
        )

        if isEmptyViewShowed.value != shouldShow {
            isEmptyViewShowed.accept(shouldShow)
        }
        emptyView.isHidden = !shouldShow
    }
    
    private final func excludedDomains(from accounts: Set<String>) -> [String] {
        accounts.compactMap { XMPPJID(string: $0)?.domain }
    }

    private func recentChatsPredicate(ignoredJids: [String]) -> NSPredicate {
        let owners = Array(enabledAccounts.value)
        let config = CommonConfigManager.shared.config
        if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: config.locked_conversation_type) {
            let allowedJids = excludedDomains(from: enabledAccounts.value) + [config.support_jid]
            return NSPredicate(
                format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND NOT (jid IN %@)",
                argumentArray: [false, owners, lockedType.rawValue, allowedJids, ignoredJids]
            )
        }
        return NSPredicate(
            format: "isArchived == %@ AND owner IN %@ AND NOT (jid IN %@)",
            argumentArray: [false, owners, ignoredJids]
        )
    }
    
    private struct PreviewMessageKey: Hashable {
        let owner: String, jid: String, type: String, id: String
    }

    private static func previewMessageKey(for chat: LastChatsStorageItem) -> PreviewMessageKey? {
        let id = chat.lastMessageId
        guard id.isNotEmpty else { return nil }
        return PreviewMessageKey(owner: chat.owner, jid: chat.jid, type: chat.conversationType_, id: id)
    }

    private func observeChats(_ chats: Results<LastChatsStorageItem>, in realm: Realm, function: String) {
        let changes = PublishSubject<Void>()
        changes
            .debounce(.milliseconds(70), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] _ in self?.runDatasetUpdateTask() })
            .disposed(by: datasetBag)

        var previous = Array(chats.map(Self.previewMessageKey(for:)))
        configurePreviewMessageObservation(in: realm, keys: previous)
        Observable.changeset(from: chats, synchronousStart: false)
            .subscribe(onNext: { [weak self] results, delta in
                guard let self else { return }
                var scopeChanged = false
                if let delta, delta.deleted.isEmpty, delta.inserted.isEmpty {
                    for index in delta.updated {
                        let key = Self.previewMessageKey(for: results[index])
                        if previous[index] != key {
                            previous[index] = key
                            scopeChanged = true
                        }
                    }
                } else {
                    // Modification indices use the previous order when the
                    // same notification also inserts or removes rows.
                    let current = Array(results.map(Self.previewMessageKey(for:)))
                    scopeChanged = current != previous
                    previous = current
                }
                if scopeChanged {
                    self.configurePreviewMessageObservation(in: realm, keys: previous)
                }
                if delta != nil || scopeChanged { changes.onNext(()) }
            }, onError: { error in
                DDLogDebug("LastChatsViewController: \(function). RX error: \(error.localizedDescription)")
            }, onCompleted: {
                DDLogDebug("LastChatsViewController: \(function). RX state: completed")
            }, onDisposed: {
                DDLogDebug("LastChatsViewController: \(function). RX state: disposed")
            })
            .disposed(by: datasetBag)
    }

    private func configurePreviewMessageObservation(in realm: Realm, keys scopeKeys: [PreviewMessageKey?]) {
        let visibleKeys = Set(scopeKeys.compactMap { $0 })
        guard visibleKeys != previewMessageObservationKeys else { return }
        previewMessageObservationKeys = visibleKeys
        previewMessageObservationBag = DisposeBag()
        guard !visibleKeys.isEmpty else { return }
        let owners = Array(Set(visibleKeys.map(\.owner)))
        let ids = Array(Set(visibleKeys.map(\.id)))
        let messages = realm.objects(MessageStorageItem.self).filter(
            "owner IN %@ AND (messageId IN %@ OR archivedId IN %@)", owners, ids, ids)
        func keys(_ message: MessageStorageItem) -> Set<PreviewMessageKey> {
            Set([message.messageId, message.archivedId].filter(\.isNotEmpty).map {
                PreviewMessageKey(owner: message.owner, jid: message.opponent,
                    type: message.conversationType_, id: $0)
            })
        }
        var previousKeys: [Set<PreviewMessageKey>] = []
        Observable.changeset(from: messages)
            .subscribe(onNext: { [weak self] event in
                let (results, changes) = event
                guard let changes else { previousKeys = results.map(keys); return }
                var affected = Set<PreviewMessageKey>()
                for index in changes.deleted.sorted(by: >) where previousKeys.indices.contains(index) {
                    affected.formUnion(previousKeys.remove(at: index))
                }
                for index in changes.inserted.sorted() where results.indices.contains(index) {
                    let value = keys(results[index])
                    affected.formUnion(value)
                    if index <= previousKeys.count { previousKeys.insert(value, at: index) }
                }
                for index in changes.updated where results.indices.contains(index) {
                    let value = keys(results[index])
                    affected.formUnion(value)
                    if previousKeys.indices.contains(index) {
                        affected.formUnion(previousKeys[index])
                        previousKeys[index] = value
                    }
                }
                // Only changed records and exact scoped set lookups participate;
                // no owner-history materialization or chats × candidates scan.
                guard !affected.isDisjoint(with: visibleKeys) else { return }
                self?.runDatasetUpdateTask()
            })
            .disposed(by: previewMessageObservationBag)
    }

    private func captureProjectionReadRevision() -> ProjectionReadRevision {
        let owners = enabledAccounts.value
        return ProjectionReadRevision(owners: owners, filter: filter.value.rawValue,
            batches: Dictionary(uniqueKeysWithValues: owners.map { ($0, ClientSyncPageBatch.shared.revision(for: $0)) }),
            previews: Dictionary(uniqueKeysWithValues: owners.map { ($0, LastChatListSyncPreviewStore.shared.revision(for: $0)) }))
    }

    private func projectionReadIsCurrent(_ revision: ProjectionReadRevision) -> Bool {
        revision.owners == enabledAccounts.value && revision.filter == filter.value.rawValue &&
            revision.owners.allSatisfy {
                !ClientSyncPageBatch.shared.isBatchActive(owner: $0) &&
                    ClientSyncPageBatch.shared.revision(for: $0) == revision.batches[$0] &&
                    LastChatListSyncPreviewStore.shared.revision(for: $0) == revision.previews[$0]
            }
    }

    private static func sameRows(_ lhs: [Datasource], _ rhs: [Datasource]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { Datasource.compareContent($0, $1) }
    }

    private func typingStateSnapshot() -> [String: Int] {
        Dictionary(CommonChatStatesManager.shared.observed.value.map {
            ([$0.owner, $0.jid].prp(), $0.state.rawValue)
        }, uniquingKeysWith: { _, new in new })
    }

    private func changedPrimariesAffectCurrentFilter(_ primaries: Set<String>) -> Bool {
        guard primaries.isNotEmpty else { return false }
        if datasource.contains(where: {
            primaries.contains(LastChatsStorageItem.genPrimary(jid: $0.jid,
                owner: $0.owner, conversationType: $0.conversationType))
        }) { return true }
        guard let realm = try? WRealm.safe() else { return true }
        return primaries.contains { primary in
            guard let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary),
                  enabledAccounts.value.contains(chat.owner) else { return false }
            switch filter.value {
            case .chats: return !chat.isArchived && chat.conversationType != .saved
            case .unread: return !chat.isArchived && chat.unread > 0
            case .archived: return chat.isArchived
            case .saved: return chat.conversationType == .saved
            }
        }
    }

    private func projectionContext(showsSpecialMessageBanners: Bool,
        dismissedInvitePrimaries: Set<String>, interfaceStyle: UIUserInterfaceStyle) -> String {
        let owners = enabledAccounts.value.sorted()
        let previews = owners.map { "\($0):\(LastChatListSyncPreviewStore.shared.revision(for: $0))" }
        let typing = CommonChatStatesManager.shared.observed.value
            .filter { enabledAccounts.value.contains($0.owner) }
            .map { [ $0.owner, $0.jid, String($0.state.rawValue) ].prp() }.sorted()
        return Self.framed([String(filter.value.rawValue), Self.framed(owners),
            Self.framed(previews), Self.framed(typing),
            String(showsSpecialMessageBanners), Self.framed(dismissedInvitePrimaries.sorted()),
            String(AccountManager.shared.users.count), CommonConfigManager.shared.config.locked_conversation_type,
            CommonConfigManager.shared.config.support_jid, String(describing: LocalizationRuntime.shared.context),
            String(interfaceStyle.rawValue)])
    }

    private static func framed(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func rowFingerprint(chat: LastChatsStorageItem, message: MessageStorageItem?,
        projection: LastChatListSyncPreviewProjection?, resource: ResourceStorageItem?,
        devices: [SignalDeviceStorageItem], requiresVerification: Bool, context: String) -> Int {
        var h = Hasher()
        h.combine(context); h.combine(chat.primary); h.combine(chat.lastMessageId)
        h.combine(chat.messageDate); h.combine(chat.isSynced); h.combine(chat.isMuted)
        h.combine(chat.unread); h.combine(chat.hasUnreadMention); h.combine(chat.draftMessage)
        h.combine(chat.isPinned); h.combine(chat.pinnedPosition); h.combine(chat.hasErrorInChat)
        h.combine(chat.updateTS); h.combine(chat.isFreshNotEmptyEncryptedChat)
        h.combine(chat.conversationType_); h.combine(requiresVerification)
        h.combine(CommonChatStatesManager.shared.actionText(for: chat.jid, owner: chat.owner))
        if AccountManager.shared.users.count > 1 {
            let color = AccountColorManager.shared.primaryColor(for: chat.owner)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                h.combine(red); h.combine(green); h.combine(blue); h.combine(alpha)
            } else { h.combine(color.cgColor.components ?? []) }
        }
        if let roster = chat.rosterItem {
            h.combine(roster.primary); h.combine(roster.username); h.combine(roster.customUsername)
            h.combine(roster.subscription_); h.combine(roster.ask_); h.combine(roster.removed)
            h.combine(roster.avatarMinUrl); h.combine(roster.avatarMaxUrl); h.combine(roster.oldschoolAvatarKey)
        }
        h.combine(resource?.primary); h.combine(resource?.status_); h.combine(resource?.statusExt)
        h.combine(projection?.text); h.combine(projection?.isAttachment)
        h.combine(projection?.isSystemMessage); h.combine(projection?.groupchatNickname)
        h.combine(projection?.groupchatAuthorColorKey)
        devices.forEach { h.combine($0.primary); h.combine($0.state_); h.combine($0.isTrustedByCertificate) }
        if let message {
            h.combine(message.primary); h.combine(message.owner); h.combine(message.opponent)
            h.combine(message.conversationType_); h.combine(message.messageId); h.combine(message.archivedId)
            h.combine(message.body); h.combine(message.legacyBody); h.combine(message.date)
            h.combine(message.editDate); h.combine(message.outgoing); h.combine(message.state_)
            h.combine(message.messageType); h.combine(message.isDeleted); h.combine(message.deleteState_)
            h.combine(message.isLocallyHiddenByReport); h.combine(message.localReportState)
            h.combine(message.systemMetadata_); h.combine(message.isSavedForward); h.combine(message.savedForwardAuthorJid)
            hashReferences(message.references, into: &h)
            message.inlineForwards.forEach { hashForward($0, into: &h) }
        }
        return h.finalize()
    }

    private static func hashReferences(_ references: List<MessageReferenceStorageItem>, into h: inout Hasher) {
        h.combine(references.count)
        references.forEach {
            h.combine($0.primary); h.combine($0.kind_); h.combine($0.mimeType)
            h.combine($0.url); h.combine($0.metadata_); h.combine($0.begin); h.combine($0.end)
            h.combine($0.isLocallyHiddenByReport)
        }
    }

    private static func hashForward(_ forward: MessageForwardsInlineStorageItem, into h: inout Hasher) {
        h.combine(forward.primary); h.combine(forward.body); h.combine(forward.forwardNickname)
        h.combine(forward.forwardJid); h.combine(forward.opponent); h.combine(forward.isOutgoing)
        h.combine(forward.rosterItem?.displayName)
        hashReferences(forward.references, into: &h)
        // The existing preview only uses the immediate forward's content and
        // attachment references; nested forward identities still invalidate it.
        forward.subforwards.forEach { h.combine($0.primary); h.combine($0.body); h.combine($0.forwardNickname) }
    }

    private func cacheRender(_ row: Datasource, primary: String, fingerprint: Int) {
        let bytes = row.message.utf8.count + row.username.utf8.count + 256
        guard bytes <= 16 * 1024 else { return }
        if let old = rowRenderCache.removeValue(forKey: primary) {
            rowRenderBytes -= old.bytes
            rowRenderOrder.removeAll { $0 == primary }
        }
        while (rowRenderCache.count >= 512 || rowRenderBytes + bytes > 2 * 1024 * 1024),
              let first = rowRenderOrder.first {
            rowRenderOrder.removeFirst()
            if let old = rowRenderCache.removeValue(forKey: first) { rowRenderBytes -= old.bytes }
        }
        rowRenderCache[primary] = (fingerprint, row, bytes)
        rowRenderOrder.append(primary)
        rowRenderBytes += bytes
    }

    private func clearProjectionCaches() {
        updateQueue.async { [weak self] in self?.clearProjectionCachesImmediately() }
    }

    private func clearProjectionCachesImmediately() {
        projectionCacheLock.lock(); defer { projectionCacheLock.unlock() }
        projectionCacheEvictionGeneration &+= 1
        projectionCacheEvictionWorkItem?.cancel()
        projectionCacheEvictionWorkItem = nil
        expireProjectionReadCaches()
        clearImmutableRowCache()
        rowRenderOwners = nil
    }

    /// Caller owns projectionCacheLock. Expiring read proofs releases pinned
    /// Realm versions; immutable bounded DTOs carry no database authority.
    private func expireProjectionReadCaches() {
        projectionCacheRetentionDeadline = .distantPast
        cachedDatasetRealm = nil; cachedDataset.removeAll(); cachedDatasetContext = ""
        materializedPreviewCache.removeAll()
    }

    private func clearImmutableRowCache() {
        rowRenderCache.removeAll(); rowRenderOrder.removeAll(); rowRenderBytes = 0
    }

    private func scheduleProjectionCacheEviction() {
        projectionCacheEvictionWorkItem?.cancel()
        projectionCacheEvictionGeneration &+= 1
        let generation = projectionCacheEvictionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.projectionCacheLock.lock(); defer { self.projectionCacheLock.unlock() }
            guard generation == self.projectionCacheEvictionGeneration else { return }
            self.projectionCacheEvictionWorkItem = nil
            self.expireProjectionReadCaches()
        }
        projectionCacheEvictionWorkItem = work
        // Serial with projection work, and never schedules a UI refresh.
        updateQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    #if DEBUG
    internal var retainedProjectionSnapshotCountForTesting: Int {
        projectionCacheLock.lock(); defer { projectionCacheLock.unlock() }
        return (cachedDatasetRealm == nil ? 0 : 1) + materializedPreviewCache.retainedSnapshotCount
    }
    #endif

    internal static func makeDatasetReadSnapshot(from realm: Realm) -> Realm {
        // Account cleanup can commit while the dataset is being materialized,
        // so every row and linked object must share one immutable read version.
        if !realm.isFrozen && !realm.isInWriteTransaction {
            realm.refresh()
        }
        return realm.freeze()
    }

    internal final func mapDataset(
        in readRealm: Realm? = nil,
        showsSpecialMessageBanners: Bool,
        dismissedInvitePrimaries: Set<String>,
        interfaceStyle suppliedInterfaceStyle: UIUserInterfaceStyle? = nil,
        showsSkeleton: Bool? = nil
    ) -> [Datasource] {
        let interfaceStyle = suppliedInterfaceStyle ?? (Thread.isMainThread ? traitCollection.userInterfaceStyle : .unspecified)
        projectionCacheLock.lock()
        defer { projectionCacheLock.unlock() }
        mappingDeferredForSyncPage = false
        let readRevision = captureProjectionReadRevision()
        mappingReadRevision = readRevision
        guard projectionReadIsCurrent(readRevision) else {
            mappingDeferredForSyncPage = true
            return []
        }
        if rowRenderOwners != readRevision.owners {
            clearImmutableRowCache()
            rowRenderOwners = readRevision.owners
        }
        if showsSkeleton ?? self.showSkeleton.value {
            syncLatencyWorkCounter.record(.fullDatasetBuild)
            let skeletonItemsCount = self.skeletonItemsCount
            return (0..<skeletonItemsCount).compactMap {
                return Datasource(
                    jid: "\($0)",
                    owner: "",
                    username: "",
                    attributedUsername: nil,
                    message: "",
                    date: Date(),
                    state: nil,
                    isMute: false,
                    isSynced: false,
                    status: .away,
                    entity: .bot,
                    conversationType: .axolotl,
                    unread: 0,
                    unreadString: nil,
                    hasUnreadMention: false,
                    color: .white,
                    isDraft: false,
                    hasAttachment: false,
                    userNickname: nil,
                    isSystemMessage: false,
                    isPinned: false,
                    subRequest: false,
                    isEncrypted: false,
                    avatarUrl: nil,
                    hasErrorInChat: false,
                    updateTS: 0,
                    isVerificationActionRequired: false,
                    specialMessageKind: .none,
                    avatars: []
                )
            }
        }
        do {
            let realm = Self.makeDatasetReadSnapshot(from: try readRealm ?? WRealm.safe())
            let context = projectionContext(showsSpecialMessageBanners: showsSpecialMessageBanners,
                dismissedInvitePrimaries: dismissedInvitePrimaries, interfaceStyle: interfaceStyle)
            if !projectionReadIsCurrent(readRevision) {
                mappingDeferredForSyncPage = true
                return []
            }
            if cachedDatasetRealm == realm && cachedDatasetContext == context &&
                Date() < cachedDatasetExpiry && Date() < projectionCacheRetentionDeadline {
                syncLatencyWorkCounter.record(.datasetHit)
                return cachedDataset
            }
            syncLatencyWorkCounter.record(.fullDatasetBuild)
            let predicate: NSPredicate
            var pinnedChatsSorting: Bool = false
            let jids = Array(realm.objects(AccountStorageItem.self).filter("enabled == true").map(\.jid))
            let ignoredJids = XMPPServiceJidsSupport.ignoredServiceJids(in: realm, accountJids: jids)
            switch self.filter.value {
            case .chats:
                self.unreadedJids = []
                predicate = recentChatsPredicate(ignoredJids: ignoredJids)
                pinnedChatsSorting = true
            case .unread:
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    
                    var excludedJids = self.excludedDomains(from: enabledAccounts.value)
                    excludedJids.append(CommonConfigManager.shared.config.support_jid)
                    let basePredicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND unread > %@ AND NOT (jid IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids,
                            0,
                            ignoredJids
                        ]
                    )
                    let unreadedJidsNew = Array(Set(realm
                        .objects(LastChatsStorageItem.self)
                        .filter(basePredicate)
                        .compactMap({ return $0.jid })))
                    self.unreadedJids.append(contentsOf: unreadedJidsNew)
                    self.unreadedJids = Array(Set(self.unreadedJids))
//                    print(unreadedJids)
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND (unread > %@ OR jid IN %@) AND NOT (jid IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids,
                            0,
                            unreadedJids,
                            ignoredJids
                        ]
                    )
                } else {
                    let basePredicate = NSPredicate(format: "isArchived == %@ AND unread > %@ AND owner IN %@ AND NOT (jid IN %@)",
                                                    argumentArray: [false,
                                                                    0,
                                                                    Array(enabledAccounts.value),
                                                                    ignoredJids])
                    let unreadedJidsNew = Array(Set(realm
                        .objects(LastChatsStorageItem.self)
                        .filter(basePredicate)
                        .compactMap({ return $0.jid })))
                    self.unreadedJids.append(contentsOf: unreadedJidsNew)
                    self.unreadedJids = Array(Set(self.unreadedJids))
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND (unread > %@ OR jid IN %@) AND owner IN %@",
                        argumentArray: [false,
                                        0,
                                        unreadedJids,
                                        Array(enabledAccounts.value)
                                       ]
                    )
                    
                }
            case .archived:
                self.unreadedJids = []
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    var excludedJids = self.excludedDomains(from: enabledAccounts.value)
                    excludedJids.append(CommonConfigManager.shared.config.support_jid)
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND NOT (jid IN %@)",
                        argumentArray: [
                            true,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids,
                            ignoredJids
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@ AND NOT (jid IN %@)", argumentArray: [true, Array(enabledAccounts.value), ignoredJids])
                }
            case .saved:
                let enabledOwners = Array(enabledAccounts.value)
                predicate = SavedMessagesAvailabilityPolicy.visibleSavedLastChatsPredicate(
                    enabledOwners: enabledOwners,
                    favoritesNodesByOwner: SavedMessagesAvailabilityPolicy.favoritesNodesByOwner(
                        in: realm,
                        enabledOwners: enabledOwners
                    )
                )
            }
            var collection = realm
                .objects(LastChatsStorageItem.self)
                .filter(predicate)
            
            if pinnedChatsSorting {
                collection = collection.sorted(by: [
                    SortDescriptor(keyPath: "isPinned", ascending: false),
                    SortDescriptor(keyPath: "pinnedPosition", ascending: true),
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            } else {
                collection = collection.sorted(by: [
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            }
            
            var out: [Datasource] = []
            let storedCollectionItems = collection.toArray()
            let collectionOwners = Array(Set(storedCollectionItems.map(\.owner)))
            let activeGroupPrimaries = CanonicalGroupRegularShadowPolicy
                .activeGroupPrimaries(
                    in: realm,
                    owners: collectionOwners
                )
            let collectionItems = storedCollectionItems.filter {
                !CanonicalGroupRegularShadowPolicy.shouldSuppress(
                    owner: $0.owner,
                    jid: $0.jid,
                    conversationType: $0.conversationType,
                    activeGroupPrimaries: activeGroupPrimaries
                )
            }
            let materializedPreviewMessagesByChatPrimary =
                materializedPreviewCache.resolve(in: realm, for: collectionItems,
                    counter: syncLatencyWorkCounter)
            let syncOnlyIdentityItems = collectionItems.filter {
                $0.rosterItem == nil && $0.conversationType != .saved
            }
            let syncOnlyOwners = Array(Set(syncOnlyIdentityItems.map(\.owner)))
            let syncOnlyJIDs = Array(Set(syncOnlyIdentityItems.map(\.jid)))
            let syncOnlyVCardIdentities = Set(
                syncOnlyIdentityItems.compactMap {
                    VCardPresentationIdentity(owner: $0.owner, jid: $0.jid)
                }
            )
            var synchronizedVCardTitlesByIdentity =
                VCardPresentationProjectionStore.shared
                    .titles(for: syncOnlyVCardIdentities)
                    .reduce(into: [String: String]()) { result, entry in
                        result[[entry.key.jid, entry.key.owner].prp()] = entry.value
                    }
            if syncOnlyOwners.isNotEmpty && syncOnlyJIDs.isNotEmpty {
                realm
                    .objects(vCardStorageItem.self)
                    .filter(
                        "owner IN %@ AND jid IN %@ AND isLastUpdateErrorOccured == %@",
                        syncOnlyOwners,
                        syncOnlyJIDs,
                        false
                    )
                    .forEach { card in
                        guard let identity = VCardPresentationIdentity(
                            owner: card.owner,
                            jid: card.jid
                        ) else {
                            return
                        }
                        let title = card.generatedNickname
                        _ = VCardPresentationProjectionStore.shared.apply(
                            owner: identity.owner,
                            jid: identity.jid,
                            title: title
                        )
                        let presentationKey = [identity.jid, identity.owner].prp()
                        synchronizedVCardTitlesByIdentity[presentationKey] = title
                    }
            }
            let rosterJIDs = Array(Set(collectionItems.compactMap { $0.rosterItem?.jid }))
            var resourcesByIdentity: [String: ResourceStorageItem] = [:]
            if collectionOwners.isNotEmpty && rosterJIDs.isNotEmpty {
                syncLatencyWorkCounter.record(.resourceQuery)
                realm.objects(ResourceStorageItem.self)
                    .filter("owner IN %@ AND jid IN %@", collectionOwners, rosterJIDs)
                    .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                        SortDescriptor(keyPath: "priority", ascending: false)])
                    .forEach { resource in
                        let key = [resource.owner, resource.jid].prp()
                        if resourcesByIdentity[key] == nil { resourcesByIdentity[key] = resource }
                    }
            }
            let enabledAccountCount = max(enabledAccounts.value.count, AccountManager.shared.users.count)
            
            let invites = showsSpecialMessageBanners
                ? ((try? CanonicalGroupInviteUIQuery.incoming(
                    in: realm,
                    owners: jids
                )) ?? []).filter {
                    !dismissedInvitePrimaries.contains($0.primary)
                }
                : []

            let requests = showsSpecialMessageBanners
                ? realm
                    .objects(UINotificationStorageItem.self)
                    .filter("owner IN %@ AND isRead == %@ AND kind_ == %@", jids, false, UINotificationStorageItem.Kind.contactRequest.rawValue)
                    .toArray()
                : []
            
            if requests.isNotEmpty {
                let rosterItems = requests.compactMap({ return realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: $0.jid, owner: $0.owner)) })
                let avatars = rosterItems.prefix(3).compactMap { AvatarStructItem(jid: $0.jid, owner: $0.owner, name: $0.displayName, url: $0.avatarUrl, isGroup: false, uuid: "")}
                if let rosterInstance = rosterItems.first {
                    out.append(Datasource(
                        jid: rosterInstance.jid,
                        owner: rosterInstance.owner,
                        username: rosterInstance.displayName,
                        attributedUsername: nil,
                        message: "",
                        date: nil,
                        state: nil,
                        isMute: false,
                        isSynced: true,
                        status: .offline,
                        entity: .groupchat,
                        conversationType: .group,
                        unread: rosterItems.count,
                        unreadString: nil,
                        hasUnreadMention: false,
                        color: .brown,
                        isDraft: false,
                        hasAttachment: false,
                        userNickname: nil,
                        isSystemMessage: false,
                        isPinned: false,
                        subRequest: false,
                        isEncrypted: false,
                        avatarUrl: nil,
                        hasErrorInChat: false,
                        updateTS: 0,
                        isVerificationActionRequired: false,
                        specialMessageKind: SpecialMessageKind.contact,
                        avatars: avatars
                    ))
                }
            }
            if invites.isNotEmpty {
                let presentations = invites.map(CanonicalGroupInvitePresentation.init)
                let avatars = presentations.prefix(3).map {
                    AvatarStructItem(
                        jid: $0.groupJID,
                        owner: $0.owner,
                        name: $0.title,
                        url: $0.avatarURL,
                        isGroup: true,
                        uuid: $0.primary
                    )
                }
                if let firstInvite = presentations.first {
                    out.append(Datasource(
                        jid: firstInvite.groupJID,
                        owner: firstInvite.owner,
                        username: firstInvite.title,
                        attributedUsername: nil,
                        message: "",
                        date: nil,
                        state: nil,
                        isMute: false,
                        isSynced: true,
                        status: .offline,
                        entity: .groupchat,
                        conversationType: .group,
                        unread: invites.count,
                        unreadString: nil,
                        hasUnreadMention: false,
                        color: .brown,
                        isDraft: false,
                        hasAttachment: false,
                        userNickname: nil,
                        isSystemMessage: false,
                        isPinned: false,
                        subRequest: false,
                        isEncrypted: false,
                        avatarUrl: nil,
                        hasErrorInChat: false,
                        updateTS: 0,
                        isVerificationActionRequired: false,
                        specialMessageKind: .invite,
                        avatars: avatars
                    ))
                }
            }
            let encryptedChatItems = collectionItems.filter { $0.conversationType.isEncrypted }
            let encryptedOwners = Array(Set(encryptedChatItems.map { $0.owner }))
            let encryptedJids = Array(Set(encryptedChatItems.map { $0.jid }))
            let signalDevices = encryptedOwners.isEmpty || encryptedJids.isEmpty
                ? []
                : realm.objects(SignalDeviceStorageItem.self)
                    .filter("owner IN %@ AND jid IN %@", encryptedOwners, encryptedJids)
                    .toArray()
            let signalDeviceStateByKey = Dictionary(grouping: signalDevices, by: { self.datasourceKey(jid: $0.jid, owner: $0.owner) })
            let verificationSessions = encryptedOwners.isEmpty || encryptedJids.isEmpty
                ? []
                : realm.objects(VerificationSessionStorageItem.self)
                    .filter("owner IN %@ AND jid IN %@", encryptedOwners, encryptedJids)
                    .toArray()
            let verificationRequiredKeys = Set(
                verificationSessions.compactMap { session -> String? in
                    guard [.receivedRequest, .receivedRequestAccept].contains(session.state) else {
                        return nil
                    }
                    return self.datasourceKey(jid: session.jid, owner: session.owner)
                }
            )
            
            let realmConfiguration = realm.configuration
            let realmIdentity = realmConfiguration.inMemoryIdentifier ?? realmConfiguration.fileURL?.absoluteString ?? ""
            let rowContext = [String(describing: LocalizationRuntime.shared.context),
                String(interfaceStyle.rawValue), String(enabledAccountCount), realmIdentity].joined(separator: "|")
            out.append(contentsOf: collectionItems.compactMap {
                item in
                let blankMessageText: String = "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: [])
                let isSavedConversation = item.conversationType == .saved
                let presentationLastMessage = item.lastMessage ??
                    materializedPreviewMessagesByChatPrimary[item.primary]
                let synchronizedPreview = presentationLastMessage == nil
                    ? LastChatListSyncPreviewStore.shared.projection(
                        owner: item.owner,
                        conversationPrimary: item.primary,
                        expectedLastMessageID: item.lastMessageId
                    )
                    : nil
                
                let subscriptionRequest: Bool = item.rosterItem?.isThereSubscriptionRequest() ?? false
                
                let primaryResource = item.rosterItem.flatMap {
                    resourcesByIdentity[[$0.owner, $0.jid].prp()]
                }
                let fingerprint = Self.rowFingerprint(chat: item, message: presentationLastMessage,
                    projection: synchronizedPreview, resource: primaryResource,
                    devices: signalDeviceStateByKey[self.datasourceKey(jid: item.jid, owner: item.owner)] ?? [],
                    requiresVerification: verificationRequiredKeys.contains(self.datasourceKey(jid: item.jid, owner: item.owner)),
                    context: rowContext + "|" + (synchronizedVCardTitlesByIdentity[[item.jid, item.owner].prp()] ?? ""))
                if let cached = self.rowRenderCache[item.primary], cached.fingerprint == fingerprint {
                    self.syncLatencyWorkCounter.record(.rowHit)
                    return cached.row
                }
                self.syncLatencyWorkCounter.record(.rowBuild)
                let date = item.messageDate == Date(timeIntervalSince1970: 0) ? nil : item.messageDate
                
                var message: String
                var isAttachmentPreviewItalic: Bool = false
                
                if presentationLastMessage != nil || synchronizedPreview != nil {
                    let preview = LastChatMessagePreviewPolicy.preview(
                        for: presentationLastMessage,
                        synchronizedProjection: synchronizedPreview,
                        blankMessageText: blankMessageText
                    )
                    message = preview.text
                    isAttachmentPreviewItalic = preview.isItalic
                    if presentationLastMessage?.isDeleted == true {
                        message = blankMessageText
                        isAttachmentPreviewItalic = false
                    }
                } else if isSavedConversation {
                    message = SavedMessagesChatListPresentationPolicy.previewText(
                        lastMessageText: nil,
                        owner: item.owner,
                        enabledAccountCount: enabledAccountCount
                    )
                } else {
                    message = blankMessageText
                }
                
                var isDraft: Bool = false
                if let draft = item.draftMessage {
                    message = draft
                    isDraft = true
                    isAttachmentPreviewItalic = false
                }
                if item.conversationType != .group && !isSavedConversation {
                    if let action = CommonChatStatesManager.shared.actionText(for: item.jid, owner: item.owner) {
                        message = action
                        isAttachmentPreviewItalic = false
                    }
                }
                var isAttachment: Bool = [
                    MessageStorageItem.MessageDisplayType.sticker,
                    MessageStorageItem.MessageDisplayType.call].contains(presentationLastMessage?.displayAs ?? .text)
                if synchronizedPreview?.isAttachment == true {
                    isAttachment = true
                }
                if !isAttachment,
                   presentationLastMessage?.references.contains(where: { reference in
                       !reference.isLocallyHiddenByReport &&
                           LastChatAttachmentPreviewFormatter.kind(
                               referenceKindRaw: reference.kind_,
                               mimeType: reference.mimeType,
                               mediaType: reference.metadata?["media-type"] as? String
                           ) != nil
                   }) == true {
                    isAttachment = true
                }
                if !isAttachment,
                   let authMessageMetadata = presentationLastMessage?.systemMetadata?["auth_message"] as? Bool,
                   authMessageMetadata {
                    isAttachment = true
                }
                
                let isInvite = false
                
                let synchronizedGroupNickname = item.conversationType == .group
                    ? synchronizedPreview?.groupchatNickname
                    : nil
                let synchronizedGroupColorKey = item.conversationType == .group
                    ? synchronizedPreview?.groupchatAuthorColorKey
                    : nil
                var nickname: String? =
                    presentationLastMessage?.groupchatDisplayedNickname ??
                    synchronizedGroupNickname
                if let sender = presentationLastMessage?.inlineForwards.first {
                    let forwardedNickname = sender.forwardNickname
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if forwardedNickname.isNotEmpty {
                        nickname = forwardedNickname
                    } else {
                        let forwardedJID = sender.forwardJid
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        nickname = forwardedJID.isNotEmpty
                            ? String(
                                JidManager.shared.prepareJid(
                                    jid: forwardedJID
                                )
                            )
                            : "Forwarded message".localizeString(
                                id: "chat_message_forwarded_message",
                                arguments: []
                            )
                    }
                }
                let materializedUserColorKey: String? = presentationLastMessage.flatMap { message in
                    [
                        message.groupchatAuthorId,
                        message.groupchatMetadata?["jid"] as? String,
                        message.groupchatAuthorNickname,
                        nickname
                    ].compactMap { value in
                        let value = value?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        return value?.isNotEmpty == true ? value : nil
                    }.first
                }
                let userColorKey = materializedUserColorKey ??
                    synchronizedGroupColorKey

                var isSystemMessage: Bool = [.system].contains(presentationLastMessage?.displayAs ?? .text)
                if isAttachmentPreviewItalic {
                    isSystemMessage = true
                }
                if LastChatMessagePreviewPolicy.shouldShowEmptyEncryptedPlaceholder(
                    for: item,
                    message: presentationLastMessage,
                    synchronizedProjection: synchronizedPreview
                ) {
                    message = L10n.text("chat__empty_conversation__encrypted_message_placeholder", fallback: "Write your encrypted messages here")
                    isSystemMessage = true
                }
                if presentationLastMessage == nil {
                    isSystemMessage = synchronizedPreview?.isSystemMessage ?? true
                }
                
                let username = isSavedConversation
                    ? SavedMessagesChatListPresentationPolicy.title
                    : LastChatsIdentityTitlePolicy.title(
                        rosterDisplayName: item.rosterItem?.displayName,
                        synchronizedVCardTitle:
                            synchronizedVCardTitlesByIdentity[
                                [item.jid, item.owner].prp()
                            ],
                        jid: item.jid
                    )
                var attributedUsername: NSAttributedString? = nil
                let messageState = isSavedConversation
                    ? nil
                    : presentationLastMessage?.outgoing ?? true ? presentationLastMessage?.state ?? nil : nil
                let subRequest = isSavedConversation
                    ? false
                    : (XMPPJID(string: item.jid)?.isServer ?? true) ? false : subscriptionRequest
                
                var isVerificationActionRequired: Bool = false
                                
                if item.conversationType.isEncrypted {
                    let attributedTitle: NSMutableAttributedString = NSMutableAttributedString()
                    let indicatorAttach = NSTextAttachment()
                    var color: UIColor = .label
                    let key = self.datasourceKey(jid: item.jid, owner: item.owner)
                    let collectionJid = signalDeviceStateByKey[key] ?? []
                    if collectionJid.isEmpty {
                        color = .secondaryLabel
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.secondaryLabel)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.state == .fingerprintChanged || $0.state == .revoked }) {
                        color = .systemRed
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.state != .trusted }) {
                        color = .systemOrange
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.isTrustedByCertificate }) {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    }
                    
                    isVerificationActionRequired = verificationRequiredKeys.contains(key)
                    
                    attributedTitle.append(NSAttributedString(string: username, attributes: [
                        .foregroundColor: color,
                        .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                    ]))
                    attributedUsername = attributedTitle as NSAttributedString
                }
                let row = Datasource(
                    jid: item.jid,
                    owner: item.owner,
                    username: username,
                    attributedUsername: attributedUsername,
                    message: message,
                    date: date,
                    state: messageState,
                    isMute: item.isMuted,
                    isSynced: item.isSynced,
                    status: isSavedConversation ? SavedMessagesChatListPresentationPolicy.status : primaryResource?.status ?? .offline,
                    entity: isSavedConversation ? SavedMessagesChatListPresentationPolicy.entity : primaryResource?.entity ?? .contact,
                    conversationType: item.conversationType,
                    unread: presentationLastMessage?.outgoing ?? false ? 0 : item.unread,
                    unreadString: nil,
                    hasUnreadMention: item.hasUnreadMention,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: isDraft,
                    hasAttachment: isAttachment,
                    userNickname: nickname,
                    userColorKey: userColorKey,
                    isSystemMessage: isSystemMessage,
                    isPinned: item.isPinned,
                    subRequest: subRequest,
                    isEncrypted: item.conversationType.isEncrypted,
                    avatarUrl: isSavedConversation
                        ? nil
                        : item.rosterItem?.avatarMinUrl
                            ?? item.rosterItem?.avatarMaxUrl
                            ?? item.rosterItem?.oldschoolAvatarKey,
                    hasErrorInChat: item.hasErrorInChat,
                    updateTS: item.updateTS,
                    isVerificationActionRequired: isVerificationActionRequired,
                    specialMessageKind: .none,
                    avatars: []
                )
                self.cacheRender(row, primary: item.primary, fingerprint: fingerprint)
                return row
            })
            #if DEBUG
            projectionMappingDidPrepareForTesting?()
            #endif
            guard projectionReadIsCurrent(readRevision) else {
                mappingDeferredForSyncPage = true
                cachedDatasetRealm = nil
                return []
            }
            let bytes = out.reduce(0) { $0 + $1.message.utf8.count + $1.username.utf8.count + 256 }
            if bytes <= 4 * 1024 * 1024 && out.count <= 512 {
                cachedDatasetRealm = realm
                cachedDatasetContext = context
                cachedDataset = out
                projectionCacheRetentionDeadline = Date().addingTimeInterval(2)
                scheduleProjectionCacheEviction()
                cachedDatasetExpiry = collectionItems.compactMap { item -> Date? in
                    let date = Date(timeIntervalSince1970: item.muteExpired)
                    return date > Date() ? date : nil
                }.min() ?? .distantFuture
            } else {
                cachedDatasetRealm = nil
                cachedDataset.removeAll()
            }
            return out
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    public final var canUpdateDataset = true
    
    
    private static func convertChangeset(
        changes: [Change<Datasource>],
        oldSectionIndex: Int,
        newSectionIndex: Int
    ) -> ChangesWithIndexPath {
        let inserts = changes
            .compactMap { $0.insert?.index }
            .map { IndexPath(row: $0, section: newSectionIndex) }
        let deletes = changes
            .compactMap { $0.delete?.index }
            .map { IndexPath(row: $0, section: oldSectionIndex) }
        let replaces = changes
            .compactMap { $0.replace?.index }
            .map { IndexPath(row: $0, section: newSectionIndex) }

        let moves = changes.compactMap({ $0.move }).map {
            (
                from: IndexPath(row: $0.fromIndex, section: oldSectionIndex),
                to: IndexPath(row: $0.toIndex, section: newSectionIndex)
            )
        }

        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }

    internal static func sectionedChanges(
        oldSections: [DatasourceSection],
        newSections: [DatasourceSection]
    ) -> ChangesWithIndexPath {
        var insertedSections = IndexSet()
        var deletedSections = IndexSet()
        var inserts: [IndexPath] = []
        var deletes: [IndexPath] = []
        var replaces: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []

        oldSections.enumerated().forEach { oldIndex, oldSection in
            if sectionIndex(of: oldSection.kind, in: newSections) == nil {
                deletedSections.insert(oldIndex)
            }
        }

        newSections.enumerated().forEach { newIndex, newSection in
            if sectionIndex(of: newSection.kind, in: oldSections) == nil {
                insertedSections.insert(newIndex)
            }
        }

        oldSections.enumerated().forEach { oldIndex, oldSection in
            guard let newIndex = sectionIndex(of: oldSection.kind, in: newSections) else {
                return
            }
            let rowChanges = diff(old: oldSection.rows, new: newSections[newIndex].rows)
            let sectionChanges = convertChangeset(
                changes: rowChanges,
                oldSectionIndex: oldIndex,
                newSectionIndex: newIndex
            )
            inserts.append(contentsOf: sectionChanges.inserts)
            deletes.append(contentsOf: sectionChanges.deletes)
            replaces.append(contentsOf: sectionChanges.replaces)
            moves.append(contentsOf: sectionChanges.moves)
        }

        return ChangesWithIndexPath(
            insertedSections: insertedSections,
            deletedSections: deletedSections,
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    public final func initializeDataset() {
        
    }
    
    public final func runDatasetUpdateTask() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.runDatasetUpdateTask()
            }
            return
        }
        if enabledAccounts.value.contains(where: { ClientSyncPageBatch.shared.isBatchActive(owner: $0) }) {
            deferredSyncPageRefresh = true
            return
        }
        let pressureActive = self.hasVisibleDatasetUpdatePressureInProgress
        if LastChatsBootstrapDatasetUpdatePolicy.shouldDeferDatasetUpdateForNavigationTransition(
            isBootstrapActive: pressureActive,
            isNavigationTransitionActive: self.isNavigationTransitionActive
        ) {
            self.pendingDatasetUpdateAfterNavigationTransition = true
            self.shouldSuppressNextDatasetAnimation = true
            DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateCoalesced reason=navigationTransition")
            return
        }
        if LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
            isTransitionActive: self.isNavigationTransitionActive,
            isCriticalForFirstFrame: false
        ) {
            self.pendingDatasetUpdateAfterNavigationTransition = true
            self.shouldSuppressNextDatasetAnimation = true
            return
        }
        if self.scheduleBootstrapDatasetUpdateIfNeeded() {
            self.shouldSuppressNextDatasetAnimation = true
            return
        }
        preprocessDataset()
        postprocessDataset()
    }

    @discardableResult
    private func deferDatasetMutationForNavigationTransitionIfNeeded() -> Bool {
        guard self.isNavigationTransitionActive else {
            return false
        }
        self.pendingDatasetUpdateAfterNavigationTransition = true
        self.shouldSuppressNextDatasetAnimation = true
        self.needsDatasetRefresh = false
        self.isDatasetUpdateInFlight = false
        self.canUpdateDataset = true
        return true
    }

    @discardableResult
    private final func scheduleBootstrapDatasetUpdateIfNeeded() -> Bool {
        let pressureActive = self.hasVisibleDatasetUpdatePressureInProgress
        guard !self.isExecutingBootstrapCoalescedDatasetUpdate else {
            return false
        }
        guard pressureActive else {
            self.pendingDatasetUpdateAfterBootstrapCoalescing = false
            return false
        }

        guard LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(
            isDatasetUpdatePressureActive: pressureActive,
            hasScheduledUpdate: self.bootstrapDatasetUpdateWorkItem != nil
        ) else {
            self.pendingDatasetUpdateAfterBootstrapCoalescing = true
            DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateCoalesced reason=alreadyScheduled")
            return true
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bootstrapDatasetUpdateWorkItem = nil
            if ChatUIResponsivenessGate.shouldDefer(
                workKind: .presentationRefresh,
                isActive: ChatUIResponsivenessGate.shared.isActive
            ) {
                self.pendingDatasetUpdateAfterBootstrapCoalescing = true
                _ = self.scheduleBootstrapDatasetUpdateIfNeeded()
                return
            }
            self.pendingDatasetUpdateAfterBootstrapCoalescing = false
            self.isExecutingBootstrapCoalescedDatasetUpdate = true
            self.runDatasetUpdateTask()
            self.isExecutingBootstrapCoalescedDatasetUpdate = false
        }
        self.bootstrapDatasetUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + LastChatsBootstrapDatasetUpdatePolicy.coalescingDelay,
            execute: workItem
        )
        DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateCoalesced reason=pressureActive delayMs=\(Int(LastChatsBootstrapDatasetUpdatePolicy.coalescingDelay * 1000))")
        return true
    }
    
    private final func preprocessDataset() {
        if enabledAccounts.value.contains(where: { ClientSyncPageBatch.shared.isBatchActive(owner: $0) }) {
            deferredSyncPageRefresh = true
            return
        }
        if !canUpdateDataset { return }
        self.needsDatasetRefresh = true
        guard !self.isDatasetUpdateInFlight else { return }
        self.needsDatasetRefresh = false
        self.isDatasetUpdateInFlight = true
        let oldDataset = self.datasource
        let oldSections = self.datasourceSections
        let oldShowsSkeleton = self.datasourceShowsSkeleton
        let newShowsSkeleton = self.showSkeleton.value
        let showsSpecialMessageBanners =
            LastChatsSpecialMessageVisibilityPolicy.shouldShowSpecialMessageBanners(
                filter: filter.value,
                isSearchActive: bottomSearchHostView.isExpanded
            )
        let dismissedInvitePrimaries = dismissedCanonicalInviteBannerPrimaries
        let pressureActive = self.hasVisibleDatasetUpdatePressureInProgress
        let requestedAnimate = LeftMenuFirstPresentationPolicy.shouldAnimate(
            requested: self.isFirstLayout && !self.shouldSuppressNextDatasetAnimation,
            isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
        )
        let shouldAnimate = LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(
            requestedAnimated: requestedAnimate,
            isDatasetUpdatePressureActive: pressureActive
        )
        let navigationMutationGeneration = self.navigationDatasetMutationGeneration
        self.shouldSuppressNextDatasetAnimation = false
        let renderStartedAt = Date()
        let interfaceStyle = traitCollection.userInterfaceStyle
        let lifecycleEpoch = projectionLifecycleEpoch
        self.updateQueue.async {
            self.projectionCacheLock.lock()
            let newDataset = self.mapDataset(
                showsSpecialMessageBanners: showsSpecialMessageBanners,
                dismissedInvitePrimaries: dismissedInvitePrimaries,
                interfaceStyle: interfaceStyle,
                showsSkeleton: newShowsSkeleton
            )
            let readRevision = self.mappingReadRevision
            let deferredForSyncPage = self.mappingDeferredForSyncPage
            self.projectionCacheLock.unlock()
            if deferredForSyncPage {
                DispatchQueue.main.async {
                    guard lifecycleEpoch == self.projectionLifecycleEpoch else {
                        self.isDatasetUpdateInFlight = false; self.needsDatasetRefresh = false
                        return
                    }
                    self.deferredSyncPageRefresh = true
                    self.needsDatasetRefresh = true
                    self.finishDatasetUpdateCycle(didCommitDatasetApply: false)
                }
                return
            }
            if oldShowsSkeleton == newShowsSkeleton && Self.sameRows(oldDataset, newDataset) {
                DispatchQueue.main.async {
                    guard lifecycleEpoch == self.projectionLifecycleEpoch else {
                        self.isDatasetUpdateInFlight = false; self.needsDatasetRefresh = false
                        return
                    }
                    if let readRevision, !self.projectionReadIsCurrent(readRevision) {
                        self.deferredSyncPageRefresh = true
                        self.needsDatasetRefresh = true
                    }
                    self.finishDatasetUpdateCycle(didCommitDatasetApply: false)
                }
                return
            }
            let newSections = Self.makeDatasourceSections(
                from: newDataset,
                showsSkeleton: newShowsSkeleton
            )
            let indexPaths = Self.sectionedChanges(
                oldSections: oldSections,
                newSections: newSections
            )
            DispatchQueue.main.async {
                guard lifecycleEpoch == self.projectionLifecycleEpoch else {
                    self.isDatasetUpdateInFlight = false
                    self.needsDatasetRefresh = false
                    return
                }
                guard let readRevision, self.projectionReadIsCurrent(readRevision),
                      interfaceStyle == self.traitCollection.userInterfaceStyle,
                      newShowsSkeleton == self.showSkeleton.value else {
                    self.deferredSyncPageRefresh = true
                    self.needsDatasetRefresh = true
                    self.finishDatasetUpdateCycle(didCommitDatasetApply: false)
                    return
                }
                guard navigationMutationGeneration == self.navigationDatasetMutationGeneration else {
                    DDLogDebug(
                        "LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateDropped reason=staleNavigationGeneration"
                    )
                    self.finishDatasetUpdateCycle(didCommitDatasetApply: false)
                    return
                }
                if self.deferDatasetMutationForNavigationTransitionIfNeeded() {
                    DDLogDebug(
                        "LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateCoalesced reason=navigationTransitionAfterMapping"
                    )
                    return
                }
                if !shouldAnimate {
                    UIView.performWithoutAnimation {
                        self.apply(
                            changes: indexPaths,
                            oldSections: oldSections,
                            newSections: newSections,
                            oldShowsSkeleton: oldShowsSkeleton,
                            newShowsSkeleton: newShowsSkeleton
                        ) {
                            self.setDatasource(newDataset, sections: newSections, showsSkeleton: newShowsSkeleton)
                        }
                    }
                } else {
                    let updatesCount = indexPaths.deletedSections.count
                        + indexPaths.insertedSections.count
                        + indexPaths.deletes.count
                        + indexPaths.inserts.count
                        + indexPaths.moves.count
                    if updatesCount < 4 {
                        self.apply(
                            changes: indexPaths,
                            oldSections: oldSections,
                            newSections: newSections,
                            oldShowsSkeleton: oldShowsSkeleton,
                            newShowsSkeleton: newShowsSkeleton
                        ) {
                            self.setDatasource(newDataset, sections: newSections, showsSkeleton: newShowsSkeleton)
                        }
                    } else {
                        UIView.performWithoutAnimation {
                            self.apply(
                                changes: indexPaths,
                                oldSections: oldSections,
                                newSections: newSections,
                                oldShowsSkeleton: oldShowsSkeleton,
                                newShowsSkeleton: newShowsSkeleton
                            ) {
                                self.setDatasource(newDataset, sections: newSections, showsSkeleton: newShowsSkeleton)
                            }
                        }
                    }
                }
                let durationMs = Int(Date().timeIntervalSince(renderStartedAt) * 1000)
                let visibleRowCount = self.tableView.window == nil
                    ? 0
                    : self.tableView.indexPathsForVisibleRows?.count ?? 0
                DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=datasetUpdateFinish pressureActive=\(pressureActive) rows=\(newDataset.count) visibleRows=\(visibleRowCount) durationMs=\(durationMs) animated=\(shouldAnimate)")
            }
        }
    }
    
    private final func postprocessDataset() {
        
    }
    
    private final func finishDatasetUpdateCycle(
        didCommitDatasetApply: Bool = true
    ) {
        if self.deferDatasetMutationForNavigationTransitionIfNeeded() {
            return
        }
        self.isFirstLayout =
            LastChatsFirstDatasetApplyOwnershipPolicy.pendingAfterCycle(
                wasPending: self.isFirstLayout,
                didCommitDatasetApply: didCommitDatasetApply
            )
        self.isDatasetUpdateInFlight = false
        self.canUpdateDataset = true
        if self.tableView.window != nil {
            self.syncSelectedChatSelection()
        }
        guard self.needsDatasetRefresh else { return }
        if self.hasVisibleDatasetUpdatePressureInProgress {
            self.runDatasetUpdateTask()
            return
        }
        self.preprocessDataset()
    }
    
    private final func replacementUpdatePlan(
        changes: ChangesWithIndexPath,
        oldSections: [DatasourceSection],
        newSections: [DatasourceSection],
        oldShowsSkeleton: Bool,
        newShowsSkeleton: Bool
    ) -> (reloads: [IndexPath], reconfigures: [IndexPath]) {
        var reloads: [IndexPath] = []
        var reconfigures: [IndexPath] = []

        changes.replaces.forEach { indexPath in
            guard newSections.indices.contains(indexPath.section) else {
                reloads.append(indexPath)
                return
            }
            let sectionKind = newSections[indexPath.section].kind
            guard let oldSectionIndex = Self.sectionIndex(of: sectionKind, in: oldSections),
                  oldSections[oldSectionIndex].rows.indices.contains(indexPath.row),
                  newSections[indexPath.section].rows.indices.contains(indexPath.row) else {
                reloads.append(indexPath)
                return
            }

            switch LastChatsRowUpdatePolicy.classify(
                old: oldSections[oldSectionIndex].rows[indexPath.row],
                new: newSections[indexPath.section].rows[indexPath.row],
                oldShowsSkeleton: oldShowsSkeleton,
                newShowsSkeleton: newShowsSkeleton
            ) {
            case .contentOnly:
                reconfigures.append(indexPath)
            case .structuralReload:
                reloads.append(indexPath)
            }
        }

        return (reloads, reconfigures)
    }

    internal final func applyReplacementUpdates(
        changes: ChangesWithIndexPath,
        oldSections: [DatasourceSection],
        newSections: [DatasourceSection],
        reloads: [IndexPath],
        reconfigures: [IndexPath]
    ) {
        let pressureActive = hasVisibleDatasetUpdatePressureInProgress
        let effectiveReconfigures: [IndexPath]
        if LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(isDatasetUpdatePressureActive: pressureActive) {
            effectiveReconfigures = []
            if reconfigures.isNotEmpty {
                DDLogDebug("LAST_CHATS_BOOTSTRAP_TRACE event=skipVisibleReconfigure count=\(reconfigures.count)")
            }
        } else {
            effectiveReconfigures = reconfigures
        }

        guard reloads.isNotEmpty || effectiveReconfigures.isNotEmpty else { return }

        UIView.performWithoutAnimation {
            if reloads.isNotEmpty {
                self.tableView.reloadRows(at: reloads, with: .none)
            }
            if effectiveReconfigures.isNotEmpty {
                self.reconfigureVisibleRows(at: effectiveReconfigures)
            }
        }
    }

    internal final func apply(
        changes: ChangesWithIndexPath,
        oldSections: [DatasourceSection],
        newSections: [DatasourceSection],
        oldShowsSkeleton: Bool,
        newShowsSkeleton: Bool,
        prepare: @escaping (() -> Void)
    ) {
        if self.deferDatasetMutationForNavigationTransitionIfNeeded() {
            return
        }
        if oldShowsSkeleton && !newShowsSkeleton {
            UIView.performWithoutAnimation {
                prepare()
                self.tableView.reloadData()
                if self.tableView.window != nil {
                    self.tableView.layoutIfNeeded()
                }
            }
            self.finishDatasetUpdateCycle()
            return
        }
        if LastChatsDatasourceApplyPolicy.resolve(
            isTableAttachedToWindow: self.tableView.window != nil
        ) == .detachedSnapshot {
            prepare()
            self.tableView.reloadData()
            self.finishDatasetUpdateCycle()
            return
        }
        if changes.deletedSections.isEmpty &&
            changes.insertedSections.isEmpty &&
            changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.finishDatasetUpdateCycle()
            return
        }

        guard self.tableView.dataSource != nil else {
            prepare()
            self.finishDatasetUpdateCycle()
            return
        }

        guard Self.hasStructuralTableChanges(changes) else {
            let replacementPlan = self.replacementUpdatePlan(
                changes: changes,
                oldSections: oldSections,
                newSections: newSections,
                oldShowsSkeleton: oldShowsSkeleton,
                newShowsSkeleton: newShowsSkeleton
            )
            prepare()
            self.applyReplacementUpdates(
                changes: changes,
                oldSections: oldSections,
                newSections: newSections,
                reloads: replacementPlan.reloads,
                reconfigures: replacementPlan.reconfigures
            )
            self.finishDatasetUpdateCycle()
            return
        }

        if Self.shouldReloadStructuralTableChanges(
            changes,
            isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
        ) {
            prepare()
            self.tableView.reloadData()
            self.finishDatasetUpdateCycle()
            return
        }

        let replacementPlan = self.replacementUpdatePlan(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: oldShowsSkeleton,
            newShowsSkeleton: newShowsSkeleton
        )

        let tableAnimation = LeftMenuFirstPresentationPolicy.rowAnimation(
            requested: .automatic,
            isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
        )
        LeftMenuFirstPresentationPolicy.performWithoutAnimationsIfNeeded(
            isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
        ) {
            self.tableView.performBatchUpdates({
                prepare()
                if !changes.deletedSections.isEmpty {
                    self.tableView.deleteSections(changes.deletedSections, with: tableAnimation)
                }
                if !changes.insertedSections.isEmpty {
                    self.tableView.insertSections(changes.insertedSections, with: tableAnimation)
                }
                if !changes.deletes.isEmpty {
                    self.tableView.deleteRows(at: changes.deletes, with: tableAnimation)
                }
                if !changes.inserts.isEmpty {
                    self.tableView.insertRows(at: changes.inserts, with: tableAnimation)
                }
                if changes.moves.isNotEmpty {
                    changes.moves.forEach {
                        (from, to) in
                        self.tableView.moveRow(at: from, to: to)
                    }
                }
            }, completion: { result in
                self.applyReplacementUpdates(
                    changes: changes,
                    oldSections: oldSections,
                    newSections: newSections,
                    reloads: replacementPlan.reloads,
                    reconfigures: replacementPlan.reconfigures
                )
                self.finishDatasetUpdateCycle()
            })
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        configureVoiceMessagePlaybackCoordinatorObserver()

        NotificationCenter.default.rx
            .notification(LastChatListSyncPreviewStore.didChangeNotification)
            .observe(on: MainScheduler.asyncInstance)
            .filter { [weak self] notification in
                guard let owner = notification.object as? String else {
                    return false
                }
                return self?.enabledAccounts.value.contains(owner) == true
            }
            .subscribe(onNext: { [weak self] notification in
                guard let self else { return }
                let primaries = Set(notification.userInfo?[LastChatListSyncPreviewStore.changedConversationPrimariesUserInfoKey] as? [String] ?? [])
                guard self.changedPrimariesAffectCurrentFilter(primaries) else { return }
                self.runDatasetUpdateTask()
            })
            .disposed(by: bag)

        NotificationCenter.default.rx
            .notification(ClientSyncPageBatch.didCommitNotification)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] notification in
                guard let self, let receipt = notification.object as? ClientSyncPageBatch.Receipt,
                      self.enabledAccounts.value.contains(receipt.owner) else { return }
                let needsRefresh = self.deferredSyncPageRefresh ||
                    self.changedPrimariesAffectCurrentFilter(receipt.changedConversationPrimaries)
                self.deferredSyncPageRefresh = false
                let didChangeSkeleton = self.updateStartupRecentsSkeleton(for: self.filter.value)
                if needsRefresh && !didChangeSkeleton { self.runDatasetUpdateTask() }
            })
            .disposed(by: bag)

        NotificationCenter.default.rx
            .notification(ClientSynchronizationManager.startupRecentsSyncActivityDidChange)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] notification in
                guard let self, let owner = notification.object as? String,
                      self.enabledAccounts.value.contains(owner) else { return }
                self.updateStartupRecentsSkeleton(for: self.filter.value)
            })
            .disposed(by: bag)

        NotificationCenter.default.rx
            .notification(ClientSyncPageBatch.didCancelNotification)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] notification in
                guard let self, let token = notification.object as? ClientSyncPageBatch.Token,
                      self.enabledAccounts.value.contains(token.owner), self.deferredSyncPageRefresh else { return }
                self.deferredSyncPageRefresh = false
                self.runDatasetUpdateTask()
            })
            .disposed(by: bag)

        NotificationCenter.default.rx
            .notification(VCardManager.didPersistVCardNotification)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] notification in
                self?.scheduleVCardProjectionRefresh(for: notification)
            })
            .disposed(by: bag)

        NotificationCenter.default.rx
            .notification(VCardManager.didFailVisibleVCardRequestNotification)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] notification in
                self?.scheduleVisibleVCardRetry(for: notification)
            })
            .disposed(by: bag)

        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm.objects(AccountStorageItem.self).filter("enabled == %@", true))
                .subscribe(onNext: { (results) in
                    let jids = Set(results.map(\.jid))
                    if jids != self.enabledAccounts.value {
                        self.enabledAccounts.accept(jids)
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager
            .shared
            .connectingUsers
            .asObservable()
            .subscribe(onNext: { results in
                do {
                    let realm = try WRealm.safe()
                    let accounts = Set(realm.objects(AccountStorageItem.self).toArray().compactMap(\.jid))
                    let filteredConnectingUsers = results.filter { accounts.contains($0) }
                    self.updateTitle(self.filter.value)
                    self.unreadAllMessagesButton.isEnabled = filteredConnectingUsers.isEmpty
                    LeftMenuFirstPresentationPolicy.animate(
                        withDuration: 0.1,
                        isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
                    ) {
                        self.unreadAllMessagesButton.backgroundColor = filteredConnectingUsers.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                    }
                    self.updateUnreadChatsCounter()
                } catch {
                    DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
                }
            })
            .disposed(by: bag)
        
        enabledAccounts
            .asObservable()
            .subscribe(onNext: { _ in
                self.filter.accept(self.filter.value)
                self.subscribeUnreadChatsCounter()
            })
            .disposed(by: bag)
        
        filter
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                self.emptyView.update(for: value)
                self.updateDatasource(value)
                self.updateTitle(value)
                self.bottomBar.leftButton.setImage(imageLiteral(self.filter.value == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
                self.updateBottomTitle()
                self.configureBarsAfterFilterChange()
                self.updateUnreadChatsCounter()
            })
            .disposed(by: bag)
        
        isEmptyViewShowed
            .asObservable()
            .subscribe(onNext: { (value) in
                self.emptyView.isHidden = !value
            })
            .disposed(by: bag)

        observedTypingStates = typingStateSnapshot()
        CommonChatStatesManager.shared.observed.asObservable()
            .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] _ in
                guard let self else { return }
                let next = self.typingStateSnapshot()
                let changed = Set(self.observedTypingStates.keys).union(next.keys).filter {
                    self.observedTypingStates[$0] != next[$0]
                }
                self.observedTypingStates = next
                guard self.datasource.contains(where: {
                    $0.conversationType != .group && $0.conversationType != .saved &&
                        changed.contains([$0.owner, $0.jid].prp())
                }) else { return }
                self.runDatasetUpdateTask()
            })
            .disposed(by: bag)
        
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            self.accountNavButton.update(jid: self.topAccountJid, status: collection.first?.resource?.status ?? .offline)
            Observable
                .collection(from: collection)
                .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.topAccountJid = item.jid
                        self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                        self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                        self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                    }
                    self.retryPendingMessageNotificationRouteOnLifecycleStability()
                }).disposed(by: bag)
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    internal func unsubscribe(clearCaches: Bool = true) {
        projectionLifecycleEpoch = UUID()
        if clearCaches { clearProjectionCaches() }
        deferredSyncPageRefresh = false
        observedTypingStates.removeAll()
        previewMessageObservationBag = DisposeBag()
        previewMessageObservationKeys.removeAll()
        bag = DisposeBag()
        datasetBag = DisposeBag()
        unreadCounterBag = DisposeBag()
        cancelProjectionRefresh()
        visibleVCardRetryScheduler.cancelAll()
        VoiceMessagePlaybackCoordinator.shared.removeObserver(voiceMessageStateObserverToken)
        voiceMessageStateObserverToken = nil
    }

    private func scheduleVCardProjectionRefresh(for notification: Notification) {
        guard let owner = notification.userInfo?[
            VCardManager.persistedOwnerUserInfoKey
        ] as? String,
        let jid = notification.userInfo?[
            VCardManager.persistedJIDUserInfoKey
        ] as? String,
        enabledAccounts.value.contains(owner) else {
            return
        }

        if let identity = VCardPresentationIdentity(owner: owner, jid: jid) {
            visibleVCardRetryScheduler.cancel(identity: identity)
        }

        let identity = datasourceKey(jid: jid, owner: owner)
        guard datasourceIndexPathByKey[identity] != nil else { return }
        scheduleProjectionRefresh(.vCard(identity))
    }

    private func scheduleProjectionRefresh(
        _ invalidation: LastChatsProjectionInvalidation
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleProjectionRefresh(invalidation)
            }
            return
        }

        let registration = projectionRefreshCoalescer.register(invalidation)
        guard registration.shouldRescheduleQuietFlush else { return }

        projectionRefreshQuietWorkItem?.cancel()
        projectionRefreshQuietGeneration &+= 1
        let quietGeneration = projectionRefreshQuietGeneration
        let quietWorkItem = DispatchWorkItem { [weak self] in
            guard self?.projectionRefreshQuietGeneration == quietGeneration else {
                return
            }
            self?.flushProjectionRefresh()
        }
        projectionRefreshQuietWorkItem = quietWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + LastChatsProjectionRefreshCoalescer.quietDelay,
            execute: quietWorkItem
        )

        guard registration.shouldScheduleDeadline else { return }
        projectionRefreshDeadlineGeneration &+= 1
        let deadlineGeneration = projectionRefreshDeadlineGeneration
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            guard self?.projectionRefreshDeadlineGeneration ==
                    deadlineGeneration else {
                return
            }
            self?.flushProjectionRefresh()
        }
        projectionRefreshDeadlineWorkItem = deadlineWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + LastChatsProjectionRefreshCoalescer.maximumDelay,
            execute: deadlineWorkItem
        )
    }

    private func flushProjectionRefresh() {
        let invalidations = projectionRefreshCoalescer.flush()
        guard invalidations.isNotEmpty else {
            cancelProjectionRefresh()
            return
        }
        projectionRefreshQuietGeneration &+= 1
        projectionRefreshDeadlineGeneration &+= 1
        projectionRefreshQuietWorkItem?.cancel()
        projectionRefreshQuietWorkItem = nil
        projectionRefreshDeadlineWorkItem?.cancel()
        projectionRefreshDeadlineWorkItem = nil
        guard isAppeared else { return }
        DDLogDebug(
            "LAST_CHATS_PROJECTION_TRACE event=batchFlush invalidations=\(invalidations.count)"
        )
        updateQueue.async { [weak self] in
            guard let self else { return }
            self.projectionCacheLock.lock(); defer { self.projectionCacheLock.unlock() }
            self.cachedDatasetRealm = nil
        }
        runDatasetUpdateTask()
    }

    private func cancelProjectionRefresh() {
        projectionRefreshCoalescer.cancel()
        projectionRefreshQuietGeneration &+= 1
        projectionRefreshDeadlineGeneration &+= 1
        projectionRefreshQuietWorkItem?.cancel()
        projectionRefreshQuietWorkItem = nil
        projectionRefreshDeadlineWorkItem?.cancel()
        projectionRefreshDeadlineWorkItem = nil
    }

    internal func requestVisibleVCard(owner: String, jid: String) {
        guard let identity = VCardPresentationIdentity(owner: owner, jid: jid) else {
            return
        }
        AccountManager.shared.find(for: identity.owner)?.action {
            [weak self] user, stream in
            let disposition = user.vcards.requestVisibleIfNeeded(
                stream,
                jid: identity.jid
            )
            DispatchQueue.main.async { [weak self] in
                self?.handleVisibleVCardRequestDisposition(
                    disposition,
                    identity: identity
                )
            }
        }
    }

    private func scheduleVisibleVCardRetry(for notification: Notification) {
        guard let owner = notification.userInfo?[
            VCardManager.failedOwnerUserInfoKey
        ] as? String,
        let jid = notification.userInfo?[
            VCardManager.failedJIDUserInfoKey
        ] as? String,
        let failedAt = notification.userInfo?[
            VCardManager.failedAtUserInfoKey
        ] as? Date,
        let identity = VCardPresentationIdentity(owner: owner, jid: jid),
        enabledAccounts.value.contains(identity.owner),
        isVisibleVCardIdentity(identity) else {
            return
        }
        let generationValue = notification.userInfo?[
            VCardManager.failedGenerationUserInfoKey
        ]
        let generation = (generationValue as? UInt64)
            ?? (generationValue as? NSNumber)?.uint64Value
        guard let managerEpoch = notification.userInfo?[
            VCardManager.failedManagerEpochUserInfoKey
        ] as? UUID,
        let generation else {
            return
        }

        scheduleVisibleVCardRetry(
            identity: identity,
            proof: VCardVisibleRetryProof(
                managerEpoch: managerEpoch,
                generation: generation
            ),
            deadline: failedAt.addingTimeInterval(
                VCardRequestRefreshPolicy.failureRetryCooldown
            )
        )
    }

    private func handleVisibleVCardRequestDisposition(
        _ disposition: VCardVisibleRequestDisposition,
        identity: VCardPresentationIdentity
    ) {
        switch disposition {
        case .retryAfter(let deadline, let proof):
            scheduleVisibleVCardRetry(
                identity: identity,
                proof: proof,
                deadline: deadline
            )
        case .satisfied, .submitted, .stale, .unavailable:
            visibleVCardRetryScheduler.cancel(identity: identity)
        }
    }

    private func scheduleVisibleVCardRetry(
        identity: VCardPresentationIdentity,
        proof: VCardVisibleRetryProof,
        deadline: Date
    ) {
        guard isVisibleVCardIdentity(identity) else { return }
        visibleVCardRetryScheduler.schedule(
            identity: identity,
            proof: proof,
            deadline: deadline,
            isStillVisible: { [weak self] in
                self?.isVisibleVCardIdentity(identity) == true
            },
            retry: { [weak self] identity, proof in
                self?.performVisibleVCardRetry(
                    identity: identity,
                    proof: proof
                )
            }
        )
    }

    private func performVisibleVCardRetry(
        identity: VCardPresentationIdentity,
        proof: VCardVisibleRetryProof
    ) {
        guard isVisibleVCardIdentity(identity) else { return }
        AccountManager.shared.find(for: identity.owner)?.action {
            [weak self] user, stream in
            let disposition = user.vcards.retryVisibleIfNeeded(
                stream,
                jid: identity.jid,
                expectedProof: proof
            )
            DispatchQueue.main.async { [weak self] in
                self?.handleVisibleVCardRequestDisposition(
                    disposition,
                    identity: identity
                )
            }
        }
    }

    private func isVisibleVCardIdentity(
        _ identity: VCardPresentationIdentity
    ) -> Bool {
        guard isAppeared,
              !showSkeleton.value,
              !isShowingSearchResults else {
            return false
        }
        return tableView.indexPathsForVisibleRows?.contains { indexPath in
            guard let item = item(at: indexPath),
                  item.specialMessageKind == .none else {
                return false
            }
            return item.owner == identity.owner && item.jid == identity.jid
        } == true
    }

    override func observer() {
        super.observer()
        NotificationCenter.default.addObserver(
            chatBackgroundBackdropView,
            selector: #selector(ChatBackgroundBackdropView.reloadFromSettings),
            name: .chatBackgroundChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .appearanceDidChange,
                                               object: nil)
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterForeground),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)
    }
    
    
    @objc
    private func willEnterForeground() {
//        print(#function)
        NotifyManager.shared.clearAllNotifications()
        guard isAppeared else { return }
        canUpdateDataset = true
        runDatasetUpdateTask()
    }

    private final func setupFloatingToolbar() {
        self.installBottomSearchHostIfNeeded()

        guard self.floatingBottomBarView.superview == nil else {
            self.view.bringSubviewToFront(self.floatingBottomBarView)
            self.view.bringSubviewToFront(self.bottomSearchHostView)
            self.updateFloatingToolbarFilterButtonState()
            self.updateUnreadChatsCounter()
            self.updateTableInsetsForFloatingToolbar()
            return
        }

        self.view.addSubview(self.floatingBottomBarView)
        self.floatingBottomBarView.leftButton.addTarget(
            self,
            action: #selector(onFilterButtonTouchUpInside),
            for: .touchUpInside
        )
        self.floatingBottomBarView.centerButton.addTarget(
            self,
            action: #selector(onMarkAllReadButtonTouchUpInside),
            for: .touchUpInside
        )

        NSLayoutConstraint.activate([
            self.floatingBottomBarView.bottomAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.bottomAnchor,
                constant: -FloatingBottomBarView.Metrics.bottomOffset
            ),
            self.floatingBottomBarView.leadingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.leadingAnchor,
                constant: FloatingBottomBarView.Metrics.horizontalInset
            ),
            self.floatingBottomBarView.trailingAnchor.constraint(
                equalTo: self.bottomSearchHostView.collapsedButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),
            self.floatingBottomBarView.heightAnchor.constraint(equalToConstant: FloatingBottomBarView.Metrics.height)
        ])

        self.view.bringSubviewToFront(self.floatingBottomBarView)
        self.view.bringSubviewToFront(self.bottomSearchHostView)
        self.updateFloatingToolbarFilterButtonState()
        self.updateUnreadChatsCounter()
        self.updateTableInsetsForFloatingToolbar()
    }

    internal final func updateUnreadChatsCounter(count: Int? = nil) {
        let resolvedUnreadChatsCount: Int

        if let count = count {
            resolvedUnreadChatsCount = count
        } else {
            do {
                let realm = try WRealm.safe()
                resolvedUnreadChatsCount = realm
                    .objects(LastChatsStorageItem.self)
                    .filter(
                        "isArchived == false AND unread > 0 AND owner IN %@",
                        Array(self.enabledAccounts.value)
                    )
                    .count
            } catch {
                DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
                resolvedUnreadChatsCount = 0
            }
        }

        self.unreadChatsCount = max(0, resolvedUnreadChatsCount)
        if self.unreadChatsCount == 0, self.filter.value == .unread {
            self.normalState = .chats
            self.filter.accept(.chats)
        }
        self.updateFloatingToolbarFilterButtonState()
    }

    internal final func unreadChatReadTargets() -> [UnreadChatReadTarget] {
        do {
            let realm = try WRealm.safe()
            let candidates = realm
                .objects(LastChatsStorageItem.self)
                .filter(
                    "isArchived == false AND unread > 0 AND owner IN %@",
                    Array(self.enabledAccounts.value)
                )
                .sorted(byKeyPath: "messageDate", ascending: false)
                .map {
                    UnreadChatReadCandidate(
                        owner: $0.owner,
                        jid: $0.jid,
                        conversationType: $0.conversationType,
                        isArchived: $0.isArchived,
                        unread: $0.unread,
                        lastMessagePrimary: $0.lastMessage?.primary,
                        lastMessageId: $0.lastMessageId
                    )
                }

            return Self.unreadChatReadTargets(
                from: Array(candidates),
                enabledAccounts: self.enabledAccounts.value
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    internal final func markUnreadChatsAsRead(_ targets: [UnreadChatReadTarget]) {
        Dictionary(grouping: targets, by: \.owner).forEach { owner, ownerTargets in
            AccountManager.shared.find(for: owner)?.unsafeAction { user, _ in
                ownerTargets.forEach {
                    user.messages.readLastMessage($0.messageTarget)
                }
            }
        }
    }

    internal final func updateFloatingToolbarFilterButtonState() {
        let isUnreadFilterActive = self.filter.value == .unread
        let imageName = isUnreadFilterActive
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        let presentation = Self.bottomBarPresentation(
            unreadChatsCount: self.unreadChatsCount,
            hasConnectingEnabledAccounts: self.hasConnectingEnabledAccounts,
            filter: self.filter.value,
            shouldShowBottomBar: self.shouldShowBottomBar,
            hidesUnderlyingActions: self.bottomSearchHostView.hidesUnderlyingActions
        )

        self.floatingBottomBarView.updateLeftButton(imageName: imageName, isActive: isUnreadFilterActive)
        self.floatingBottomBarView.applyActionPresentation(presentation.actions)
        self.floatingBottomBarFilterButton.isEnabled =
            presentation.actions.isLeftVisible && self.unreadChatsCount > 0
        self.floatingBottomBarView.isHidden = presentation.isActionBarHidden
        self.floatingBottomBarView.refreshAppearance()
    }

    internal final func updateTableInsetsForFloatingToolbar() {
        self.bottomOverlayInsetCoordinator.apply(
            to: self.tableView,
            in: self.view,
            overlays: [self.floatingBottomBarView, self.bottomSearchHostView]
        )
    }

    private final func subscribeUnreadChatsCounter() {
        self.unreadCounterBag = DisposeBag()

        do {
            let realm = try WRealm.safe()
            let unreadCollection = realm
                .objects(LastChatsStorageItem.self)
                .filter(
                    "isArchived == false AND unread > 0 AND owner IN %@",
                    Array(self.enabledAccounts.value)
                )

            Observable
                .collection(from: unreadCollection)
                .debounce(.microseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { results in
                    self.bottomBar.leftButton.isEnabled = results.count > 0
                    self.updateUnreadChatsCounter(count: results.count)
                }, onError: { error in
                    DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
                    self.updateUnreadChatsCounter()
                })
                .disposed(by: self.unreadCounterBag)

            self.updateUnreadChatsCounter(count: unreadCollection.count)
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            self.updateUnreadChatsCounter()
        }
    }
    
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        self.restorationIdentifier = "LastChatsViewController"
        self.restoresFocusAfterTransition = true
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        NavigationLargeTitlePolicy.apply(to: self)
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        
//        tableView.backgroundColor = .clear
        
        
        emptyView.configure {
            self.openAddContactFlow()
        }
        
        emptyView.isHidden = true
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
        configureChatBackground()
        
        if !archivedMode {
            configurePullToArchived()
        }
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            
            enabledAccounts.accept(Set(collection.compactMap { return $0.jid }))
            
            if let item = collection.first {
                self.topAccountJid = item.jid
                self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
            }
            
            
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        self.setupFloatingToolbar()
        self.configurePlayerView()
//        configureNavbar()
    }
    
    private func configureChatBackground() {
        tableView.backgroundColor = .clear
        tableView.isOpaque = false
        emptyView.backgroundColor = .clear
        emptyView.isOpaque = false

        if ContinuousSplitBackgroundExperiment.mode(for: self) == .sharedBackdrop {
            tableView.backgroundView = nil
        } else if tableView.backgroundView !== chatBackgroundBackdropView {
            chatBackgroundBackdropView.reloadFromSettings()
            tableView.backgroundView = chatBackgroundBackdropView
        }
    }

    var isPrimaryShow: Bool = false
    
    @objc
    private func onSidebarButtonTouchUp(_ sender: UIBarButtonItem) {
        
        if #available(iOS 26.0, *) {
            if self.splitViewController?.isShowing(.primary) ?? false {
                self.splitViewController?.hide(.primary)
            } else {
                self.splitViewController?.show(.primary)
            }
        } else {
            if isPrimaryShow {
                isPrimaryShow = false
                self.splitViewController?.hide(.primary)
            } else {
                isPrimaryShow = true
                self.splitViewController?.show(.primary)
            }
        }
    }
    
    open var shouldShowBottomBar: Bool = true

    internal func configureBars(updateNavigationItems: Bool = true) {
        guard !self.isNavigationTransitionActive else {
            self.pendingNavigationChromeRefreshAfterNavigationTransition = true
            return
        }
        if self.navigationItem.backButtonDisplayMode != .minimal {
            self.navigationItem.backButtonDisplayMode = .minimal
        }
        //self.title = "Chats"
        let shouldAnimateNavigationItems = LastChatsNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: true,
            isTransitionActive: self.isNavigationTransitionActive
        )
        self.updateTitle(self.filter.value)
        if navigationItem.titleView !== navigationTitleView {
            navigationItem.titleView = navigationTitleView
        }

        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                if updateNavigationItems {
                    if CommonConfigManager.shared.config.use_yubikey {
                        NavigationBarItemOwnership.applyIfChanged(
                            to: self.navigationItem,
                            left: tabsLeadingNavigationItemAssignment(),
                            right: .items([chatsTabsAddBarButton, securityButton]),
                            animated: shouldAnimateNavigationItems
                        )
                    } else {
                        NavigationBarItemOwnership.applyIfChanged(
                            to: self.navigationItem,
                            left: tabsLeadingNavigationItemAssignment(),
                            right: .item(chatsTabsAddBarButton),
                            animated: shouldAnimateNavigationItems
                        )
                    }
                }
                accountNavButton.removeTarget(self, action: #selector(showSettings), for: .touchUpInside)
                accountNavButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            case .split:
                self.bottomBar.isHidden = true
                self.playerViewToolbar.frame = CGRect(0, 0, self.view.frame.width, AudioPlayerBarView.Metrics.height)
                if updateNavigationItems,
                   let splitNavigationItem = self.splitViewController?.navigationItem {
                    NavigationBarItemOwnership.clearIfChanged(splitNavigationItem, sides: [.left], animated: false)
                }
                
                if updateNavigationItems {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    NavigationBarItemOwnership.applyIfChanged(
                        to: self.navigationItem,
                        left: splitLeadingNavigationItemAssignment(),
                        right: .item(chatsSplitAddBarButton),
                        animated: shouldAnimateNavigationItems
                    )
                }
                
        }
        self.updateFloatingToolbarFilterButtonState()
        self.updateUnreadChatsCounter()
        self.updateTableInsetsForFloatingToolbar()
        
    }

    private func tabsLeadingNavigationItemAssignment() -> NavigationBarItemOwnership.Assignment {
        switch filter.value {
        case .archived, .saved:
            return .item(chatsBackButton)
        case .chats, .unread:
            return .item(accountBarButton)
        }
    }

    private func splitLeadingNavigationItemAssignment() -> NavigationBarItemOwnership.Assignment {
        switch filter.value {
        case .archived, .saved:
            return .item(chatsBackButton)
        case .chats, .unread:
            return .item(chatsSplitSidebarButton)
        }
    }

    internal func configureBarsAfterFilterChange() {
        UIView.performWithoutAnimation {
            configureBars(updateNavigationItems: true)
        }
    }
    
    var normalState: Filter = .chats
    
    func onTitleBarButtonTapped() {
        guard !self.hasConnectingEnabledAccounts else {
            self.updateUnreadChatsCounter()
            return
        }

        let targets = self.unreadChatReadTargets()
        guard !targets.isEmpty else {
            self.updateUnreadChatsCounter(count: 0)
            return
        }

        self.markUnreadChatsAsRead(targets)
        self.canUpdateDataset = true

        if self.filter.value == .unread {
            self.updateUnreadChatsCounter(count: 0)
            self.configureBarsAfterFilterChange()
        } else {
            self.runDatasetUpdateTask()
            self.updateUnreadChatsCounter()
        }
    }
    
    func updateBottomTitle() {
        var title = ""
        bottomBar.isHidden = CommonConfigManager.shared.interfaceType == .split || filter.value == .saved
        switch self.filter.value {
            case .archived:
                title = CommonConfigManager.shared.config.app_name
                bottomBar.titleButton.setTitleColor(.label, for: .normal)
            case .unread:
                title = "Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: [])
                bottomBar.titleButton.setTitleColor(.systemBlue, for: .normal)
            case .chats:
                title = CommonConfigManager.shared.config.app_name
                bottomBar.titleButton.setTitleColor(.label, for: .normal)
            case .saved:
                title = CommonConfigManager.shared.config.app_name
                bottomBar.titleButton.setTitleColor(.label, for: .normal)
        }
        bottomBar.titleButton.setTitle(title, for: .normal)
        self.updateFloatingToolbarFilterButtonState()
        self.updateTableInsetsForFloatingToolbar()
    }
        
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuSelectRootCategoryDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    @objc
    func showSettings(_ sender: AnyObject) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc, parent: self)
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: AnyObject) {
        let vc = CreateNewEntityViewController()
        vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
        showModal(vc, parent: self)
    }

    internal func openAddContactFlow() {
        let vc = CreateNewEntityViewController()
        vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
        showModal(vc, parent: self)
    }
    
    @objc
    func onFilterButtonTouchUpInside(_ sender: AnyObject) {
        onLeftBarButtonTapped()
    }

    @objc
    private func onMarkAllReadButtonTouchUpInside(_ sender: UIButton) {
        onTitleBarButtonTapped()
    }
    
    func onLeftBarButtonTapped() {
        if self.filter.value != .unread {
            self.normalState = self.filter.value
            self.filter.accept(.unread)
        } else {
            self.filter.accept(self.normalState)
        }
        self.bottomBar.leftButton.setImage(UIImage(systemName: self.filter.value == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
        self.updateFloatingToolbarFilterButtonState()
        self.updateUnreadChatsCounter()
        self.updateBottomTitle()
        self.configureBarsAfterFilterChange()
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        self.updateTableInsetsForPinnedVoicePlayer()
        self.updateTableInsetsForFloatingToolbar()
        self.view.bringSubviewToFront(self.pinnedVoicePlayerView)
        self.view.bringSubviewToFront(self.floatingBottomBarView)
        self.view.bringSubviewToFront(self.bottomSearchHostView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureChatBackground()
        self.updateTableInsetsForFloatingToolbar()
    }
    
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        AccountManager.shared.users.forEach {
            user in
            user.action { user, _ in
                user.cloudStorage.getStats()
            }
        }
        NotifyManager.shared.setLastChats(displayed: true)
        configure()
        UIView.performWithoutAnimation {
            configureBars(updateNavigationItems: true)
        }
        configureSearchBar()
    }

    override func reloadDatasource() {
        reloadTableViewOrDeferForActiveSwipe()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        configureChatBackground()
        NavigationLargeTitlePolicy.apply(to: self)
        beginNavigationTransitionDeferralIfNeeded()
        NotifyManager.shared.setLastChats(displayed: true)
        isAppeared = true
        hasCompletedCurrentAppearance = false
        isFirstLayout = true
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        if !self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
            self?.subscribe()
        }) {
            subscribe()
        }
        if SignatureManager.shared.certificate != nil {
            self.securityButton.tintColor = .systemGreen
        } else {
            self.securityButton.tintColor = .systemRed
        }
        UIView.performWithoutAnimation {
            configureBars(updateNavigationItems: true)
            configureSearchBar()
        }
        if !self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
            self?.showPlayerViewIfNeeded()
        }) {
            self.showPlayerViewIfNeeded()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasCompletedCurrentAppearance = true
        let chatNavigationReconciliationOwnsLifecycleRetry =
            reconcileChatNavigationTransactionOnDidAppear(
                scheduleLifecycleRetry: true
            )
        cancelPendingBottomSearchDismissalAfterCancelledRoute()
        updateTitle(filter.value)
        UIView.performWithoutAnimation {
            syncSelectedChatSelection()
        }
        clearSelectedChatSelectionOnReturnIfNeeded(
            route: stackedNavigationRoute(for: self),
            animated: true
        )
        NotifyManager.shared.setLastChats(displayed: true)
        if !chatNavigationReconciliationOwnsLifecycleRetry {
            retryPendingMessageNotificationRouteOnLifecycleStability()
        }
        if shouldRequestNotificationAuthorizationPrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.shouldRequestNotificationAuthorizationPrompt == true else {
                    return
                }
                let center = UNUserNotificationCenter.current()
                center.requestAuthorization(options: [.alert, .sound, .badge]) {
                    _, _ in
                }
            }
        }
        completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()
        flushPendingRootChatActivationAfterAppearance()
    }

    private var shouldRequestNotificationAuthorizationPrompt: Bool {
        LastChatsNotificationAuthorizationPromptPolicy.shouldRequest(
            isLastChatsVisible:
                isAppeared && viewIfLoaded?.window != nil,
            applicationState: UIApplication.shared.applicationState,
            sceneActivationState:
                viewIfLoaded?.window?.windowScene?.activationState
        )
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.retryPendingMessageNotificationRouteOnLifecycleStability()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        markChatNavigationPresenterWillDisappear()
        beginNavigationTransitionDeferralIfNeeded()
        NotifyManager.shared.setLastChats(displayed: false)
        isAppeared = false
        hasCompletedCurrentAppearance = false
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        completePendingBottomSearchDismissalAfterRoute()
        endLeftMenuFirstPresentationQuietMode()
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        clearProjectionCaches()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(chatBackgroundBackdropView)
        stopExpandedSplitAccountRegistryMutationObservation()
        unsubscribe(clearCaches: false)
        clearProjectionCachesImmediately()
    }
}

extension LastChatsViewController: MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String {
        return "last_chats_smid"
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        
    }
    
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        
    }
    
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("finish")
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }
}

extension LastChatsViewController: AudioPlayerBarViewDelegate {
    func audioPlayerBarViewDidTapClose(_ view: AudioPlayerBarView) {
        VoiceMessagePlaybackCoordinator.shared.stopPlayback()
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }

    func audioPlayerBarViewDidTapPlayPause(_ view: AudioPlayerBarView) {
        VoiceMessagePlaybackCoordinator.shared.toggleCurrentPlayback()
    }

    func audioPlayerBarViewDidTapTitle(_ view: AudioPlayerBarView) {
        self.openActiveVoiceMessageRoute()
    }
}

extension LastChatsViewController: SharedAudioPlayerPanelDelegate {
    func shouldPlay() {
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }
    
    func shouldPause() {
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }
    
    func shouldShow() {
        self.renderPinnedVoicePlayer(snapshot: VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot)
    }
    
    func shouldHide() {
        self.renderPinnedVoicePlayer(snapshot: nil)
    }
}

extension LastChatsViewController: LeftMenuRootNavigationChromeRefreshable {
    func refreshLeftMenuRootNavigationChromeAfterModalDismiss() {
        UIView.performWithoutAnimation {
            configureBars(updateNavigationItems: true)
        }
    }
}
