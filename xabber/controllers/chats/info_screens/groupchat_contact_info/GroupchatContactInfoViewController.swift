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

class GroupchatContactInfoViewController: SimpleBaseViewController {
    
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
    
    open var userId: String = ""
    
    open var shouldResetNavbar: Bool = false
    
    var headerHeightMax: CGFloat = 188
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
                
        return view
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
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
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
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
    
    internal let lastSeenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        
        return formatter
    }()
    
    override func loadDatasource() {
        super.loadDatasource()
        datasource = []
        do {
            let realm = try WRealm.safe()
            
            Observable
                .collection(from: realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("owner == %@ AND userId == %@", owner, userId))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    var lastSeen: Date? = nil
                    var avatarUrl: String? = nil
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
                        avatarUrl = item.avatarURI
                        self.isMyProfile = item.isMe
                        lastSeen = item.lastSeen
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
                    
                    if let date = lastSeen {
                        let today = Date()
                        if abs(today.timeIntervalSince(date)) < 60 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen just now'"
                                .localizeString(id: "chat_seen_just_now", arguments: [])
                        } else if abs(today.timeIntervalSince(date)) < 60 * 60 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen \(Int(abs(today.timeIntervalSince(date)) / 60)) minutes ago'"
                                .localizeString(id: "chat_seen_minutes_ago",
                                                arguments: ["\(Int(abs(today.timeIntervalSince(date)) / 60))"])
                        } else if abs(today.timeIntervalSince(date)) < 2 * 60 * 60 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen an hour ago '"
                                .localizeString(id: "chat_seen_hour_ago", arguments: [])
                        } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen at 'HH:mm"
                                .localizeString(id: "chat_seen_at", arguments: [])
                        } else if abs(today.timeIntervalSince(date)) < 24 * 60 * 60 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen yesterday at 'HH:mm"
                                .localizeString(id: "chat_seen_yesterday", arguments: [])
                        }  else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen on 'E' at 'HH:mm"
                                .localizeString(id: "chat_seen_date_time", arguments: [])
                        } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                            self.lastSeenDateFormatter.dateFormat = "'last seen 'dd MMM"
                                .localizeString(id: "chat_seen_date", arguments: [])
                        } else {
                            self.lastSeenDateFormatter.dateFormat = "'last seen 'd MMM yyyy"
                                .localizeString(id: "chat_seen_date_year", arguments: [])
                        }
                    }
                    
                    let offlineString: String = lastSeen == nil ? "Offline".localizeString(id: "account_state_offline", arguments: []) : self.lastSeenDateFormatter.string(from: lastSeen ?? Date(timeIntervalSince1970: 1))
                    
                    
                    self.headerView.configure(
                        avatarUrl: avatarUrl,
                        owner: self.owner,
                        jid: self.jid,
                        titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                        title: self.userNickname,
                        subtitle: self.isMyProfile ? "This is you".localizeString(id: "this_is_you", arguments: []) : (self.userOnline ? "Online".localizeString(id: "account_state_connected", arguments: []) : offlineString ) ,
                        thirdLine: nil
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
                                    session.groupchat?.requestUserPermissions(stream, groupchat: self.jid, user: "0")
                                }, fail: {
                                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                        user.groupchats.requestUserPermissions(stream, groupchat: self.jid, user: "0")
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
//                                            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                                                self.callbackIds.insert(
//                                                    session.groupchat?.requestEditUserForm(
//                                                        stream,
//                                                        groupchat: self.jid,
//                                                        userId: self.userId,
//                                                        callback: self.onReceiveForm
//                                                ) ?? "")
//                                            }, fail: {
//                                                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                                                    self.callbackIds.insert(
//                                                        user.groupchats.requestEditUserForm(
//                                                            stream,
//                                                            groupchat: self.jid,
//                                                            userId: self.userId,
//                                                            callback: self.onReceiveForm
//                                                    ))
//                                                })
//                                            })
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
//                                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                                            self.callbackIds.insert(
//                                                session.groupchat?.requestEditUserForm(
//                                                    stream,
//                                                    groupchat: self.jid,
//                                                    userId: self.userId,
//                                                    callback: self.onReceiveForm
//                                            ) ?? "")
//                                        }, fail: {
//                                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                                                self.callbackIds.insert(
//                                                    user.groupchats.requestEditUserForm(
//                                                        stream,
//                                                        groupchat: self.jid,
//                                                        userId: self.userId,
//                                                        callback: self.onReceiveForm
//                                                ))
//                                            })
//                                        })
                                        
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
                        } else {
                            self.isIncognitoGroup = false
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
                })
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    override func configure() {
        super.configure()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        
        tableView.tableHeaderView = headerView
        headerView.delegate = self
        
        saveButton.target = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
                
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
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
//        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//            session.groupchat?.requestUsers(stream, groupchat: self.jid, userId: self.userId)
//        }, fail: {
//            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
//            })
//        })
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        headerView.updateSubviews()
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
