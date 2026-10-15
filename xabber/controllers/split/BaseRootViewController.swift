//
//  BaseRootViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 26.06.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift

class BaseRootViewController: BaseViewController {
    
    class XabberTabBarView: UIToolbar {
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            
            return stack
        }()
        /*self.tabBar.itemPositioning = .automatic
         self.tabBar.items?[0].image = imageLiteral("message")
         self.tabBar.items?[0].title = "Chats"
         self.tabBar.items?[1].image = imageLiteral("person.2")
         self.tabBar.items?[1].title = "Contacts"
         self.tabBar.items?[2].image = imageLiteral("bell")
         self.tabBar.items?[2].title = "Notifications"
         self.tabBar.items?[3].image = imageLiteral("archivebox")
         self.tabBar.items?[3].title = "Archive"
         if CommonConfigManager.shared.config.support_calls {
             self.tabBar.items?[4].image = imageLiteral("phone")
             self.tabBar.items?[4].title = "Calls"
         }*/
        internal let chatsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("message")
            conf.attributedTitle = AttributedString(L10n.text("navigation__destination__chats", fallback: "Chats"), attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let contactsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("person.2")
//            conf.title = "Contacts"
            conf.attributedTitle = AttributedString(L10n.text("navigation__destination__contacts", fallback: "Contacts"), attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let notificationsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("bell")
//            conf.title = "Notifications"
            conf.attributedTitle = AttributedString(L10n.text("navigation__destination__notifications", fallback: "Notifications"), attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let archivedButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("archivebox")
//            conf.title = "Archive"
            conf.attributedTitle = AttributedString(L10n.text("navigation__destination__archive", fallback: "Archive"), attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let callsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("phone")
//            conf.title = "Calls"
            conf.attributedTitle = AttributedString(L10n.text("navigation__destination__calls", fallback: "Calls"), attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func setupSubviews() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(chatsButton)
            stack.addArrangedSubview(contactsButton)
            stack.addArrangedSubview(notificationsButton)
            stack.addArrangedSubview(archivedButton)
            stack.addArrangedSubview(callsButton)
        }
    }
    
    let tabBarHeight: CGFloat = 49
    
    internal let xabberTabBar: XabberTabBarView = {
        let bar = XabberTabBarView(frame: .zero)
        
        return bar
    }()
    
    
    
    func addTabBar() {
        self.view.addSubview(self.xabberTabBar)
        self.updateFrame()
    }
    
    func configureTabBar() {
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.addTabBar()
        self.navigationItem.backButtonDisplayMode = .minimal
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.updateFrame()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        self.updateFrame()
    }
    
    func updateFrame() {
        self.view.bringSubviewToFront(xabberTabBar)
        var barHeight = tabBarHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            barHeight += bottomInset
        }
        self.xabberTabBar.frame = CGRect(
            origin: CGPoint(x: 0, y: self.view.frame.height - barHeight),
            size: CGSize(width: self.view.frame.width, height: barHeight)
        )
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        updateFrame()
    }
    
}

enum ContinuousSplitBackgroundMode: Equatable {
    case inactive
    case deferred
    case sharedBackdrop
    case stockCompact
}

enum ContinuousSplitBackgroundExperiment {
    static let isEnabled = true

    static var mode: ContinuousSplitBackgroundMode {
        mode(
            interfaceType: CommonConfigManager.shared.interfaceType,
            windowHorizontalSizeClass: activeWindowHorizontalSizeClass() ?? .unspecified,
            splitHorizontalSizeClass: .unspecified,
            isSplitCollapsed: nil
        )
    }

    static var isActive: Bool {
        mode == .sharedBackdrop
    }

    static var usesSplitListChrome: Bool {
        switch mode {
        case .sharedBackdrop, .stockCompact:
            return true
        case .inactive, .deferred:
            return false
        }
    }

    static func mode(
        interfaceType: CommonConfigManager.InterfaceType,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> ContinuousSplitBackgroundMode {
        mode(
            interfaceType: interfaceType,
            windowHorizontalSizeClass: horizontalSizeClass,
            splitHorizontalSizeClass: horizontalSizeClass,
            isSplitCollapsed: false
        )
    }

    static func mode(
        interfaceType: CommonConfigManager.InterfaceType,
        windowHorizontalSizeClass: UIUserInterfaceSizeClass,
        splitHorizontalSizeClass _: UIUserInterfaceSizeClass,
        isSplitCollapsed: Bool?
    ) -> ContinuousSplitBackgroundMode {
        guard isEnabled, interfaceType == .split else {
            return .inactive
        }

        switch windowHorizontalSizeClass {
        case .regular:
            return .sharedBackdrop
        case .compact:
            return .stockCompact
        case .unspecified:
            return .deferred
        @unknown default:
            return .deferred
        }
    }

    static func mode(for viewController: UIViewController) -> ContinuousSplitBackgroundMode {
        let splitViewController = resolvedSplitViewController(for: viewController)
        return mode(
            interfaceType: CommonConfigManager.shared.interfaceType,
            windowHorizontalSizeClass: resolvedWindowHorizontalSizeClass(
                viewController: viewController,
                splitViewController: splitViewController
            ),
            splitHorizontalSizeClass: splitViewController?.traitCollection.horizontalSizeClass ?? .unspecified,
            isSplitCollapsed: splitViewController?.isCollapsed
        )
    }

    static func mode(for view: UIView) -> ContinuousSplitBackgroundMode {
        if let viewController = owningViewController(for: view) {
            return mode(for: viewController)
        }

        return mode(
            interfaceType: CommonConfigManager.shared.interfaceType,
            windowHorizontalSizeClass: view.window?.traitCollection.horizontalSizeClass ?? .unspecified,
            splitHorizontalSizeClass: .unspecified,
            isSplitCollapsed: nil
        )
    }

    static func configureTransparentSplit(_ splitViewController: UISplitViewController) {
        switch mode(for: splitViewController) {
        case .sharedBackdrop:
            splitViewController.view.backgroundColor = .clear
            splitViewController.view.isOpaque = false
            splitViewController.primaryBackgroundStyle = .none
        case .stockCompact:
            splitViewController.view.backgroundColor = .systemBackground
            splitViewController.view.isOpaque = true
            splitViewController.primaryBackgroundStyle = .sidebar
        case .inactive, .deferred:
            break
        }
    }

    static func configureTransparentColumn(_ viewController: UIViewController) {
        switch mode(for: viewController) {
        case .sharedBackdrop:
            viewController.view.backgroundColor = .clear
            viewController.view.isOpaque = false
        case .stockCompact:
            viewController.view.backgroundColor = .systemBackground
            viewController.view.isOpaque = true
        case .inactive, .deferred:
            break
        }
    }

    private static func resolvedWindowHorizontalSizeClass(
        viewController: UIViewController,
        splitViewController: UISplitViewController?
    ) -> UIUserInterfaceSizeClass {
        firstSpecifiedHorizontalSizeClass([
            viewController.viewIfLoaded?.window?.traitCollection.horizontalSizeClass,
            viewController.navigationController?.viewIfLoaded?.window?.traitCollection.horizontalSizeClass,
            viewController.parent?.viewIfLoaded?.window?.traitCollection.horizontalSizeClass,
            viewController.navigationController?.parent?.viewIfLoaded?.window?.traitCollection.horizontalSizeClass,
            splitViewController?.viewIfLoaded?.window?.traitCollection.horizontalSizeClass
        ])
    }

    private static func firstSpecifiedHorizontalSizeClass(
        _ candidates: [UIUserInterfaceSizeClass?]
    ) -> UIUserInterfaceSizeClass {
        candidates
            .compactMap { $0 }
            .first { $0 != .unspecified } ?? .unspecified
    }

    private static func resolvedSplitViewController(for viewController: UIViewController) -> UISplitViewController? {
        if let splitViewController = viewController as? UISplitViewController {
            return splitViewController
        }
        return viewController.splitViewController
            ?? viewController.navigationController?.splitViewController
            ?? viewController.parent?.splitViewController
    }

    private static func owningViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }

    private static func activeWindowHorizontalSizeClass() -> UIUserInterfaceSizeClass? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }?
            .windows
            .first { $0.isKeyWindow }?
            .traitCollection
            .horizontalSizeClass
    }
}

/// Only the navigation chrome may overflow a shared-wallpaper column. Scroll
/// views retain their own clipping so rows and messages stay in their columns.
enum ContinuousSplitNavigationShadowPolicy {
    private static let originalClipping = NSMapTable<UIView, NSNumber>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    private static let originalDividerVisibility = NSMapTable<UIView, NSNumber>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func hideBoundaryDividers(in splitRoot: UIView, columnViews: [UIView]) {
        let contentRoots = Set(columnViews.map(ObjectIdentifier.init))
        let boundaries = columnViews.flatMap { column -> [CGFloat] in
            let frame = column.convert(column.bounds, to: splitRoot)
            return [frame.minX, frame.maxX]
        }.filter { $0 > splitRoot.bounds.minX + 1 && $0 < splitRoot.bounds.maxX - 1 }

        func visit(_ view: UIView) {
            // Stop at our content roots: separators and scroll indicators inside
            // app screens are not split dividers and must remain untouched.
            guard !contentRoots.contains(ObjectIdentifier(view)) else { return }
            let frame = view.convert(view.bounds, to: splitRoot)
            if view !== splitRoot, !(view is UIControl), !view.isAccessibilityElement,
               frame.width > 0, frame.width <= 1,
               frame.height >= splitRoot.bounds.height * 0.9,
               boundaries.contains(where: { abs($0 - frame.midX) <= 1 }) {
                if originalDividerVisibility.object(forKey: view) == nil {
                    originalDividerVisibility.setObject(NSNumber(value: view.isHidden), forKey: view)
                }
                view.isHidden = true
                return
            }
            view.subviews.forEach(visit)
        }
        visit(splitRoot)
    }

    static func restoreClipping(in splitRoot: UIView) {
        for view in originalDividerVisibility.keyEnumerator().allObjects.compactMap({ $0 as? UIView }) {
            guard view === splitRoot || view.isDescendant(of: splitRoot),
                  let original = originalDividerVisibility.object(forKey: view) else { continue }
            view.isHidden = original.boolValue
            originalDividerVisibility.removeObject(forKey: view)
        }
        for view in originalClipping.keyEnumerator().allObjects.compactMap({ $0 as? UIView }) {
            guard view === splitRoot || view.isDescendant(of: splitRoot),
                  let original = originalClipping.object(forKey: view) else { continue }
            view.clipsToBounds = original.boolValue
            originalClipping.removeObject(forKey: view)
        }
    }

    static func allowOverflow(from navigationBar: UIView, through splitRoot: UIView) {
        guard navigationBar.isDescendant(of: splitRoot) else { return }
        var current: UIView? = navigationBar
        while let view = current {
            if originalClipping.object(forKey: view) == nil {
                originalClipping.setObject(NSNumber(value: view.clipsToBounds), forKey: view)
            }
            view.clipsToBounds = false
            if view === splitRoot { break }
            current = view.superview
        }
    }
}

final class ChatBackgroundBackdropView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let patternImageView = UIImageView()
    private let blurView = UIVisualEffectView(effect: nil)
    private var usesEncryptedPalette = false
    private var configuredDocument: AppearanceSettingsDocument?

    private(set) var representedWallpaper: AppearanceWallpaper?
    var hasVisibleWallpaperImage: Bool { patternImageView.image != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .systemBackground
        layer.insertSublayer(gradientLayer, at: 0)
        addSubview(patternImageView)
        patternImageView.alpha = 0.1
        patternImageView.tintColor = .systemBackground
        patternImageView.contentMode = .scaleAspectFill
        patternImageView.clipsToBounds = true
        addSubview(blurView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        patternImageView.frame = bounds
        blurView.frame = bounds
    }

    @objc
    func reloadFromSettings() {
        reload(encrypted: usesEncryptedPalette)
    }

    func reload(encrypted: Bool) {
        configuredDocument = nil
        usesEncryptedPalette = encrypted
        let document = AppearanceSettingsStore()?.load()
            ?? AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        render(document: document, encrypted: encrypted)
    }

    /// Renders an explicit appearance document for settings previews while
    /// keeping the production chat background renderer as the single source
    /// of truth for gradients, tiled assets, cloud images, blur and motion.
    func configure(document: AppearanceSettingsDocument, encrypted: Bool = false) {
        configuredDocument = document
        usesEncryptedPalette = encrypted
        render(document: document, encrypted: encrypted)
    }

    private func render(document: AppearanceSettingsDocument, encrypted: Bool) {
        representedWallpaper = encrypted ? nil : document.profile.wallpaper
        let snapshot = AppearanceResolver.resolve(
            document: document,
            traitStyle: traitCollection.userInterfaceStyle
        )
        gradientLayer.colors = encrypted
            ? [
                UIColor(red: 253 / 255, green: 216 / 255, blue: 25 / 255, alpha: 1).cgColor,
                UIColor(red: 232 / 255, green: 5 / 255, blue: 5 / 255, alpha: 1).cgColor
            ]
            : snapshot.palette.backgroundStops.map { $0.uiColor.cgColor }
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.0)
        patternImageView.transform = .identity
        blurView.effect = nil

        guard !encrypted else {
            patternImageView.image = nil
            return
        }

        switch document.profile.wallpaper {
        case .none:
            patternImageView.image = nil
        case .builtIn(let name):
            patternImageView.image = UIImage(named: name.lowercased())?
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: .zero, resizingMode: .tile)
            patternImageView.tintColor = .systemBackground
            patternImageView.alpha = 0.1
            patternImageView.contentMode = .scaleAspectFill
        case .gradient(let stops, let pattern, let intensity):
            if !stops.isEmpty {
                gradientLayer.colors = stops.map { $0.uiColor.cgColor }
            }
            patternImageView.image = pattern.flatMap { UIImage(named: $0.lowercased()) }?
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: .zero, resizingMode: .tile)
            patternImageView.tintColor = .systemBackground
            patternImageView.alpha = CGFloat(intensity) / 100
            patternImageView.contentMode = .scaleAspectFill
        case .cloud(let reference, let blurred, let motion):
            patternImageView.image = AppearanceWallpaperCache().image(for: reference)
            patternImageView.tintColor = nil
            patternImageView.alpha = 1
            patternImageView.contentMode = .scaleAspectFill
            if blurred {
                blurView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            }
            if motion && !UIAccessibility.isReduceMotionEnabled {
                patternImageView.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            if let configuredDocument {
                render(document: configuredDocument, encrypted: usesEncryptedPalette)
            } else {
                reloadFromSettings()
            }
        }
    }
}

final class BackgroundRootContainerViewController: UIViewController {
    private let contentViewController: UIViewController
    private let backgroundView = ChatBackgroundBackdropView()

    override var childForStatusBarStyle: UIViewController? {
        contentViewController
    }

    override var childForStatusBarHidden: UIViewController? {
        contentViewController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        contentViewController
    }

    init(contentViewController: UIViewController) {
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        backgroundView.reloadFromSettings()
        backgroundView.isHidden = true
        applyBackgroundMode()
        view.addSubview(backgroundView)
        backgroundView.fillSuperview()

        addChild(contentViewController)
        view.addSubview(contentViewController.view)
        contentViewController.view.fillSuperview()
        contentViewController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            backgroundView,
            selector: #selector(ChatBackgroundBackdropView.reloadFromSettings),
            name: .chatBackgroundChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(backgroundView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBackgroundMode()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBackgroundMode()
    }

    private func applyBackgroundMode() {
        applyContentBackgroundMode()

        switch ContinuousSplitBackgroundExperiment.mode(for: self) {
        case .sharedBackdrop:
            view.backgroundColor = .clear
            view.isOpaque = false
            backgroundView.isHidden = false
        case .stockCompact, .inactive:
            view.backgroundColor = .systemBackground
            view.isOpaque = true
            backgroundView.isHidden = true
        case .deferred:
            break
        }
    }

    private func applyContentBackgroundMode() {
        guard let splitViewController = contentViewController as? UISplitViewController else {
            return
        }

        if ContinuousSplitBackgroundExperiment.mode(for: self) != .sharedBackdrop {
            ContinuousSplitNavigationShadowPolicy.restoreClipping(in: splitViewController.view)
        }
        ContinuousSplitBackgroundExperiment.configureTransparentSplit(splitViewController)
        [
            UISplitViewController.Column.primary,
            .supplementary,
            .secondary,
            .compact
        ].forEach { column in
            guard let columnController = splitViewController.viewController(for: column) else {
                return
            }
            applyColumnBackgroundMode(to: columnController)
        }
        if ContinuousSplitBackgroundExperiment.mode(for: self) == .sharedBackdrop {
            let columnViews = [UISplitViewController.Column.primary, .supplementary, .secondary, .compact]
                .compactMap { splitViewController.viewController(for: $0)?.viewIfLoaded }
            ContinuousSplitNavigationShadowPolicy.hideBoundaryDividers(
                in: splitViewController.view, columnViews: columnViews)
        }
    }

    private func applyColumnBackgroundMode(to viewController: UIViewController) {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(viewController)

        if let navigationController = viewController as? UINavigationController {
            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)
            if ContinuousSplitBackgroundExperiment.mode(for: self) == .sharedBackdrop,
               let split = contentViewController as? UISplitViewController {
                ContinuousSplitNavigationShadowPolicy.allowOverflow(
                    from: navigationController.navigationBar, through: split.view)
            }
            navigationController.viewControllers.forEach {
                ContinuousSplitBackgroundExperiment.configureTransparentColumn($0)
            }
        }
    }
}

extension UIViewController {
    /// Match Recent Chats while allowing the regular-width split container to own
    /// one continuous wallpaper across its columns.
    func applyChatWallpaper(to tableView: UITableView, emptyView: UIView? = nil) {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.backgroundColor = .clear
        tableView.isOpaque = false
        emptyView?.backgroundColor = .clear
        emptyView?.isOpaque = false
        if ContinuousSplitBackgroundExperiment.mode(for: self) == .sharedBackdrop {
            tableView.backgroundView = nil
        } else if !(tableView.backgroundView is ChatBackgroundBackdropView) {
            let backdrop = ChatBackgroundBackdropView()
            backdrop.reload(encrypted: false)
            NotificationCenter.default.addObserver(
                backdrop,
                selector: #selector(ChatBackgroundBackdropView.reloadFromSettings),
                name: .chatBackgroundChanged,
                object: nil
            )
            tableView.backgroundView = backdrop
        }
    }
}

extension UITableView {
    func applyContinuousSplitInsetGroupedAppearance() {
        switch ContinuousSplitBackgroundExperiment.mode(for: self) {
        case .sharedBackdrop:
            backgroundColor = .clear
            backgroundView = nil
            isOpaque = false
        case .stockCompact:
            backgroundColor = .systemGroupedBackground
            backgroundView = nil
            isOpaque = true
        case .inactive, .deferred:
            break
        }
    }
}

enum ContinuousSplitCellBackgroundStyle {
    static var nativeGlassTintColor: UIColor? {
        XabberGlassStyle.nativeGlassTintColor
    }

    static var normalFallbackBlurStyle: UIBlurEffect.Style {
        XabberGlassStyle.fallbackBlurStyle(for: .splitCellNormal)
    }

    static var highlightedFallbackBlurStyle: UIBlurEffect.Style {
        XabberGlassStyle.fallbackBlurStyle(for: .splitCellHighlighted)
    }

    static var normalBackgroundColor: UIColor {
        XabberGlassStyle.splitCellNormalBackgroundColor
    }

    static func makeEffect(
        isHighlighted: Bool,
        prefersNativeGlass: Bool = true,
        tintColor: UIColor? = nil
    ) -> UIVisualEffect {
        XabberGlassStyle.makeEffect(
            role: isHighlighted ? .splitCellHighlighted : .splitCellNormal,
            interactive: false,
            prefersNativeGlass: prefersNativeGlass,
            tintColor: tintColor
        )
    }

    static func backgroundColor(isHighlighted: Bool, selectedColor: UIColor) -> UIColor {
        XabberGlassStyle.splitCellBackgroundColor(
            isHighlighted: isHighlighted,
            selectedColor: selectedColor
        )
    }
}

enum AccountSelectionHighlightStyle {
    static func tint50(owner: String?, fallbackOwners: Set<String> = []) -> UIColor {
        if let owner, owner.isNotEmpty {
            return AccountColorManager.shared.palette(for: owner).tint50
        }

        if let owner = firstOwner(from: fallbackOwners) ?? firstEnabledOwner() {
            return AccountColorManager.shared.palette(for: owner).tint50
        }

        return AccountColorManager.shared.topPalette().tint50
    }

    private static func firstOwner(from owners: Set<String>) -> String? {
        guard owners.isNotEmpty else { return nil }

        do {
            let realm = try WRealm.safe()
            if let account = realm
                .objects(AccountStorageItem.self)
                .filter("jid IN %@", Array(owners))
                .sorted(byKeyPath: "order", ascending: true)
                .first {
                return account.jid
            }
        } catch {
            return owners.sorted().first
        }

        return owners.sorted().first
    }

    private static func firstEnabledOwner() -> String? {
        do {
            return try WRealm.safe()
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
                .first?
                .jid
        } catch {
            return nil
        }
    }
}

extension UITableViewCell {
    func applyPlainGroupedSystemBackground(selectedColor: UIColor?) {
        applyPlainGroupedSystemBackground(selectedColor: selectedColor, isSelected: false)
    }

    func applyPlainGroupedSystemBackground(
        selectedColor: UIColor? = nil,
        isSelected: Bool = false,
        usesHighlightedStateForSelection: Bool = true,
        usesStateDrivenSelection: Bool = true
    ) {
        configurationUpdateHandler = nil

        func applyBackground(color: UIColor) {
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = color
            background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in
                color
            }
            background.strokeColor = .clear
            background.strokeColorTransformer = UIConfigurationColorTransformer { _ in
                .clear
            }
            background.strokeWidth = 0
            background.strokeOutset = 0
            background.visualEffect = nil
            backgroundConfiguration = background

            backgroundColor = color
            contentView.backgroundColor = .clear
            isOpaque = true
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
        }

        let normalColor = UIColor.systemBackground
        let selectedBackgroundColor = selectedColor ?? normalColor
        applyBackground(color: isSelected ? selectedBackgroundColor : normalColor)

        guard let selectedColor, usesStateDrivenSelection else { return }

        configurationUpdateHandler = { cell, state in
            let color = isSelected
                || state.isSelected
                || (usesHighlightedStateForSelection && state.isHighlighted)
                ? selectedColor
                : normalColor
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = color
            background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in
                color
            }
            background.strokeColor = .clear
            background.strokeColorTransformer = UIConfigurationColorTransformer { _ in
                .clear
            }
            background.strokeWidth = 0
            background.strokeOutset = 0
            background.visualEffect = nil
            cell.backgroundConfiguration = background
            cell.backgroundColor = color
            cell.contentView.backgroundColor = .clear
            cell.isOpaque = true
            cell.selectionStyle = .none
            cell.focusStyle = .custom
            cell.backgroundView = nil
            cell.selectedBackgroundView = nil
            cell.multipleSelectionBackgroundView = nil
            cell.layer.borderWidth = 0
            cell.layer.borderColor = UIColor.clear.cgColor
            cell.layer.shadowOpacity = 0
            cell.layer.shadowColor = nil
            cell.contentView.layer.borderWidth = 0
            cell.contentView.layer.borderColor = UIColor.clear.cgColor
            cell.contentView.layer.shadowOpacity = 0
            cell.contentView.layer.shadowColor = nil
        }
        setNeedsUpdateConfiguration()
    }

    func applyContinuousSplitSystemBackground(selectedColor: UIColor = .systemFill) {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }

        configurationUpdateHandler = nil

        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .systemBackground
        background.visualEffect = nil
        backgroundConfiguration = background

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isOpaque = false

        let selectedView = UIView()
        selectedView.backgroundColor = selectedColor
        selectedBackgroundView = selectedView
    }

    func applyContinuousSplitGlassBackground(selectedColor: UIColor = .systemFill) {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isOpaque = false
        selectedBackgroundView = nil

        configurationUpdateHandler = { cell, state in
            let isHighlighted = state.isSelected || state.isHighlighted
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.visualEffect = ContinuousSplitCellBackgroundStyle.makeEffect(
                isHighlighted: isHighlighted,
                tintColor: XabberGlassStyle.splitCellTintColor(
                    isHighlighted: isHighlighted,
                    selectedColor: selectedColor
                )
            )
            background.backgroundColor = ContinuousSplitCellBackgroundStyle.backgroundColor(
                isHighlighted: isHighlighted,
                selectedColor: selectedColor
            )
            cell.backgroundConfiguration = background
        }
        setNeedsUpdateConfiguration()
    }

    func applyContinuousSplitStaticGlassBackground() {
        configurationUpdateHandler = nil

        guard ContinuousSplitBackgroundExperiment.isActive else { return }

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isOpaque = false
        backgroundView = nil
        selectedBackgroundView = nil
        multipleSelectionBackgroundView = nil
        focusStyle = .custom

        var background = UIBackgroundConfiguration.listGroupedCell()
        background.visualEffect = ContinuousSplitCellBackgroundStyle.makeEffect(isHighlighted: false)
        background.backgroundColor = ContinuousSplitCellBackgroundStyle.normalBackgroundColor
        backgroundConfiguration = background
    }
}

extension UINavigationController {
    func applyTransparentSplitContainerBackground(backgroundMode: ContinuousSplitBackgroundMode? = nil) {
        switch backgroundMode ?? ContinuousSplitBackgroundExperiment.mode(for: self) {
        case .sharedBackdrop:
            view.backgroundColor = .clear
            view.isOpaque = false
        case .stockCompact:
            view.backgroundColor = .systemBackground
            view.isOpaque = true
        case .inactive, .deferred:
            break
        }
    }

    func applyTransparentSplitAppearance(backgroundMode: ContinuousSplitBackgroundMode? = nil) {
        let resolvedBackgroundMode = backgroundMode ?? ContinuousSplitBackgroundExperiment.mode(for: self)
        applyTransparentSplitContainerBackground(backgroundMode: resolvedBackgroundMode)

        switch resolvedBackgroundMode {
        case .sharedBackdrop:
            navigationBar.isTranslucent = true

            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.25)

            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
            navigationBar.compactScrollEdgeAppearance = appearance
        case .stockCompact, .inactive, .deferred:
            break
        }
    }
}
