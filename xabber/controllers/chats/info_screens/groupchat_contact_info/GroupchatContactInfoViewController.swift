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
import CocoaLumberjack
import TOInsetGroupedTableView

class GroupchatContactInfoViewController: BaseViewController {
    
    class Datasource {
        enum Kind {
            case text
            case selection
            case status
            case button
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var key: String?
        var disabled: Bool
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, subtitle: String? = nil, key: String? = nil, disabled: Bool = false, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            if subtitle?.isEmpty ?? true {
                self.subtitle = nil
            } else {
                self.subtitle = subtitle
            }
            self.key = key
            self.disabled = disabled
            self.childs = childs
        }
    }
    
    internal class FormDatasource {
        enum Kind {
            case boolItem
            case listItem
            case fixed
        }
        
        var kind: Kind
        
        var itemId: String
        var title: String
        var state: Bool
        var hasExpired: Bool
        var value: String?
        var payload: Any?
        var item: [String: Any]
        
        
        init(_ kind: Kind, itemId: String = "", title: String, state: Bool = false, hasExpired: Bool = false, value: String? = nil, payload: Any? = nil, item: [String: Any]) {
            self.kind = kind
            self.itemId = itemId
            self.title = title
            self.state = state
            self.hasExpired = hasExpired
            self.value = value
            self.payload = payload
            self.item = item
        }
    }
    
//    open var owner: String = ""
//    open var jid: String = ""
    open var userId: String = ""
    
    open var shouldResetNavbar: Bool = false
    
//    var headerHeightMax: CGFloat = 304//256
//    var headerHeightMin: CGFloat = 162//156
    
    var headerHeightMax: CGFloat = 274
    var headerHeightMin: CGFloat = 180//150
    
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
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        view.register(InfoCell.self, forCellReuseIdentifier: InfoCell.cellName)
        
        return view
    }()
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .save, target: nil, action: nil)
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var headerConstraintSet: NSLayoutConstraintSet? = nil
    
    internal var datasource: [Datasource] = []
    internal var formDatasource: [[FormDatasource]] = []
    
    internal var formId: String? = nil
    internal var updateFormId: String? = nil
    
    internal var formSectionTitles: [String] = []
    
    internal var about: [[String: Any]] = []
    internal var restrictions: [[String: Any]] = []
    internal var permissions: [[String: Any]] = []
    
    internal var form: [[String: Any]] = []
    internal var changedValues: BehaviorRelay<[[String: Any]]> = BehaviorRelay(value: [])
    
    internal var isIncognitoGroup: Bool = false
    internal var isMyProfile: Bool = false
    internal var canBlock: Bool = false
    internal var canChangeBadge: Bool = false
    internal var canChangeNickname: Bool = false
    internal var canChangeAvatars: Bool = false
    internal var canChangeUserPermissions: Bool? = nil
    internal var userRole: GroupchatUserStorageItem.Role = .member
    internal var userOnline: Bool = false
    internal var onlineCount: Int = 0
    internal var userBadge: String = ""
    internal var userNickname: String = ""
    
    internal var userJid: String? = nil
    
    internal var isBlocked: Bool = false
    internal var isKicked: Bool = false
    
    internal var callbackIds: Set<String> = Set<String>()
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)

    
    internal func subscribe() {
        datasource = []
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            
            Observable
                .collection(from: realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("owner == %@ AND userId == %@", owner, userId))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.userJid = item.jid.isNotEmpty ? item.jid : nil
                        var fullReload: Bool = false
                        var toReloadRows: Set<IndexPath> = Set<IndexPath>()
                        self.isBlocked = item.isBlocked
                        self.isKicked = item.isKicked
                        if self.datasource.isEmpty {
                            self.userRole = item.role
                            self.userOnline = item.isOnline
                            if !self.isKicked {
                                var set: [Datasource] = [
                                    Datasource(.text, title: "Role".localizeString(id: "vcard_role", arguments: []), key: "gcc_role")
                                ]
                                if item.badge.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
                                    set.append(Datasource(.text, title: "Badge".localizeString(id: "groupchat_member_badge", arguments: []), subtitle: item.badge.trimmingCharacters(in: .whitespacesAndNewlines), key: "gcc_badge"))
                                }
                                set.append(Datasource(.status, title: ""))
                                self.datasource.append(Datasource(.text, title: "", key: "gcc_status", childs: set))
                            }
                            fullReload = true
                        } else {
                            if self.userOnline != item.isOnline {
                                self.userOnline = item.isOnline
                                toReloadRows.insert(IndexPath(row: 0, section: 0))
                            }
                            if self.userRole != item.role {
                                self.userRole = item.role
                                toReloadRows.insert(IndexPath(row: 0, section: 1))
                            }
                        }
                        self.isMyProfile = item.isMe
                        self.userBadge = item.badge
                        self.userNickname = item.nickname
                        if fullReload {
                            self.tableView.reloadData()
                        } else {
                            if #available(iOS 11.0, *) {
                                if toReloadRows.isNotEmpty {
                                    UIView.performWithoutAnimation {
                                        self.tableView.performBatchUpdates({
                                            self.tableView.reloadRows(at: toReloadRows.sorted(), with: .none)
                                        }, completion: nil)
                                    }
                                }
                            } else {
                                if toReloadRows.isNotEmpty {
                                    UIView.performWithoutAnimation {
                                        self.tableView.beginUpdates()
                                        self.tableView.reloadRows(at: toReloadRows.sorted(), with: .none)
                                        self.tableView.endUpdates()
                                    }
                                }
                            }
                        }
                        
                    }
                    self.headerView.configure(
                        avatarUrl: nil,
                        jid: self.jid,
                        owner: self.owner,
                        userId: self.userId,
                        title: self.userNickname,
                        subtitle: self.userJid,
                        thirdLine: nil,
                        titleColor: AccountColorManager.shared.primaryColor(for: self.owner)
                    )
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm.objects(GroupChatStorageItem.self)
                    .filter("jid == %@ AND owner == %@", jid, owner))
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        
                        self.canChangeBadge = item.canChangeBadge
                        self.canChangeNickname = item.canChangeNicknames
                        self.canChangeAvatars = item.canChangeAvatars
                        
                        if self.isMyProfile {
                            if self.canChangeUserPermissions == nil {
                                self.canChangeUserPermissions = false
                                
                                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                    self.callbackIds.insert(
                                        session.groupchat?.requestMyRights(
                                            stream,
                                            groupchat: self.jid,
                                            callback: self.onReceiveForm
                                    ) ?? "")
                                }, fail: {
                                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                        self.callbackIds.insert(
                                            user.groupchats.requestMyRights(
                                                stream,
                                                groupchat: self.jid,
                                                callback: self.onReceiveForm
                                        ))
                                    })
                                })
                            }
                            DispatchQueue.main.async {
                                self.navigationItem.setRightBarButton(nil, animated: true)
                            }
                        } else {
                            if let value = self.canChangeUserPermissions {
                                if value != item.canChangeUsersSettings {
                                    self.canChangeUserPermissions = item.canChangeUsersSettings
                                    if item.canChangeUsersSettings {
                                        DispatchQueue.main.async {
                                            self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                                        }
                                        if !self.isBlocked,
                                            !self.isKicked {
                                            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                                self.callbackIds.insert(
                                                    session.groupchat?.requestEditUserForm(
                                                        stream,
                                                        groupchat: self.jid,
                                                        userId: self.userId,
                                                        callback: self.onReceiveForm
                                                ) ?? "")
                                            }, fail: {
                                                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                                    self.callbackIds.insert(
                                                        user.groupchats.requestEditUserForm(
                                                            stream,
                                                            groupchat: self.jid,
                                                            userId: self.userId,
                                                            callback: self.onReceiveForm
                                                    ))
                                                })
                                            })
                                        }
                                    } else {
                                        DispatchQueue.main.async {
                                            self.navigationItem.setRightBarButton(nil, animated: true)
                                        }
                                    }
                                }
                            } else {
                                self.canChangeUserPermissions = item.canChangeUsersSettings
                                if item.canChangeUsersSettings {
                                    DispatchQueue.main.async {
                                        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                                    }
                                    if !self.isBlocked,
                                        !self.isKicked {
                                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                            self.callbackIds.insert(
                                                session.groupchat?.requestEditUserForm(
                                                    stream,
                                                    groupchat: self.jid,
                                                    userId: self.userId,
                                                    callback: self.onReceiveForm
                                            ) ?? "")
                                        }, fail: {
                                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                                self.callbackIds.insert(
                                                    user.groupchats.requestEditUserForm(
                                                        stream,
                                                        groupchat: self.jid,
                                                        userId: self.userId,
                                                        callback: self.onReceiveForm
                                                ))
                                            })
                                        })
                                        
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        self.navigationItem.setRightBarButton(nil, animated: true)
                                    }
                                }
                            }
                        }
                        
                        if item.privacy == .incognito {
                            self.isIncognitoGroup = true
                            DispatchQueue.main.async {
                                self.headerView
                                    .firstButton
                                    .configure(#imageLiteral(resourceName: "group-private"),
                                               title: "Private chat".localizeString(id: "intro_private_chat", arguments: []),
                                               style: self.isMyProfile ? .inactive : .active)
                            }
                        } else {
                            self.isIncognitoGroup = false
                            DispatchQueue.main.async {
                                self.headerView
                                    .firstButton
                                    .configure(#imageLiteral(resourceName: "chat"),
                                               title: "Direct chat".localizeString(id: "groupchat_direct_chat", arguments: []),
                                               style: self.isMyProfile ? .inactive : .active)
                            }
                        }
                        if item.canChangeBadge {
                            DispatchQueue.main.async {
                                self.headerView.thirdButton.configure(#imageLiteral(resourceName: "badge"), title: "Set badge".localizeString(id: "groupchat_set_member_badge", arguments: []), style: .active)
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.headerView.thirdButton.configure(#imageLiteral(resourceName: "badge"), title: "Set badge".localizeString(id: "groupchat_set_member_badge", arguments: []), style: .inactive)
                            }
                        }
                        if item.canBlockUsers {
                            DispatchQueue.main.async {
                                if self.isBlocked {
                                    self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"), title: "Unblock".localizeString(id: "contact_bar_unblock", arguments: []), style: .danger)
                                } else if self.isKicked {
                                    self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"), title: "Block".localizeString(id: "contact_bar_block", arguments: []), style: .danger)
                                }  else {
                                    self.headerView.fourthButton.configure(#imageLiteral(resourceName: "kick"), title: "Kick".localizeString(id: "groupchat_kick", arguments: []), style: .danger)
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.headerView.fourthButton.configure(#imageLiteral(resourceName: "kick"), title: "Kick".localizeString(id: "groupchat_kick", arguments: []), style: .inactive)
                            }
                        }
                        
                        if item.present != self.onlineCount {
                            self.onlineCount = item.present
//                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                                user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
//                            })
                            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                session.groupchat?.requestUsers(stream, groupchat: self.jid, userId: self.userId)
                            }, fail: {
                                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                    user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
                                })
                            })
                        }
                        
                    }
                })
                .disposed(by: bag)
            
            saveButton.rx.tap
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (_) in
                    self.onSave()
                })
                .disposed(by: bag)
            
            changedValues
                .asObservable()
                .subscribe(onNext: { (values) in
                    let isEnabled = values.isNotEmpty
                    DispatchQueue.main.async {
                        self.saveButton.isEnabled = isEnabled
                    }
                })
                .disposed(by: bag)
            
            inSaveMode
                .asObservable()
                .subscribe(onNext: { (value) in
                    DispatchQueue.main.async {
                        self.tableView.isUserInteractionEnabled = !value
                        if value {
                            self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                        } else {
                            if (self.canChangeUserPermissions ?? false) {
                                self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                            } else {
                                self.navigationItem.setRightBarButton(nil, animated: true)
                            }
                        }
                    }
                })
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
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
        view.addSubview(tableView)
        tableView.delegate = self
        tableView.dataSource = self
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                headerHeightMax += topOffset
                headerHeightMin += topOffset
            }
        }
        headerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: headerHeightMax)
        view.addSubview(headerView)
        tableView.contentInset = UIEdgeInsets(top: headerHeightMax - 88, bottom: 0, left: 0, right: 0)
        tableView.setContentOffset(CGPoint(x: 0, y: -headerHeightMax), animated: true)
        headerView.delegate = self
        headerView.firstButton.configure(#imageLiteral(resourceName: "chat"), title: "Direct chat".localizeString(id: "groupchat_direct_chat", arguments: []), style: .active)
        headerView.secondButton.configure(#imageLiteral(resourceName: "messages"), title: "Messages".localizeString(id: "groupchat_member_messages", arguments: []), style: .active)
        headerView.thirdButton.configure(#imageLiteral(resourceName: "badge"), title: "Set badge".localizeString(id: "groupchat_set_member_badge", arguments: []), style: .active)
        headerView.fourthButton.configure(#imageLiteral(resourceName: "kick"), title: "Kick".localizeString(id: "groupchat_kick", arguments: []), style: .danger)
        
        saveButton.target = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        activateConstraints()
        title = " "
        
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
        getAppTabBar()?.hide()
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.requestUsers(stream, groupchat: self.jid, userId: self.userId)
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
            })
        })
        
        headerView.setMask()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        callbackIds.forEach {
            AccountManager.shared.find(for: owner)?.groupchats.invalidateCallback($0)
            XMPPUIActionManager.shared.groupchat?.invalidateCallback($0)
        }
        super.viewDidDisappear(animated)
        if shouldResetNavbar {
            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
            navigationController?.navigationBar.shadowImage = nil
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
