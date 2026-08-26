import UIKit
import RealmSwift

#if DEBUG || CHAT_PERFORMANCE_LAB
enum ChatPerformanceManualNativeBackAccessibility {
    static let tabShell = "chat-performance-tab-shell"
    static let navigationShell =
        "chat-performance-last-chats-navigation-shell"
    static let lastChatsScreen = "chat-performance-last-chats-screen"
    static let row = "chat-performance-last-chats-row"
    static let p13NotificationsScreen =
        "chat-performance-p13-notifications-screen"
    static let p13DeletedMentionRow =
        "chat-performance-p13-deleted-mention-row"
    static let p14MentionRow = "chat-performance-p14-mention-row"
}

enum ChatPerformanceManualNativeBackLaunchPolicy {
    static let launchArgument = "--xabber-chat-manual-native-back"

    static func isEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard arguments.filter({ $0 == launchArgument }).count == 1,
              let descriptor = ChatPerformanceUITestLaunchPolicy.descriptor(
                arguments: arguments,
                environment: environment
              ),
              descriptor.openScenario == nil else {
            return false
        }
        return true
    }
}

enum ChatPerformanceFixtureRootMode: Equatable {
    case directChatFixture
    case lastChatsNativeRoute
}

enum ChatPerformanceFixtureRootPolicy {
    static func mode(
        for scenario: ChatOpenRealPipelineFixtureScenario
    ) -> ChatPerformanceFixtureRootMode {
        switch scenario {
        case .coldPushExact, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact:
            return .lastChatsNativeRoute
        default:
            return .directChatFixture
        }
    }
}

enum ChatPerformanceP14SourceReadinessBlocker: String, Equatable {
    case datasourceRowMissing = "datasource-row-missing"
    case rowNotVisible = "row-not-visible"
    case cellNotMaterialized = "cell-not-materialized"
    case hostDetached = "host-detached"
    case skeletonVisible = "skeleton-visible"
    case mentionPreTapProofRejected = "mention-pre-tap-proof-rejected"
}

/// P13 keeps the actual Notifications controller, its Realm observation and
/// inherited UITableViewDelegate entrypoint. This subclass only observes the
/// deterministic source row and exposes a privacy-safe accessibility marker;
/// it never assigns `datasource` or resolves/routes a mention itself.
final class ChatPerformanceMentionNotificationsRouteHostViewController:
    NotificationsListViewController {

    private let destination: ChatPerformanceFixtureViewController
    private weak var lastChatsRouteHost:
        ChatPerformanceLastChatsRouteHostViewController?
    private weak var rootCoordinator: AppRootCoordinator?
    private var readinessWorkItem: DispatchWorkItem?
    private var readinessDeadline: Date?
    private var didCaptureTerminalAttempt = false
    private(set) var performanceP13SourceRowVisibleForTesting = false
    private(set) var performanceP13DatasourceWasProductionAppliedForTesting =
        false
    private(set) var performanceP13SourceRowTapCountForTesting = 0
    private(set) var performanceP13AttemptCountForTesting = 0
    private(set) var performanceP13InvalidationCountForTesting = 0
    private(set) var performanceP13AdvanceCountForTesting = 0
    private(set) var performanceP13UnavailableCountForTesting = 0
    private(set) var performanceP13SelectedNextIdentityCountForTesting = 0
    private(set) var performanceP13UnrelatedGroupPreservedCountForTesting = 0

    init(
        descriptor: ChatPerformanceUITestLaunchDescriptor,
        destination: ChatPerformanceFixtureViewController
    ) {
        guard descriptor.openScenario == .mentionDeletedAdvance else {
            preconditionFailure(
                "The Notifications production host is reserved for P13"
            )
        }
        self.destination = destination
        super.init(nibName: nil, bundle: nil)
        installAttemptObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(
        lastChatsRouteHost: ChatPerformanceLastChatsRouteHostViewController,
        rootCoordinator: AppRootCoordinator
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.lastChatsRouteHost = lastChatsRouteHost
        self.rootCoordinator = rootCoordinator
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier =
            ChatPerformanceManualNativeBackAccessibility
                .p13NotificationsScreen
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installAttemptObservation()
        beginSourceRowReadinessObservation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        if selectedSourceRowIsDeletedMention() {
            performanceP13SourceRowTapCountForTesting = 1
        }
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Production teardown clears DEBUG observers. Reinstall the weak
        // evidence closure before the still-running inherited didSelect
        // publishes its post-route attempt receipt.
        installAttemptObservation()
    }

    private func installAttemptObservation() {
        mentionOpenAttemptObserverForTests = { [weak self] attempt in
            self?.capture(attempt: attempt)
        }
    }

    private func beginSourceRowReadinessObservation() {
        guard !performanceP13SourceRowVisibleForTesting,
              readinessWorkItem == nil else {
            return
        }
        readinessDeadline = Date().addingTimeInterval(6)
        observeSourceRowReadiness()
    }

    private func observeSourceRowReadiness() {
        readinessWorkItem = nil
        guard !performanceP13SourceRowVisibleForTesting else { return }
        if let indexPath = sourceRowIndexPath(),
           tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
           let cell = tableView.cellForRow(at: indexPath),
           viewIfLoaded?.window != nil,
           datasourceContainsEveryP13FixtureNotification(),
           (leftMenuDelegate as AnyObject?) ===
                (rootCoordinator as AnyObject?),
           destination.prepareP13DeletedMentionTapBoundaryForTesting() {
            performanceP13DatasourceWasProductionAppliedForTesting = true
            performanceP13SourceRowVisibleForTesting = true
            cell.accessibilityIdentifier =
                ChatPerformanceManualNativeBackAccessibility
                    .p13DeletedMentionRow
            return
        }
        guard (readinessDeadline ?? .distantPast) > Date() else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.observeSourceRowReadiness()
        }
        readinessWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05,
            execute: workItem
        )
    }

    private func datasourceContainsEveryP13FixtureNotification() -> Bool {
        let primaries = Set(datasource.flatMap { section in
            section.childs.map(\.primary)
        })
        let hasRequiredSourceAndControl = primaries.contains(
            destination.p13DeletedMentionNotificationPrimaryForTesting
        ) && primaries.contains(
            destination.p13UnrelatedMentionNotificationPrimaryForTesting
        )
        let hasExpectedFollowingState =
            destination.isP13NoFollowingBranchForTesting ||
            primaries.contains(
                destination.p13NextMentionNotificationPrimaryForTesting
            )
        return hasRequiredSourceAndControl && hasExpectedFollowingState
    }

    private func sourceRowIndexPath() -> IndexPath? {
        for (sectionIndex, section) in datasource.enumerated() {
            if let row = section.childs.firstIndex(where: {
                $0.primary ==
                    destination.p13DeletedMentionNotificationPrimaryForTesting
            }) {
                return IndexPath(row: row, section: sectionIndex)
            }
        }
        return nil
    }

    private func selectedSourceRowIsDeletedMention() -> Bool {
        guard let selected = tableView.indexPathForSelectedRow,
              let source = sourceRowIndexPath() else {
            return false
        }
        return selected == source
    }

    @discardableResult
    internal func performP13SourceRowTapForTesting() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard performanceP13SourceRowVisibleForTesting,
              performanceP13SourceRowTapCountForTesting == 0,
              let indexPath = sourceRowIndexPath(),
              tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
              tableView.cellForRow(at: indexPath) != nil,
              tableView(tableView, willSelectRowAt: indexPath) == indexPath
        else {
            return false
        }
        tableView.selectRow(
            at: indexPath,
            animated: false,
            scrollPosition: .none
        )
        tableView(tableView, didSelectRowAt: indexPath)
        return true
    }

    private func capture(attempt: NotificationsMentionOpenAttemptDiagnostics) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard attempt.tappedNotificationPrimary ==
                destination.p13DeletedMentionNotificationPrimaryForTesting
        else {
            return
        }
        performanceP13AttemptCountForTesting &+= 1
        guard !didCaptureTerminalAttempt else {
            lastChatsRouteHost?.performanceP13SourceDiagnosticsDidChange()
            return
        }
        didCaptureTerminalAttempt = true
        performanceP13SourceRowTapCountForTesting = 1

        switch attempt.resolution {
        case .exact(let request, let invalidatedPrimary):
            if invalidatedPrimary ==
                destination.p13DeletedMentionNotificationPrimaryForTesting {
                performanceP13InvalidationCountForTesting = 1
            }
            let isNextExact = request.source == .mentionNotification &&
                request.owner == destination.owner &&
                request.chatJid == destination.jid &&
                request.conversationType == .group &&
                request.anchor.archivedId == destination.openScenarioArchiveId(
                    ChatOpenRealPipelineFixturePlan(
                        scenario: .mentionDeletedAdvance
                    ).p13NextValidMentionOrdinal
                )
            if isNextExact {
                performanceP13AdvanceCountForTesting = 1
            }
            if isNextExact,
               attempt.selectedNotificationPrimary ==
                destination.p13NextMentionNotificationPrimaryForTesting {
                performanceP13SelectedNextIdentityCountForTesting = 1
            }
        case .unavailable(
            .deletedTargetHasNoFollowingMention
        ):
            performanceP13InvalidationCountForTesting = 1
            performanceP13UnavailableCountForTesting = 1
        case .unavailable:
            performanceP13UnavailableCountForTesting = 1
        }

        performanceP13UnrelatedGroupPreservedCountForTesting =
            unrelatedGroupIsPreserved() ? 1 : 0
        lastChatsRouteHost?.performanceP13SourceDiagnosticsDidChange()
    }

    private func unrelatedGroupIsPreserved() -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let notification = realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey:
                    destination
                        .p13UnrelatedMentionNotificationPrimaryForTesting
            ) else {
                return false
            }
            return !notification.isRead &&
                notification.shouldShow &&
                notification.mentionLinkStatus == .resolved
        } catch {
            return false
        }
    }
}

/// Pure milestone gate mirrored by the DEBUG host. It prevents scene/root,
/// Last Chats visibility and account-registry wakes from producing more than
/// one initial production route attempt.
struct ChatPerformanceColdPushStartupGate {
    private var hasPendingExactRoute = false
    private var hasInstalledRoot = false
    private var hasVisibleLastChats = false
    private var hasMaterializedAccount = false
    private(set) var hasNativeStableAttachment = false
    private(set) var hasStableTargetAcknowledgement = false
    private(set) var productionRouteAttemptCount = 0
    private(set) var pendingRouteConsumeCount = 0
    private(set) var consumeBeforeStableCount = 0

    @discardableResult
    mutating func retainPendingExactRoute() -> Bool {
        guard !hasPendingExactRoute else { return false }
        hasPendingExactRoute = true
        return true
    }

    mutating func recordRootInstalled() {
        hasInstalledRoot = true
    }

    mutating func recordLastChatsVisible() {
        hasVisibleLastChats = true
    }

    mutating func recordAccountMaterialized() {
        hasMaterializedAccount = true
    }

    var shouldAttemptProductionRoute: Bool {
        hasPendingExactRoute &&
            hasInstalledRoot &&
            hasVisibleLastChats &&
            hasMaterializedAccount &&
            productionRouteAttemptCount == 0
    }

    @discardableResult
    mutating func recordProductionRouteAttempt() -> Bool {
        guard shouldAttemptProductionRoute else { return false }
        productionRouteAttemptCount += 1
        return true
    }

    mutating func recordNativePresentationCompleted() {
        hasNativeStableAttachment = true
    }

    mutating func recordStableTargetAcknowledgement() {
        hasStableTargetAcknowledgement = true
    }

    @discardableResult
    mutating func consumePendingRouteIfEligible(
        hasStableTargetAcknowledgement: Bool
    ) -> Bool {
        guard hasPendingExactRoute,
              hasNativeStableAttachment,
              self.hasStableTargetAcknowledgement,
              hasStableTargetAcknowledgement else {
            return false
        }
        hasPendingExactRoute = false
        pendingRouteConsumeCount += 1
        return true
    }
}

enum ChatPerformanceNativePushBackdropPolicy {
    static func isAdmissible(
        rootIsRealLastChatsHost: Bool,
        usesProductionStackNewChat: Bool,
        usesNativeAnimatedPush: Bool,
        destinationViewIsAttached: Bool,
        destinationBackdropIsOpaque: Bool,
        destinationBackdropInstalledBeforeFirstRow: Bool,
        priorDatasourceRowCount: Int,
        lastChatsExposureCount: Int
    ) -> Bool {
        rootIsRealLastChatsHost &&
            usesProductionStackNewChat &&
            usesNativeAnimatedPush &&
            destinationViewIsAttached &&
            destinationBackdropIsOpaque &&
            destinationBackdropInstalledBeforeFirstRow &&
            priorDatasourceRowCount == 0 &&
            lastChatsExposureCount == 0
    }
}

/// A deterministic but production-shaped navigation fixture for native Back
/// and interactive-pop verification. It deliberately does not auto-route:
/// the only transition into Chat starts in LastChats' ordinary table delegate.
final class ChatPerformanceManualNativeBackLastChatsHostViewController:
    LastChatsViewController {

    private let destination: ChatPerformanceFixtureViewController
    private var realmLease: Realm?

    init(destination: ChatPerformanceFixtureViewController) {
        self.destination = destination
        super.init(nibName: nil, bundle: nil)
        seedSingleProductionRow()
        compactChatDestinationFactory = { [weak destination] in
            guard let destination else {
                preconditionFailure(
                    "The manual native-back destination was released"
                )
            }
            return destination
        }
        performanceChatRowAccessibilityIdentifierProvider = {
            [weak destination] item in
            guard let destination,
                  item.owner == destination.owner,
                  item.jid == destination.jid,
                  item.conversationType == destination.conversationType else {
                return nil
            }
            return ChatPerformanceManualNativeBackAccessibility.row
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier =
            ChatPerformanceManualNativeBackAccessibility.lastChatsScreen
    }

    private func seedSingleProductionRow() {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            let realm = try WRealm.safe()
            guard realm.configuration.inMemoryIdentifier != nil else {
                preconditionFailure(
                    "The manual native-back fixture requires ephemeral storage"
                )
            }
            realmLease = realm
            let owner = destination.owner
            let jid = destination.jid
            let conversationType = destination.conversationType
            try realm.write {
                let existingAccount = realm.object(
                    ofType: AccountStorageItem.self,
                    forPrimaryKey: owner
                )
                let account = existingAccount ?? AccountStorageItem()
                if existingAccount == nil {
                    account.jid = owner
                }
                account.username = ""
                account.enabled = true
                account.savePassword = false
                realm.add(account, update: .modified)

                let primary = LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
                realm.delete(
                    realm.objects(LastChatsStorageItem.self)
                        .filter("primary != %@", primary)
                )
                let existingChat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: primary
                )
                let chat = existingChat ?? LastChatsStorageItem()
                if existingChat == nil {
                    chat.primary = primary
                }
                chat.owner = owner
                chat.jid = jid
                chat.conversationType = conversationType
                chat.messageDate = Date(timeIntervalSince1970: 1_700_000_000)
                chat.isSynced = true
                chat.isInitialArchiveLoaded = true
                chat.fullArchiveLoaded = true
                chat.isAllHistoryLoaded = true
                realm.add(chat, update: .modified)
            }
            if AccountManager.shared.find(for: owner) == nil {
                AccountManager.shared.add(withJid: owner, autoConnect: false)
            }
            AccountManager.shared.markAsConnected(jid: owner)
        } catch {
            preconditionFailure(
                "Unable to seed manual native-back fixture: \(error)"
            )
        }
    }
}

/// Production-shaped route host used only by the deterministic performance
/// process. The root remains the normal Xabber tab topology; this controller
/// owns the real Last Chats lifecycle and observes the native push callbacks.
final class ChatPerformanceLastChatsRouteHostViewController:
    LastChatsViewController,
    UINavigationControllerDelegate {

    private let scenario: ChatOpenRealPipelineFixtureScenario
    private let destination: ChatPerformanceFixtureViewController
    private weak var rootCoordinator: AppRootCoordinator?
    private var coldStartupGate = ChatPerformanceColdPushStartupGate()
    private var coldPendingRoute: MessageNotificationChatRoute?
    private var didHandleFirstAppearance = false
    private var didAttemptRoute = false
    private var didPublishNativePresentationBegin = false
    private var didReleaseDestinationNavigationTransition = false
    private var rootInstalled = false
    private var lastChatsVisibleBeforeRoute = false
    private var routeAttemptCount = 0
    private var nativePushCount = 0
    private var destinationOpaqueBeforeFirstRow = false
    private var lastChatsExposureCount = 0
    private var coldPendingBeforeRoot = 0
    private var accountMaterializationCount = 0
    private var coldConsumeBeforeStableCount = 0
    private var coldConsumeAfterStableCount = 0
    private var p14SourceRowVisibleBeforeTap = false
    private var p14SourceRowTapCount = 0
    private var p14PendingRequestCountBeforeTap = 0
    private var p14RequestAdmissionCountBeforeTap = 0
    private var p14RowReadinessWorkItem: DispatchWorkItem?
    private var p14RowReadinessDeadline: Date?
    private var p13DidShowObserved = false
    private weak var p13SourceHost:
        ChatPerformanceMentionNotificationsRouteHostViewController?
    private var didMaterializeFixtureAccount = false
    internal private(set) var performanceP14SourceReadinessBlockerForTesting:
        ChatPerformanceP14SourceReadinessBlocker?

    internal var performanceRouteHostDiagnosticsSnapshot:
        ChatPerformanceRouteHostDiagnostics {
        routeHostDiagnostics()
    }

    init(
        descriptor: ChatPerformanceUITestLaunchDescriptor,
        destination: ChatPerformanceFixtureViewController,
        rootCoordinator: AppRootCoordinator
    ) {
        guard let scenario = descriptor.openScenario,
              ChatPerformanceFixtureRootPolicy.mode(for: scenario) ==
                .lastChatsNativeRoute else {
            preconditionFailure(
                "A production route host requires P04, P13, P14 or V01"
            )
        }
        self.scenario = scenario
        self.destination = destination
        self.rootCoordinator = rootCoordinator
        super.init(nibName: nil, bundle: nil)

        compactChatDestinationFactory = { [weak destination] in
            guard let destination else {
                preconditionFailure("The route fixture destination was released")
            }
            return destination
        }
        if scenario == .mentionDeletedAdvance {
            destination.performanceOpenMessageRequestAdmissionObserver = {
                [weak self] request, _ in
                self?.recordP13ProductionRequestAdmission(request)
            }
        }
        if scenario == .lastChatsSeededMentionExact {
            performanceChatRowAccessibilityIdentifierProvider = {
                [weak self, weak destination] item in
                guard let self, let destination,
                      self.p14SourceRowVisibleBeforeTap,
                      item.owner == destination.owner,
                      item.jid == destination.jid,
                      item.conversationType == .group else {
                    return nil
                }
                return ChatPerformanceManualNativeBackAccessibility
                    .p14MentionRow
            }
            performanceChatRowSelectionObserver = {
                [weak self] item, indexPath, request in
                self?.recordP14ProductionRowSelection(
                    item: item,
                    indexPath: indexPath,
                    request: request
                )
            }
        }
        pendingMessageNotificationRouteRetryHandler = { [weak self] in
            guard let self else { return false }
            if !self.didAttemptRoute {
                return self.attemptColdProductionRouteIfReady()
            }
            let hadStableExactAcknowledgement = self.coldPendingRoute.map {
                self.destination.hasStableChatOpenAcknowledgement(
                    for: $0.openMessageRequest
                )
            } ?? false
            let didConsume = self.rootCoordinator?
                .retryPendingMessageNotificationChatRouteIfPossible() ?? false
            if self.scenario == .coldPushExact,
               !hadStableExactAcknowledgement,
               NotifyManager.shared
                .performancePendingMessageNotificationChatRoute == nil {
                self.coldConsumeBeforeStableCount = 1
                self.destination
                    .performanceRouteHostDidCompleteNativePresentation(
                        self.routeHostDiagnostics()
                    )
            }
            if self.scenario == .coldPushExact,
               hadStableExactAcknowledgement,
               didConsume {
                self.recordColdStableVisibilityConsumption()
            }
            return didConsume
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if scenario == .lastChatsSeededMentionExact {
            view.accessibilityIdentifier =
                ChatPerformanceManualNativeBackAccessibility.lastChatsScreen
        }
    }

    func installColdPendingRoute(_ route: MessageNotificationChatRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard scenario == .coldPushExact,
              coldPendingRoute == nil else {
            preconditionFailure("P04 owns exactly one pending exact route")
        }
        coldPendingRoute = route
        precondition(coldStartupGate.retainPendingExactRoute())
    }

    func rootDidInstall(coldPendingBeforeRoot: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        let navigationController = navigationController
        let tabController = tabBarController
        rootInstalled = tabController is XabberTabBarViewController &&
            navigationController?.viewControllers.first === self &&
            tabController?.viewControllers?.contains {
                $0 === navigationController
            } == true
        self.coldPendingBeforeRoot = coldPendingBeforeRoot
        coldStartupGate.recordRootInstalled()
        if scenario == .mentionDeletedAdvance {
            navigationController?.delegate = self
            materializeFixtureAccountIfNeeded()
        }
    }

    func attachP13SourceHost(
        _ sourceHost:
            ChatPerformanceMentionNotificationsRouteHostViewController
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard scenario == .mentionDeletedAdvance else {
            preconditionFailure("Only P13 may attach a Notifications source")
        }
        p13SourceHost = sourceHost
    }

    internal func performanceP13SourceDiagnosticsDidChange() {
        guard scenario == .mentionDeletedAdvance,
              didAttemptRoute,
              p13DidShowObserved else {
            return
        }
        destination.performanceRouteHostDidCompleteNativePresentation(
            routeHostDiagnostics()
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        navigationController?.delegate = self
        super.viewDidAppear(animated)
        guard !didHandleFirstAppearance else { return }
        didHandleFirstAppearance = true
        lastChatsVisibleBeforeRoute = viewIfLoaded?.window != nil && isAppeared
        if lastChatsVisibleBeforeRoute {
            coldStartupGate.recordLastChatsVisible()
        }
        materializeFixtureAccountIfNeeded()

        switch scenario {
        case .coldPushExact:
            _ = attemptColdProductionRouteIfReady()
        case .lastChatsAnimatedPush:
            attemptStandardProductionRouteIfNeeded()
        case .lastChatsSeededMentionExact:
            beginP14SourceRowReadinessObservation()
        case .mentionDeletedAdvance:
            break
        default:
            preconditionFailure("Unsupported production route scenario")
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        guard viewController === destination else { return }
        if animated {
            nativePushCount += 1
        }
        let backdrop = destination.chatDestinationBackdropInstallationReceipt
        destinationOpaqueBeforeFirstRow =
            backdrop.isOpaqueBeforeFirstDatasourceRow
        if !destinationOpaqueBeforeFirstRow {
            lastChatsExposureCount += 1
        }
        guard !didPublishNativePresentationBegin else { return }
        didPublishNativePresentationBegin = true
        destination.performanceRouteHostDidBeginNativePresentation(
            routeHostDiagnostics()
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard viewController === destination else { return }
        // The deterministic fixture deliberately suppresses ChatViewController's
        // subscription-owning appearance callbacks. UIKit's native `didShow`
        // is therefore the authoritative successful-transition boundary that
        // releases queued work and mirrors viewDidAppear's pending-request
        // admission. A cold-push request delivered before view loading has no
        // timeline yet, so its first attempt cannot enqueue transition work.
        if !didReleaseDestinationNavigationTransition {
            didReleaseDestinationNavigationTransition = true
            destination.completeNavigationTransitionDeferral(cancelled: false)
            destination.performPendingOpenMessageRequestIfNeeded()
        }
        let backdrop = destination.chatDestinationBackdropInstallationReceipt
        let isAdmissible = ChatPerformanceNativePushBackdropPolicy.isAdmissible(
            rootIsRealLastChatsHost: rootInstalled,
            usesProductionStackNewChat: didAttemptRoute,
            usesNativeAnimatedPush: animated && nativePushCount == 1,
            destinationViewIsAttached:
                destination.viewIfLoaded?.window ===
                    navigationController.viewIfLoaded?.window,
            destinationBackdropIsOpaque: backdrop.isOpaque,
            destinationBackdropInstalledBeforeFirstRow:
                backdrop.isOpaqueBeforeFirstDatasourceRow,
            priorDatasourceRowCount: backdrop.priorDatasourceRowCount,
            lastChatsExposureCount: lastChatsExposureCount
        )
        destinationOpaqueBeforeFirstRow = isAdmissible
        if scenario == .coldPushExact {
            coldStartupGate.recordNativePresentationCompleted()
            if NotifyManager.shared
                .performancePendingMessageNotificationChatRoute == nil {
                coldConsumeBeforeStableCount = 1
            }
        }
        if scenario == .mentionDeletedAdvance {
            p13DidShowObserved = true
        }
        destination.performanceRouteHostDidCompleteNativePresentation(
            routeHostDiagnostics()
        )
    }

    /// The request admission callback is synchronous inside production
    /// `queueOpenMessageRequest`, before exact-local execution or asynchronous
    /// destination preparation can consume `pendingOpenMessageRequest`.
    /// The real UIKit tap receipt is published later by source disappearance
    /// or the terminal attempt callback, so it remains a terminal route proof
    /// rather than a prerequisite for this synchronous admission boundary.
    /// UIKit `willShow` remains a separate native-transition receipt and must
    /// not infer route admission from that transient execution property.
    private func recordP13ProductionRequestAdmission(
        _ request: ChatOpenMessageRequest
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .mentionDeletedAdvance
        )
        guard scenario == .mentionDeletedAdvance,
              !didAttemptRoute,
              routeAttemptCount == 0,
              nativePushCount == 0,
              let p13SourceHost,
              p13SourceHost
                .performanceP13DatasourceWasProductionAppliedForTesting,
              p13SourceHost.performanceP13SourceRowVisibleForTesting,
              request.owner == destination.owner,
              request.chatJid == destination.jid,
              request.conversationType == .group,
              request.source == .mentionNotification,
              request.highlight,
              request.markReadOnVisible,
              request.targetResolution == .anchor,
              request.anchor.messagePrimary == nil,
              request.anchor.archivedId ==
                destination.openScenarioArchiveId(
                    plan.p13NextValidMentionOrdinal
                ),
              request.anchor.messageId ==
                destination.openScenarioMessageId(
                    plan.p13NextValidMentionOrdinal
                ) else {
            return
        }
        didAttemptRoute = true
        routeAttemptCount = 1
    }

    private func materializeFixtureAccountIfNeeded() {
        guard !didMaterializeFixtureAccount else { return }
        if AccountManager.shared.find(for: destination.owner) == nil {
            AccountManager.shared.add(
                withJid: destination.owner,
                autoConnect: false
            )
        }
        guard AccountManager.shared.find(for: destination.owner) != nil else {
            return
        }
        // `add(autoConnect: false)` enters the normal connecting state, but
        // this deterministic fixture has no transport that could complete it.
        // Finish that fixture-only lifecycle before Last Chats decides whether
        // its seeded production row may replace the skeleton.
        AccountManager.shared.markAsConnected(jid: destination.owner)
        didMaterializeFixtureAccount = true
        // This diagnostic counts observation of the readiness milestone, not
        // object construction. A preexisting matching account is equally
        // materialized for the cold-start gate and must not deadlock routing.
        accountMaterializationCount += 1
        coldStartupGate.recordAccountMaterialized()
    }

    @discardableResult
    private func attemptColdProductionRouteIfReady() -> Bool {
        guard scenario == .coldPushExact,
              coldStartupGate.recordProductionRouteAttempt() else {
            return false
        }
        didAttemptRoute = true
        routeAttemptCount += 1
        return rootCoordinator?
            .retryPendingMessageNotificationChatRouteIfPossible() ?? false
    }

    private func attemptStandardProductionRouteIfNeeded() {
        guard scenario == .lastChatsAnimatedPush,
              !didAttemptRoute else {
            return
        }
        didAttemptRoute = true
        routeAttemptCount += 1
        _ = rootCoordinator?.route(.chat(
            owner: destination.owner,
            jid: destination.jid,
            conversationType: destination.conversationType
        ))
    }

    private func beginP14SourceRowReadinessObservation() {
        guard scenario == .lastChatsSeededMentionExact,
              !p14SourceRowVisibleBeforeTap,
              p14RowReadinessWorkItem == nil else {
            return
        }
        p14RowReadinessDeadline = Date().addingTimeInterval(6)
        observeP14SourceRowReadiness()
    }

    private func observeP14SourceRowReadiness() {
        p14RowReadinessWorkItem = nil
        guard scenario == .lastChatsSeededMentionExact,
              !p14SourceRowVisibleBeforeTap,
              !didAttemptRoute else {
            return
        }
        let readiness = p14SourceRowReadinessCandidate()
        performanceP14SourceReadinessBlockerForTesting = readiness.blocker
        if let indexPath = readiness.indexPath {
            p14PendingRequestCountBeforeTap =
                destination.pendingOpenMessageRequest == nil ? 0 : 1
            p14RequestAdmissionCountBeforeTap =
                destination.p14RequestAdmissionCountForTesting
            p14SourceRowVisibleBeforeTap =
                destination.captureP14MentionPreTapProofIfNeeded()
            if p14SourceRowVisibleBeforeTap {
                performanceP14SourceReadinessBlockerForTesting = nil
                tableView.cellForRow(at: indexPath)?.accessibilityIdentifier =
                    ChatPerformanceManualNativeBackAccessibility.p14MentionRow
            } else {
                performanceP14SourceReadinessBlockerForTesting =
                    .mentionPreTapProofRejected
                NSLog(
                    "CHAT_OPEN_FIXTURE_P14_READINESS blocker=%@",
                    ChatPerformanceP14SourceReadinessBlocker
                        .mentionPreTapProofRejected.rawValue
                )
            }
            return
        }
        guard (p14RowReadinessDeadline ?? .distantPast) > Date() else {
            NSLog(
                "CHAT_OPEN_FIXTURE_P14_READINESS blocker=%@",
                performanceP14SourceReadinessBlockerForTesting?.rawValue ??
                    "deadline-without-classification"
            )
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.observeP14SourceRowReadiness()
        }
        p14RowReadinessWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05,
            execute: workItem
        )
    }

    private func p14SourceRowReadinessCandidate() -> (
        indexPath: IndexPath?,
        blocker: ChatPerformanceP14SourceReadinessBlocker?
    ) {
        guard let indexPath = p14SourceRowIndexPath() else {
            return (nil, .datasourceRowMissing)
        }
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == true else {
            return (nil, .rowNotVisible)
        }
        guard tableView.cellForRow(at: indexPath) != nil else {
            return (nil, .cellNotMaterialized)
        }
        guard viewIfLoaded?.window != nil else {
            return (nil, .hostDetached)
        }
        guard !showSkeleton.value else {
            return (nil, .skeletonVisible)
        }
        return (indexPath, nil)
    }

    private func p14SourceRowIndexPath() -> IndexPath? {
        let key = datasourceKey(
            jid: destination.jid,
            owner: destination.owner
        )
        guard let indexPath = datasourceIndexPathByKey[key],
              let item = item(at: indexPath),
              item.owner == destination.owner,
              item.jid == destination.jid,
              item.conversationType == .group else {
            return nil
        }
        return indexPath
    }

    @discardableResult
    internal func performP14SourceRowTapForTesting() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard scenario == .lastChatsSeededMentionExact,
              p14SourceRowVisibleBeforeTap,
              p14SourceRowTapCount == 0,
              let indexPath = p14SourceRowIndexPath(),
              tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
              tableView.cellForRow(at: indexPath) != nil else {
            return false
        }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        tableView(tableView, didSelectRowAt: indexPath)
        return true
    }

    private func recordP14ProductionRowSelection(
        item: Datasource,
        indexPath: IndexPath,
        request: ChatOpenMessageRequest?
    ) {
        guard scenario == .lastChatsSeededMentionExact,
              item.owner == destination.owner,
              item.jid == destination.jid,
              item.conversationType == .group,
              p14SourceRowIndexPath() == indexPath,
              tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
              p14SourceRowVisibleBeforeTap,
              p14SourceRowTapCount == 0,
              request?.source == .mentionNotification else {
            return
        }
        p14RowReadinessWorkItem?.cancel()
        p14RowReadinessWorkItem = nil
        p14SourceRowTapCount = 1
        didAttemptRoute = true
        routeAttemptCount = 1
    }

    private func recordColdStableVisibilityConsumption() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard scenario == .coldPushExact,
              coldConsumeAfterStableCount == 0,
              let coldPendingRoute,
              destination.hasStableChatOpenAcknowledgement(
                for: coldPendingRoute.openMessageRequest
              ),
              NotifyManager.shared
                .performancePendingMessageNotificationChatRoute == nil else {
            destination.performanceRouteHostDidCompleteNativePresentation(
                routeHostDiagnostics()
            )
            return
        }
        coldStartupGate.recordStableTargetAcknowledgement()
        guard coldStartupGate.consumePendingRouteIfEligible(
            hasStableTargetAcknowledgement: true
        ) else {
            return
        }
        coldConsumeAfterStableCount = 1
        destination.performanceRouteHostDidCompleteNativePresentation(
            routeHostDiagnostics()
        )
    }

    private func routeHostDiagnostics() -> ChatPerformanceRouteHostDiagnostics {
        let p13Source = p13SourceHost
        return ChatPerformanceRouteHostDiagnostics(
            rootInstalled: rootInstalled,
            lastChatsVisibleBeforeRoute: lastChatsVisibleBeforeRoute,
            routeAttemptCount: routeAttemptCount,
            nativePushCount: nativePushCount,
            destinationOpaqueBeforeFirstRow:
                destinationOpaqueBeforeFirstRow,
            lastChatsExposureCount: lastChatsExposureCount,
            coldPendingBeforeRoot: coldPendingBeforeRoot,
            accountMaterializationCount: accountMaterializationCount,
            coldConsumeBeforeStableCount: coldConsumeBeforeStableCount,
            coldConsumeAfterStableCount: coldConsumeAfterStableCount,
            hostKind: {
                switch scenario {
                case .mentionDeletedAdvance:
                    return .notificationsDeletedMention
                case .lastChatsSeededMentionExact:
                    return .lastChatsSeededMention
                default:
                    return .lastChatsNative
                }
            }(),
            p14SourceRowVisibleBeforeTap: p14SourceRowVisibleBeforeTap,
            p14SourceRowTapCount: p14SourceRowTapCount,
            p14PendingRequestCountBeforeTap:
                p14PendingRequestCountBeforeTap,
            p14RequestAdmissionCountBeforeTap:
                p14RequestAdmissionCountBeforeTap,
            p14RequestAdmissionCount:
                destination.p14RequestAdmissionCountForTesting,
            p14RequestAdmissionBeforeViewLoadCount:
                destination.p14RequestAdmissionBeforeViewLoadCountForTesting,
            p14GroupConversationProofCount:
                destination.p14GroupConversationProofCountForTesting,
            p14ExplicitRequestCount:
                destination.p14ExplicitRequestCountForTesting,
            p14UnreadRequestCount:
                destination.p14UnreadRequestCountForTesting,
            p14SavedRequestCount:
                destination.p14SavedRequestCountForTesting,
            p14LatestRequestCount:
                destination.p14LatestRequestCountForTesting,
            p13SourceRowVisibleBeforeTap:
                p13Source?.performanceP13SourceRowVisibleForTesting ?? false,
            p13SourceRowTapCount:
                p13Source?.performanceP13SourceRowTapCountForTesting ?? 0,
            p13AttemptCount:
                p13Source?.performanceP13AttemptCountForTesting ?? 0,
            p13InvalidationCount:
                p13Source?.performanceP13InvalidationCountForTesting ?? 0,
            p13AdvanceCount:
                p13Source?.performanceP13AdvanceCountForTesting ?? 0,
            p13UnavailableCount:
                p13Source?.performanceP13UnavailableCountForTesting ?? 0,
            p13SelectedNextIdentityCount:
                p13Source?
                    .performanceP13SelectedNextIdentityCountForTesting ?? 0,
            p13UnrelatedGroupPreservedCount:
                p13Source?
                    .performanceP13UnrelatedGroupPreservedCountForTesting ?? 0
        )
    }
}
#endif
