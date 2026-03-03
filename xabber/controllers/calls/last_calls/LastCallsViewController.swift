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

class LastCallsViewController: BaseViewController {
    
    struct Datasource: DiffAware {
        
        var diffId: String {
            get {
                return [jid, owner].prp()
            }
        }
        
        let owner: String
        let jid: String
        let username: String
        let body: String
        let date: Date
        let outgoing: Bool
        let state: MessageStorageItem.VoIPCallState
        let duration: TimeInterval
        
        static func compareContent(_ a: LastCallsViewController.Datasource, _ b: LastCallsViewController.Datasource) -> Bool {
            return a.owner == b.owner &&
                a.jid == b.jid &&
                a.username == b.username &&
                a.body == b.body &&
                a.date == b.date &&
                a.outgoing == b.outgoing &&
                a.state == b.state &&
                a.duration == b.duration
            
        }
    }
    
    internal final var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    internal var calls: Results<MessageStorageItem>? = nil
    internal var displayNames: Results<RosterDisplayNameStorageItem>? = nil
    internal var enabledAccounts: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var topAccountJid: String = ""
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.backgroundColor = .white
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        
        view.tableFooterView = UIView(frame: .zero)
        
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
    
    internal func subscribe() {
        bag = DisposeBag()
        
        do {
            let realm = try WRealm.safe()
            
            Observable
                .collection(from: realm.objects(AccountStorageItem.self).filter("enabled == %@", true))
                .subscribe(onNext: { (results) in
                    let jids: [String] = results.compactMap{ return $0.jid }
                    if jids.count != self.enabledAccounts.value.count {
                        self.enabledAccounts.accept(Set(jids))
                    }
                })
                .disposed(by: bag)
            
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
                        UIView.animate(withDuration: 0.1) {
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
            
            Observable
                .collection(from: realm
                    .objects(MessageStorageItem.self)
                    .filter("owner IN %@ AND messageType == %@",
                            Array(enabledAccounts.value),
                            MessageStorageItem.MessageDisplayType.call.rawValue)
                    .sorted(byKeyPath: "date", ascending: false))
//                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .map { (results) -> [Datasource] in
                    return Array(results.compactMap {
                        item in
                        var name: String = item.opponent
                        do {
                            let realm = try WRealm.safe()
                            name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: item.opponent, owner: item.owner))?.displayName ?? item.opponent
                        } catch {
                            DDLogDebug("LastCallsViewController: \(#function). \(error.localizedDescription)")
                        }
//                        let name = self.displayNames?.first(where: { $0.primary == RosterDisplayNameStorageItem.genPrimary(jid: item.opponent, owner: item.owner) })?.displayName ?? item.opponent
                        let stateUnwr = (item.callMetadata?["callState"] as? String) ?? ""
                        let duration = item.callMetadata?["duration"] as? TimeInterval ?? 0
                        
                        return Datasource(
                            owner: item.owner,
                            jid: item.opponent,
                            username: name,
                            body: item.displayedBody(),
                            date: item.date,
                            outgoing: item.outgoing,
                            state: MessageStorageItem.VoIPCallState(rawValue: stateUnwr) ?? .none,
                            duration: duration
                        )
                    }.prefix(50))
                }
                .subscribe { (results) in
                    if results.isEmpty {
                        if !self.isEmptyViewShowed.value {
                            self.isEmptyViewShowed.accept(true)
                        }
                    } else {
                        if self.isEmptyViewShowed.value {
                            self.isEmptyViewShowed.accept(false)
                        }
                    }
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
                        }) { (result) in
                            
                        }
                    }
                   
                } onError: { (error) in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: bag)

            
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
    
    internal func configureBars() {
        self.title = "Calls"
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
                let addBarButton = UIBarButtonItem(
                    image: UIImage(systemName: "plus")?
                        .upscale(dimension: 24)
                        .withRenderingMode(.alwaysTemplate),
                    style: .done,
                    target: self,
                    action: #selector(onAddButtonTouchUpInside)
                )
                if CommonConfigManager.shared.config.use_yubikey {
                    self.navigationItem.setRightBarButtonItems([addBarButton, securityButton], animated: true)
                } else {
                    self.navigationItem.setRightBarButtonItems([addBarButton], animated: true)
                }
                let leftBarButton = UIBarButtonItem(customView: accountNavButton)
                self.navigationItem.setLeftBarButton(leftBarButton, animated: true)
                accountNavButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            case .split:
                self.bottomBar.splitViewController = self.splitViewController
                self.view.addSubview(bottomBar)
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
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        
        emptyView.configure(image: (UIImage(systemName: "phone")?.upscale(dimension: 160).withRenderingMode(.alwaysTemplate))!,
                            title: "Under construction",
                            subtitle: "",
                            buttonTitle: "Make a call".localizeString(id: "chat_make_call_hint", arguments: [])) {
            self.showAddDialog()
            
        }
        emptyView.isHidden = true
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
//        configureNavbar()
//        configureSearchBar()
        load()
        activateConstraints()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        let backButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
        self.navigationItem.setLeftBarButton(backButton, animated: false)
        self.title = "Calls"
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
        configureBars()
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
            tableView.deselectRow(at: selected, animated: true)
        }
        
        
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
        self.navigationController?.navigationBar.layoutIfNeeded()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
