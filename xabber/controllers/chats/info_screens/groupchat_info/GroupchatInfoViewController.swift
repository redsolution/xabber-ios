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
import DeepDiff
import CocoaLumberjack
import TOInsetGroupedTableView
import XMPPFramework.XMPPJID

class GroupchatInfoViewController: SimpleBaseViewController {
    
    class Datasource: DiffAware, Equatable, Hashable {
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.key == rhs.key && lhs.title == rhs.title && lhs.kind == rhs.kind
        }
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return key ?? title
            }
        }
        enum Kind {
            case text
            case info
            case contact
            case button
            case danger
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var key: String?
        var icon: String?
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, subtitle: String? = nil, icon: String? = nil, key: String? = nil, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            if subtitle?.isEmpty ?? true {
                self.subtitle = nil
            } else {
                self.subtitle = subtitle
            }
            self.key = key
            self.childs = childs
            self.icon = icon
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            if let key = self.key {
                hasher.combine(key)
            }
        }
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.key == b.key &&
                a.title == b.title &&
                a.kind == b.kind &&
                a.subtitle == b.subtitle &&
                a.childs.count == b.childs.count &&
                a.childs.first == b.childs.first
        }
        
    }
    
//    open var owner: String = ""
//    open var jid: String = ""
    
    var headerHeightMax: CGFloat = 156//264
//    var headerHeightMin: CGFloat = 180150
    
    internal let lastSeenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        
        return formatter
    }()
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
                
        return view
    }()
    
    internal let footerView: InfoScreenFooterView = {
        let view = InfoScreenFooterView(frame: .zero)
        view.isGroupChat = true

        return view
      }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "InfoCell")
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(EditCirclesCell.self, forCellReuseIdentifier: EditCirclesCell.cellName)
        
        return view
    }()
    
    internal let infoButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: #imageLiteral(resourceName: "information").withRenderingMode(.alwaysTemplate), style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal let showQRCodeButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: #imageLiteral(resourceName: "qrcode").withRenderingMode(.alwaysTemplate), style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal var headerConstraintSet: NSLayoutConstraintSet? = nil
    
    internal var contacts: Results<GroupchatUserStorageItem>? = nil
    internal var datasource: [Datasource] = []
    
    internal var nickname: String = ""
    
    internal var membersCount: Int = 0
    internal var lastPresentContacts: Int = 0
    internal var onlineContacts: Int = 0
    internal var blockedCount: Int = 0
    internal var invitationsCount: Int = 0
    internal var isBlocked: Bool = false
    internal var isMuted: Bool = false
    internal var canInvite: Bool = false
    internal var canChangeAvatar: Bool = false
    internal var canChangeStatus: Bool = false
    internal var isIncognitoChat: Bool = false
    internal var canBeChanged: Bool = false
    
    internal var currentStatus: ResourceStatus = .offline
    internal var currentVerboseStatus: String = "Offline".localizeString(id: "unavailable", arguments: [])
    internal var isTemporaryStatus: Bool = true
    
    internal var callbackIds: Set<String> = Set<String>()
    
    internal var shouldResetNavbar: Bool = false
    
    internal var circles: [String] = []
    internal var groupEditFormValues: [[String: Any]]? = nil
    
    private func reloadHeaderTitle(inSection section: Int) {
        UIView.setAnimationsEnabled(false)
        tableView.beginUpdates()

        let headerView = tableView.headerView(forSection: section)
        headerView?.textLabel?.text = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section)?.uppercased()
        headerView?.sizeToFit()

        tableView.endUpdates()
        UIView.setAnimationsEnabled(true)
    }

    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            
            circles = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?.groups.toArray().sorted() ?? []
            contacts = realm
                .objects(GroupchatUserStorageItem.self)
                .filter("groupchatId == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false", [jid, owner].prp())
                .sorted(by: [
                    SortDescriptor(keyPath: "isMe", ascending: false),
                    SortDescriptor(keyPath: "sortedRole", ascending: true),
                    SortDescriptor(keyPath: "nickname", ascending: true)
                ])
            
            Observable
                .collection(from: realm
                    .objects(ResourceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                    .sorted(by: [
                        SortDescriptor(keyPath: "timestamp", ascending: false),
                        SortDescriptor(keyPath: "priority", ascending: false)
                    ]))
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.currentStatus = item.status
                        self.currentVerboseStatus = item.displayedStatus
                        self.isTemporaryStatus = item.isTemporary
                        guard let section = self.datasource.firstIndex(where: { $0.key == "gc_status" }),
                            let row = self.datasource[section].childs.firstIndex(where: { $0.key == "gc_set_status" }) else {
                                return
                        }
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                        }
                    }
                })
                .disposed(by: bag)
            
            let groupChatInstance = realm
                .objects(GroupChatStorageItem.self)
                .filter("jid == %@ AND owner == %@", jid, owner)
            self.membersCount = groupChatInstance.first?.members ?? 0
            Observable
                .collection(from: groupChatInstance)
                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        var fullReload: Bool = false
                        var toUpdateRow: Set<IndexPath> = Set<IndexPath>()
                        if self.datasource.isEmpty {
                            fullReload = true
                        }
                        var newDatasource: [Datasource] = []
                        self.canBeChanged = item.canChangeSettings
                        DispatchQueue.main.async {
                            if self.canBeChanged {
//                                self.infoButton.title = "Edit"
                                self.infoButton.image = #imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate)
                            } else {
                                self.infoButton.image = #imageLiteral(resourceName: "information").withRenderingMode(.alwaysTemplate)
                            }
                        }
                        
                        self.isIncognitoChat = item.privacy == .incognito
                        self.canChangeAvatar = item.canChangeSettings
                        self.canChangeStatus = item.canChangeSettings
                        self.canInvite = item.canInvite

                        if self.canInvite {
                            newDatasource.append(Datasource(.text, title: " ", childs: [
                                Datasource(.button, title: "Invite".localizeString(id: "groupchat_bar_invite", arguments: []), icon: "person.badge.plus", key: "invite"),
                                Datasource(.danger, title: "Leave".localizeString(id: "groupchat_bar_leave", arguments: []), icon: "figure.run", key: "leave")
                            ]))
                        } else {
                            newDatasource.append(Datasource(.text, title: " ", childs: [
                                Datasource(.danger, title: "Leave".localizeString(id: "groupchat_bar_leave", arguments: []), key: "leave")
                            ]))
                        }
                        
                        newDatasource.append(Datasource(.text, title: "About".localizeString(id: "about", arguments: []), childs: [
                            Datasource(.info, title: item.descr.isNotEmpty ? item.descr : "No description".localizeString(id: "no_description", arguments: []), key: "gc_descr"),
                            Datasource(.text, title: "Set status".localizeString(id: "status_editor", arguments: []), key: "gc_set_status")
                        ]))
                        toUpdateRow.insert(IndexPath(row: 1, section: newDatasource.count - 1))
                        
                        newDatasource.append(Datasource(.text, title: "", childs: [
                            Datasource(.button, title: "Circles".localizeString(id: "contact_circle", arguments: []), key: "gc_circles"),
                        ]))
                        
                        if !(self.contacts?.isEmpty ?? true) {
                            newDatasource.append(Datasource(.contact, title: "", key: "gc_contacts"))
                        }
                        
                        let imagesCount = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@ AND jid == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "image").count
                        let videosCount = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@ AND jid == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "video").count
                        let audiosCount = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@ AND jid == %@ AND kind_ == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.voice.rawValue).count
                        let mimeTypes: [String] = ["document", "pdf", "table", "presentation", "archive", "audio", "file"]
                        let filesCount = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@ AND jid == %@ AND mimeType IN %@ AND hasError == false", self.owner, self.jid, mimeTypes, "image").count
                        
                        newDatasource.append(Datasource(.text, title: "", key: "chat_files", childs: [
                            Datasource(.button, title: "Images", subtitle: String(imagesCount), key: "images"),
                            Datasource(.button, title: "Videos", subtitle: String(videosCount), key: "videos"),
                            Datasource(.button, title: "Files", subtitle: String(filesCount), key: "files"),
                            Datasource(.button, title: "Voice", subtitle: String(audiosCount), key: "voice")
                        ]))
                        
                        if self.datasource.count != newDatasource.count {
                            fullReload = true
                        } else {
                            self.datasource.enumerated().forEach {
                                (offset, item) in
                                if item.key != newDatasource[offset].key {
                                    fullReload = true
                                } else {
                                    if item.childs.count != newDatasource[offset].childs.count {
                                        fullReload = true
                                    }
                                }
                            }
                        }
                                                
                        self.datasource = newDatasource
                        
                        if fullReload {
                            UIView.performWithoutAnimation {
                                self.tableView.reloadData()
                            }
                        } else {
                            if #available(iOS 11.0, *) {
                                UIView.performWithoutAnimation {
                                    self.tableView.performBatchUpdates({
                                        if toUpdateRow.isNotEmpty {
                                            self.tableView.reloadRows(at: toUpdateRow.sorted(), with: .none)
                                        }
                                    }, completion: nil)
                                }
                                
                            } else {
                                UIView.performWithoutAnimation {
                                    self.tableView.beginUpdates()
                                    if toUpdateRow.isNotEmpty {
                                        self.tableView.reloadRows(at: toUpdateRow.sorted(), with: .none)
                                    }
                                    self.tableView.endUpdates()
                                }
                            }
                        }
                        if item.present != self.lastPresentContacts || item.members != self.membersCount {
                            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                session.groupchat?.requestUsers(stream, groupchat: self.jid)
                            }, fail: {
                                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                    user.groupchats.requestUsers(stream, groupchat: self.jid)
                                })
                            })
                        }
                        self.membersCount = item.members
                        self.lastPresentContacts = item.present
                        self.reloadHeaderTitle(inSection: self.datasource.count - 1)
                    }
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm
                    .objects(RosterStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, jid))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    let subtitle: String
                    if self.membersCount == 0 {
                        subtitle = "No members".localizeString(id: "groupchats_no_members", arguments: [])
                    } else if self.membersCount == 1 {
                        subtitle = "1 member".localizeString(id: "groupchats_one_member", arguments: [])
                    } else {
                        subtitle = "\(self.membersCount) members".localizeString(id: "groupchats_some_members", arguments: ["\(self.membersCount)"])
                    }
                    var avatarUrl: String? = nil
                    if let item = results.first {
                        avatarUrl = item.avatarMaxUrl ?? item.avatarMinUrl ?? item.oldschoolAvatarKey
                        self.nickname = item.displayName
                        if item.groups.toArray().sorted() != self.circles.sorted() {
                            self.circles = item.groups.toArray().sorted()
                            if let circleSection = self.datasource.firstIndex(where: { $0.childs.first(where: { $0.key == "gc_circles" }) != nil }),
                               let circleRow = self.datasource[circleSection].childs.firstIndex(where: { $0.key == "gc_circles" }) {
                                self.tableView.reloadRows(at: [IndexPath(row: circleRow, section: circleSection)], with: .none)
                            }
                        }
                    } else {
                        self.nickname = XMPPJID(string: self.jid)?.user ?? self.jid
                    }
                    self.headerView.configure(
                        avatarUrl: avatarUrl,
                        owner: self.owner,
                        jid: self.jid,
                        titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                        title: self.nickname    ,
                        subtitle: subtitle,
                        thirdLine: nil
                    )
                }).disposed(by: bag)
                        
            Observable
                .changeset(from: contacts!)
                .subscribe(onNext: { (results) in
                    self.onlineContacts = self.contacts?.filter({ $0.isOnline }).count ?? 0
                    if results.0.isEmpty {
                        if let index = self.datasource.firstIndex(where: { $0.kind == .contact }) {
                            self.datasource.remove(at: index)
                            if #available(iOS 11.0, *) {
                                self.tableView.performBatchUpdates({
                                    self.tableView.deleteSections(IndexSet([index]), with: .none)
                                }, completion: nil)
                            } else {
                                self.tableView.beginUpdates()
                                self.tableView.deleteSections(IndexSet([index]), with: .none)
                                self.tableView.endUpdates()
                            }
                        }
                    } else {
                        var shouldInsertSection: Bool = false
                        if !self.datasource.contains(where: { $0.kind == .contact }) {
                            self.datasource.append(Datasource(.contact, title: ""))
                            shouldInsertSection = true
                        }
                        let sectionIndex = self.datasource.count - 1
                        guard let changeset = results.1 else {
                            UIView.performWithoutAnimation {
                                self.tableView.reloadData()
                            }
                            return
                        }
                        UIView.performWithoutAnimation {
                            if #available(iOS 11.0, *) {
                                self.tableView.performBatchUpdates{
                                    if shouldInsertSection {
                                        self.tableView.insertSections(IndexSet([sectionIndex]), with: .none)
                                    }
                                    if changeset.deleted.isNotEmpty {
                                        self.tableView
                                            .deleteRows(at: changeset
                                                .deleted
                                                .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                    }
                                    if changeset.inserted.isNotEmpty {
                                        self.tableView
                                            .insertRows(at: changeset
                                                .inserted
                                                .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                    }
                                   
                                } completion: {
                                    result in
                                    if !result { return }
                                    if changeset.updated.isNotEmpty {
                                        self.tableView
                                            .reloadRows(at: changeset
                                                .updated
                                                .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                    }
                                }
                            } else {
                                self.tableView.beginUpdates()
                                if shouldInsertSection {
                                    self.tableView.insertSections(IndexSet([sectionIndex]), with: .none)
                                }
                                if changeset.deleted.isNotEmpty {
                                    self.tableView
                                        .deleteRows(at: changeset
                                            .deleted
                                            .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                }
                                if changeset.inserted.isNotEmpty {
                                    self.tableView
                                        .insertRows(at: changeset
                                            .inserted
                                            .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                }
                                if changeset.updated.isNotEmpty {
                                    self.tableView
                                        .reloadRows(at: changeset
                                            .updated
                                            .compactMap({ return IndexPath(row: $0, section: sectionIndex) }), with: .none)
                                }
                                self.tableView.endUpdates()
                            }
                        }
                    
                    }
                }).disposed(by: bag)
            
            Observable.collection(from: realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isBlocked == true", [jid, owner].prp()))
                .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.blockedCount = results.count
                    guard let section = self.datasource.firstIndex(where: { $0.key == "gc_participants" }),
                        let row = self.datasource[section].childs.firstIndex(where: { $0.key == "gc_blocked" }) else {
                            return
                    }
                    DispatchQueue.main.async {
                        UIView.performWithoutAnimation {
                            if #available(iOS 11.0, *) {
                                self.tableView.performBatchUpdates({
                                    self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                                }, completion: nil)
                            } else {
                                self.tableView.beginUpdates()
                                self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                                self.tableView.endUpdates()
                            }
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
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        view.addSubview(tableView)
        
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        
        tableView.tableHeaderView = headerView
        headerView.delegate = self
        
//        footerView.conversationType = .group
//        footerView.jid = self.jid
//        footerView.owner = self.owner
//        
//        footerView.frame = CGRect(x: 0, y: 0,
//                                  width: view.frame.width,
//                                  height: view.frame.height)
//        footerView.mediaButtonsDelegate = self
//        footerView.infoVCDelegate = self
//        footerView.getReferences()
//        tableView.tableFooterView = footerView
        
        infoButton.target = self
        infoButton.action = #selector(groupchatInfo)
        
        showQRCodeButton.target = self
        showQRCodeButton.action = #selector(showQRCode)
        
        datasource = []
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            let requestId = session.groupchat?.requestMyRights(stream, groupchat: self.jid)
            self.callbackIds.insert(requestId ?? "")
            session.vcardManager?.requestItem(stream, jid: self.jid)
            session.groupchat?.requestUsers(stream, groupchat: self.jid)
            session.groupchat?.requestInvitedUsers(stream, groupchat: self.jid)
            session.groupchat?.blockList(stream, groupchat: self.jid)
            _ = session
                .groupchat?
                .requestChatSettingsForm(
                    stream,
                    groupchat: self.jid,
                    callback: self.onChatSettingsFormResponse
                )
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                let requestId = user.groupchats.requestMyRights(stream, groupchat: self.jid)
                self.callbackIds.insert(requestId)
                user.vcards.requestItem(stream, jid: self.jid)
                user.groupchats.requestUsers(stream, groupchat: self.jid)
                user.groupchats.requestInvitedUsers(stream, groupchat: self.jid)
                user.groupchats.blockList(stream, groupchat: self.jid)
                _ = user.groupchats
                    .requestChatSettingsForm(
                        stream,
                        groupchat: self.jid,
                        callback: self.onChatSettingsFormResponse
                    )
            })
        })
        
        footerView.imagesButton.isSelected = true
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        headerView.setMask()
        tableView.reloadData()
    }
    
    internal final func onChatSettingsFormResponse(values: [[String: Any]]?, error: String?) {
        self.groupEditFormValues = values
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        headerView.updateSubviews()
        headerView.setMask()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shouldResetNavbar = true
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
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
        
//        navigationController?.navigationBar.isTranslucent = true
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
