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
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import YubiKit
import CocoaLumberjack
import MaterialComponents.MDCPalettes

class LastCallsViewController: BaseViewController, LeftMenuFirstPresentationQuieting {
    
    enum DisplayCallDirection: Equatable {
        case missed
        case outgoing
        case incoming
        case rejected
        
        var title: String {
            switch self {
            case .missed:
                return "Missed".localizeString(id: "chat_message_missed_call", arguments: [])
            case .outgoing:
                return "Outgoing".localizeString(id: "chat_message_outgoing", arguments: [])
            case .incoming:
                return "Incoming".localizeString(id: "chat_message_incoming", arguments: [])
            case .rejected:
                return CallsListFilter.declined.title
            }
        }
        
        func iconName(outgoing: Bool) -> String {
            switch self {
            case .missed:
                return "phone.arrow.down.left"
            case .outgoing:
                return "phone.arrow.up.right"
            case .incoming:
                return "phone.arrow.down.left"
            case .rejected:
                return outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
            }
        }
        
        var titleColor: UIColor {
            switch self {
            case .missed:
                return .systemRed
            default:
                if #available(iOS 13.0, *) {
                    return .label
                } else {
                    return .darkText
                }
            }
        }
        
        var subtitleTintColor: UIColor {
            switch self {
            case .missed:
                return .systemRed
            default:
                if #available(iOS 13.0, *) {
                    return .secondaryLabel
                } else {
                    return MDCPalette.grey.tint500
                }
            }
        }
    }
    
    static func displayDirection(for state: MessageStorageItem.VoIPCallState, outgoing: Bool) -> DisplayCallDirection {
        CallsListCoordinator.displayDirection(for: state, outgoing: outgoing)
    }

    internal static func emptyStateDescriptor(
        hasResolvedSnapshot: Bool,
        isLoading: Bool,
        isSearchActive: Bool,
        callHistoryIsEmpty: Bool,
        hasCallableContacts: Bool
    ) -> CoreListEmptyStateDescriptor? {
        guard hasResolvedSnapshot, !isLoading, !isSearchActive, callHistoryIsEmpty else {
            return nil
        }

        if hasCallableContacts {
            return CoreListEmptyStateDescriptor(
                iconSystemName: "phone.circle",
                title: "No calls yet".localizeString(id: "calls_empty_title", arguments: []),
                subtitle: "Start a call with one of your contacts.".localizeString(id: "calls_empty_start_subtitle", arguments: []),
                buttonTitle: "Start Call".localizeString(id: "calls_empty_start_call", arguments: []),
                buttonAccessibilityIdentifier: "calls_empty_start_call_button",
                action: .startCall
            )
        }

        return CoreListEmptyStateDescriptor(
            iconSystemName: "phone.circle",
            title: "No calls yet".localizeString(id: "calls_empty_title", arguments: []),
            subtitle: "Add your first contact before starting a call.".localizeString(id: "calls_empty_add_contact_subtitle", arguments: []),
            buttonTitle: "Add Contact".localizeString(id: "calls_empty_add_contact", arguments: []),
            buttonAccessibilityIdentifier: "calls_empty_add_contact_button",
            action: .addContact
        )
    }

    internal static func hasCallableContacts(in realm: Realm, enabledAccounts: Set<String>) -> Bool {
        realm
            .objects(RosterStorageItem.self)
            .filter(
                "owner IN %@ AND subscription_ == %@ AND jid != owner",
                Array(enabledAccounts),
                RosterStorageItem.Subsccribtion.both.rawValue
            )
            .contains {
                ($0.getPrimaryResource()?.entity ?? .contact) == .contact
            }
    }

    internal static func enabledAccountJids(in realm: Realm) -> Set<String> {
        Set(realm.objects(AccountStorageItem.self)
            .filter("enabled == true")
            .compactMap { $0.jid })
    }

    internal static func callDatasource(in realm: Realm, enabledAccounts: Set<String>) -> [Datasource] {
        CallsListCoordinator
            .deriveState(realm: realm, enabledAccounts: enabledAccounts, filter: .all)
            .listDatasource
    }
    
    struct Datasource: DiffAware {
        
        var diffId: String {
            get {
                return messagePrimary
            }
        }
        
        let owner: String
        let jid: String
        let username: String
        let avatarUrl: String?
        let date: Date
        let direction: DisplayCallDirection
        let outgoing: Bool
        let messagePrimary: String
        let referencePrimary: String?
        
        static func compareContent(_ a: LastCallsViewController.Datasource, _ b: LastCallsViewController.Datasource) -> Bool {
            return a.owner == b.owner &&
                a.jid == b.jid &&
                a.username == b.username &&
                a.avatarUrl == b.avatarUrl &&
                a.date == b.date &&
                a.direction == b.direction &&
                a.outgoing == b.outgoing &&
                a.messagePrimary == b.messagePrimary &&
                a.referencePrimary == b.referencePrimary
            
        }
    }
    
    internal final var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    internal var calls: Results<MessageStorageItem>? = nil
    internal var displayNames: Results<RosterDisplayNameStorageItem>? = nil
    internal var enabledAccounts: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var filter: BehaviorRelay<CallsListFilter> = BehaviorRelay(value: .all)
    internal var filterMenu: UIMenu = UIMenu()
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var isCallHistoryLoaded: Bool = false
    
    internal var topAccountJid: String = ""
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        view.separatorStyle = .singleLine
        view.cellLayoutMarginsFollowReadableWidth = true
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 68
        view.applyContinuousSplitInsetGroupedAppearance()
        
        return view
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = SearchResultsViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search contacts and messages".localizeString(id: "contact_search_hint", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = true
        controller.definesPresentationContext = true

        return controller
    }()
    
    internal let addButton: UIBarButtonItem = {
//        let button = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
        let button = UIBarButtonItem(image: imageLiteral("phone.fill"), style: .done, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
    
    internal let accountNavButton: AccountNavButton = {
        let button = AccountNavButton(frame: CGRect(width: 64, height: 40))
        
        return button
    }()
    
    internal let customTitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: UIFont.Weight.medium)
        
        return label
    }()
    
    internal func updateTitle() {
        if AccountManager.shared.connectingUsers.value.isNotEmpty {
            customTitleLabel.text = "Connecting...".localizeString(id: "application_state_connecting", arguments: [])
            customTitleLabel.sizeToFit()
            customTitleLabel.layoutIfNeeded()
            return
        }
        customTitleLabel.text = "Calls".localizeString(id: "chat_calls_title", arguments: [])
        
        customTitleLabel.sizeToFit()
        customTitleLabel.layoutIfNeeded()
    }
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            enabledAccounts.accept(Self.enabledAccountJids(in: realm))
            displayNames = realm.objects(RosterDisplayNameStorageItem.self)
            calls = realm.objects(MessageStorageItem.self)
                .filter("owner IN %@ AND messageType == %@",
                        Array(enabledAccounts.value),
                        MessageStorageItem.MessageDisplayType.call.rawValue)
                .sorted(byKeyPath: "date", ascending: true)
        } catch {
            DDLogDebug("cant get list of last calls")
        }
    }

    internal func reloadCallDatasource() {
        do {
            let realm = try WRealm.safe()
            let accounts = Self.enabledAccountJids(in: realm)
            if enabledAccounts.value != accounts {
                enabledAccounts.accept(accounts)
            }
            let results = CallsListCoordinator
                .deriveState(realm: realm, enabledAccounts: accounts, filter: filter.value)
                .listDatasource
            applyCallDatasource(results)
            isCallHistoryLoaded = true
            refreshEmptyStateVisibility(callHistoryIsEmpty: results.isEmpty)
        } catch {
            DDLogDebug("LastCallsViewController: \(#function). \(error.localizedDescription)")
        }
    }

    internal func applyCallDatasource(_ results: [Datasource]) {
        let changes = diff(old: self.datasource, new: results)
        UIView.performWithoutAnimation {
            self.tableView.reload(
                changes: changes,
                section: 0,
                insertionAnimation: .none,
                deletionAnimation: .none,
                replacementAnimation: .none,
                updateData: {
                    self.datasource = results
                }
            ) { _ in }
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        do {
            let realm = try WRealm.safe()
            let accountsCollection = realm.objects(AccountStorageItem.self).filter("enabled == true")
            let callMessagesCollection = realm.objects(MessageStorageItem.self).filter(
                "messageType == %@ AND isDeleted == false",
                MessageStorageItem.MessageDisplayType.call.rawValue
            )
            let rosterCollection = realm.objects(RosterStorageItem.self)
            
            Observable
                .collection(from: realm
                    .objects(AccountStorageItem.self)
                    .filter("enabled == true")
                    .sorted(byKeyPath: "order", ascending: true))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.topAccountJid = item.jid
                        self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                        LeftMenuFirstPresentationPolicy.animate(
                            withDuration: 0.1,
                            isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
                        ) {
                            self.customTitleLabel.textColor = AccountColorManager.shared.topColor()
                            self.addButton.tintColor = AccountColorManager.shared.topColor()
                        }
                    }
                }).disposed(by: bag)
            
            AccountManager
                .shared
                .connectingUsers
                .asObservable()
                .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    DispatchQueue.main.async {
                        self.updateTitle()
                    }
                })
                .disposed(by: bag)
            filter
                .asObservable()
                .distinctUntilChanged()
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] _ in
                    self?.reloadCallDatasource()
                    self?.configureBars()
                })
                .disposed(by: bag)
            Observable
                .merge([
                    Observable.collection(from: accountsCollection).map { _ in () },
                    Observable.collection(from: callMessagesCollection).map { _ in () },
                    Observable.collection(from: rosterCollection).map { _ in () }
                ])
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.reloadCallDatasource()
                } onError: { _ in

                } onCompleted: {

                } onDisposed: {

                }
                .disposed(by: bag)

            reloadCallDatasource()
            
            isEmptyViewShowed
                .asObservable()
                .subscribe(onNext: { (value) in
                    self.emptyView.isHidden = !value
                })
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("LastCallsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    private final func showAddDialog() {
        let vc = NewCallViewController()
        showModal(vc, parent: self)
    }

    internal func openAddContactFlow() {
        let vc = CreateNewEntityViewController()
        vc.leftMenuSelectRootCategoryDelegate = leftMenuDelegate
        showModal(vc, parent: self)
    }

    internal final func refreshEmptyStateVisibility(isSearchActive: Bool? = nil, callHistoryIsEmpty: Bool? = nil) {
        let hasCallableContacts: Bool
        do {
            hasCallableContacts = Self.hasCallableContacts(in: try WRealm.safe(), enabledAccounts: enabledAccounts.value)
        } catch {
            hasCallableContacts = false
        }

        let descriptor = Self.emptyStateDescriptor(
            hasResolvedSnapshot: enabledAccounts.value.isNotEmpty,
            isLoading: !isCallHistoryLoaded,
            isSearchActive: isSearchActive ?? searchController.isActive,
            callHistoryIsEmpty: callHistoryIsEmpty ?? datasource.isEmpty,
            hasCallableContacts: hasCallableContacts
        )

        if let descriptor = descriptor {
            emptyView.accessibilityIdentifier = "calls_empty_view"
            emptyView.configure(descriptor: descriptor) { [weak self] in
                self?.performEmptyStateAction(descriptor.action)
            }
        }

        let shouldShowEmptyState = descriptor != nil
        if isEmptyViewShowed.value != shouldShowEmptyState {
            isEmptyViewShowed.accept(shouldShowEmptyState)
        }
        emptyView.isHidden = !shouldShowEmptyState
    }

    private final func performEmptyStateAction(_ action: CoreListEmptyStateAction?) {
        switch action {
        case .startCall:
            showAddDialog()
        case .addContact:
            openAddContactFlow()
        case .createPublicGroup, .none:
            break
        }
    }
    
    @objc
    internal func onAddButtonPress(_ sender: UIBarButtonItem) {
        showAddDialog()
    }
    
    @objc
    internal func onAccountNavButtonPress(_ sender: UIButton) {
        let vc = SettingsViewController() //AccountInfoViewController()
        vc.jid = self.topAccountJid
        showModal(vc, parent: self)
    }
    
//    private final func configureNavbar() {
//        addButton.target = self
//        addButton.action = #selector(onAddButtonPress)
//        
//        navigationItem.setRightBarButton(addButton,
//                                         animated: true)
//        let leftButton = UIBarButtonItem(customView: accountNavButton)
//        accountNavButton.addTarget(self, action: #selector(onAccountNavButtonPress), for: .touchUpInside)
//        navigationItem.setLeftBarButton(leftButton, animated: true)
//        customTitleLabel.textColor = AccountColorManager.shared.topColor()
//        self.navigationItem.titleView = customTitleLabel
//    }
    
    internal let bottomBar: BottomBarView = {
        let view = BottomBarView(frame: .zero)
        
        return view
    }()
    
    @objc
    private func onSidebarButtonTouchUp(_ sender: UIBarButtonItem) {
        self.splitViewController?.show(.primary)
    }
    
    internal final func showRegisterYubikeyDialog() {
        if SignatureManager.shared.certificate != nil {
            let vc = YubikeySetupViewController()
            vc.isFromOnboarding = false
            vc.isModal = true
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            SignatureManager.shared.delegate = self
            FeedbackManager.shared.tap()
            if #available(iOS 13.0, *) {
                if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                    YubiKitExternalLocalization.nfcScanAlertMessage = "Register Yubikey for account"
                    YubiKitManager.shared.startNFCConnection()
                    YubiKitManager.shared.delegate = SignatureManager.shared
                    SignatureManager.shared.currentAction = .certificate
                }
            }
        }
    }
    
    @objc
    internal func onRegisterYubikey() {
        showRegisterYubikeyDialog()
    }

    internal func makeCallsFilterMenu() -> UIMenu {
        let actions = CallsListFilter.visibleCategoryCases.map { item in
            UIAction(
                title: item.title,
                image: imageLiteral(item.iconName),
                identifier: UIAction.Identifier(rawValue: "calls.filter.\(item.rawValue)"),
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == item ? .on : .off,
                handler: { [weak self] _ in
                    self?.shouldFilterBy(category: item.rawValue)
                }
            )
        }
        filterMenu = UIMenu(options: [.singleSelection], children: actions)
        return filterMenu
    }

    internal func makeCallsFilterButton() -> UIBarButtonItem {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: nil)
        button.accessibilityIdentifier = "calls_filter_menu_button"
        button.menu = makeCallsFilterMenu()
        return button
    }

    private func makeCallsBackButton() -> UIBarButtonItem {
        let button = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
        button.accessibilityIdentifier = "calls_back_to_chats_button"
        return button
    }
    
    internal func configureBars(animated: Bool = false) {
        self.title = "Calls".localizeString(id: "chat_calls_title", arguments: [])
//        if CommonConfigManager.shared.config.use_large_title {
//            self.navigationItem.largeTitleDisplayMode = .automatic
//        } else {
            self.navigationItem.largeTitleDisplayMode = .never
//        }
        self.navigationController?.navigationBar.prefersLargeTitles = false//CommonConfigManager.shared.config.use_large_title
        if #available(iOS 16.0, *) {
            self.navigationItem.preferredSearchBarPlacement = .stacked
        }
        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                let filterBarButton = makeCallsFilterButton()
                let addBarButton = UIBarButtonItem(
                    image: UIImage(systemName: "plus")?
                        .upscale(dimension: 24)
                        .withRenderingMode(.alwaysTemplate),
                    style: .done,
                    target: self,
                    action: #selector(onAddButtonTouchUpInside)
                )
                if CommonConfigManager.shared.config.use_yubikey {
                    self.navigationItem.setRightBarButtonItems([addBarButton, securityButton], animated: animated)
                } else {
                    self.navigationItem.setRightBarButtonItems([addBarButton], animated: animated)
                }
                let leftBarButton = UIBarButtonItem(customView: accountNavButton)
                self.navigationItem.setLeftBarButtonItems([filterBarButton, leftBarButton], animated: animated)
                accountNavButton.removeTarget(self, action: #selector(showSettings), for: .touchUpInside)
                accountNavButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            case .split:
                self.bottomBar.splitViewController = self.splitViewController
                if bottomBar.superview == nil {
                    self.view.addSubview(bottomBar)
                }
                self.view.bringSubviewToFront(bottomBar)
                var inputHeight: CGFloat = 49
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
                
                let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                bottomBar.updateFrame(to: frame)
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
//                let sidebarButton = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: self, action: #selector(onSidebarButtonTouchUp))
                
//                if UIDevice.current.userInterfaceIdiom != .pad {
//                    self.navigationItem.setHidesBackButton(true, animated: false)
//                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
//                }
                if UIDevice.current.userInterfaceIdiom != .pad {
                    navigationItem.setHidesBackButton(true, animated: false)
                    navigationItem.setLeftBarButton(makeCallsBackButton(), animated: animated)
                    navigationItem.setRightBarButton(makeCallsFilterButton(), animated: animated)
                } else {
                    navigationItem.setLeftBarButtonItems([], animated: animated)
                    navigationItem.setRightBarButtonItems([], animated: animated)
                }
                self.bottomBar.isHidden = true
        }
    }
    
    internal let securityButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "security"), style: UIBarButtonItem.Style.plain, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
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
        showModal(vc, parent: self)
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        bottomBar.updateFrame(to: frame)
    }
    
    internal func configure() {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        tableView.dataSource = self
        tableView.delegate = self
        
        emptyView.isHidden = true
        emptyView.backgroundColor = ContinuousSplitBackgroundExperiment.isActive ? .clear : .systemBackground
        emptyView.isOpaque = !ContinuousSplitBackgroundExperiment.isActive
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
        
//        navigationController?
//            .navigationBar
//            .titleTextAttributes = [NSAttributedString.Key.foregroundColor: AccountColorManager.shared.topColor()]
        title = "Calls".localizeString(id: "chat_calls_title", arguments: [])
        
        do {
            let realm = try WRealm.safe()
            enabledAccounts
                .accept(Set(realm.objects(AccountStorageItem.self)
                    .filter("enabled == %@", true).compactMap { return $0.jid }))
            
            if let item = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
                .first {
                self.accountNavButton.update(jid: item.jid, status: item.resource?.status ?? .offline)
            }
            
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        configureBars(animated: false)
//        configureNavbar()
//        configureSearchBar()
        load()
        activateConstraints()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        self.title = "Calls".localizeString(id: "chat_calls_title", arguments: [])
//        if CommonConfigManager.shared.config.use_large_title {
//            self.navigationItem.largeTitleDisplayMode = .automatic
//        } else {
            self.navigationItem.largeTitleDisplayMode = .never
//        }
        self.navigationController?.navigationBar.prefersLargeTitles = false//CommonConfigManager.shared.config.use_large_title
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        configureBars(animated: false)
        NotifyManager.shared.setLastChats(displayed: false)
        
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        if SignatureManager.shared.certificate != nil {
            self.securityButton.tintColor = .systemGreen
        } else {
            self.securityButton.tintColor = .systemRed
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(
                at: selected,
                animated: LeftMenuFirstPresentationPolicy.shouldAnimate(
                    requested: true,
                    isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
                )
            )
        }
        
        
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
        self.navigationController?.navigationBar.layoutIfNeeded()
        completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endLeftMenuFirstPresentationQuietMode()
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}

extension LastCallsViewController: CallsControllerFilterProtocol {
    func shouldFilterBy(category: String?) {
        guard let category,
              let value = CallsListFilter(rawValue: category) else {
            filter.accept(.all)
            return
        }
        filter.accept(value)
    }
}
