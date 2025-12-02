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
import RxRealm
import RxCocoa
import CocoaLumberjack

class GroupchatEditContactViewController: BaseViewController {
    
    class Section {
        enum Kind {
            case nickname
            case badge
            case permissions
            case restrictions
        }
        
        var kind: Kind
        var title: String
        var footer: String?
        var rows: [Datasource]
        
        init(_ kind: Kind, title: String, footer: String?, rows: [Datasource]) {
            self.kind = kind
            self.title = title
            self.footer = footer
            self.rows = rows
        }
    }
    
    struct Value {
        let label: String
        let value: String
    }
    
    class Datasource {
        enum Kind {
            case textItem
            case listItem
        }
        
        var kind: Kind
        var itemId: String
        var title: String
        var value: String?
        var values: [Value]
        var enabled: Bool
        
        init(_ kind: Kind, itemId: String, title: String, value: String?, values: [Value], enabled: Bool) {
            self.kind = kind
            self.itemId = itemId
            self.title = title
            self.value = value
            self.values = values
            self.enabled = enabled
        }
    }
    
    internal var userId: String = ""
    internal var groupchat: String = ""
//    internal var owner: String = ""
    
    internal var requestFormId: String? = nil
    
    internal var nickname: String? = nil
    internal var badge: String? = nil
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var modifiedNickname: BehaviorRelay<String?> = BehaviorRelay<String?>(value: nil)
    internal var modifiedBadge: BehaviorRelay<String?> = BehaviorRelay<String?>(value: nil)
    
    internal var datasource: [Section] = []
    
    internal var form: [[String: Any]] = []
    internal var modifiedForm: BehaviorRelay<[[String: Any]]> = BehaviorRelay(value: [])
    
    internal var enableSaveButton: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.allowsSelection = false
        
        view.register(TextEditCell.self, forCellReuseIdentifier: TextEditCell.cellName)
        view.register(ListItemEditCell.self, forCellReuseIdentifier: ListItemEditCell.cellName)
        
        return view
    }()
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                           forPrimaryKey: [userId, groupchat, owner].prp()) {
                nickname = instance.nickname
                badge = instance.badge
                modifiedNickname.accept(nickname)
                modifiedBadge.accept(badge)
                self.datasource = [Section(.nickname,
                                           title: "Nickname".localizeString(id: "vcard_nick_name", arguments: []),
                                           footer: nil,
                                           rows: [Datasource(.textItem,
                                                             itemId: "nickname",
                                                             title: "Empty nickname".localizeString(id: "title_empty_nickname", arguments: []),
                                                             value: modifiedNickname.value,
                                                             values: [],
                                                             enabled: false)]),
                                   Section(.badge,
                                           title: "Badge".localizeString(id: "groupchat_member_badge", arguments: []),
                                           footer: nil,
                                           rows: [Datasource(.textItem,
                                                             itemId: "badge",
                                                             title: "Empty badge".localizeString(id: "groupchats_empty_badge", arguments: []),
                                                             value: modifiedBadge.value,
                                                             values: [],
                                                             enabled: false)])]
            }
        } catch {
            DDLogDebug("GroupchatEditContactViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        inSaveMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                    }
                }
            })
            .disposed(by: bag)
        
        enableSaveButton
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.33) {
                        if value {
                            if !self.saveButton.isEnabled {
                                self.saveButton.isEnabled = true
                            }
                        } else {
                            if self.saveButton.isEnabled {
                                self.saveButton.isEnabled = false
                            }
                        }
                    }
                }
            })
            .disposed(by: bag)
        
        modifiedNickname
            .asObservable()
            .subscribe(onNext: { (_) in
                self.enableSaveButton.accept(self.checkChanges())
            })
            .disposed(by: bag)
        
        modifiedBadge
            .asObservable()
            .subscribe(onNext: { (_) in
                self.enableSaveButton.accept(self.checkChanges())
            })
            .disposed(by: bag)
        
        modifiedForm
            .asObservable()
            .subscribe(onNext: { (_) in
                self.enableSaveButton.accept(self.checkChanges())
            })
            .disposed(by: bag)
        
        saveButton
            .rx
            .tap
            .asObservable()
            .subscribe(onNext: { (_) in
                self.onSave()
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
        if let requestFormId = requestFormId {
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.invalidateCallback(requestFormId)
            })
        }
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configureNavbar() {
        navigationItem.setLeftBarButton(UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                                        style: .plain, target: self, action: #selector(dismissController)), animated: true)
    }
    
    open func configure(_ userId: String, groupchat: String, owner: String) {
        title = "Properties".localizeString(id: "groupchat_properties", arguments: [])
        self.userId = userId
        self.groupchat = groupchat
        self.owner = owner
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        configureNavbar()
        load()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        inSaveMode.accept(true)
//        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//            self.requestFormId = user.groupchats.requestEditUserForm(stream, groupchat: self.groupchat,
//                                                                     userId: self.userId,
//                                                                     callback: self.onReceiveForm)
//        })
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
