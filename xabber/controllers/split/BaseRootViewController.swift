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
            conf.attributedTitle = AttributedString("Chats", attributes: AttributeContainer([
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
            conf.attributedTitle = AttributedString("Contacts", attributes: AttributeContainer([
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
            conf.attributedTitle = AttributedString("Notifications", attributes: AttributeContainer([
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
            conf.attributedTitle = AttributedString("Archive", attributes: AttributeContainer([
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
            conf.attributedTitle = AttributedString("Calls", attributes: AttributeContainer([
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

final class ChatBackgroundBackdropView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let patternImageView = UIImageView()

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
        reloadFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        patternImageView.frame = bounds
    }

    @objc
    func reloadFromSettings() {
        let rawColor = SettingManager.shared.getString(for: "chat_chooseBackgroundColor") ?? "purple"
        let color = ChatViewController.BackgroundColor(rawValue: rawColor) ?? .purple
        gradientLayer.colors = ChatViewController.getColorsForGradient(forColor: color)
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.0)

        let backgroundName = SettingManager.shared.getString(for: "chat_chooseBackground") ?? "None"
        if backgroundName == "None" {
            patternImageView.image = nil
        } else {
            patternImageView.image = UIImage(named: backgroundName.lowercased())?
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: .zero, resizingMode: .tile)
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
    }

    private func applyColumnBackgroundMode(to viewController: UIViewController) {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(viewController)

        if let navigationController = viewController as? UINavigationController {
            SearchSectionNavigationContainerPolicy.applyTransparentSplitAppearanceIfAllowed(to: navigationController)
            navigationController.viewControllers.forEach {
                ContinuousSplitBackgroundExperiment.configureTransparentColumn($0)
            }
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
    static let nativeGlassTintColor = UIColor.systemBackground.withAlphaComponent(0.16)
    static let normalFallbackBlurStyle: UIBlurEffect.Style = .systemThinMaterial
    static let highlightedFallbackBlurStyle: UIBlurEffect.Style = .systemMaterial
    static let normalBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.24)

    static func makeEffect(
        isHighlighted: Bool,
        prefersNativeGlass: Bool = true,
        tintColor: UIColor? = nil
    ) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            effect.tintColor = tintColor ?? nativeGlassTintColor
            return effect
        }

        return UIBlurEffect(style: isHighlighted ? highlightedFallbackBlurStyle : normalFallbackBlurStyle)
    }

    static func backgroundColor(isHighlighted: Bool, selectedColor: UIColor) -> UIColor {
        isHighlighted
            ? selectedColor.withAlphaComponent(0.35)
            : normalBackgroundColor
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
                tintColor: isHighlighted ? selectedColor.withAlphaComponent(0.18) : nil
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
    func applyTransparentSplitAppearance(backgroundMode: ContinuousSplitBackgroundMode? = nil) {
        switch backgroundMode ?? ContinuousSplitBackgroundExperiment.mode(for: self) {
        case .sharedBackdrop:
            view.backgroundColor = .clear
            view.isOpaque = false
            navigationBar.isTranslucent = true

            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.25)

            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
            navigationBar.compactScrollEdgeAppearance = appearance
        case .stockCompact:
            view.backgroundColor = .systemBackground
            view.isOpaque = true
        case .inactive, .deferred:
            break
        }
    }
}
