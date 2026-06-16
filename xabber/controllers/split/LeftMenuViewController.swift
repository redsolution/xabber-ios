//
//  LeftMenuViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 22.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import QuartzCore
import ObjectiveC
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift

import RxSwift
import RxCocoa
import RxRealm

enum LeftMenuSurfaceEffectFactory {
    static let fallbackBlurStyle: UIBlurEffect.Style = .systemThinMaterial
    static let nativeGlassTintColor = UIColor.systemBackground.withAlphaComponent(0.16)
    static let fallbackSurfaceBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.28)

    static func makeEffect(prefersNativeGlass: Bool = true) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = nativeGlassTintColor
            effect.isInteractive = false
            return effect
        }

        return UIBlurEffect(style: fallbackBlurStyle)
    }

    static func surfaceBackgroundColor(prefersNativeGlass: Bool = true) -> UIColor {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            return .clear
        }

        return fallbackSurfaceBackgroundColor
    }
}

enum LeftMenuSelectionPresentationPolicy {
    enum PresentationAction: Equatable {
        case compactRevealSupplementary
        case regularRevealSupplementaryAndHidePrimary

        var hidesPrimary: Bool {
            self == .regularRevealSupplementaryAndHidePrimary
        }
    }

    static func action(
        isSplitCollapsed: Bool,
        splitHorizontalSizeClass: UIUserInterfaceSizeClass,
        windowHorizontalSizeClass: UIUserInterfaceSizeClass,
        viewHorizontalSizeClass: UIUserInterfaceSizeClass
    ) -> PresentationAction {
        // The left-menu primary column can report compact width inside an expanded iPad split.
        // Use only split/window state to choose the global presentation action.
        if isSplitCollapsed ||
            splitHorizontalSizeClass == .compact ||
            windowHorizontalSizeClass == .compact {
            return .compactRevealSupplementary
        }

        return .regularRevealSupplementaryAndHidePrimary
    }
}

enum LeftMenuSplitPresentationAnimationPolicy {
    enum Phase {
        case destinationPreparation
        case columnInstallation
        case selectionReveal
    }

    static func disablesAnimations(for phase: Phase) -> Bool {
        switch phase {
            case .destinationPreparation, .columnInstallation:
                return true
            case .selectionReveal:
                return false
        }
    }

    static func revealPhase(for _: LeftMenuSelectionPresentationPolicy.PresentationAction) -> Phase {
        .selectionReveal
    }
}

enum SearchSectionNavigationContainerPolicy {
    static func requiresNativeDefaultNavigationContainer(for rootViewController: UIViewController) -> Bool {
        rootViewController is LastChatsViewController ||
            rootViewController is ContactsViewController ||
            rootViewController is LastCallsViewController
    }

    static func requiresNativeDefaultNavigationContainer(for navigationController: UINavigationController) -> Bool {
        navigationController.viewControllers.contains {
            requiresNativeDefaultNavigationContainer(for: $0)
        }
    }

    static func requiresDeferredAttachedLayout(for navigationController: UINavigationController) -> Bool {
        requiresNativeDefaultNavigationContainer(for: navigationController)
    }

    static func requiresDeferredAttachedLayout(for viewController: UIViewController) -> Bool {
        if let navigationController = viewController as? UINavigationController {
            return requiresDeferredAttachedLayout(for: navigationController)
        }

        return requiresNativeDefaultNavigationContainer(for: viewController)
    }

    @discardableResult
    static func prepareSearchHostForReveal(
        _ viewController: UIViewController,
        in splitViewController: UISplitViewController? = nil,
        forceSearchRebind: Bool = false
    ) -> Bool {
        if let navigationController = viewController as? UINavigationController {
            return prepareSearchHostForReveal(
                navigationController,
                in: splitViewController,
                forceSearchRebind: forceSearchRebind
            )
        }

        return rebindSearchControllerIfNeeded(
            in: viewController,
            forceSearchRebind: forceSearchRebind
        )
    }

    @discardableResult
    static func prepareSearchHostForReveal(
        _ navigationController: UINavigationController,
        in splitViewController: UISplitViewController? = nil,
        forceSearchRebind: Bool = false
    ) -> Bool {
        applyTransparentSplitAppearanceIfAllowed(to: navigationController, in: splitViewController)
        var didRebind = false
        navigationController.viewControllers.forEach { viewController in
            didRebind = rebindSearchControllerIfNeeded(
                in: viewController,
                forceSearchRebind: forceSearchRebind
            ) || didRebind
        }
        return didRebind
    }

    @discardableResult
    private static func rebindSearchControllerIfNeeded(
        in viewController: UIViewController,
        forceSearchRebind: Bool
    ) -> Bool {
        switch viewController {
        case let viewController as LastChatsViewController:
            return viewController.configureSearchBar(forceRebind: forceSearchRebind)
        case let viewController as ContactsViewController:
            return viewController.configureSearchBar(forceRebind: forceSearchRebind)
        case let viewController as LastCallsViewController:
            return viewController.configureSearchBar(forceRebind: forceSearchRebind)
        default:
            return false
        }
    }

    static func applyTransparentSplitAppearanceIfAllowed(
        to navigationController: UINavigationController,
        in splitViewController: UISplitViewController? = nil
    ) {
        let backgroundMode = splitViewController.map {
            ContinuousSplitBackgroundExperiment.mode(for: $0)
        } ?? ContinuousSplitBackgroundExperiment.mode(for: navigationController)

        switch backgroundMode {
        case .sharedBackdrop, .stockCompact:
            guard !requiresNativeDefaultNavigationContainer(for: navigationController) else {
                applyNativeDefaultSplitAppearance(to: navigationController, backgroundMode: backgroundMode)
                return
            }
            navigationController.applyTransparentSplitAppearance(backgroundMode: backgroundMode)
        case .inactive, .deferred:
            break
        }
    }

    private static func applyNativeDefaultSplitAppearance(
        to navigationController: UINavigationController,
        backgroundMode: ContinuousSplitBackgroundMode
    ) {
        switch backgroundMode {
        case .sharedBackdrop:
            navigationController.view.backgroundColor = .clear
            navigationController.view.isOpaque = false
        case .stockCompact:
            navigationController.view.backgroundColor = .systemBackground
            navigationController.view.isOpaque = true
        case .inactive, .deferred:
            break
        }

        let defaultNavigationBar = UINavigationBar()
        navigationController.navigationBar.isTranslucent = defaultNavigationBar.isTranslucent
        navigationController.navigationBar.standardAppearance = defaultNavigationBar.standardAppearance
        navigationController.navigationBar.scrollEdgeAppearance = defaultNavigationBar.scrollEdgeAppearance
        navigationController.navigationBar.compactAppearance = defaultNavigationBar.compactAppearance
        navigationController.navigationBar.compactScrollEdgeAppearance = defaultNavigationBar.compactScrollEdgeAppearance

        navigationController.viewControllers
            .filter { requiresNativeDefaultNavigationContainer(for: $0) }
            .forEach { viewController in
                viewController.navigationItem.standardAppearance = nil
                viewController.navigationItem.scrollEdgeAppearance = nil
                viewController.navigationItem.compactAppearance = nil
                if #available(iOS 15.0, *) {
                    viewController.navigationItem.compactScrollEdgeAppearance = nil
                }
            }
    }
}

enum LeftMenuFirstPresentationPolicy {
    static func rowAnimation(
        requested: UITableView.RowAnimation,
        isQuietModeActive: Bool
    ) -> UITableView.RowAnimation {
        isQuietModeActive ? .none : requested
    }

    static func shouldAnimate(
        requested: Bool,
        isQuietModeActive: Bool
    ) -> Bool {
        requested && !isQuietModeActive
    }

    static func performWithoutAnimationsIfNeeded(
        isQuietModeActive: Bool,
        _ updates: () -> Void
    ) {
        guard isQuietModeActive else {
            updates()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            updates()
        }
        CATransaction.commit()
    }

    static func animate(
        withDuration duration: TimeInterval,
        isQuietModeActive: Bool,
        animations: @escaping () -> Void
    ) {
        guard !isQuietModeActive else {
            performWithoutAnimationsIfNeeded(isQuietModeActive: true, animations)
            return
        }

        UIView.animate(withDuration: duration, animations: animations)
    }
}

protocol LeftMenuFirstPresentationQuieting: AnyObject {
    var isLeftMenuFirstPresentationQuietModeActive: Bool { get }

    func beginLeftMenuFirstPresentationQuietMode()
    func completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()
    func endLeftMenuFirstPresentationQuietMode()
}

private enum LeftMenuFirstPresentationQuietingStorage {
    static var activeKey: UInt8 = 0
    static var completionWorkItemKey: UInt8 = 0
}

extension LeftMenuFirstPresentationQuieting where Self: UIViewController {
    var isLeftMenuFirstPresentationQuietModeActive: Bool {
        (objc_getAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.activeKey
        ) as? NSNumber)?.boolValue ?? false
    }

    func beginLeftMenuFirstPresentationQuietMode() {
        cancelLeftMenuFirstPresentationCompletion()
        objc_setAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.activeKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame() {
        cancelLeftMenuFirstPresentationCompletion()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endLeftMenuFirstPresentationQuietMode()
        }
        objc_setAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.completionWorkItemKey,
            workItem,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        DispatchQueue.main.async {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    func endLeftMenuFirstPresentationQuietMode() {
        cancelLeftMenuFirstPresentationCompletion()
        objc_setAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.activeKey,
            NSNumber(value: false),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func cancelLeftMenuFirstPresentationCompletion() {
        let workItem = objc_getAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.completionWorkItemKey
        ) as? DispatchWorkItem
        workItem?.cancel()
        objc_setAssociatedObject(
            self,
            &LeftMenuFirstPresentationQuietingStorage.completionWorkItemKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

enum LeftMenuSplitDestinationPreparer {
    static func targetBounds(
        existingColumnBounds: CGRect,
        splitBounds: CGRect,
        presenterBounds: CGRect
    ) -> CGRect? {
        [existingColumnBounds, splitBounds, presenterBounds]
            .compactMap(normalizedNonZeroBounds)
            .first
    }

    static func targetBounds(
        for column: UISplitViewController.Column,
        in splitViewController: UISplitViewController,
        presenter: UIViewController
    ) -> CGRect? {
        targetBounds(
            existingColumnBounds: splitViewController.viewController(for: column)?.view.bounds ?? .zero,
            splitBounds: splitViewController.view.bounds,
            presenterBounds: presenter.view.bounds
        )
    }

    static func prepare(_ viewController: UIViewController, targetBounds: CGRect?) {
        if SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController) {
            return
        }

        prepareAttached(viewController, targetBounds: targetBounds)
    }

    static func prepareAttachedIfDeferred(_ viewController: UIViewController, targetBounds: CGRect?) {
        guard SearchSectionNavigationContainerPolicy.requiresDeferredAttachedLayout(for: viewController) else {
            return
        }

        prepareAttached(viewController, targetBounds: targetBounds)
    }

    static func prepareAttached(_ viewController: UIViewController, targetBounds: CGRect?) {
        guard let targetBounds = targetBounds.flatMap(normalizedNonZeroBounds) else {
            return
        }

        perform(.destinationPreparation) {
            prepareLoaded(viewController, targetBounds: targetBounds)
        }
    }

    static func perform(_ phase: LeftMenuSplitPresentationAnimationPolicy.Phase, updates: () -> Void) {
        guard LeftMenuSplitPresentationAnimationPolicy.disablesAnimations(for: phase) else {
            updates()
            return
        }

        performWithoutAnimations(updates)
    }

    static func performWithoutAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            updates()
        }
        CATransaction.commit()
    }

    private static func prepareLoaded(_ viewController: UIViewController, targetBounds: CGRect) {
        (viewController as? LeftMenuFirstPresentationQuieting)?
            .beginLeftMenuFirstPresentationQuietMode()
        viewController.loadViewIfNeeded()
        apply(targetBounds: targetBounds, to: viewController.view)

        if let navigationController = viewController as? UINavigationController,
           let rootViewController = navigationController.topViewController {
            navigationController.view.setNeedsLayout()
            navigationController.view.layoutIfNeeded()
            prepareLoaded(rootViewController, targetBounds: navigationController.view.bounds)
        }

        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()
    }

    private static func apply(targetBounds: CGRect, to view: UIView) {
        let normalizedFrame = CGRect(origin: .zero, size: targetBounds.size)
        view.frame = normalizedFrame
        view.bounds = normalizedFrame
    }

    private static func normalizedNonZeroBounds(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull,
              !rect.isInfinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }

        return CGRect(
            origin: .zero,
            size: CGSize(width: rect.width, height: rect.height)
        )
    }
}

class LeftMenuViewController: UIViewController {
    private enum ExperimentLayout {
        static let menuSurfaceHorizontalInset: CGFloat = 16
        static let menuSurfaceBottomInset: CGFloat = 16
        static let menuSurfaceMinimumTopInset: CGFloat = 0
        static let menuSurfaceSafeAreaTopOffset: CGFloat = 2
        static let tableHeaderHeight: CGFloat = 112
        static let titleSafeAreaTopOffset: CGFloat = 8
        static let titleHeight: CGFloat = 28
        static let titleHorizontalInset: CGFloat = 16
    }

    
    class AccountView: UIView {
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 18)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 2
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(
                origin: CGPoint(x: 34, y: 34),
                size: CGSize(square: 12)
            )
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 48))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let errorIndicator: UIImageView = {
            let view = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate))
            
            view.tintColor = .systemOrange
//            view.isHidden = true
            
            return view
        }()
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
//                errorIndicator.widthAnchor.constraint(equalToConstant: 24),
                errorIndicator.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        
        public func configure() {
            addSubview(stack)
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                stack.fillSuperviewWithOffset(top: 0, bottom: bottomInset + 8, left: 70, right: 8)
            } else {
                stack.fillSuperviewWithOffset(top: 0, bottom: 8, left: 70, right: 8)
            }
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(errorIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            addSubview(userImageView)
            userImageView.frame = CGRect(x: 20, y: 10, width: 48, height: 48)
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            activateConstraints()
        }
        
        var avatarUrl: String? = nil
        
        public func update(nickname: String, jid: String, status: ResourceStatus, avatarUrl: String) {
            titleLabel.text = nickname
            subtitleLabel.text = jid//JidManager.shared.prepareJid(jid: subtitle)
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: .contact)
            if avatarUrl != self.avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: jid, size: 48) { image in
                    if let image = image {
                        self.avatarUrl = avatarUrl
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: jid, size: 48)
                    }
                }
            }
        }
    }
    
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        let category: String
        var subtitle: String
        var showTriangle: Bool
    }
    
    var datasource: [[Datasource]] = []
    
    var chatsVc: LastChatsViewController? = nil
    var archivedVc: LastChatsViewController? = nil
    var callsVc: LastCallsViewController? = nil
    var callsCategoriesVc: CallsCategoriesViewController? = nil
    var notificationsVc: NotificationsListViewController? = nil
    var notificationsCategoriesVc: NotificationsCategoriesViewController? = nil
    var contactsCategoriesVc: ContactsCategoryViewController? = nil
    var groupsCategoriesVc: ContactsCategoryViewController? = nil
    var contactsVc: ContactsViewController? = nil
    var groupsVc: ContactsViewController? = nil
    var savedMessagesChatsVc: LastChatsViewController? = nil
    
    private let tableView: UITableView = {
        let style: UITableView.Style = ContinuousSplitBackgroundExperiment.usesSplitListChrome ? .insetGrouped : .grouped
        let view = UITableView(frame: .zero, style: style)
        
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.applyContinuousSplitInsetGroupedAppearance()
        if !ContinuousSplitBackgroundExperiment.usesSplitListChrome {
            view.separatorStyle = .none
        }
        view.isScrollEnabled = false
        
        return view
    }()

    private let menuSurfaceView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: LeftMenuSurfaceEffectFactory.makeEffect())

        view.backgroundColor = LeftMenuSurfaceEffectFactory.surfaceBackgroundColor()
        view.layer.cornerRadius = 24
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false

        return view
    }()

    private let menuTitleLabel: UILabel = {
        let label = UILabel()
        let font = UIFont.systemFont(ofSize: 20, weight: .semibold)

        label.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .label
        label.backgroundColor = .clear
        label.isUserInteractionEnabled = false

        return label
    }()

    internal let accountButton: UIButton = {
        let button = UIButton(frame: .zero)
        
        return button
    }()
    
    internal let accountView: AccountView = {
        let view = AccountView()
        
        return view
    }()
    
    var previousSelectedKey: String? = "chat"

    private var isPremiumActive: Bool = false

    private func loadDatasource() {
        isPremiumActive = SubscribtionsManager.shared.hasActiveSubsription()
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true").sorted(byKeyPath: "order")
            let jids = accounts.toArray().compactMap({ return $0.jid })
            let ignoredJids = XMPPServiceJidsSupport.ignoredServiceJids(in: realm, accountJids: jids)
            let chats = realm.objects(LastChatsStorageItem.self).filter("isArchived == false AND unread > 0").compactMap({ $0.unread }).reduce(0, +)
            let archived = realm.objects(LastChatsStorageItem.self).filter("isArchived == true AND unread > 0").compactMap({ $0.unread }).reduce(0, +)
            let calls = realm.objects(CallMetadataStorageItem.self)
            let contacts = realm.objects(RosterStorageItem.self).filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
            let notificationsCount = NotificationsSupport.unreadVisibleCount(in: realm, owners: jids)
            let invitations = realm.objects(GroupchatInvitesStorageItem.self).filter("owner IN %@ AND isRead == false", jids)
            if CommonConfigManager.shared.config.support_groupchats {
                self.datasource = [[
                    Datasource(title: "Chats", icon: "custom.bubble", key: "chat", category: "", subtitle: "\(chats)", showTriangle: false),
                    Datasource(title: "Calls", icon: "phone", key: "calls", category: "", subtitle: "\(calls.count)", showTriangle: false),
                    Datasource(title: "Notifications", icon: "bell", key: "notifications", category: "", subtitle: "\(notificationsCount)", showTriangle: false),
                    Datasource(title: "Contacts", icon: "person", key: "contacts", category: "contacts", subtitle: "\(contacts.count)", showTriangle: false),
                    Datasource(title: "Groups", icon: "person.2", key: "groups", category: "public", subtitle: "\(invitations.count)", showTriangle: false),
                    Datasource(title: "Archive", icon: "archivebox", key: "archive", category: "", subtitle: "\(archived)", showTriangle: false),
//                    Datasource(title: "Saved messages", icon: "bookmark", key: "saved", category: "", subtitle: "0", showTriangle: false),
                ],[
                   Datasource(title: "Settings", icon: "gearshape", key: "settings", category: "", subtitle: "0", showTriangle: false),
                ]
               ]
            } else {
                self.datasource = [[
                    Datasource(title: "Chats", icon: "custom.bubble", key: "chat", category: "", subtitle: "\(chats)", showTriangle: false),
                    Datasource(title: "Calls", icon: "phone", key: "calls", category: "", subtitle: "\(calls.count)", showTriangle: false),
                    Datasource(title: "Notifications", icon: "bell", key: "notifications", category: "", subtitle: "\(notificationsCount)", showTriangle: false),
                    Datasource(title: "Contacts", icon: "person", key: "contacts", category: "contacts", subtitle: "\(contacts.count)", showTriangle: false),
                    Datasource(title: "Archive", icon: "archivebox", key: "archive", category: "", subtitle: "\(archived)", showTriangle: false),
//                    Datasource(title: "Saved messages", icon: "bookmark", key: "saved", category: "", subtitle: "0", showTriangle: false),
                ],[
                   Datasource(title: "Settings", icon: "gearshape", key: "settings", category: "", subtitle: "0", showTriangle: false),
                ]
               ]
            }
            
        } catch {
            DDLogDebug("LeftMenuViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    @objc
    private func onAppear() {
        
    }
    
    var bag = DisposeBag()
    
    enum TriangleIndicatorStyle {
        case none
        case orangeTriangle
        case redTriangle
    }
    
    var triangleIndicatorStyle: TriangleIndicatorStyle = .none
    
    func subscribe() {
        self.bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true").sorted(byKeyPath: "order")
            let jids = accounts.toArray().compactMap({ return $0.jid })
            var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
            ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
            if CommonConfigManager.shared.config.support_jid.isNotEmpty {
                ignoredJids.append(CommonConfigManager.shared.config.support_jid)
            }
            var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
            ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
            ignoredJids.append(contentsOf: Array(ignoredAbuse))
            let chats = realm.objects(LastChatsStorageItem.self).filter("isArchived == false AND unread > 0")
            let archived = realm.objects(LastChatsStorageItem.self).filter("isArchived == true AND unread > 0")
            let calls = realm.objects(CallMetadataStorageItem.self)
            let contacts = realm.objects(RosterStorageItem.self).filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
            let notifications = realm.objects(NotificationStorageItem.self).filter("owner IN %@ AND isRead == false AND shouldShow == true", jids)
            let invitations = realm.objects(GroupchatInvitesStorageItem.self).filter("owner IN %@ AND isRead == false", jids)
            let section = 0
            
            let badDevices = realm
                .objects(SignalDeviceStorageItem.self)
                .filter("owner IN %@ AND owner == jid AND state_ IN %@", jids, [SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.fingerprintChanged.rawValue, SignalDeviceStorageItem.TrustState.revoked.rawValue])
            
            Observable
                .collection(from: badDevices)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if results.isEmpty {
                        self.accountView.errorIndicator.isHidden = true
                        self.triangleIndicatorStyle = .none
                        return
                    }
                    self.accountView.errorIndicator.isHidden = false
                    if results.filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).count > 0 {
                        self.accountView.errorIndicator.tintColor = .systemRed
                        self.triangleIndicatorStyle = .redTriangle
                        return
                    }
                    self.accountView.errorIndicator.tintColor = .systemOrange
                    self.triangleIndicatorStyle = .orangeTriangle
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: bag)

            
            Observable
                .collection(from: accounts)
                .subscribe { results in
                    if let item = results.first {
                        self.accountView.update(nickname: item.username, jid: item.jid, status: .online, avatarUrl: item.avatarMaxUrl ?? item.avatarMinUrl ?? item.oldschoolAvatarKey ?? "none")
                    }
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)

            
            Observable
                .collection(from: chats)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(
                        for: "chat",
                        section: section,
                        subtitle: "\(results.compactMap({ $0.unread }).reduce(0, +))"
                    )
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: archived)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(
                        for: "archive",
                        section: section,
                        subtitle: "\(results.compactMap({ $0.unread }).reduce(0, +))"
                    )
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: calls)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(for: "calls", section: section, subtitle: "\(results.count)")
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: contacts)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(for: "contacts", section: section, subtitle: "\(results.count)")
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: invitations)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(for: "groups", section: section, subtitle: "\(results.count)")
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: notifications)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.updateDatasourceSubtitle(for: "notifications", section: section, subtitle: "\(results.count)")
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
        } catch {
            DDLogDebug("LeftMenuViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }

    private func updateDatasourceSubtitle(for key: String, section: Int = 0, subtitle: String) {
        guard datasource.indices.contains(section),
              let index = datasource[section].firstIndex(where: { $0.key == key }) else {
            return
        }

        datasource[section][index].subtitle = subtitle
        reloadMenuRowIfPossible(at: IndexPath(row: index, section: section))
    }

    private func reloadMenuRowIfPossible(at indexPath: IndexPath) {
        UIView.performWithoutAnimation {
            guard tableView.window != nil else {
                tableView.reloadData()
                return
            }

            let tableSections = tableView.numberOfSections
            guard tableSections == datasource.count,
                  indexPath.section < tableSections,
                  indexPath.row < tableView.numberOfRows(inSection: indexPath.section) else {
                tableView.reloadData()
                return
            }

            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
    
//    internal let bottomBar: AccountView = {
//        let view = AccountView()
//        
//        return view
//    }()
    
    public func configure() {
        let title = CommonConfigManager.shared.config.app_name.capitalized
        if ContinuousSplitBackgroundExperiment.isActive {
            self.title = nil
            navigationItem.title = nil
            menuTitleLabel.text = title
        } else {
            self.title = title
        }
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)

        navigationItem.largeTitleDisplayMode = .automatic
        navigationController?.navigationBar.prefersLargeTitles = true
        self.navigationItem.backButtonDisplayMode = .minimal
//        if CommonConfigManager.shared.config.use_large_title {
//            navigationItem.largeTitleDisplayMode = .automatic
//        } else {
//            navigationItem.largeTitleDisplayMode = .never
//        }
//        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title

        configureMenuSurfaceIfNeeded()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        configureExperimentTitleIfNeeded()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
        updatePremiumBarButton()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(onTableViewEmptySpaceTap))
        tapGesture.cancelsTouchesInView = false
//        tableView.addGestureRecognizer(tapGesture)

    }

    private func configureMenuSurfaceIfNeeded() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        guard menuSurfaceView.superview == nil else { return }

        view.insertSubview(menuSurfaceView, at: 0)
        configureExperimentTableHeaderIfNeeded()
        layoutMenuSurfaceIfNeeded()
    }

    private func configureExperimentTitleIfNeeded() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        guard menuTitleLabel.superview == nil else {
            view.bringSubviewToFront(menuTitleLabel)
            return
        }

        view.addSubview(menuTitleLabel)
        layoutMenuTitleIfNeeded()
    }

    private func configureExperimentTableHeaderIfNeeded() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        let headerFrame = CGRect(
            x: 0,
            y: 0,
            width: max(tableView.bounds.width, view.bounds.width),
            height: ExperimentLayout.tableHeaderHeight
        )

        if let headerView = tableView.tableHeaderView {
            guard headerView.frame != headerFrame else { return }
            headerView.frame = headerFrame
            tableView.tableHeaderView = headerView
            return
        }

        let headerView = UIView(frame: headerFrame)
        headerView.backgroundColor = .clear
        headerView.isUserInteractionEnabled = false
        tableView.tableHeaderView = headerView
    }

    private func layoutMenuSurfaceIfNeeded() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        let topSafeAreaInset = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let topInset = max(
            ExperimentLayout.menuSurfaceMinimumTopInset,
            topSafeAreaInset + ExperimentLayout.menuSurfaceSafeAreaTopOffset
        )
        let surfaceFrame = CGRect(
            x: ExperimentLayout.menuSurfaceHorizontalInset,
            y: topInset,
            width: max(0, view.bounds.width - ExperimentLayout.menuSurfaceHorizontalInset * 2),
            height: max(0, view.bounds.height - topInset - ExperimentLayout.menuSurfaceBottomInset)
        )

        menuSurfaceView.frame = surfaceFrame
    }

    private func layoutMenuTitleIfNeeded() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        let topSafeAreaInset = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let surfaceFrame = menuSurfaceView.frame
        menuTitleLabel.frame = CGRect(
            x: surfaceFrame.minX + ExperimentLayout.titleHorizontalInset,
            y: topSafeAreaInset + ExperimentLayout.titleSafeAreaTopOffset,
            width: max(0, surfaceFrame.width - ExperimentLayout.titleHorizontalInset * 2),
            height: ExperimentLayout.titleHeight
        )
    }

    private func updatePremiumBarButton() {
        let iconName = isPremiumActive ? "star.fill" : "star"
        let image = UIImage(systemName: iconName)
        let button = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(onPremiumButton))
        button.tintColor = isPremiumActive ? .systemYellow : .label
        if CommonConfigManager.shared.config.support_subscribtions {
            navigationItem.rightBarButtonItem = button
        }
    }

    @objc
    private func onPremiumButton() {
        let vc = PremiumSubscribtionViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc, parent: self)
        revealSelectedContentColumn()
    }
    
    @objc
    func onTableViewEmptySpaceTap(_ sender: AnyObject) {
        revealSelectedContentColumn()
    }
 
    @objc
    func onAccountButton(_ sender: UIButton) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc, parent: self)
        revealSelectedContentColumn()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
    }

    private func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(onAppear),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)
    }

    @objc
    func languageChanged() {
//        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        unsubscribe()
        removeNotificationObserer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let newPremiumState = SubscribtionsManager.shared.hasActiveSubsription()
        if newPremiumState != isPremiumActive {
            isPremiumActive = newPremiumState
            updatePremiumBarButton()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureExperimentTableHeaderIfNeeded()
        layoutMenuSurfaceIfNeeded()
        layoutMenuTitleIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}


extension LeftMenuViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
            fatalError()
        }
        let item = datasource[indexPath.section][indexPath.row]
        
        cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: true)
        if item.key == "archive" {
            cell.badgeView.backgroundColor = .systemGray
        } else {
            cell.badgeView.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        }
        cell.applyContinuousSplitSystemBackground()
        cell.selectionStyle = .none
        return cell
    }
    
    
}

class MenuItemHeaderTableCell: UITableViewCell {
    static let cellName: String = "MenuItemHeaderTableCell"
    private var suppressSelectionFeedback = false
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 0
        stack.layoutMargins = UIEdgeInsets(top: 12, bottom: 12, left: 24, right: 24)
        stack.isLayoutMarginsRelativeArrangement = true
        
//        stack.layer.cornerRadius = 8
//        stack.layer.masksToBounds = true
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 25, weight: .bold)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        
        return label
    }()
    
    let iconView: UIButton = {
        let button = UIButton()
        
        return button
    }()
    
    func configure(title: String, subtitle: String, icon: String, color: UIColor, withCircle: Bool = false) {
        self.titleLabel.text = title
        self.subtitleLabel.text = subtitle
        
        var configuration = UIButton.Configuration.filled()
        if withCircle {
            configuration.baseBackgroundColor = .secondarySystemBackground
        } else {
            configuration.baseBackgroundColor = .systemBackground
        }
        
        configuration.baseForegroundColor = color
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        if withCircle {
            configuration.image = imageLiteral(icon)?.upscale(dimension: 48).withRenderingMode(.alwaysTemplate)
            self.stack.setCustomSpacing(8, after: self.iconView)
        } else {
            configuration.image = imageLiteral(icon)?.upscale(dimension: 76).withRenderingMode(.alwaysTemplate)
            self.stack.setCustomSpacing(0, after: self.iconView)
        }
        self.stack.setCustomSpacing(4, after: self.titleLabel)
        self.iconView.configuration = configuration
    }

    func configureAsInformationalHeader() {
        suppressSelectionFeedback = true
        selectionStyle = .none
        focusStyle = .custom
        backgroundView = nil
        selectedBackgroundView = nil
        multipleSelectionBackgroundView = nil
        layer.borderWidth = 0
        layer.borderColor = UIColor.clear.cgColor
        layer.shadowOpacity = 0
        layer.shadowColor = nil
        contentView.layer.borderWidth = 0
        contentView.layer.borderColor = UIColor.clear.cgColor
        contentView.layer.shadowOpacity = 0
        contentView.layer.shadowColor = nil
        super.setHighlighted(false, animated: false)
        super.setSelected(false, animated: false)
    }
    
    func setupSubviews() {
        self.backgroundColor = .systemBackground
        self.contentView.addSubview(stack)
        self.stack.fillSuperviewWithOffset(top: 0, bottom: 16, left: 16, right: 16)
        self.stack.addArrangedSubview(self.iconView)
        self.stack.addArrangedSubview(self.titleLabel)
        self.stack.addArrangedSubview(self.subtitleLabel)
//        self.stack.backgroundColor = .systemBackground
//        self.stack.setCustomSpacing(8, after: self.titleLabel)
        self.activateConstraints()
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            self.iconView.widthAnchor.constraint(equalToConstant: 96),
            self.iconView.heightAnchor.constraint(equalToConstant: 96)
        ])
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        suppressSelectionFeedback = false
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        guard suppressSelectionFeedback else {
            super.setSelected(selected, animated: animated)
            return
        }

        super.setSelected(false, animated: animated)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        guard suppressSelectionFeedback else {
            super.setHighlighted(highlighted, animated: animated)
            return
        }

        super.setHighlighted(false, animated: animated)
    }
}

class MenuItemTableCell: UITableViewCell {
    static let cellName: String = "MenuItemTableCell"

    private final class BadgeButton: UIButton {
        private static let minSize: CGFloat = 20
        private static let horizontalPadding: CGFloat = 8

        override var intrinsicContentSize: CGSize {
            let titleWidth = titleLabel?.intrinsicContentSize.width ?? 0
            return CGSize(
                width: max(Self.minSize, ceil(titleWidth + Self.horizontalPadding)),
                height: Self.minSize
            )
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.height / 2
        }
    }
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 8
        stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()

    let subtitleLabel: UILabel = {
        let label = UILabel()

        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.isHidden = true

        return label
    }()

    let labelsStack: UIStackView = {
        let stack = UIStackView()

        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = .fill
        stack.distribution = .fill
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return stack
    }()
    
    let badgeView: UIButton = {
        let view = BadgeButton(type: .custom)

        view.layer.cornerRadius = 10
        view.layer.masksToBounds = true
        view.isUserInteractionEnabled = false
        view.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.isHidden = true

        return view
    }()
    
    func configure(
        title: String,
        subtitle: String = "",
        badge: String,
        icon: String,
        isImportant: Bool,
        iconRenderingMode: UIImage.RenderingMode = .alwaysTemplate
    ) {
        self.titleLabel.text = title
        self.subtitleLabel.text = subtitle
        self.subtitleLabel.isHidden = subtitle.isEmpty
        self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(iconRenderingMode)
        self.imageView?.contentMode = iconRenderingMode == .alwaysOriginal ? .scaleAspectFill : .scaleAspectFit
        self.imageView?.clipsToBounds = iconRenderingMode == .alwaysOriginal
        self.imageView?.layer.cornerRadius = iconRenderingMode == .alwaysOriginal ? 6 : 0
        self.badgeView.setTitle(badge, for: .normal)
        self.badgeView.isHidden = badge.isEmpty || badge == "0"
        if isImportant {
            self.badgeView.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
            self.badgeView.setTitleColor(.white, for: .normal)
        } else {
            self.badgeView.backgroundColor = .clear
            self.badgeView.setTitleColor(.secondaryLabel, for: .normal)
        }
        self.badgeView.setNeedsLayout()
        self.badgeView.invalidateIntrinsicContentSize()
        self.badgeView.layoutIfNeeded()
    }
    
    func setupSubviews() {
        self.backgroundColor = .clear
        self.layer.cornerRadius = 8
        self.layer.masksToBounds = true
        self.contentView.addSubview(stack)
        self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 56, right: 4)
        self.stack.addArrangedSubview(self.labelsStack)
        self.labelsStack.addArrangedSubview(self.titleLabel)
        self.labelsStack.addArrangedSubview(self.subtitleLabel)
        self.stack.addArrangedSubview(self.badgeView)
        self.activateConstraints()
    }

    func activateConstraints() {
        NSLayoutConstraint.activate([
            self.badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            self.badgeView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.titleLabel.text = nil
        self.subtitleLabel.text = nil
        self.subtitleLabel.isHidden = true
        self.imageView?.image = nil
        self.badgeView.setTitle(nil, for: .normal)
        self.badgeView.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        self.badgeView.setTitleColor(.white, for: .normal)
        self.badgeView.isHidden = true
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }
    
}

extension LeftMenuViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }
    
    private func selectionPresentationAction(for splitVC: UISplitViewController) -> LeftMenuSelectionPresentationPolicy.PresentationAction {
        let windowHorizontalSizeClass = splitVC.view.window?.traitCollection.horizontalSizeClass
            ?? view.window?.traitCollection.horizontalSizeClass
            ?? .unspecified

        return LeftMenuSelectionPresentationPolicy.action(
            isSplitCollapsed: splitVC.isCollapsed,
            splitHorizontalSizeClass: splitVC.traitCollection.horizontalSizeClass,
            windowHorizontalSizeClass: windowHorizontalSizeClass,
            viewHorizontalSizeClass: view.traitCollection.horizontalSizeClass
        )
    }

    private func applySelectionPresentation(to splitVC: UISplitViewController) {
        if usesStockCompactSplit(splitVC) {
            let action = selectionPresentationAction(for: splitVC)
            splitVC.show(.supplementary)
            if action.hidesPrimary {
                splitVC.hide(.primary)
            }
            return
        }

        let action = selectionPresentationAction(for: splitVC)
        let phase = LeftMenuSplitPresentationAnimationPolicy.revealPhase(for: action)
        LeftMenuSplitDestinationPreparer.perform(phase) {
            splitVC.show(.supplementary)
            if action.hidesPrimary {
                splitVC.hide(.primary)
            }
            splitVC.view.setNeedsLayout()
        }
    }

    @discardableResult
    private func revealSelectedContentColumn() -> Bool {
        guard let splitVC = splitViewController else {
            return false
        }

        prepareSearchHostForReveal(in: splitVC, forceSearchRebind: false)
        applySelectionPresentation(to: splitVC)
        return true
    }

    @discardableResult
    private func prepareSearchHostForReveal(
        in splitVC: UISplitViewController,
        forceSearchRebind: Bool = false
    ) -> Bool {
        var didRebind = false
        [
            UISplitViewController.Column.supplementary,
            UISplitViewController.Column.secondary,
            UISplitViewController.Column.compact
        ].forEach { column in
            guard let viewController = splitVC.viewController(for: column) else {
                return
            }
            let targetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
                for: column,
                in: splitVC,
                presenter: self
            )
            didRebind = SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
                viewController,
                in: splitVC,
                forceSearchRebind: forceSearchRebind
            ) || didRebind
            LeftMenuSplitDestinationPreparer.prepareAttachedIfDeferred(
                viewController,
                targetBounds: targetBounds
            )
        }
        layoutInstalledSearchChromeForFirstVisibleFrame(
            in: splitVC,
            controllers: [
                splitVC.viewController(for: .supplementary),
                splitVC.viewController(for: .secondary),
                splitVC.viewController(for: .compact)
            ].compactMap { $0 }
        )
        return didRebind
    }

    private func usesRegularCategorySplit() -> Bool {
        guard let splitVC = splitViewController else {
            return UIDevice.current.userInterfaceIdiom == .pad
        }

        return selectionPresentationAction(for: splitVC) == .regularRevealSupplementaryAndHidePrimary
    }

    private func usesStockCompactSplit(_ splitVC: UISplitViewController) -> Bool {
        ContinuousSplitBackgroundExperiment.mode(for: splitVC) == .stockCompact
    }

    private func prepareSearchHostForFirstVisibleFrame(
        _ viewController: UIViewController,
        in splitVC: UISplitViewController,
        targetBounds: CGRect?
    ) {
        SearchSectionNavigationContainerPolicy.prepareSearchHostForReveal(
            viewController,
            in: splitVC
        )
        LeftMenuSplitDestinationPreparer.prepareAttachedIfDeferred(
            viewController,
            targetBounds: targetBounds
        )
    }

    private func layoutInstalledSearchChromeForFirstVisibleFrame(
        in splitVC: UISplitViewController,
        controllers: [UIViewController]
    ) {
        LeftMenuSplitDestinationPreparer.perform(.destinationPreparation) {
            splitVC.view.setNeedsLayout()
            splitVC.view.layoutIfNeeded()
            controllers.forEach { controller in
                if let navigationController = controller as? UINavigationController {
                    navigationController.navigationBar.setNeedsLayout()
                    navigationController.navigationBar.layoutIfNeeded()
                }
                controller.navigationController?.navigationBar.setNeedsLayout()
                controller.navigationController?.navigationBar.layoutIfNeeded()
            }
        }
    }

    private func show(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isCalls: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) -> Bool {
        if #available(iOS 26, *) {
            // Code for iOS 26 and above
            return self.showNew(controller: vc, kind: kind, isNotifications: isNotifications, isCalls: isCalls, isContacts: isContacts, isGroups: isGroups, category: category, leftMenuDelegate: leftMenuDelegate)
        } else {
            // Fallback for older iOS versions
            return self.showOld(controller: vc, kind: kind, isNotifications: isNotifications, isCalls: isCalls, isContacts: isContacts, isGroups: isGroups, category: category, leftMenuDelegate: leftMenuDelegate)
        }
    }
    
    private func showNew(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isCalls: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) -> Bool {
        let svc: UIViewController
        vc.resetState()
        if isNotifications {
            let listController = notificationsVc ?? NotificationsListViewController()
            notificationsVc = listController
            svc = listController
            (vc as? NotificationsCategoriesViewController)?.filterDelegate = listController
            (vc as? NotificationsCategoriesViewController)?.leftMenuDelegate = leftMenuDelegate
            listController.leftMenuDelegate = leftMenuDelegate
        } else if isCalls {
            let listController = callsVc ?? LastCallsViewController()
            callsVc = listController
            svc = listController
            if let categoriesController = vc as? CallsCategoriesViewController {
                CallsSectionCoordinator.wire(
                    categoriesController: categoriesController,
                    listController: listController,
                    leftMenuDelegate: leftMenuDelegate
                )
            }
        } else if isContacts {
            svc = ContactsViewController()
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
        } else if isGroups {
            svc = ContactsViewController()
            (svc as? ContactsViewController)?.isGroup = true
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
        } else {
            svc = EmptyChatViewController()
        }
        (svc as? EmptyChatViewController)?.kind = kind
        
//        let nsvc = UINavigationController(rootViewController: svc)
        guard let splitVC = self.splitViewController else {
            print("Error: splitViewController is nil")
            return false
        }
        
        let nvc = UINavigationController(rootViewController: vc)
        let supplementaryTargetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            for: .supplementary,
            in: splitVC,
            presenter: self
        )
        let secondaryTargetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            for: .secondary,
            in: splitVC,
            presenter: self
        )
        if usesStockCompactSplit(splitVC) {
            splitVC.setViewController(nvc, for: .supplementary)
            splitVC.setViewController(svc, for: .secondary)
            prepareSearchHostForFirstVisibleFrame(
                nvc,
                in: splitVC,
                targetBounds: supplementaryTargetBounds
            )
            prepareSearchHostForFirstVisibleFrame(
                svc,
                in: splitVC,
                targetBounds: secondaryTargetBounds
            )
            layoutInstalledSearchChromeForFirstVisibleFrame(
                in: splitVC,
                controllers: [nvc, svc]
            )
            applySelectionPresentation(to: splitVC)
            return true
        }

        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: nvc, in: splitVC)
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(vc)
        LeftMenuSplitDestinationPreparer.prepare(
            nvc,
            targetBounds: supplementaryTargetBounds
        )
        LeftMenuSplitDestinationPreparer.prepare(
            svc,
            targetBounds: secondaryTargetBounds
        )
        LeftMenuSplitDestinationPreparer.perform(.columnInstallation) {
            splitVC.setViewController(nvc, for: .supplementary)
            splitVC.setViewController(svc, for: .secondary)
        }
        prepareSearchHostForFirstVisibleFrame(
            nvc,
            in: splitVC,
            targetBounds: supplementaryTargetBounds
        )
        prepareSearchHostForFirstVisibleFrame(
            svc,
            in: splitVC,
            targetBounds: secondaryTargetBounds
        )
        layoutInstalledSearchChromeForFirstVisibleFrame(
            in: splitVC,
            controllers: [nvc, svc]
        )
        applySelectionPresentation(to: splitVC)
        return true
    }
    
    private func showOld(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isCalls: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) -> Bool {
        let svc: UIViewController
        vc.resetState()
        if isNotifications {
            let listController = notificationsVc ?? NotificationsListViewController()
            notificationsVc = listController
            svc = listController
            (vc as? NotificationsCategoriesViewController)?.filterDelegate = listController
            (vc as? NotificationsCategoriesViewController)?.leftMenuDelegate = leftMenuDelegate
            listController.leftMenuDelegate = leftMenuDelegate
        } else if isCalls {
            let listController = callsVc ?? LastCallsViewController()
            callsVc = listController
            svc = listController
            if let categoriesController = vc as? CallsCategoriesViewController {
                CallsSectionCoordinator.wire(
                    categoriesController: categoriesController,
                    listController: listController,
                    leftMenuDelegate: leftMenuDelegate
                )
            }
        } else if isContacts {
            svc = ContactsViewController()
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
            
        } else if isGroups {
            svc = ContactsViewController()
            (svc as? ContactsViewController)?.isGroup = true
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
            
        } else {
            svc = EmptyChatViewController()
        }
        (svc as? EmptyChatViewController)?.kind = kind
        let nsvc = UINavigationController(rootViewController: svc)
        guard let splitVC = self.splitViewController else {
            return false
        }
        let supplementaryTargetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            for: .supplementary,
            in: splitVC,
            presenter: self
        )
        let secondaryTargetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            for: .secondary,
            in: splitVC,
            presenter: self
        )
        if usesStockCompactSplit(splitVC) {
            splitVC.viewControllers = [self, vc, nsvc]
            prepareSearchHostForFirstVisibleFrame(
                vc,
                in: splitVC,
                targetBounds: supplementaryTargetBounds
            )
            prepareSearchHostForFirstVisibleFrame(
                nsvc,
                in: splitVC,
                targetBounds: secondaryTargetBounds
            )
            layoutInstalledSearchChromeForFirstVisibleFrame(
                in: splitVC,
                controllers: [vc, nsvc]
            )
            applySelectionPresentation(to: splitVC)
            return true
        }

        SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: nsvc, in: splitVC)
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(vc)
        LeftMenuSplitDestinationPreparer.prepare(
            vc,
            targetBounds: supplementaryTargetBounds
        )
        LeftMenuSplitDestinationPreparer.prepare(
            nsvc,
            targetBounds: secondaryTargetBounds
        )
        LeftMenuSplitDestinationPreparer.perform(.columnInstallation) {
            splitVC.viewControllers = [self, vc, nsvc]
        }
        prepareSearchHostForFirstVisibleFrame(
            vc,
            in: splitVC,
            targetBounds: supplementaryTargetBounds
        )
        prepareSearchHostForFirstVisibleFrame(
            nsvc,
            in: splitVC,
            targetBounds: secondaryTargetBounds
        )
        layoutInstalledSearchChromeForFirstVisibleFrame(
            in: splitVC,
            controllers: [vc, nsvc]
        )
        applySelectionPresentation(to: splitVC)
        return true
    }
    
    private func showSavedMessages(controller vc: UIViewController) -> Bool {
        guard let splitVC = self.splitViewController else {
            return false
        }
        let supplementaryTargetBounds = LeftMenuSplitDestinationPreparer.targetBounds(
            for: .supplementary,
            in: splitVC,
            presenter: self
        )
        if usesStockCompactSplit(splitVC) {
            splitVC.viewControllers = [self, vc]
            prepareSearchHostForFirstVisibleFrame(
                vc,
                in: splitVC,
                targetBounds: supplementaryTargetBounds
            )
            layoutInstalledSearchChromeForFirstVisibleFrame(
                in: splitVC,
                controllers: [vc]
            )
            applySelectionPresentation(to: splitVC)
            return true
        }

        LeftMenuSplitDestinationPreparer.prepare(
            vc,
            targetBounds: supplementaryTargetBounds
        )
        LeftMenuSplitDestinationPreparer.perform(.columnInstallation) {
            splitVC.viewControllers = [self, vc]
        }
        prepareSearchHostForFirstVisibleFrame(
            vc,
            in: splitVC,
            targetBounds: supplementaryTargetBounds
        )
        layoutInstalledSearchChromeForFirstVisibleFrame(
            in: splitVC,
            controllers: [vc]
        )
        applySelectionPresentation(to: splitVC)
        return true
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = self.datasource[indexPath.section][indexPath.row].key
        if key == "settings" {
            let vc = SettingsViewController()
            vc.jid = AccountManager.shared.users.first?.jid ?? ""
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            showModal(vc, parent: self)
            revealSelectedContentColumn()
        } else {
            let category = self.datasource[indexPath.section][indexPath.row].category
            self.didSelectRootScreenBy(key: key, category: category)
        }
    }
}

extension LeftMenuViewController: LeftMenuSelectRootScreenDelegate {
    
    func didSelectRootScreenBy(key: String, category: String? = nil) {
        if self.previousSelectedKey == key {
            revealSelectedContentColumn()
            return
        }
        var didPresent = false
        switch key {
            case "chat":
                if let vc = self.chatsVc {
                    vc.filter.accept(.chats)
                    didPresent = self.show(controller: vc, kind: .emptyChat)
                    vc.leftMenuSelectRootCategoryDelegate = self
                  
                } else {
                    let vc = LastChatsViewController()
                    self.chatsVc = vc
                    didPresent = self.show(controller: vc, kind: .emptyChat)
                    vc.leftMenuSelectRootCategoryDelegate = self
                    
                }
            case "calls":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if usesRegularCategorySplit() {
                    let listController = self.callsVc ?? LastCallsViewController()
                    let categoriesController = self.callsCategoriesVc ?? CallsCategoriesViewController()
                    self.callsVc = listController
                    self.callsCategoriesVc = categoriesController
                    CallsSectionCoordinator.wire(
                        categoriesController: categoriesController,
                        listController: listController,
                        leftMenuDelegate: self
                    )
                    didPresent = self.show(controller: categoriesController, kind: .emptyCall, isCalls: true, leftMenuDelegate: self)
                } else {
                    if let vc = self.callsVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyCall)
                    } else {
                        let vc = LastCallsViewController()
                        vc.leftMenuDelegate = self
                        self.callsVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyCall)
                    }
                }
            case "mentions":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.notificationsVc {
                    vc.leftMenuDelegate = self
                    didPresent = self.show(controller: vc, kind: .emptyChat)
                } else {
                    let vc = NotificationsListViewController()
                    vc.leftMenuDelegate = self
                    self.notificationsVc = vc
                    didPresent = self.show(controller: vc, kind: .emptyChat)
                }
            case "notifications":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if usesRegularCategorySplit() {
                    if let vc = self.notificationsCategoriesVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, isNotifications: true, leftMenuDelegate: self)
                    } else {
                        let vc = NotificationsCategoriesViewController()
                        vc.leftMenuDelegate = self
                        self.notificationsCategoriesVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyChat, isNotifications: true, leftMenuDelegate: self)
                    }
                } else {
                    if let vc = self.notificationsVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat)
                    } else {
                        let vc = NotificationsListViewController()
                        vc.leftMenuDelegate = self
                        self.notificationsVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyChat)
                    }
                }
                
            case "contacts":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if usesRegularCategorySplit() {
                    if let vc = self.contactsCategoriesVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, isContacts: true, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsCategoryViewController()
                        self.contactsCategoriesVc = vc
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, isContacts: true, category: category, leftMenuDelegate: self)
                    }
                } else {
                    if let vc = self.contactsVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsViewController()
                        vc.leftMenuDelegate = self
                        self.contactsVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    }
                }
            case "groups":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if usesRegularCategorySplit() {
                    if let vc = self.groupsCategoriesVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, isGroups: true, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsCategoryViewController()
                        vc.isGroup = true
                        vc.leftMenuDelegate = self
                        self.groupsCategoriesVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyChat, isGroups: true, category: category, leftMenuDelegate: self)
                    }
                } else {
                    if let vc = self.groupsVc {
                        vc.leftMenuDelegate = self
                        didPresent = self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsViewController()
                        vc.isGroup = true
                        vc.leftMenuDelegate = self
                        self.groupsVc = vc
                        didPresent = self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    }
                }
            case "archive":
                if let vc = self.archivedVc {
                    vc.filter.accept(.archived)
                    vc.leftMenuSelectRootCategoryDelegate = self
                    didPresent = self.show(controller: vc, kind: .emptyChat)
                } else {
                    let vc = LastChatsViewController()
                    vc.shouldShowBottomBar = false
                    vc.leftMenuSelectRootCategoryDelegate = self
                    vc.filter.accept(.archived)
                    self.archivedVc = vc
                    didPresent = self.show(controller: vc, kind: .emptyChat)
//                    self.showEmptyDetail(for: .emptyChat)
                }
            case "saved":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.savedMessagesChatsVc {
                    vc.leftMenuSelectRootCategoryDelegate = self
                    didPresent = self.showSavedMessages(controller: vc)
                } else {
                    let vc = LastChatsViewController()
                    vc.shouldShowBottomBar = false
                    vc.leftMenuSelectRootCategoryDelegate = self
                    vc.filter.accept(.saved)
                    self.savedMessagesChatsVc = vc
                    didPresent = self.showSavedMessages(controller: vc)
                }
            default:
                break
        }

        if didPresent {
            self.previousSelectedKey = key
        }
    }
    
    func selectRootScreenAndCategory(screen key: String, category: String?) {
        self.didSelectRootScreenBy(key: key, category: category)
    }
    
    func openChatlistWithChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, configure: ((ChatViewController?) -> Void)?) {
        self.previousSelectedKey = nil
        if let vc = self.chatsVc {
            vc.filter.accept(.chats)
            if self.show(controller: vc, kind: .emptyChat) {
                self.previousSelectedKey = "chat"
            }
            vc.leftMenuSelectRootCategoryDelegate = self
            vc.stackNewChat(owner: owner, jid: jid, conversationType: conversationType, configure: configure)
//                    self.showEmptyDetail(for: .emptyChat)
        } else {
            let vc = LastChatsViewController()
            self.chatsVc = vc
            if self.show(controller: vc, kind: .emptyChat) {
                self.previousSelectedKey = "chat"
            }
            vc.leftMenuSelectRootCategoryDelegate = self
            vc.stackNewChat(owner: owner, jid: jid, conversationType: conversationType, configure: configure)
//                    self.showEmptyDetail(for: .emptyChat)
        }
    }
}

protocol LeftMenuSelectRootScreenDelegate {
    func selectRootScreenAndCategory(screen key: String, category: String?)
    func openChatlistWithChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, configure: ((ChatViewController?) -> Void)?)
}
