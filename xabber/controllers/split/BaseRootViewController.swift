//
//  BaseRootViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 26.06.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

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

enum ContinuousSplitBackgroundExperiment {
    static let isEnabled = true

    static var isActive: Bool {
        isEnabled && CommonConfigManager.shared.interfaceType == .split
    }

    static func configureTransparentSplit(_ splitViewController: UISplitViewController) {
        guard isActive else { return }
        splitViewController.view.backgroundColor = .clear
        splitViewController.view.isOpaque = false
        splitViewController.primaryBackgroundStyle = .none
    }

    static func configureTransparentColumn(_ viewController: UIViewController) {
        guard isActive else { return }
        viewController.view.backgroundColor = .clear
        viewController.view.isOpaque = false
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
        view.backgroundColor = .clear
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
}

extension UITableView {
    func applyContinuousSplitInsetGroupedAppearance() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
        backgroundColor = .clear
        backgroundView = nil
        isOpaque = false
    }
}

extension UITableViewCell {
    func applyContinuousSplitSystemBackground(selectedColor: UIColor = .systemFill) {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }

        configurationUpdateHandler = nil

        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .systemBackground
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
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.visualEffect = UIBlurEffect(style: state.isSelected || state.isHighlighted ? .systemMaterial : .systemThinMaterial)
            background.backgroundColor = state.isSelected || state.isHighlighted
                ? selectedColor.withAlphaComponent(0.35)
                : UIColor.systemBackground.withAlphaComponent(0.24)
            cell.backgroundConfiguration = background
        }
        setNeedsUpdateConfiguration()
    }
}

extension UINavigationController {
    func applyTransparentSplitAppearance() {
        guard ContinuousSplitBackgroundExperiment.isActive else { return }
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
    }
}
