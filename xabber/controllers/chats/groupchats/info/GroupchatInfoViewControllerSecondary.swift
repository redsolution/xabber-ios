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
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import Kingfisher
import TOInsetGroupedTableView
import Toast_Swift
import AVFoundation

class GroupchatInfoViewControllerSecondary: SimpleBaseViewController {
    
    struct DatasourceCell {
        let title: String
        let value: String?
        let editable: Bool
        let key: String
        let subvalues: [[String: String]]
    }
    
    struct DatasourceSection {
        let key: String?
        let header: NSAttributedString?
        let footer: NSAttributedString?
        let cells: [DatasourceCell]
    }

    public var isViewForAdmin: Bool = false
    
    internal var name: String = ""
    internal var privacy: GroupChatStorageItem.Privacy = .none
    internal var index: GroupChatStorageItem.Index = .none
    internal var membership: GroupChatStorageItem.Membership = .none
    internal var descr: String = ""
    internal var restrictions: [String] = []
    internal var descCellHeight: CGFloat = 0
    
    internal var avatar: UIImage? = nil

    internal var datasource: [DatasourceSection] = []

    internal var nameObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var descrObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var saveButtonEnabledObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    public var privacyValues: [[String: String]] = []
    public var membershipValues: [[String: String]] = []
    public var indexValues: [[String: String]] = []
    
    public var formData: [[String: Any]] = []
    
    internal var membersCount: Int = 0
    internal var invitesCount: Int = 0
    internal var blockedCount: Int = 0
        
    internal var saveButton: UIBarButtonItem? = nil
    internal var cancelButton: UIBarButtonItem? = nil
    
    let topFrontView: UITabBar = {
        let view = UITabBar()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private final func loadDatasource(_ instance: GroupChatStorageItem) {
        self.title = " "
        self.name = instance.name
        self.privacy = instance.privacy
        self.index = instance.index
        self.membership = instance.membership
        self.descr = instance.descr
        self.restrictions = instance.defaultRestrictions.toArray()
        self.invitesCount = instance.invited.count
        
        membersCount = instance.members
        invitesCount = instance.invited.count
        do {
            let realm = try WRealm.safe()
            blockedCount = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isBlocked == true", instance.primary).count
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
        }
        
        self.descCellHeight = NSAttributedString(string: self.descr, attributes: [.font: UIFont.systemFont(ofSize: 17)])
            .boundingRect(
                with: CGSize(width: UIScreen.main.bounds.width - 64, height: .greatestFiniteMagnitude),
                options: [.usesFontLeading, .usesLineFragmentOrigin],
                context: nil
            ).height
        
        self.nameObserver.accept(self.name)
        self.descrObserver.accept(self.descr)
        
        self.doReloadTableView()
    }
    
    @objc
    internal func cancelChanges(_ sender: AnyObject) {
        self.nameObserver.accept(self.name)
        self.descrObserver.accept(self.descr)
        if let nameIndex = self.datasource.firstIndex(where: { $0.key == "text" }) {
            self.tableView.reloadSections(IndexSet([nameIndex,]), with: .none)
        }
    }
    
    @objc
    internal func saveChanges(_ sender: AnyObject) {
        
        let descrModified = self.descrObserver.value ?? ""
        let nameModified = self.nameObserver.value ?? ""
        
        if let modifiedIndex = formData.firstIndex(where: { $0["var"] as? String == "name" }) {
            formData[modifiedIndex]["value"] = nameModified
        }
        
        if let modifiedIndex = formData.firstIndex(where: { $0["var"] as? String == "description" }) {
            formData[modifiedIndex]["value"] = descrModified
        }
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            _ = session.groupchat?
                .updateForm(stream,
                            formType: .settings,
                            groupchat: self.jid,
                            userData: self.formData,
                            callback: { error in
//                                print(error)
                                if error != nil {
                                    DispatchQueue.main.async {
                                        self.view.makeToast("Internal server error".localizeString(id: "error_internal_server", arguments: []))
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        self.close(self)
                                    }
                                }
                            }
                )
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                _ = user.groupchats
                    .updateForm(stream,
                                formType: .settings,
                                groupchat: self.jid,
                                userData: self.formData,
                                callback: { error in
                                    if error != nil {
                                        DispatchQueue.main.async {
                                            self.view.makeToast("Internal server error".localizeString(id: "error_internal_server", arguments: []))
                                        }
                                    } else {
                                        DispatchQueue.main.async {
                                            self.close(self)
                                        }
                                    }
                                }
                    )
            })
        }
    }
    
    override func close(_ sender: AnyObject) {
        self.navigationController?.popViewController(animated: true)
    }
    
    private final func doReloadTableView() {
        if self.isViewForAdmin {
            self.datasource = [
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "", value: nil, editable: true, key: "header", subvalues: [])
                ]),
                DatasourceSection(key: "text", header: nil, footer: NSAttributedString.init(string: self.jid), cells: [
                    DatasourceCell(title: "", value: self.name, editable: true, key: "name", subvalues: []),
                    DatasourceCell(title: "", value: self.descr.isEmpty ? "No description".localizeString(id: "no_description", arguments: []) : self.descr.trimmingCharacters(in: .whitespacesAndNewlines), editable: true, key: "description", subvalues: [])
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "Privacy".localizeString(id: "privacy", arguments: []), value: self.privacy.localized, editable: false, key: "privacy", subvalues: privacyValues),
                    DatasourceCell(title: "Membership".localizeString(id: "groupchat_membership", arguments: []), value: self.membership.localized, editable: true, key: "membership", subvalues: membershipValues),
                    DatasourceCell(title: "Index".localizeString(id: "groupchat_index", arguments: []), value: self.index.localized, editable: true, key: "index", subvalues: indexValues),
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "Members".localizeString(id: "group_settings__members_list__header", arguments: []), value: "\(self.membersCount)", editable: true, key: "members", subvalues: []),
                    DatasourceCell(title: "Invitations".localizeString(id: "groupchat_invitations", arguments: []), value: "\(self.invitesCount)", editable: true, key: "invitations", subvalues: []),
                    DatasourceCell(title: "Blocked".localizeString(id: "groupchat_blocked", arguments: []), value: "\(self.blockedCount)", editable: true, key: "blocked", subvalues: []),
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
//                    DatasourceCell(title: "Show QR code", value: nil, editable: false, key: "qr_code", subvalues: []),
                    DatasourceCell(title: "Clear history".localizeString(id: "clear_history", arguments: []), value: nil, editable: false, key: "clear_history", subvalues: []),
                    DatasourceCell(title: "Search".localizeString(id: "search", arguments: []), value: nil, editable: false, key: "search", subvalues: []),
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "Delete group".localizeString(id: "group_remove", arguments: []), value: nil, editable: false, key: "delete", subvalues: [])
                ])
            ]
        } else {
            self.datasource = [
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "", value: nil, editable: false, key: "header", subvalues: [])
                ]),
                DatasourceSection(key: nil, header: NSAttributedString(string: "About".localizeString(id: "about", arguments: [])),
                                  footer: NSAttributedString.init(string: self.jid), cells: [
                                    DatasourceCell(title: self.descr.isEmpty ? "No description".localizeString(id: "no_description", arguments: []) : self.descr.trimmingCharacters(in: .whitespacesAndNewlines), value: nil, editable: false, key: "description", subvalues: [])
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "Membership".localizeString(id: "groupchat_membership", arguments: []),
                                   value: self.membership.localized, editable: false, key: "membership", subvalues: []),
                    DatasourceCell(title: "Index".localizeString(id: "groupchat_index", arguments: []),
                                   value: self.index.localized, editable: false, key: "index", subvalues: []),
                    DatasourceCell(title: "Privacy".localizeString(id: "privacy", arguments: []),
                                   value: self.privacy.localized, editable: false, key: "privacy", subvalues: [])
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    
                    DatasourceCell(title: "Invitations".localizeString(id: "groupchat_invitations", arguments: []),
                                   value: "\(self.invitesCount)", editable: true, key: "invitations", subvalues: []),
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
//                    DatasourceCell(title: "Show QR code", value: nil, editable: false, key: "qr_code", subvalues: []),
                    DatasourceCell(title: "Search".localizeString(id: "search", arguments: []),
                                   value: nil, editable: false, key: "search", subvalues: []),
                ]),
                DatasourceSection(key: nil, header: nil, footer: nil, cells: [
                    DatasourceCell(title: "Leave group".localizeString(id: "groupchat_leave_full", arguments: []),
                                   value: nil, editable: false, key: "leave", subvalues: [])
                ])
            ]
        }
        
        self.tableView.reloadData()
    }
    
    override func subscribe() {
        super.subscribe()
        DefaultAvatarManager.shared.getAvatar(url: nil, jid: self.jid, owner: self.owner) { image in
            if let image = image {
                self.avatar = image
            } else {
                self.avatar = UIImageView.getDefaultAvatar(for: self.jid, owner: self.owner, size: 128)
            }
        }
        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm
                                .objects(GroupChatStorageItem.self)
                                .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { results in
                    guard let item = results.first else {
                        return
                    }
                    self.loadDatasource(item)
//                    self.bag = DisposeBag()
                }, onError: { _ in
                    
                }, onCompleted: {
                    
                }, onDisposed: {
                    
                })
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
        }
        
        nameObserver
            .asObservable()
            .subscribe { value in
                if value != self.name {
                    if !self.saveButtonEnabledObserver.value {
                        self.saveButtonEnabledObserver.accept(true)
                    }
                } else {
                    if self.descr == self.descrObserver.value {
                        self.saveButtonEnabledObserver.accept(false)
                    }
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)
        
        descrObserver
            .asObservable()
            .subscribe { value in
                if value != self.descr {
                    if !self.saveButtonEnabledObserver.value {
                        self.saveButtonEnabledObserver.accept(true)
                    }
                } else {
                    if self.name == self.nameObserver.value {
                        self.saveButtonEnabledObserver.accept(false)
                    }
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)

        saveButtonEnabledObserver
            .asObservable()
            .subscribe { value in
                DispatchQueue.main.async {
                    if value {
                        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                        self.navigationItem.setLeftBarButton(self.cancelButton, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(nil, animated: true)
                        self.navigationItem.setLeftBarButton(nil, animated: true)
                    }
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)

    }
    
    private let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(SimpleItemCell.self, forCellReuseIdentifier: SimpleItemCell.cellName)
        view.register(TableHeaderWithAvatarCell.self, forCellReuseIdentifier: TableHeaderWithAvatarCell.cellName)
        view.register(SimpleTextFieldCell.self, forCellReuseIdentifier: SimpleTextFieldCell.cellName)
        view.register(SimpleTextAreaCell.self, forCellReuseIdentifier: SimpleTextAreaCell.cellName)
        
        view.keyboardDismissMode = .interactive
        
        view.tableHeaderView = UIView()
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: -70, bottom: 0, left: 0, right: 0) //-70
        view.addSubview(topFrontView)
        makeConstraints()
    }
    
    func makeConstraints() {
        NSLayoutConstraint.activate([
            topFrontView.leftAnchor.constraint(equalTo: view.leftAnchor),
            topFrontView.topAnchor.constraint(equalTo: view.topAnchor),
            topFrontView.rightAnchor.constraint(equalTo: view.rightAnchor),
            topFrontView.heightAnchor.constraint(equalToConstant: 48)
        ])
    }
    
    override func configure() {
        super.configure()
        self.tableView.dataSource = self
        self.tableView.delegate = self
        
        
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        
        cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelChanges))
        saveButton = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveChanges))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
    }
}

extension GroupchatInfoViewControllerSecondary {
    
    internal func onLeave() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: GroupChatStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.name ?? jid
            let leaveItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Leave".localizeString(id: "groupchat_leave", arguments: []), value: "leave"),
                ActionSheetPresenter.Item(destructive: true, title: "Leave and block".localizeString(id: "groupchats_leave_block", arguments: []), value: "leave_and_block"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Leave group".localizeString(id: "groupchat_leave_full", arguments: []),
                message: "Do you really want to leave group \(displayedName)?".localizeString(id: "groupchat_leave_confirm", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: leaveItems,
                animated: true,
                completion: onLeaveCallback
            )
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onLeaveCallback(_ action: String) {
        switch action {
        case "leave":
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.leave(stream, groupchat: self.jid, callback: self.onLeaveResultCallback)
            })
        case "leave_and_block":
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.leave(stream, groupchat: self.jid, callback: self.onLeaveResultCallback)
            })
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.blocked.blockContact(stream, jid: self.jid)
            })
        default: break
        }
    }
    
    internal func onLeaveResultCallback(_ error: String?) {
        if let error = error {
            var message: String = ""
            switch error {
            case "fail": message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
            case "not-allowed": message = "Last owner can`t leave chat. Please transfer owner rights to somebody".localizeString(id: "groupchats_last_owner_leave_error", arguments: [])
            default: message = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
            }
            DispatchQueue.main.async {
                ErrorMessagePresenter().present(in: self, message: message, animated: true, completion: nil)
            }
        } else {
            DispatchQueue.main.async {
                self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                self.navigationController?.navigationBar.shadowImage = nil
                self.navigationController?.popToRootViewController(animated: true)
            }
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.afterLeave(groupchat: self.jid)
            })
        }
    }
    
    func openSearch() {
        let chatVc = ChatViewController()
        chatVc.owner = self.owner
        chatVc.jid = self.jid
        chatVc.entity = self.privacy == .incognito ? .privateChat : .groupchat
        chatVc.conversationType = .group
        chatVc.inSearchMode.accept(true)
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        if let rootVc = navigationController?.viewControllers.first {
            navigationController?.setViewControllers([rootVc, chatVc], animated: true)
        } else {
            navigationController?.pushViewController(chatVc, animated: true)
        }
    }
    
    
    func openInvitations() {
        let vc = GroupchatInviteListViewController()
        vc.configure(jid, owner: owner)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func openBlocked() {
        let vc = GroupchatBlockedViewController()
        vc.configure(jid, owner: owner)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        navigationController?.pushViewController(vc, animated: true)
    }
}

extension GroupchatInfoViewControllerSecondary: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if self.isViewForAdmin && datasource[indexPath.section].cells[indexPath.row].key == "description" {
            return descCellHeight + 44
        }
        switch datasource[indexPath.section].cells[indexPath.row].key {
        case "description", "name":
            return tableView.estimatedRowHeight
        case "header":
            if self.isViewForAdmin {
                return 170
            }
            return 196//184//236
        default:
            return 44
        }
    }
    
//    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
//        return 0
//    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return 0
        }
        return tableView.estimatedSectionHeaderHeight
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section].cells[indexPath.row]
        switch item.key {
        case "invitations":
            self.openInvitations()
        case "search":
            self.openSearch()
        case "leave":
            self.onLeave()
        case "clear_history":
            onClearHistory()
        case "members":
            let vc = GroupchatMembersListViewController()
            vc.owner = owner
            vc.jid = jid
            self.navigationController?.pushViewController(vc, animated: true)
        case "blocked":
            self.openBlocked()
        case "membership", "index":
            let vc = GroupchatInfoEditItemViewController()
            vc.datasource = item.subvalues.compactMap { return GroupchatInfoEditItemViewController.Datasource(label: $0["label"] ?? "", value: $0["value"] ?? "")}
            vc.section = item.key
            if item.key == "membership" {
                vc.currentValue = membership.rawValue
            } else if item.key == "index" {
                vc.currentValue = index.rawValue
            }
            vc.deleggate = self
            self.navigationController?.pushViewController(vc, animated: true)
        default:
            break
        }
    }
}

extension GroupchatInfoViewControllerSecondary: GroupchatInfoEditItemViewControllerDelegate {
    
    func didSelect(section: String, value: String) {
        guard let modifiedIndex = formData.firstIndex(where: { $0["var"] as? String == section }) else {
            fatalError()
        }
        formData[modifiedIndex]["value"] = value
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            _ = session.groupchat?
                .updateForm(stream,
                            formType: .settings,
                            groupchat: self.jid,
                            userData: self.formData,
                            callback: { error in
                                if error != nil {
                                    DispatchQueue.main.async {
                                        self.view.makeToast("Internal server error".localizeString(id: "error_internal_server", arguments: []))
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        self.close(self)
                                    }
                                }
                            }
                )
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                _ = user.groupchats
                    .updateForm(stream,
                                formType: .settings,
                                groupchat: self.jid,
                                userData: self.formData,
                                callback: { error in
                                    if error != nil {
                                        DispatchQueue.main.async {
                                            self.view.makeToast("Internal server error".localizeString(id: "error_internal_server", arguments: []))
                                        }
                                    } else {
                                        DispatchQueue.main.async {
                                            self.close(self)
                                        }
                                    }
                                }
                    )
            })
        }
    }
    
    internal func onCellTextDidChange(key: String, value: String?) {
        switch key {
        case "name":
            self.nameObserver.accept(value)
        case "description":
            self.descrObserver.accept(value)
        default:
            break
        }
    }
}

extension GroupchatInfoViewControllerSecondary: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].cells.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].cells[indexPath.row]
        if item.key == "header" {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TableHeaderWithAvatarCell.cellName, for: indexPath) as? TableHeaderWithAvatarCell else {
                fatalError()
            }
            
            if self.isViewForAdmin {
                cell.configure(avatar: self.avatar, owner: self.owner, jid: self.jid,
                               displayName: "Set new avatar".localizeString(id: "groupchat_set_avatar", arguments: []),
                               thinLabel: true)
                cell.actionCallback = self.headerCellAction
                
            } else {
                cell.configure(avatar: self.avatar, owner: self.owner, jid: self.jid, displayName: self.name, thinLabel: false)
            }
            cell.setMask()
            
            return cell
        } else if item.key == "description" && self.isViewForAdmin{
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SimpleTextAreaCell.cellName, for: indexPath) as? SimpleTextAreaCell else {
                fatalError()
            }
            
            cell.configure(item.key, text: self.descrObserver.value)
            cell.callback = onCellTextDidChange
            
            return cell
        } else if item.key == "name" && self.isViewForAdmin {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SimpleTextFieldCell.cellName, for: indexPath) as? SimpleTextFieldCell else {
                fatalError()
            }
            
            cell.configure(item.key, text: self.nameObserver.value)
            cell.callback = onCellTextDidChange
            
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SimpleItemCell.cellName, for: indexPath) as? SimpleItemCell else {
            fatalError()
        }
        switch item.key {
        case "invitations", "members", "blocked", "clear_history", "qr_code", "search":
            cell.configure(kind: .button, title: item.title, value: item.value, editable: item.editable)
        case "leave", "delete":
            cell.configure(kind: .danger, title: item.title, value: item.value, editable: item.editable)
        default:
            cell.configure(kind: .normal, title: item.title, value: item.value, editable: item.editable)
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].header?.string
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return datasource[section].footer?.string
    }
}

extension GroupchatInfoViewControllerSecondary {
    
    class SimpleTextAreaCell: UITableViewCell, UITextViewDelegate {
        public static let cellName: String = "SimpleTextAreaCell"
        public var cellId: String = ""
        public var callback: ((String, String?) -> Void)? = nil
        internal let textArea: UITextView = {
            let view = UITextView(frame: .zero)
            
            view.font = UIFont.systemFont(ofSize: 17)
            
            return view
        }()
        
        public final func configure(_ cellId: String, text: String?) {
            print("SimpleTextAreaCell: \(#function)")
            textArea.text = text
            textArea.sizeToFit()
            textArea.delegate = self
            self.cellId = cellId
        }
        
        private final func setupSubviews() {
            selectionStyle = .none
            contentView.addSubview(textArea)
            textArea.fillSuperviewWithOffset(top: 8, bottom: 8, left: 16, right: 16)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
                
        func textViewDidChange(_ textView: UITextView) {
            self.callback?(cellId, textView.text)
        }
    }
    
    class SimpleTextFieldCell: UITableViewCell {
        public static let cellName: String = "SimpleTextFieldCell"
        public var cellId: String = ""
        public var callback: ((String, String?) -> Void)? = nil
        internal let textField: UITextField = {
            let field = UITextField()
            
            return field
        }()
        
        public final func configure(_ cellId: String, text: String?) {
            textField.text = text
            textField.addTarget(self, action: #selector(onUpdate), for: .editingChanged)
            self.cellId = cellId
        }
        
        private final func setupSubviews() {
            selectionStyle = .none
            contentView.addSubview(textField)
            textField.fillSuperviewWithOffset(top: 8, bottom: 8, left: 16, right: 16)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        private func onUpdate(_ sender: UITextField) {
            self.callback?(cellId, sender.text)
            print(sender.text)
        }
    }
    
    class SimpleItemCell: UITableViewCell {
        public static let cellName: String = "SimpleItemCell"
        
        enum Kind {
            case normal
            case button
            case danger
        }
        
        public final func configure(kind: Kind, title: String, value: String?, editable: Bool) {
            self.textLabel?.text = title
            self.detailTextLabel?.text = value
            self.textLabel?.numberOfLines = 0
            self.textLabel?.lineBreakMode = .byWordWrapping
            self.textLabel?.textAlignment = .justified
            if editable {
                self.accessoryType = .disclosureIndicator
            } else {
                self.accessoryType = .none
            }
            switch kind {
            case .normal:
                break
            case .button:
                self.textLabel?.textColor = .systemBlue
            case .danger:
                self.textLabel?.textColor = .systemRed
            }
        }
        
        private final func setupSubviews() {
            selectionStyle = .none
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}

extension GroupchatInfoViewControllerSecondary {
    public final func headerCellAction(target: TableHeaderWithAvatarCell.Target) {
        onChangeAvatar()
    }
    
    func onChangeAvatar() {
        let groupchatItems = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera"),
            ActionSheetPresenter.Item(destructive: true, title: "Clear avatar".localizeString(id: "account_clear_avatar", arguments: []), value: "clear")
        ]
        ActionSheetPresenter().present(in: self,
                                       title: nil,
                                       message: nil,
                                       cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                                       values: groupchatItems,
                                       animated: true) { (value) in
                                        switch value {
                                        case "camera": self.onOpenCamera()
                                        case "gallery": self.onOpenGallery()
                                        case "emoji": self.onOpenEmojiPicker()
                                        case "clear": self.onClearAvatar()
                                        default: break
                                        }
        }
    }
    
    internal func askPermision(_ callback: @escaping ((Bool) -> Void)) {
        if self.isViewForAdmin {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                callback(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    callback(granted)
                }
            case .denied, .restricted:
                callback(false)
                return
            @unknown default:
                callback(false)
            }
        } else {
            callback(false)
        }
    }
    
    internal func openCamera() {
        askPermision { (result) in
            DispatchQueue.main.async {
                if result && UIImagePickerController.isSourceTypeAvailable(.camera) {
                    let cameraPickerVC = UIImagePickerController()
                    cameraPickerVC.delegate = self
                    cameraPickerVC.sourceType = .camera
                    cameraPickerVC.allowsEditing = true
                    self.present(cameraPickerVC, animated: true, completion: nil)
                } else {
                    ErrorMessagePresenter()
                        .present(in: self,
                                 message: "To choose profile picture from camera, you should grant permission first".localizeString(id: "account_camera_permission", arguments: []),
                                 animated: true,
                                 completion: nil)
                }
            }
        }
    }
    
    internal func openGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            let galleryPickerVC = UIImagePickerController()
            galleryPickerVC.delegate = self
            galleryPickerVC.sourceType = .photoLibrary
            galleryPickerVC.allowsEditing = true
            self.present(galleryPickerVC, animated: true, completion: nil)
        }
    }
    
    internal final func openAvatarPicker() {
        let vc = AvatarPickerViewController()
        vc.delegate = self
        vc.palette = nil
        vc.lastSettedEmoji = nil
        showModal(vc, from: self)
    }
    
    internal final func onOpenEmojiPicker() {
        openAvatarPicker()
    }
    
    internal final func onOpenCamera() {
        openCamera()
    }
    
    internal final func onOpenGallery() {
        openGallery()
    }
    
    internal final func onClearAvatar() {
        onUpdateAvatar(nil)
    }
    
    func onClearHistory() {
        let deleteItems: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: true, title: "Clear".localizeString(id: "clear", arguments: []), value: "delete"),
        ]
        let message = "All message history in this group will be cleared. This action can not be undone.".localizeString(id: "clear_group_chat_history_dialog_message", arguments: [])
        ActionSheetPresenter().present(
            in: self,
            title: "Clear history".localizeString(id: "clear_history", arguments: []),
            message: message,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: deleteItems,
            animated: true
        ) { (value) in
            switch value {
            case "delete":
                self.view.makeToastActivity(ToastPosition.center)
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.retract?.deleteMessageGroupchat(stream, chat: self.jid)
                    { (error, result) in
                        DispatchQueue.main.async {
                            self.view.hideToastActivity()
                        }
                        if result {
                            DispatchQueue.main.async {
                                self.view.makeToast("All message history for this chat was deleted".localizeString(id: "groupchats_message_history_deleted_message", arguments: []))
                                self.navigationController?.popToRootViewController(animated: true)
                            }
                        } else {
                            DispatchQueue.main.async {
                                if let error = error {
                                    self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                }
                            }
                        }
                    }
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.msgDeleteManager
                            .deleteMessageGroupchat(stream, chat: self.jid)
                            { (error, result) in
                                DispatchQueue.main.async {
                                    self.view.hideToastActivity()
                                }
                                if result {
                                    DispatchQueue.main.async {
                                        self.view.makeToast("All message history for this chat was deleted".localizeString(id: "groupchats_message_history_deleted_message", arguments: []))
                                        self.navigationController?.popToRootViewController(animated: true)
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        if let error = error {
                                            self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                        }
                                    }
                                }
                            }
                    })
                })
            default:
                break
            }
        }
    }
    
    func onUpdateAvatar(_ image: UIImage?) {
        DispatchQueue.main.async {
            self.view.makeToastActivity(.center)
        }
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.publishAvatar(stream,
                                          groupchat: self.jid,
                                          groupAvatar: true,
                                          image: image,
                                          callback: self.onUpdateAvatarCallback)
        })
    }
    
    func onUpdateAvatarCallback(_ error: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
            if let error = error {
                var message: String = ""
                switch error {
                case "not-allowed":
                    message = "You have no permission to change member`s avatar".localizeString(id: "groupchats_member_avatar_no_permission", arguments: [])
                case "fail":
                    message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
                default:
                    message = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
                }
                ErrorMessagePresenter().present(in: self,
                                                message: message,
                                                animated: true,
                                                completion: nil)
            } else {
                DefaultAvatarManager.shared.getAvatar(url: nil, jid: self.jid, owner: self.owner, size: 128) { image in
                    if let image = image {
                        self.avatar = image
                    } else {
                        self.avatar = UIImageView.getDefaultAvatar(for: self.jid, owner: self.owner, size: 128)
                    }
                }
                self.subscribe()
                self.tableView.reloadData()
            }
        }
        
    }
}

extension GroupchatInfoViewControllerSecondary: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        self.onUpdateAvatar(image)
    }
}

extension GroupchatInfoViewControllerSecondary: UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        let maxSize: CGFloat = 164
        guard let newImage = info[UIImagePickerController.InfoKey.editedImage] as? UIImage ?? info[UIImagePickerController.InfoKey.originalImage] as? UIImage else {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
            return
        }
        var image = newImage
        if picker.sourceType == .camera {
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        }
//        if image.size.width > maxSize || image.size.height > maxSize {
//            image = image.resize(targetSize: CGSize(square: maxSize))
//        }
        image = image.fixOrientation()
        picker.dismiss(animated: true) {
            self.onUpdateAvatar(image)
        }
    }
}
