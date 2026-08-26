import Foundation
import UIKit
import UserNotifications

let EULA_VERSION = "2026-05-04"

enum EULAAcceptance {
    static let currentVersion = EULA_VERSION
    static let acceptedKey = "eulaAccepted"
    static let versionKey = "eulaVersion"
    static let acceptedAtKey = "eulaAcceptedAt"

    static var sharedDefaults: UserDefaults {
        let suiteName = CredentialsManager.uniqueAccessGroup()
        if suiteName.isNotEmpty,
           let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        return .standard
    }

    static func hasAcceptedCurrentVersion(defaults: UserDefaults = sharedDefaults) -> Bool {
        defaults.bool(forKey: acceptedKey) && defaults.string(forKey: versionKey) == currentVersion
    }

    @discardableResult
    static func accept(date: Date = Date(), defaults: UserDefaults = sharedDefaults) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
        defaults.set(true, forKey: acceptedKey)
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(timestamp, forKey: acceptedAtKey)
        defaults.synchronize()
        return timestamp
    }

    static func clear(defaults: UserDefaults = sharedDefaults) {
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: acceptedAtKey)
        defaults.synchronize()
    }

    static func decline(defaults: UserDefaults = sharedDefaults) {
        clear(defaults: defaults)
    }

    static func supportEmail() -> String {
        let reportAddress = CommonConfigManager.shared.config.default_report_address
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if reportAddress.isNotEmpty {
            return reportAddress
        }

        let supportJid = CommonConfigManager.shared.config.support_jid
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if supportJid.isNotEmpty {
            return supportJid
        }

        return "abuse@xabber.com"
    }

    static func eulaText(supportEmail: String = supportEmail()) -> String {
        """
        End User License Agreement and User Conduct Policy

        This application is an XMPP client that allows users to connect to XMPP messaging services. Some XMPP servers and services may be operated by the application developer. Other XMPP servers may be operated by independent third parties and are outside the developer's ownership, jurisdiction, and direct administrative control.

        By using this application, you agree to the following terms:

        1. No tolerance for objectionable content or abusive conduct

        You may not create, send, upload, post, transmit, distribute, or make available any objectionable content or engage in abusive behavior through this application.

        Objectionable content and abusive behavior include, but are not limited to:
        - harassment, bullying, stalking, threats, or intimidation;
        - hate speech or content attacking people based on protected characteristics;
        - sexually explicit, pornographic, or exploitative content;
        - content involving child sexual abuse material or exploitation of minors;
        - graphic violence, incitement to violence, or threats of physical harm;
        - illegal content or content that encourages illegal activity;
        - spam, scams, impersonation, phishing, or malicious links;
        - content that infringes intellectual property or privacy rights;
        - any content or behavior that makes the service unsafe for other users.

        The application has no tolerance for objectionable content or abusive users.

        2. Third-party XMPP servers

        This application may allow you to connect to third-party XMPP servers that are not operated, moderated, or controlled by the application developer.

        When connecting to a third-party XMPP server, you are responsible for following that server's own terms, policies, and applicable laws. The developer is not responsible for operating, moderating, or administering third-party XMPP servers.

        However, your use of third-party XMPP servers through this application must still comply with this User Conduct Policy.

        3. Developer-operated services

        For XMPP services, accounts, chat rooms, or servers operated by the developer, violation of these terms may result in removal or hiding of content, suspension or termination of access, ejection from rooms or services, or other measures needed to protect users and comply with applicable law.

        4. User responsibility

        You are responsible for the content you send, upload, post, transmit, or otherwise make available through this application.

        You agree not to use this application to engage in abusive, harmful, illegal, deceptive, or unsafe behavior.

        5. Safety and moderation limitations

        Because XMPP is a federated protocol and users may connect to third-party servers, the developer may not always have the technical or legal ability to remove content from a remote server, moderate a third-party room, or terminate a third-party account.

        This does not change your obligation to follow this User Conduct Policy when using the application.

        6. Termination and restrictions

        Violation of these terms may result in restriction or termination of access to developer-operated services, disabling of app features, restriction of access to specific servers through the app, or other measures needed to protect users and comply with applicable law.

        7. Contact

        Users can contact the developer to report safety issues, objectionable content, abusive users, legal concerns, or moderation concerns at:

        \(supportEmail)

        By tapping "I Agree", you confirm that you have read and agree to this End User License Agreement and User Conduct Policy.
        """.localizeString(id: "eula_terms_text", arguments: [supportEmail])
    }
}

enum AppRootKind: Equatable {
    case onboarding
    case split
    case tabs
}

enum MainSplitLayout {
    static let lastChatsSupplementaryColumnWidth: CGFloat = 414

    static func apply(to splitViewController: UISplitViewController) {
        splitViewController.preferredSupplementaryColumnWidth = lastChatsSupplementaryColumnWidth
        splitViewController.minimumSupplementaryColumnWidth = lastChatsSupplementaryColumnWidth
        splitViewController.maximumSupplementaryColumnWidth = lastChatsSupplementaryColumnWidth
    }
}

final class EULAViewController: SimpleBaseViewController {
    enum Mode {
        case acceptance(onAccept: (() -> Void)?)
        case viewOnly
    }

    private let mode: Mode
    private var didActivateConstraints = false
    private var isAcknowledged = false

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let supportEmailLabel = UILabel()
    private let controlsStack = UIStackView()
    private let acknowledgementControl = UIControl()
    private let acknowledgementRow = UIStackView()
    private let acknowledgementImageView = UIImageView()
    private let acknowledgementLabel = UILabel()
    private let agreeButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)
    private let declineMessageLabel = UILabel()

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setupSubviews() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        [titleLabel, subtitleLabel, bodyLabel, supportEmailLabel].forEach {
            $0.numberOfLines = 0
            $0.adjustsFontForContentSizeCategory = true
        }

        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.textColor = .label
        titleLabel.accessibilityIdentifier = "eula.title"

        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.accessibilityIdentifier = "eula.subtitle"

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .label
        bodyLabel.accessibilityIdentifier = "eula.body"

        supportEmailLabel.font = .preferredFont(forTextStyle: .callout)
        supportEmailLabel.textColor = .secondaryLabel
        supportEmailLabel.accessibilityIdentifier = "eula.supportEmail"

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(supportEmailLabel)

        configureControls()
    }

    override func configure() {
        super.configure()
        view.accessibilityIdentifier = "eula.screen"
        view.backgroundColor = .systemBackground
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "eula.scroll"

        switch mode {
        case .acceptance:
            navigationItem.hidesBackButton = true
        case .viewOnly:
            title = "End User License Agreement".localizeString(id: "eula_screen_title", arguments: [])
        }
    }

    override func activateConstraints() {
        guard !didActivateConstraints else {
            return
        }
        didActivateConstraints = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let guide = view.safeAreaLayoutGuide
        let bottomAnchor: NSLayoutYAxisAnchor

        switch mode {
        case .acceptance:
            view.addSubview(controlsStack)
            bottomAnchor = controlsStack.topAnchor
            NSLayoutConstraint.activate([
                controlsStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
                controlsStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
                controlsStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
            ])
        case .viewOnly:
            bottomAnchor = guide.bottomAnchor
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    override func localizeResources() {
        titleLabel.text = "End User License Agreement".localizeString(id: "eula_screen_title", arguments: [])
        subtitleLabel.text = "You must accept these terms before using the app.".localizeString(id: "eula_screen_subtitle", arguments: [])
        bodyLabel.text = EULAAcceptance.eulaText()
        let supportEmail = EULAAcceptance.supportEmail()
        supportEmailLabel.text = "Contact: %@".localizeString(id: "eula_support_email", arguments: [supportEmail])
        acknowledgementLabel.text = "I have read and agree to the End User License Agreement and User Conduct Policy."
            .localizeString(id: "eula_acknowledgement", arguments: [])
        agreeButton.setTitle("I Agree".localizeString(id: "eula_agree", arguments: []), for: .normal)
        declineButton.setTitle("Decline".localizeString(id: "eula_decline", arguments: []), for: .normal)
        declineMessageLabel.text = "You cannot use this app unless you accept the End User License Agreement."
            .localizeString(id: "eula_decline_message", arguments: [])
        updateAcknowledgementState()
    }

    private func configureControls() {
        guard case .acceptance = mode else {
            return
        }

        controlsStack.axis = .vertical
        controlsStack.spacing = 14
        controlsStack.alignment = .fill

        acknowledgementControl.accessibilityIdentifier = "eula.checkbox"
        acknowledgementControl.isAccessibilityElement = true
        acknowledgementControl.addTarget(self, action: #selector(toggleAcknowledgement), for: .touchUpInside)

        acknowledgementRow.axis = .horizontal
        acknowledgementRow.alignment = .top
        acknowledgementRow.spacing = 10
        acknowledgementRow.isUserInteractionEnabled = false

        acknowledgementImageView.contentMode = .scaleAspectFit
        acknowledgementImageView.tintColor = .secondaryLabel
        acknowledgementImageView.setContentHuggingPriority(.required, for: .horizontal)
        acknowledgementImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        acknowledgementLabel.font = .preferredFont(forTextStyle: .body)
        acknowledgementLabel.adjustsFontForContentSizeCategory = true
        acknowledgementLabel.numberOfLines = 0
        acknowledgementLabel.textColor = .label
        acknowledgementLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        acknowledgementControl.addSubview(acknowledgementRow)
        acknowledgementRow.translatesAutoresizingMaskIntoConstraints = false
        acknowledgementRow.addArrangedSubview(acknowledgementImageView)
        acknowledgementRow.addArrangedSubview(acknowledgementLabel)
        NSLayoutConstraint.activate([
            acknowledgementRow.topAnchor.constraint(equalTo: acknowledgementControl.topAnchor),
            acknowledgementRow.leadingAnchor.constraint(equalTo: acknowledgementControl.leadingAnchor),
            acknowledgementRow.trailingAnchor.constraint(equalTo: acknowledgementControl.trailingAnchor),
            acknowledgementRow.bottomAnchor.constraint(equalTo: acknowledgementControl.bottomAnchor),
            acknowledgementImageView.widthAnchor.constraint(equalToConstant: 28),
            acknowledgementImageView.heightAnchor.constraint(equalToConstant: 28)
        ])

        agreeButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        agreeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        agreeButton.layer.cornerRadius = 10
        agreeButton.accessibilityIdentifier = "eula.agree"
        agreeButton.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)
        agreeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        declineButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        declineButton.titleLabel?.adjustsFontForContentSizeCategory = true
        declineButton.accessibilityIdentifier = "eula.decline"
        declineButton.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)

        declineMessageLabel.font = .preferredFont(forTextStyle: .callout)
        declineMessageLabel.adjustsFontForContentSizeCategory = true
        declineMessageLabel.textColor = .systemRed
        declineMessageLabel.numberOfLines = 0
        declineMessageLabel.isHidden = true
        declineMessageLabel.accessibilityIdentifier = "eula.declineMessage"

        controlsStack.addArrangedSubview(acknowledgementControl)
        controlsStack.addArrangedSubview(agreeButton)
        controlsStack.addArrangedSubview(declineButton)
        controlsStack.addArrangedSubview(declineMessageLabel)
    }

    private func updateAcknowledgementState() {
        let imageName = isAcknowledged ? "checkmark.square.fill" : "square"
        acknowledgementImageView.image = UIImage(systemName: imageName)
        acknowledgementImageView.tintColor = isAcknowledged ? .systemGreen : .secondaryLabel
        acknowledgementControl.accessibilityLabel = acknowledgementLabel.text
        acknowledgementControl.accessibilityValue = isAcknowledged
            ? "Checked".localizeString(id: "eula_checkbox_checked", arguments: [])
            : "Unchecked".localizeString(id: "eula_checkbox_unchecked", arguments: [])
        var traits: UIAccessibilityTraits = .button
        if isAcknowledged {
            traits.insert(.selected)
        }
        acknowledgementControl.accessibilityTraits = traits

        agreeButton.isEnabled = isAcknowledged
        agreeButton.backgroundColor = isAcknowledged ? .systemBlue : .tertiarySystemFill
        agreeButton.setTitleColor(isAcknowledged ? .white : .secondaryLabel, for: .normal)
        agreeButton.accessibilityHint = isAcknowledged
            ? nil
            : "Check the acknowledgement before accepting."
                .localizeString(id: "eula_agree_disabled_hint", arguments: [])
        agreeButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    }

    @objc
    private func toggleAcknowledgement() {
        isAcknowledged.toggle()
        declineMessageLabel.isHidden = true
        updateAcknowledgementState()
    }

    @objc
    private func acceptTapped() {
        guard isAcknowledged else {
            return
        }

        EULAAcceptance.accept()
        if case let .acceptance(onAccept) = mode {
            onAccept?()
        }
    }

    @objc
    private func declineTapped() {
        EULAAcceptance.decline()
        declineMessageLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: declineMessageLabel.text)
    }
}

enum EULANavigationGate {
    enum Decision: Equatable {
        case continueNavigation
        case presentEULA
    }

    static func decision(hasAcceptedCurrentVersion: Bool = EULAAcceptance.hasAcceptedCurrentVersion()) -> Decision {
        hasAcceptedCurrentVersion ? .continueNavigation : .presentEULA
    }

    static func continueAfterAcceptance(from presenter: UIViewController, navigation: @escaping () -> Void) {
        switch decision() {
        case .continueNavigation:
            navigation()
        case .presentEULA:
            let vc = EULAAcceptanceNavigationController(onAccepted: navigation)
            presentContainedNavigationModal(
                vc,
                rootViewController: vc.viewControllers.first ?? vc,
                presentedContentViewController: vc.viewControllers.first ?? vc,
                from: presenter,
                forwardedDelegate: presenter as? UIAdaptivePresentationControllerDelegate
            )
        }
    }
}

private final class EULAAcceptanceNavigationController: UINavigationController {
    private let onAccepted: () -> Void

    init(onAccepted: @escaping () -> Void) {
        self.onAccepted = onAccepted
        super.init(nibName: nil, bundle: nil)

        let vc = EULAViewController(mode: .acceptance(onAccept: { [weak self] in
            self?.acceptAndContinue()
        }))
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        setViewControllers([vc], animated: false)
        modalPresentationStyle = .formSheet
        modalTransitionStyle = .coverVertical
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func cancelTapped() {
        dismiss(animated: true)
    }

    private func acceptAndContinue() {
        dismiss(animated: true) { [onAccepted] in
            onAccepted()
        }
    }
}

enum AppRoute {
    case chat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType)
    case chatMessage(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        configure: ((ChatViewController?) -> Void)?
    )
    case notification(PushNotificationRoutePayload)
    case externalURL(URL)
    case userActivity(NSUserActivity)

    static func notification(userInfo: [AnyHashable: Any]?) -> AppRoute? {
        if let route = PushNotificationRoutePayload(userInfo: userInfo) {
            return .notification(route)
        }

        guard let owner = userInfo?["owner"] as? String,
              let jid = userInfo?["jid"] as? String else {
            return nil
        }

        let conversationType: ClientSynchronizationManager.ConversationType
        if let raw = userInfo?["conversation_type"] as? String {
            conversationType = ClientSynchronizationManager.ConversationType(rawValue: raw)
                ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type)
                ?? .regular
        } else {
            conversationType = .regular
        }

        return .chat(owner: owner, jid: jid, conversationType: conversationType)
    }

    static func chatAtMessage(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        stanzaId: String,
        configure: ((ChatViewController?) -> Void)? = nil
    ) -> AppRoute? {
        guard let openMessageRequest = ChatOpenMessageRequest.openAtMessage(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            stanzaId: stanzaId
        ) else {
            return nil
        }

        return .chatMessage(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            openMessageRequest: openMessageRequest,
            configure: configure
        )
    }
}

enum AppRootLifecycleEvent {
    case willResignActive
}

struct AppRootLifecycleActions: Equatable {
    let addBlurredScreen: Bool
    let loadAccounts: Bool
}

enum AppRootLifecyclePolicy {
    static func actions(for event: AppRootLifecycleEvent) -> AppRootLifecycleActions {
        switch event {
        case .willResignActive:
            return AppRootLifecycleActions(
                addBlurredScreen: true,
                loadAccounts: false
            )
        }
    }
}

final class AppRootCoordinator: NSObject {
    static var active: AppRootCoordinator?

    static func rootKind(
        hasAccounts: Bool,
        interfaceType: CommonConfigManager.InterfaceType
    ) -> AppRootKind {
        guard hasAccounts else {
            return .onboarding
        }

        switch interfaceType {
        case .split:
            return .split
        case .tabs:
            return .tabs
        }
    }

    static func canRoute() -> Bool {
        canRoute(hasPresentedModal: false)
    }

    static func canRoute(hasPresentedModal: Bool) -> Bool {
        !hasPresentedModal
    }

    static func makeTopLevelSectionNavigationController(
        rootViewController: UIViewController
    ) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: rootViewController)
        NavigationLargeTitlePolicy.apply(to: navigationController, rootViewController: rootViewController)
        return navigationController
    }

    static func makeStockSearchSectionNavigationController(
        rootViewController: UIViewController
    ) -> UINavigationController {
        makeTopLevelSectionNavigationController(rootViewController: rootViewController)
    }

    let window: UIWindow
    weak var appDelegate: AppDelegate?

    private(set) var splitController: UISplitViewController?
    private(set) var tabController: UITabBarController?
    var currentPresentedVc: UIViewController? {
        didSet {
            appDelegate?.currentPresentedVc = currentPresentedVc
            if currentPresentedVc == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.retryPendingMessageNotificationChatRouteIfPossible()
                    self?.retryPendingNotificationRequestListIfPossible()
                }
            }
        }
    }

    private var blurEffectView: UIVisualEffectView?
    private var pendingRoute: AppRoute?
    private var pendingNotificationRequestList: PushNotificationRequestListDestination?
    #if DEBUG || CHAT_PERFORMANCE_LAB
    private var performanceFixtureDescriptor: ChatPerformanceUITestLaunchDescriptor?
    #endif

    init(window: UIWindow, appDelegate: AppDelegate?) {
        self.window = window
        self.appDelegate = appDelegate
        super.init()
        Self.active = self
        applyCompatibilityReferences()
    }

    func start(connectionOptions: UIScene.ConnectionOptions, restorationActivity: NSUserActivity?) {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        if let descriptor = ChatPerformanceUITestLaunchPolicy.descriptor() {
            performanceFixtureDescriptor = descriptor
            if ChatPerformanceManualNativeBackLaunchPolicy.isEnabled() {
                startChatPerformanceManualNativeBackFixture(
                    descriptor: descriptor
                )
            } else if let scenario = descriptor.openScenario,
               ChatPerformanceFixtureRootPolicy.mode(for: scenario) ==
                .lastChatsNativeRoute {
                startChatPerformanceProductionRouteFixture(
                    descriptor: descriptor
                )
            } else {
                window.rootViewController = UINavigationController(
                    rootViewController:
                        ChatPerformanceFixtureViewController(
                            descriptor: descriptor
                        )
                )
                applyCompatibilityReferences()
            }
            return
        }
        #endif

        let launchNotificationResponse = connectionOptions.notificationResponse
        let launchUserInfo = launchNotificationResponse?.notification.request
            .content.userInfo
        pendingRoute = launchNotificationResponse == nil
            ? route(from: connectionOptions) ?? route(from: restorationActivity)
            : nil
        rebuildRoot(userInfo: launchUserInfo)
        if let launchNotificationResponse {
            _ = routeSceneNotificationRequest(
                launchNotificationResponse.notification.request,
                actionIdentifier: launchNotificationResponse.actionIdentifier
            )
        } else if let pendingRoute {
            if case .chat = pendingRoute,
               CommonConfigManager.shared.interfaceType == .split,
               launchUserInfo != nil {
                self.pendingRoute = nil
                return
            }
            route(pendingRoute)
            self.pendingRoute = nil
        }
        retryPendingMessageNotificationChatRouteIfPossible()
    }

    func rebuildRoot(userInfo: [AnyHashable: Any]?) {
        splitController = nil
        tabController = nil
        NotifyManager.shared.leftMenuDelegate = nil
        clearPresentedModalStateForRootRebuild()

        switch Self.rootKind(
            hasAccounts: !AccountManager.shared.emptyAccountsList(),
            interfaceType: CommonConfigManager.shared.interfaceType
        ) {
        case .onboarding:
            CredentialsManager.shared.clearKeyachain()
            DispatchQueue.main.async {
                AccountManager.shared.connectingUsers.accept(Set<String>())
            }
            window.rootViewController = makeOnboardingRoot()

        case .split:
            window.rootViewController = makeSplitRoot(userInfo: userInfo)

        case .tabs:
            window.rootViewController = makeTabRoot()
        }

        applyCompatibilityReferences()
        ApplicationStateManager.shared.runPincodeTask(animated: false, force: true)
        retryPendingMessageNotificationChatRouteIfPossible()
        retryPendingNotificationRequestListIfPossible()
    }

    func sceneWillResignActive() {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        guard performanceFixtureDescriptor == nil else { return }
        #endif
        let lifecycleActions = AppRootLifecyclePolicy.actions(for: .willResignActive)
        ConnectionDiagnosticsLogger.log(
            event: "scene_lifecycle_will_resign_active",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appRootCoordinator",
                "willLoadAccounts": lifecycleActions.loadAccounts
            ]
        )
        if lifecycleActions.addBlurredScreen {
            addBlurredScreen()
        }
        if lifecycleActions.loadAccounts {
            AccountManager.shared.load()
        }
    }

    func sceneDidEnterBackground() {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        guard performanceFixtureDescriptor == nil else { return }
        #endif
        ConnectionDiagnosticsLogger.log(
            event: "scene_lifecycle_did_enter_background",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appRootCoordinator",
                "willDisconnectAccounts": true,
                "accountCount": AccountManager.shared.users.count
            ]
        )
        AccountManager.shared.users.forEach { user in
            user.disconnect(hard: true, cause: .backgroundSuspension)
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            splitController?.hide(.primary)
        } else {
            UIView.performWithoutAnimation {
                splitController?.show(.supplementary)
                splitController?.hide(.primary)
            }
        }
    }

    func sceneWillEnterForeground() {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        guard performanceFixtureDescriptor == nil else { return }
        #endif
        ConnectionDiagnosticsLogger.log(
            event: "scene_lifecycle_will_enter_foreground",
            stream: .primary,
            jid: nil,
            details: ["source": "appRootCoordinator"]
        )
        AccountManager.shared.prepare()
        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .foreground)
        NotifyManager.shared.setLastChats(displayed: true)
        ApplicationStateManager.shared.runPincodeTask(animated: false, force: true)
    }

    func sceneDidBecomeActive() {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        guard performanceFixtureDescriptor == nil else { return }
        #endif
        ConnectionDiagnosticsLogger.log(
            event: "scene_lifecycle_did_become_active",
            stream: .primary,
            jid: nil,
            details: ["source": "appRootCoordinator"]
        )
        removeBlurredScreen()
        retryPendingMessageNotificationChatRouteIfPossible()
        retryPendingNotificationRequestListIfPossible()
    }

    func sceneDidDisconnect() {
        blurEffectView?.removeFromSuperview()
        blurEffectView = nil
        if Self.active === self {
            Self.active = nil
        }
    }

    @discardableResult
    func route(_ route: AppRoute, atStart: Bool = false) -> Bool {
        guard Self.canRoute(hasPresentedModal: currentPresentedVc != nil) else {
            return false
        }

        switch route {
        case let .chat(owner, jid, conversationType):
            return openChat(owner: owner, jid: jid, conversationType: conversationType)
        case let .chatMessage(owner, jid, conversationType, openMessageRequest, configure):
            return openChat(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                openMessageRequest: openMessageRequest,
                configure: configure
            )
        case let .notification(route):
            return NotifyManager.shared.onTouchNotificationRoute(
                route,
                atStart: atStart,
                handler: nil
            )
        case .externalURL:
            return false
        case .userActivity:
            return false
        }
    }

    @discardableResult
    internal func routeNotificationRequest(
        _ request: UNNotificationRequest,
        actionIdentifier: String,
        atStart: Bool
    ) -> Bool {
        NotifyManager.shared.onTouchNotificationRequest(
            request,
            actionIdentifier: actionIdentifier,
            atStart: atStart,
            handler: nil
        )
    }

    @discardableResult
    internal func routeSceneNotificationRequest(
        _ request: UNNotificationRequest,
        actionIdentifier: String
    ) -> Bool {
        routeNotificationRequest(
            request,
            actionIdentifier: actionIdentifier,
            atStart: true
        )
    }

    func clearPresentedModalStateForRootRebuild() {
        currentPresentedVc = nil
    }

    @discardableResult
    internal func retryPendingMessageNotificationChatRouteIfPossible() -> Bool {
        guard Self.active === self,
              currentPresentedVc == nil else {
            return false
        }
        return NotifyManager.shared.retryPendingMessageNotificationChatRouteIfPossible()
    }

    @discardableResult
    internal func routeNotificationChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        configure: ((ChatViewController?) -> Void)?
    ) -> Bool {
        guard Self.canRoute(hasPresentedModal: currentPresentedVc != nil) else {
            return false
        }
        return openChat(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            openMessageRequest: openMessageRequest,
            navigationSource: .notification,
            configure: configure
        )
    }

    @discardableResult
    internal func routeNotificationRequestList(
        _ destination: PushNotificationRequestListDestination
    ) -> Bool {
        guard Self.canRoute(hasPresentedModal: currentPresentedVc != nil) else {
            pendingNotificationRequestList = destination
            return false
        }

        let routed: Bool
        switch CommonConfigManager.shared.interfaceType {
        case .split:
            guard let leftMenuDelegate = NotifyManager.shared.leftMenuDelegate else {
                pendingNotificationRequestList = destination
                return false
            }
            routed = leftMenuDelegate.selectRootScreenAndCategory(
                screen: destination.screenKey,
                category: destination.categoryKey
            )
        case .tabs:
            routed = routeTabRequestList(destination)
        }

        pendingNotificationRequestList = routed ? nil : destination
        return routed
    }

    @discardableResult
    private func retryPendingNotificationRequestListIfPossible() -> Bool {
        guard Self.active === self,
              currentPresentedVc == nil,
              let destination = pendingNotificationRequestList else {
            return false
        }
        return routeNotificationRequestList(destination)
    }

    @discardableResult
    func openChat(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        stanzaId: String
    ) -> Bool {
        guard let route = AppRoute.chatAtMessage(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            stanzaId: stanzaId
        ) else {
            return false
        }

        return self.route(route)
    }

    func addBlurredScreen() {
        guard appDelegate?.excludeBlur != true else { return }
        guard blurEffectView == nil,
              !ApplicationStateManager.shared.isPincodeShowed else {
            return
        }

        let blurEffect = UIBlurEffect(style: .light)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = window.frame
        window.addSubview(blurEffectView)
        self.blurEffectView = blurEffectView
        appDelegate?.blurEffectView = blurEffectView
    }

    func removeBlurredScreen() {
        blurEffectView?.removeFromSuperview()
        blurEffectView = nil
        appDelegate?.blurEffectView = nil
    }

    var presentationRootViewController: UIViewController? {
        switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            return tabController ?? window.rootViewController
        case .split:
            return splitController ?? window.rootViewController
        }
    }

    func restorationActivity() -> NSUserActivity? {
        let activityType = [Bundle.main.bundleIdentifier ?? "xabber", "scene"].joined(separator: ".")
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "Xabber Scene"

        switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            activity.userInfo = [
                "interface_type": CommonConfigManager.shared.config.interface_type,
                "selected_tab": tabController?.selectedIndex ?? 0
            ]
        case .split:
            activity.userInfo = [
                "interface_type": CommonConfigManager.shared.config.interface_type
            ]
        }

        return activity
    }

    private func route(from connectionOptions: UIScene.ConnectionOptions) -> AppRoute? {
        if let notificationResponse = connectionOptions.notificationResponse,
           let route = AppRoute.notification(userInfo: notificationResponse.notification.request.content.userInfo) {
            return route
        }

        if let urlContext = connectionOptions.urlContexts.first {
            return .externalURL(urlContext.url)
        }

        if let activity = connectionOptions.userActivities.first {
            return .userActivity(activity)
        }

        return nil
    }

    private func route(from restorationActivity: NSUserActivity?) -> AppRoute? {
        guard let restorationActivity else {
            return nil
        }
        return .userActivity(restorationActivity)
    }

    private func makeOnboardingRoot() -> UIViewController {
        let vc = OnboardingViewController()
        let navigationController = UINavigationController(rootViewController: vc)
        navigationController.isNavigationBarHidden = true
        return navigationController
    }

    private func makeSplitRoot(userInfo: [AnyHashable: Any]?) -> UIViewController {
        let vc = UISplitViewController(style: .tripleColumn)
        MainSplitLayout.apply(to: vc)
        NavigationLargeTitlePolicy.apply(to: vc)
        vc.restorationIdentifier = "MainSplitViewController"
        vc.restoresFocusAfterTransition = true

        let chatsVc = LastChatsViewController()
        let primaryVc = LeftMenuViewController()
        let emptyChatVc = EmptyChatViewController()
        var chatViewController: ChatViewController? = nil

        if PushNotificationRoutePayload(userInfo: userInfo) == nil,
           let jid = userInfo?["jid"] as? String,
           let owner = userInfo?["owner"] as? String {
            chatViewController = ChatViewController()
            chatViewController?.jid = jid
            chatViewController?.owner = owner
            chatViewController?.conversationType = .regular
        }

        chatsVc.leftMenuSelectRootCategoryDelegate = primaryVc
        primaryVc.chatsVc = chatsVc
        chatsVc.splitDelegate = emptyChatVc
        NavigationLargeTitlePolicy.apply(to: chatsVc)
        vc.displayModeButtonVisibility = .never
        vc.preferredDisplayMode = .oneBesideSecondary
        vc.preferredSplitBehavior = .displace
        vc.primaryBackgroundStyle = .sidebar
        vc.delegate = self

        let chatsNvc = UINavigationController(rootViewController: chatsVc)
        NavigationLargeTitlePolicy.apply(to: chatsNvc, rootViewController: chatsVc)

        let detailNvc = UINavigationController(rootViewController: chatViewController ?? emptyChatVc)

        vc.viewControllers = [
            primaryVc,
            chatsNvc,
            detailNvc
        ]
        splitController = vc
        NotifyManager.shared.leftMenuDelegate = primaryVc
        if ContinuousSplitBackgroundExperiment.mode(for: vc) != .inactive {
            return BackgroundRootContainerViewController(contentViewController: vc)
        }
        return vc
    }

    private func makeTabRoot(
        chatsViewController: LastChatsViewController? = nil,
        notificationsViewController:
            NotificationsListViewController? = nil
    ) -> UITabBarController {
        let vc = XabberTabBarViewController()
        vc.restorationIdentifier = "MainTabBarController"
        vc.restoresFocusAfterTransition = true

        let chatsVc = chatsViewController ?? LastChatsViewController()
        let contactsVc = ContactsViewController()
        let archivedVc = LastChatsViewController()
        archivedVc.filter.accept(.archived)
        let notificationsVc = notificationsViewController ??
            NotificationsListViewController()
        notificationsVc.leftMenuDelegate = self
        let callsVc = LastCallsViewController()
        let chatsNavigationController = Self.makeTopLevelSectionNavigationController(rootViewController: chatsVc)
        let contactsNavigationController = Self.makeTopLevelSectionNavigationController(rootViewController: contactsVc)
        let archivedNavigationController = Self.makeTopLevelSectionNavigationController(rootViewController: archivedVc)
        let notificationsNavigationController = Self.makeTopLevelSectionNavigationController(rootViewController: notificationsVc)
        let callsNavigationController = Self.makeTopLevelSectionNavigationController(rootViewController: callsVc)

        if CommonConfigManager.shared.config.support_calls {
            vc.viewControllers = [
                chatsNavigationController,
                contactsNavigationController,
                notificationsNavigationController,
                archivedNavigationController,
                callsNavigationController
            ]
        } else {
            vc.viewControllers = [
                chatsNavigationController,
                contactsNavigationController,
                notificationsNavigationController,
                archivedNavigationController
            ]
        }

        tabController = vc
        return vc
    }

    #if DEBUG || CHAT_PERFORMANCE_LAB
    internal func startChatPerformanceManualNativeBackFixture(
        descriptor: ChatPerformanceUITestLaunchDescriptor
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(
            descriptor.openScenario == nil,
            "The native-back fixture must stay outside the open matrix"
        )
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.tabs.rawValue
        splitController = nil
        tabController = nil
        NotifyManager.shared.leftMenuDelegate = nil
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()

        let destination = ChatPerformanceFixtureViewController(
            descriptor: descriptor
        )
        let host =
            ChatPerformanceManualNativeBackLastChatsHostViewController(
                destination: destination
            )
        let root = makeTabRoot(chatsViewController: host)
        window.rootViewController = root
        root.view.accessibilityIdentifier =
            ChatPerformanceManualNativeBackAccessibility.tabShell
        if let navigationController = root.viewControllers?.first
            as? UINavigationController {
            navigationController.view.accessibilityIdentifier =
                ChatPerformanceManualNativeBackAccessibility.navigationShell
        }
        applyCompatibilityReferences()
    }

    internal func startChatPerformanceProductionRouteFixture(
        descriptor: ChatPerformanceUITestLaunchDescriptor
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.tabs.rawValue
        splitController = nil
        tabController = nil
        NotifyManager.shared.leftMenuDelegate = nil
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()

        let destination = ChatPerformanceFixtureViewController(
            descriptor: descriptor
        )
        let host = ChatPerformanceLastChatsRouteHostViewController(
            descriptor: descriptor,
            destination: destination,
            rootCoordinator: self
        )
        let notificationsHost:
            ChatPerformanceMentionNotificationsRouteHostViewController? =
                descriptor.openScenario == .mentionDeletedAdvance
                ? ChatPerformanceMentionNotificationsRouteHostViewController(
                    descriptor: descriptor,
                    destination: destination
                )
                : nil

        var coldPendingBeforeRoot = 0
        if descriptor.openScenario == .coldPushExact {
            guard let request = destination.pendingOpenMessageRequest,
                  request.source == .pushNotification,
                  request.owner == destination.owner,
                  request.chatJid == destination.jid,
                  request.conversationType == destination.conversationType,
                  request.anchor.archivedId?.isEmpty == false ||
                    request.anchor.messageId?.isEmpty == false else {
                preconditionFailure(
                    "P04 requires one complete exact push request"
                )
            }
            let payload = PushNotificationRoutePayload.message(
                owner: request.owner,
                routeJid: request.chatJid,
                conversationType: request.conversationType.rawValue,
                stanzaId: request.anchor.archivedId,
                messageId: request.anchor.messageId,
                stanza: nil,
                senderJid: request.anchor.authorId,
                senderNickname: nil,
                groupchat: request.conversationType == .group
                    ? request.chatJid
                    : nil,
                timestamp: request.anchor.sourceDate?
                    .timeIntervalSinceReferenceDate
            )
            _ = NotifyManager.shared.onTouchNotificationRoute(
                payload,
                atStart: true,
                handler: nil
            )
            guard let pendingRoute = NotifyManager.shared
                .performancePendingMessageNotificationChatRoute else {
                preconditionFailure(
                    "P04 notification must remain pending before root install"
                )
            }
            coldPendingBeforeRoot = 1
            host.installColdPendingRoute(pendingRoute)
        }

        let root = makeTabRoot(
            chatsViewController: host,
            notificationsViewController: notificationsHost
        )
        window.rootViewController = root
        if let notificationsHost {
            host.attachP13SourceHost(notificationsHost)
            notificationsHost.bind(
                lastChatsRouteHost: host,
                rootCoordinator: self
            )
            root.selectedIndex = 2
        }
        host.rootDidInstall(coldPendingBeforeRoot: coldPendingBeforeRoot)
        applyCompatibilityReferences()
    }
    #endif

    private func openChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest? = nil,
        navigationSource explicitNavigationSource: ChatOpenNavigationSource? = nil,
        configure configureCallback: ((ChatViewController?) -> Void)? = nil
    ) -> Bool {
        let navigationSource = explicitNavigationSource ?? (
            openMessageRequest?.source == .pushNotification
                ? .notification
                : .standard
        )
        switch CommonConfigManager.shared.interfaceType {
        case .split:
            if let leftMenuDelegate = NotifyManager.shared.leftMenuDelegate {
                return leftMenuDelegate.openChatlistWithChat(
                    owner: owner,
                    jid: jid,
                    conversationType: conversationType,
                    openMessageRequest: openMessageRequest,
                    navigationSource: navigationSource,
                    configure: configureCallback
                )
            }

            if let lastChats = splitController?.viewController(for: .supplementary)
                as? UINavigationController,
               let lastChats = lastChats.topViewController
                as? LastChatsViewController {
                return lastChats.stackNewChat(
                    owner: owner,
                    jid: jid,
                    conversationType: conversationType,
                    openMessageRequest: openMessageRequest,
                    navigationSource: navigationSource,
                    configure: configureCallback
                )
            }

            guard navigationSource != .notification else {
                return false
            }

            let vc = ChatViewController()
            vc.owner = owner
            vc.jid = jid
            vc.conversationType = conversationType
            _ = vc.acceptChatOpenPerformanceTrace(
                purpose: .fallbackRoute,
                semanticTargetFingerprint:
                    vc.chatOpenPerformanceSemanticTargetFingerprint(
                        for: openMessageRequest
                    )
            )
            configureCallback?(vc)
            if let openMessageRequest {
                vc.queueOpenMessageRequest(openMessageRequest)
            }
            if let presenter = splitController?.viewControllers
                .compactMap({ $0 as? UINavigationController })
                .first(where: { $0.topViewController is LastChatsViewController })?
                .topViewController ?? splitController {
                showStacked(vc, in: presenter)
            }
            return splitController != nil

        case .tabs:
            guard let tabController,
                  let navigationController = tabController.viewControllers?.first as? UINavigationController else {
                return false
            }

            tabController.selectedIndex = 0
            let root = navigationController.viewControllers.first
            if let lastChats = root as? LastChatsViewController {
                return lastChats.stackNewChat(
                    owner: owner,
                    jid: jid,
                    conversationType: conversationType,
                    openMessageRequest: openMessageRequest,
                    navigationSource: navigationSource,
                    configure: configureCallback
                )
            } else {
                guard navigationSource != .notification else {
                    return false
                }
                let vc = ChatViewController()
                vc.owner = owner
                vc.jid = jid
                vc.conversationType = conversationType
                _ = vc.acceptChatOpenPerformanceTrace(
                    purpose: .fallbackRoute,
                    semanticTargetFingerprint:
                        vc.chatOpenPerformanceSemanticTargetFingerprint(
                            for: openMessageRequest
                        )
                )
                configureCallback?(vc)
                if let openMessageRequest {
                    vc.queueOpenMessageRequest(openMessageRequest)
                }
                navigationController.pushViewController(vc, animated: false)
                return true
            }
        }
    }

    private func routeTabRequestList(
        _ destination: PushNotificationRequestListDestination
    ) -> Bool {
        guard let tabController,
              let controllers = tabController.viewControllers,
              controllers.indices.contains(1),
              let navigationController = controllers[1] as? UINavigationController,
              let contactsRoot = navigationController.viewControllers.first
                as? ContactsViewController else {
            return false
        }

        tabController.selectedIndex = 1
        navigationController.popToRootViewController(animated: false)

        switch destination {
        case .contactRequests:
            contactsRoot.isGroup = false
            contactsRoot.leftMenuDelegate = self
            applyRequestListCategory(destination.categoryKey, to: contactsRoot)
        case .groupInvitations:
            let groupsController = ContactsViewController()
            groupsController.isGroup = true
            groupsController.leftMenuDelegate = self
            applyRequestListCategory(destination.categoryKey, to: groupsController)
            navigationController.pushViewController(groupsController, animated: false)
        }
        return true
    }

    private func applyRequestListCategory(
        _ category: String,
        to controller: ContactsViewController
    ) {
        if controller.isViewLoaded {
            controller.selectSpecialCategory(category)
        } else {
            controller.didSelectSpecialCategory(category)
        }
    }

    private func applyCompatibilityReferences() {
        appDelegate?.window = window
        appDelegate?.splitController = splitController
        appDelegate?.tabController = tabController
        appDelegate?.currentPresentedVc = currentPresentedVc
    }
}

extension AppRootCoordinator: UISplitViewControllerDelegate {
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        NavigationLargeTitlePolicy.apply(to: svc)
        return .supplementary
    }
}

extension AppRootCoordinator: LeftMenuSelectRootScreenDelegate {
    @discardableResult
    func selectRootScreenAndCategory(screen key: String, category: String?) -> Bool {
        switch key {
        case "chat":
            guard let tabController else { return false }
            tabController.selectedIndex = 0
            return true
        case "contacts" where category == "show_all_contacts":
            return routeTabRequestList(
                .contactRequests(owner: "")
            )
        case "groups" where category == "show_all_invites":
            return routeTabRequestList(
                .groupInvitations(owner: "")
            )
        default:
            return false
        }
    }

    @discardableResult
    func openChatlistWithChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource,
        configure: ((ChatViewController?) -> Void)?
    ) -> Bool {
        openChat(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            configure: configure
        )
    }
}

enum SceneWindowProvider {
    static var activeWindow: UIWindow? {
        if let window = AppRootCoordinator.active?.window {
            return window
        }

        if let foregroundWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return foregroundWindow
        }

        if let sceneWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { !$0.isHidden }) {
            return sceneWindow
        }

        return (UIApplication.shared.delegate as? AppDelegate)?.window
    }

    static var presentationRootViewController: UIViewController? {
        AppRootCoordinator.active?.presentationRootViewController ?? activeWindow?.rootViewController
    }

    static func topMostViewController(base: UIViewController? = presentationRootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topMostViewController(base: nav.visibleViewController)
        }

        if let tab = base as? UITabBarController,
           let selected = tab.selectedViewController {
            return topMostViewController(base: selected)
        }

        if let presented = base?.presentedViewController {
            return topMostViewController(base: presented)
        }

        return base
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rootCoordinator: AppRootCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: UIApplication.shared.delegate as? AppDelegate
        )
        coordinator.start(
            connectionOptions: connectionOptions,
            restorationActivity: session.stateRestorationActivity
        )

        self.window = window
        self.rootCoordinator = coordinator
        window.makeKeyAndVisible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        rootCoordinator?.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        rootCoordinator?.sceneDidEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        rootCoordinator?.sceneWillEnterForeground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        rootCoordinator?.sceneDidBecomeActive()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        rootCoordinator?.sceneDidDisconnect()
        rootCoordinator = nil
        window = nil
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else {
            return
        }
        _ = rootCoordinator?.route(.externalURL(url))
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = rootCoordinator?.route(.userActivity(userActivity))
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        rootCoordinator?.restorationActivity()
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }
}
