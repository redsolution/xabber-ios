////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import UIKit
//import RealmSwift
//import RxRealm
//import RxSwift
//import RxCocoa
//import XMPPFramework
//import CocoaLumberjack
//import TOInsetGroupedTableView
//
//class _AccountInfoViewController: BaseViewController {
//    
//    class Datasource {
//        enum Kind {
//            case text
//            case status
//            case resource
//            case button
//            case storage
//        }
//        
//        var kind: Kind
//        var title: String
//        var subtitle: String?
//        var key: String?
//        
//        var childs: [Datasource]
//        
//        init(_ kind: Kind, title: String, subtitle: String? = nil, key: String? = nil, childs: [Datasource] = []) {
//            self.kind = kind
//            self.title = title
//            if subtitle?.isEmpty ?? true {
//                self.subtitle = nil
//            } else {
//                self.subtitle = subtitle
//            }
//            self.key = key
//            self.childs = childs
//        }
//    }
//    
////    open var jid: String = ""
//    open var isModal: Bool = false
//    
////    var headerHeightMax: CGFloat = 206//236//256
////    var headerHeightMin: CGFloat = 112//156
//    
//    var headerHeightMax: CGFloat = 214//264
//    var headerHeightMin: CGFloat = 120//150
//    
//    var quota: String = ""
//    var used: String = ""
//    
//    internal let refreshControl: UIRefreshControl = {
//        let view = UIRefreshControl()
//        
//        return view
//    }()
//    
//    internal let headerView: InfoScreenHeaderView = {
//        let view = InfoScreenHeaderView(frame: .zero)
//                
//        return view
//    }()
//    
//    internal let tableView: UITableView = {
////        let view = UITableView(frame: .zero, style: .grouped)
//        let view = InsetGroupedTableView(frame: .zero)
//        
//        view.translatesAutoresizingMaskIntoConstraints = false
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
//        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
//        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
//        view.register(QuotaInfoCell.self, forCellReuseIdentifier: QuotaInfoCell.cellName)
//        
//        return view
//    }()
//    
//    let stateSwitch: UISwitch = {
//        let view = UISwitch()
//        
//        return view
//    }()
//    
//    internal var bag: DisposeBag = DisposeBag()
//    
//    internal var headerConstraintSet: NSLayoutConstraintSet? = nil
//    
//    internal var datasource: [Datasource] = []
//    internal var resources: Results<ResourceStorageItem>? = nil
//    
//    internal var sessionsCount: Int = 0
//    internal var blockedContactsCount: Int = 0
//    internal var groupchatInvitationsCount: Int = 0
//    
//    internal var nickname: String = ""
//    
//    internal var currentResource: String? = nil
//    
//    internal func subscribe() {
//        
//        datasource = []
//        bag = DisposeBag()
//        do {
//            let realm = try Realm()
//            
//            if AccountManager.shared.find(for: self.jid) != nil {
//                self.stateSwitch.isOn = true
//            } else {
//                self.stateSwitch.isOn = false
//            }
//            
//            resources = realm
//                .objects(ResourceStorageItem.self)
//                .filter("owner == %@ AND jid == %@", jid, jid)
//                .sorted(by: [
//                    SortDescriptor(keyPath: "isCurrentResourceForAccount", ascending: false),
//                    SortDescriptor(keyPath: "timestamp", ascending: false)
//                ])
//            
//            Observable
//                .collection(from: realm
//                    .objects(AccountStorageItem.self)
//                    .filter("jid == %@", jid))
//                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    if let item = results.first {
//                        self.nickname = item.username
//                        self.datasource = []
//                        if item.enabled {
//                            self.currentResource = item.resource?.resource
//                        } else {
//                            self.currentResource = nil
//                        }
//                        self.datasource.append(Datasource(.status, title: "", key: "account_status", childs: [
//                            Datasource(.status, title: "", key: "account_status")
//                        ]))
//                        self.datasource.append(Datasource(.text, title: "Settings".localizeString(id: "settings", arguments: []), childs: [
//                            Datasource(.text, title: "Profile".localizeString(id: "contact_vcard_header_title", arguments: []), key: "account_vcard"),
////                            Datasource(.text, title: "Resource", subtitle: item.resource?.resource, key: "account_resource"),
//                            Datasource(.text, title: item.xTokenSupport ? "Devices".localizeString(id: "account_settings_devices", arguments: []) : "Password".localizeString(id: "account_password", arguments: []),
//                                       key: item.xTokenSupport ? "account_sessions" : "account_password"),
//                            Datasource(.text, title: "Account color".localizeString(id: "account_color", arguments: []), key: "account_color"),
////                            Datasource(.text, title: "Storage", key: "account_quota"),
//                        ]))
//                        
//                        self.datasource.append(Datasource(.storage , title: "Cloud storage".localizeString(id: "account_cloud_storage", arguments: []), childs: [
//                            Datasource(.storage, title: "Media Gallery".localizeString(id: "account_media_gallery", arguments: []), key: "account_quota"),
//                            Datasource(.text, title: "Manage storage".localizeString(id: "account_manage_storage", arguments: []), key: "manage_storage")
//                        ]))
//                                                
////                        if !(self.resources?.isEmpty ?? true) {
////                            self.datasource.append(Datasource(.resource, title: "Connected devices"))
////                        }
//                        self.datasource.append(Datasource(.text, title: "", subtitle: nil, childs: [
////                            Datasource(.text, title: "Group invitations", key: "account_groupchat_invitations"),
//                            Datasource(.text, title: "Blocked contacts".localizeString(id: "blocked_contacts", arguments: []), key: "account_blocked_contacts")
//                        ]))
//                        
//                        
//                        self.datasource.append(Datasource(.text, title: "", subtitle: nil, childs: [
//                            Datasource(.text, title: "Encryption".localizeString(id: "encryption", arguments: []), key: "account_encryption")
//                        ]))
//                        
//                        
//                        self.datasource.append(Datasource(.text, title: "", subtitle: nil, childs: [
//                            Datasource(.text, title: "YubiKey".localizeString(id: "yubikey", arguments: []), key: "account_yubikey")
//                        ]))
//                        
//                        
//                        self.datasource.append(Datasource(.text, title: "", childs: [
//                            Datasource(.button, title: "Show QR-code".localizeString(id: "contact_settings__button_show_qr_code", arguments: []), key: "qr_code")
//                        ]))
//                        
//                        self.datasource.append(Datasource(.text, title: "", childs: [
//                            Datasource(.button, title: "Quit account".localizeString(id: "settings_account__button_quit_account", arguments: []), key: "account_quit")
//                        ]))
//                    } else {
//                        self.nickname = XMPPJID(string: self.jid)?.user ?? self.jid
//                    }
//                    self.headerView.configure(
//                        jid: self.jid,
//                        owner: self.jid,
//                        userId: nil,
//                        title: self.nickname,
//                        subtitle: self.jid,
//                        thirdLine: nil,
//                        titleColor: AccountColorManager.shared.primaryColor(for: self.jid)
//                    )
//                }).disposed(by: bag)
//            
//            Observable
//                .changeset(from: resources!)
//                .debounce(.milliseconds(12), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    if results.0.isEmpty {
//                        if let index = self.datasource.firstIndex(where: { $0.kind == .resource }) {
//                            self.datasource.remove(at: index)
//                            if #available(iOS 11.0, *) {
//                                self.tableView.performBatchUpdates({
//                                    self.tableView.deleteSections(IndexSet([index]), with: .none)
//                                }, completion: nil)
//                            } else {
//                                self.tableView.beginUpdates()
//                                self.tableView.deleteSections(IndexSet([index]), with: .none)
//                                self.tableView.endUpdates()
//                            }
//                        }
//                    } else {
////                        var shouldInsertSection: Bool = false
////                        if !self.datasource.contains(where: { $0.kind == .resource }) {
////                            self.datasource.insert(Datasource(.resource, title: "Connected devices"), at: 2)
////                            shouldInsertSection = true
////                        }
////                        guard let changeset = results.1 else {
//                            self.tableView.reloadData()
////                            return
////                        }
//                        
////                        if #available(iOS 11.0, *) {
////                            self.tableView.performBatchUpdates({
////                                if shouldInsertSection {
////                                    self.tableView.insertSections(IndexSet([2]), with: .none)
////                                }
////                                self.tableView
////                                    .deleteRows(at: changeset
////                                        .deleted
////                                        .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                                self.tableView
////                                    .insertRows(at: changeset
////                                        .inserted
////                                        .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                                self.tableView
////                                    .reloadRows(at: changeset
////                                        .updated
////                                        .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                            }, completion: nil)
////                        } else {
////                            self.tableView.beginUpdates()
////                            if shouldInsertSection {
////                                self.tableView.insertSections(IndexSet([2]), with: .none)
////                            }
////                            if !self.datasource.contains(where: { $0.kind == .resource }) {
////                                self.datasource.insert(Datasource(.resource, title: "Connected devices"), at: 2)
////                                self.tableView.insertSections(IndexSet([2]), with: .none)
////                            }
////                            self.tableView
////                                .deleteRows(at: changeset
////                                    .deleted
////                                    .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                            self.tableView
////                                .insertRows(at: changeset
////                                    .inserted
////                                    .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                            self.tableView
////                                .reloadRows(at: changeset
////                                    .updated
////                                    .compactMap({ return IndexPath(row: $0, section: 2) }), with: .none)
////                            self.tableView.endUpdates()
////                        }
//                    }
//                }).disposed(by: bag)
//            
//            Observable.collection(from: realm.objects(BlockStorageItem.self)
//                    .filter("owner == %@", self.jid))
//                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    if results.isEmpty {
//                        self.groupchatInvitationsCount = 0
//                        self.blockedContactsCount = 0
//                    } else {
//                        self.groupchatInvitationsCount = results
//                            .compactMap({ return XMPPJID(string: $0.jid)?.resource })
//                            .compactMap({ return TimeInterval($0) })
//                            .count
//                        self.blockedContactsCount = results.count - self.groupchatInvitationsCount
//                    }
//                    DispatchQueue.main.async {
//                        if self.datasource.count > 3 {
//                            let section = self.datasource.count - 3
//                            self.tableView.reloadRows(at: [IndexPath(row: 0, section: section)],
//                                                      with: .none)
//                        }
//                    }
//                }).disposed(by: bag)
//            
//            Observable
//                .collection(from: realm.objects(DeviceStorageItem.self)
//                    .filter("owner == %@", self.jid))
//                .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    self.sessionsCount = results.count
//                    DispatchQueue.main.async {
//                        if self.datasource.isNotEmpty {
//                            let section = 1
//                            guard let row = self.datasource[section]
//                                .childs
//                                .firstIndex(where: { $0.key == "account_sessions" }) else { return }
//                            let indexPath = IndexPath(row: row, section: section)
//                            if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
//                                visibleIndexPaths.contains(indexPath) {
//                                self.tableView.reloadRows(at: [indexPath], with: .none)
//                            }
//                        }
//                    }
//                })
//                .disposed(by: bag)
//            
//        } catch {
//            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    func updateQuotaInfo() {
//        guard let cell = tableView.cellForRow(at: IndexPath.init(row: 0, section: 2)) as? QuotaInfoCell else { return }
//        cell.reloadData() {
//            self.tableView.reloadRows(at: [IndexPath.init(row: 0, section: 0)], with: .fade)
//        }
//    }
//    
//    internal func unsubscribe() {
//        bag = DisposeBag()
//    }
//    
//    internal func activateConstraints() {
//        NSLayoutConstraint.activate([
//            tableView.leftAnchor.constraint(equalTo: view.leftAnchor),
//            tableView.rightAnchor.constraint(equalTo: view.rightAnchor),
//            tableView.topAnchor.constraint(equalTo: view.topAnchor),
//            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
//        ])
//    }
//    
//    internal func configure() {
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
//        view.addSubview(tableView)
//        tableView.delegate = self
//        tableView.dataSource = self
//        if #available(iOS 11.0, *) {
//            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
//                headerHeightMax += topOffset
//                headerHeightMin += topOffset
//            }
//        }
//        headerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: headerHeightMax)
//        view.addSubview(headerView)
//        let barButton = UIBarButtonItem(customView: stateSwitch)
//        navigationItem.setRightBarButton(barButton, animated: true)
//        tableView.contentInset = UIEdgeInsets(top: headerHeightMax - 70, bottom: 0, left: 0, right: 0)//Was: headerHeightMax - 64
//        tableView.setContentOffset(CGPoint(x: 0, y: -headerHeightMax), animated: true)
//        headerView.delegate = self
//        headerView.buttonsStack.isHidden = true
//        stateSwitch.addTarget(self, action: #selector(onStateSwitchValueChanged), for: .valueChanged)
//        if isModal {
//            navigationItem.setLeftBarButton(UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissScreen)), animated: true)
//        }
//        refreshControl.addTarget(self, action: #selector(onRefresh), for: .valueChanged)
//        self.tableView.refreshControl = refreshControl
//    }
//    
//    private func getQuota() {
//        do {
//            let realm = try Realm()
//            guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
//                                               forPrimaryKey: self.jid) else { return }
//            self.quota = quotaItem.quota
//            self.used = quotaItem.used
//        } catch {
//            DDLogDebug("AccountInfoViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        configure()
//        activateConstraints()
//        title = " "
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
//        subscribe()
//        
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(reloadDatasource),
//                                               name: .newMaskSelected,
//                                               object: nil)
//    }
//    
//    override func reloadDatasource() {
//        headerView.setMask()
//    }
//    
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//        getQuota()
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
//        XMPPUIActionManager.shared.open(owner: self.jid)
//        self.tableView.reloadData()
//        
//        DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: jid, size: 128) { image in
//            self.headerView.imageButton.setImage(image, for: .normal)
//        }
//    }
//    
//    override func viewDidAppear(_ animated: Bool) {
//        super.viewDidAppear(animated)
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
//        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
//            session.devices?.requestList(stream)
//            session.blocked?.requestBlocklist(stream)
//            session.vcardManager?.requestItem(stream, jid: self.jid)
//        } fail: {
//            AccountManager.shared.find(for: self.jid)?.action({ (user, stream) in
//                user.xTokens.requestList(stream)
//                user.blocked.requestBlocklist(stream)
//                user.vcards.requestItem(stream, jid: self.jid)
//            })
//        }
//    }
//    
//    override func viewWillDisappear(_ animated: Bool) {
//        super.viewWillDisappear(animated)
//        unsubscribe()
//    }
//    
//    override func viewDidDisappear(_ animated: Bool) {
//        super.viewDidDisappear(animated)
////        if !isModal {
////            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////            navigationController?.navigationBar.shadowImage = nil
////        }
//        getAppTabBar()?.updateColor()
//    }
//    
//    override func didReceiveMemoryWarning() {
//        super.didReceiveMemoryWarning()
//    }
//    
//    @objc
//    internal func dismissScreen() {
//        self.dismiss(animated: true, completion: nil)
//    }
//    
//    @objc
//    internal func onRefresh(_ sender: AnyObject) {
//        print("sssssssssss")
//    }
//}
