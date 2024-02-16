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
import XMPPFramework
import CocoaLumberjack
import TOInsetGroupedTableView
import SwiftUI

class AccountInfoViewController: BaseViewController {
    
    class Datasource {
        enum Kind {
            case text
            case status
            case resource
            case button
            case storage
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var key: String?
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, subtitle: String? = nil, key: String? = nil, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            if subtitle?.isEmpty ?? true {
                self.subtitle = nil
            } else {
                self.subtitle = subtitle
            }
            self.key = key
            self.childs = childs
        }
    }
    
    class TokensDatasource {
        enum Kind {
            case current
            case token
            case button
            case text
        }
        
        var kind: Kind
        var title: String
        var value: String
        var date: Date
        var status: ResourceStatus
        var editable: Bool
        var current: Bool
        var childs: [TokensDatasource]
        
        init(_ kind: Kind, title: String, value: String = "", date: Date = Date(), status: ResourceStatus = .offline, current: Bool = false, editable: Bool, childs: [TokensDatasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.date = date
            self.current = current
            self.editable = editable
            self.childs = childs
        }
    }
    
//    open var jid: String = ""
    open var isModal: Bool = false
    
//    var headerHeightMax: CGFloat = 206//236//256
//    var headerHeightMin: CGFloat = 112//156
    
    var scrollViewContentOffsetYCopy: CGFloat = 0
    var headerHeightMax: CGFloat = 254//214//264
    var headerHeightMin: CGFloat = 0//120//150
    
    var quota: String = ""
    var used: String = ""
    
    internal let refreshControl: UIRefreshControl = {
        let view = UIRefreshControl()
        
        return view
    }()
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
                
        return view
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        view.register(QuotaInfoCell.self, forCellReuseIdentifier: QuotaInfoCell.cellName)
        
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        view.register(CenterButtonTableViewCell.self, forCellReuseIdentifier: CenterButtonTableViewCell.cellName)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsItem")
        view.register(SettingsItemDetailViewController.SelectorCell.self, forCellReuseIdentifier: SettingsItemDetailViewController.SelectorCell.cellName)
        
        return view
    }()
    
//    let stateSwitch: UISwitch = {
//        let view = UISwitch()
//        
//        return view
//    }()
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var headerConstraintSet: NSLayoutConstraintSet? = nil
    
    internal var tokensDatasource: [TokensDatasource] = []
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var tokens: Results<DeviceStorageItem>? = nil
    internal var currentToken: String = ""
    internal var tokenInstance: DeviceStorageItem? = nil
    
    //internal var settingsDatasource: [SettingsViewController.Datasource] = []
    //internal var datasource: [Datasource] = []
    internal var datasource: [SettingsViewController.Datasource] = []
    internal var resources: Results<ResourceStorageItem>? = nil
    
    internal var sessionsCount: Int = 0
    internal var blockedContactsCount: Int = 0
    internal var groupchatInvitationsCount: Int = 0
    
    internal var nickname: String = ""
    
    internal var currentResource: String? = nil
    
    func loadTokens() {
        do {
            let realm = try Realm()
            account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) ?? AccountStorageItem()
            currentToken = account.xTokenUID
            tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid != %@", jid, currentToken).sorted(byKeyPath: "authDate", ascending: false)
            tokenInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: currentToken, owner: self.jid))
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func updateTokensDatasorce() {
        tokensDatasource = [TokensDatasource(.current,
                                 title: "This device".localizeString(id: "settings_account__label_current_session", arguments: []),
                                 value: "Logs out all devices except this one.".localizeString(id: "settings_account_label_log_out_all", arguments: []),
                                 editable: false,
                                 childs: [TokensDatasource(.token,
                                                     title: " ",
                                                     value: account.resource?.resource ?? "",
                                                     editable: false),
                                          TokensDatasource(.button, title: "Terminate all other sessions".localizeString(id: "account_terminate_all_sessions", arguments: []), editable: false)])
        ]
        if !(tokens?.isEmpty ?? true) {
            tokensDatasource.append(TokensDatasource(.token,
                                         title: "Active sessions".localizeString(id: "settings_account__label_active_sessions", arguments: []),
                                         value: "You can terminate sessions you don`t need. Official Clandestino clients wipe all user data from the device upon session termination.".localizeString(id: "account_settings_terminate_description", arguments: []), /* learn more - https://www.xabber.com/devicemanagement/   */
                       editable: false,
                       childs: []))
        }
        
        tokensDatasource.append(TokensDatasource(.text,
                                                 title: " ",
                                                 editable: false,
                                                 childs: [TokensDatasource(.button, title: "Quit account".localizeString(id: "settings_account__button_quit_account", arguments: []), editable: false )]))
    }
    
    internal func updateDatasource() {
        datasource = []
        var profileChilds = [
            SettingsViewController.Datasource(section: .profile, title: "Profile", key: .accountVcard),
            SettingsViewController.Datasource(section: .profile, title: "Password"),
            SettingsViewController.Datasource(section: .profile, title: "Connection settings"),
            SettingsViewController.Datasource(section: .profile, title: "Account color", key: .accountColor),
            SettingsViewController.Datasource(section: .profile, title: "Blocked contacts", key: .accountBlockedContacts),
            SettingsViewController.Datasource(section: .profile, title: "Circles")
        ]
        if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
            profileChilds = [
                SettingsViewController.Datasource(section: .profile, title: "Profile", key: .accountVcard),
                SettingsViewController.Datasource(section: .profile, title: "Password"),
                SettingsViewController.Datasource(section: .profile, title: "Connection settings"),
                SettingsViewController.Datasource(section: .profile, title: "Blocked contacts", key: .accountBlockedContacts),
                SettingsViewController.Datasource(section: .profile, title: "Circles")
            ]
        }
        self.datasource.append(SettingsViewController.Datasource(section: .accountSettings, childs: [
                SettingsViewController.Datasource(section: .accountSettings, title: "Profile, status, password", viewController: SimpleTableViewController.self, childs: [
                    SettingsViewController.Datasource(section: .status, childs: [
                        SettingsViewController.Datasource(section: .status, title: SettingsViewController.Datasource.Section.status.description(), current: "Offline", key: .accountStatus)
                    ]),
                    SettingsViewController.Datasource(section: .profile, childs: profileChilds),
                    SettingsViewController.Datasource(section: .server, childs: [
                        SettingsViewController.Datasource(section: .server, title: "Server information")
                    ]),
                ]),
                SettingsViewController.Datasource(section: .accountSettings, title: "Cloud storage", key: .manageStorage),
//                SettingsViewController.Datasource(section: .accountSettings, title: "Encryption and keys", key: "account_encryption")
                SettingsViewController.Datasource(section: .accountSettings, title: "Devices", key: .accountSessions)
            ]))
    }
    
    
    internal func subscribe() {
        
        //datasource = []
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            
            if AccountManager.shared.find(for: self.jid) != nil {
                //self.stateSwitch.isOn = true
            } else {
                //self.stateSwitch.isOn = false
            }
            
            resources = realm
                .objects(ResourceStorageItem.self)
                .filter("owner == %@ AND jid == %@", jid, jid)
                .sorted(by: [
                    SortDescriptor(keyPath: "isCurrentResourceForAccount", ascending: false),
                    SortDescriptor(keyPath: "timestamp", ascending: false)
                ])
            
            if tokens != nil {
                Observable
                    .changeset(from: tokens!)
                    .subscribe(onNext: { (results) in
                        self.loadTokens()
                        self.updateTokensDatasorce()
                        self.tableView.reloadData()
                    })
                    .disposed(by: bag)
            }
            
            Observable
                .collection(from: realm
                    .objects(AccountStorageItem.self)
                    .filter("jid == %@", jid))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.nickname = item.username
                        
                        if item.enabled {
                            self.currentResource = item.resource?.resource
                        } else {
                            self.currentResource = nil
                        }
                        self.headerView.configure(
                            avatarUrl: item.avatarMaxUrl ?? item.avatarMinUrl ?? item.oldschoolAvatarKey,
                            jid: self.jid,
                            owner: self.jid,
                            userId: nil,
                            title: self.nickname,
                            subtitle: self.jid,
                            thirdLine: nil,
                            titleColor: AccountColorManager.shared.primaryColor(for: self.jid)
                        )
                        self.updateDatasource()
                    } else {
                        self.nickname = XMPPJID(string: self.jid)?.user ?? self.jid
                    }
                    
                    
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm.objects(BlockStorageItem.self)
                    .filter("owner == %@", self.jid))
                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if results.isEmpty {
                        self.groupchatInvitationsCount = 0
                        self.blockedContactsCount = 0
                    } else {
                        self.groupchatInvitationsCount = results
                            .compactMap({ return XMPPJID(string: $0.jid)?.resource })
                            .compactMap({ return TimeInterval($0) })
                            .count
                        self.blockedContactsCount = results.count - self.groupchatInvitationsCount
                    }
                    DispatchQueue.main.async {
                        if self.datasource.count > 3 {
                            let section = self.datasource.count - 3
                            self.tableView.reloadRows(at: [IndexPath(row: 0, section: section)],
                                                      with: .none)
                        }
                    }
                }).disposed(by: bag)
        } catch {
            DDLogDebug("AccountInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
//    func updateQuotaInfo() {
//        guard let cell = tableView.cellForRow(at: IndexPath.init(row: 0, section: 2)) as? QuotaInfoCell else { return }
//        cell.reloadData() {
//            self.tableView.reloadRows(at: [IndexPath.init(row: 0, section: 0)], with: .fade)
//        }
//    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            tableView.leftAnchor.constraint(equalTo: view.leftAnchor),
            tableView.rightAnchor.constraint(equalTo: view.rightAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    internal func configure() {
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        navigationBarButtonsConfigure()
        updateDatasource()
        view.addSubview(tableView)
        tableView.delegate = self
        tableView.dataSource = self

//        headerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: headerHeightMax)
//        view.addSubview(headerView)
//        tableView.contentInset = UIEdgeInsets(top: headerHeightMax - 70, bottom: 0, left: 0, right: 0)//Was: headerHeightMax - 64
//        tableView.setContentOffset(CGPoint(x: 0, y: -headerHeightMax), animated: true)
//        headerView.delegate = self
//        headerView.buttonsStack.isHidden = true
        headerViewConfig()
        
        if isModal {
            navigationItem.setLeftBarButton(UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissScreen)), animated: true)
        }
        refreshControl.addTarget(self, action: #selector(onRefresh), for: .valueChanged)
        self.tableView.refreshControl = refreshControl
    }
    
    func headerViewConfig() {
        self.headerView.frame = CGRect(x: 0, y: -(scrollViewContentOffsetYCopy + headerHeightMax - 20), width: view.frame.width, height: headerHeightMax)
        self.view.addSubview(headerView)
        print(self.view.subviews.count)
        tableView.contentInset = UIEdgeInsets(top: headerHeightMax - 100, bottom: 0, left: 0, right: 0)
        tableView.setContentOffset(CGPoint(x: 0, y: -(headerHeightMax - 20)), animated: true)
        headerView.delegate = self
        headerView.buttonsStack.isHidden = true
    }
    
    open func configureTokens(for jid: String) {
        self.jid =  jid
        //view.addSubview(tableView)
        //tableView.fillSuperview()
        //tableView.delegate = self
        //tableView.dataSource = self
        //hideKeyboardWhenTappedAround()
        loadTokens()
        updateTokensDatasorce()
//        editButton = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(self.onEdit))
//        doneEditButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.onDoneEditing))
//        navigationItem.setRightBarButton(editButton, animated: true)
    }
    
    func navigationBarButtonsConfigure() {
        let qrCodeButton = UIBarButtonItem(image: #imageLiteral(resourceName: "qrcode").withRenderingMode(.alwaysTemplate),
                                       style: .plain,
                                       target: self,
                                       action: #selector(self.onQRCode))
        let paletteButton = UIBarButtonItem(image: #imageLiteral(resourceName: "palette").withRenderingMode(.alwaysTemplate),
                                       style: .plain,
                                       target: self,
                                       action: #selector(self.showAccountColorViewController))
        if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
            navigationItem.setRightBarButtonItems([qrCodeButton], animated: false)
        } else {
            navigationItem.setRightBarButtonItems([qrCodeButton, paletteButton], animated: false)
        } 
    }
    
    @objc
    internal func showAccountColorViewController() {
        let vc = AccountColorViewController()
        vc.isModal = true
        vc.configure(for: jid)
        if #available(iOS 13.0, *) {
            vc.modalPresentationStyle = .automatic
        } else {
            vc.modalPresentationStyle = .pageSheet
        }
        let nvc = UINavigationController(rootViewController: vc)
        nvc.modalPresentationStyle = .fullScreen
        nvc.modalTransitionStyle = .coverVertical
        self.definesPresentationContext = true
        self.present(nvc, animated: true, completion: nil)
    }
    
    private func getQuota() {
        do {
            let realm = try WRealm.safe()
            guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
                                               forPrimaryKey: self.jid) else { return }
            self.quota = quotaItem.quota
            self.used = quotaItem.total
        } catch {
            DDLogDebug("AccountInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                print(topOffset)
                headerHeightMax += topOffset
                headerHeightMin += topOffset
            }
        }
        configure()
        activateConstraints()
        title = " "
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        //subscribe()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        headerView.setMask()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        getQuota()
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        XMPPUIActionManager.shared.open(owner: self.jid)
        self.tableView.reloadData()
        
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
            session.devices?.requestList(stream)
            session.blocked?.requestBlocklist(stream)
            session.vcardManager?.requestItem(stream, jid: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.jid)?.action({ (user, stream) in
                user.xTokens.requestList(stream)
                user.blocked.requestBlocklist(stream)
                user.vcards.requestItem(stream, jid: self.jid)
            })
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
//        if !isModal {
//            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//            navigationController?.navigationBar.shadowImage = nil
//        }
        getAppTabBar()?.updateColor()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @objc
    internal func dismissScreen() {
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    internal func onRefresh(_ sender: AnyObject) {
        print("sssssssssss")
    }
}
