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
import RxCocoa
import RxSwift
import CocoaLumberjack
import TOInsetGroupedTableView

class AddContactViewController: BaseViewController {
    
    class Datasource {
        
        enum Kind {
            case account
            case field
            case group
        }
        var kind: Kind
        var title: String
        var value: String
        var key: String
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, value: String = "", key: String = "", childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.key = key
            self.childs = childs
        }
    }
    
    open var isModal: Bool = false
    open var delegate: AddContactDelegate? = nil
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(AccountCell.self, forCellReuseIdentifier: AccountCell.cellName)
        view.register(EditCell.self, forCellReuseIdentifier: EditCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "GroupsCell")
        view.keyboardDismissMode = .onDrag
        
        view.isEditing = true
        view.allowsMultipleSelectionDuringEditing = true
        
        return view
    }()
    
    internal let doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Add".localizeString(id: "add", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        return button
    }()
    
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal var rosterRequestId: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    internal var subscribtionBag: DisposeBag = DisposeBag()
    override var owner: String {
        didSet {
            updateDatasource(for: owner)
        }
    }
    
    var datasource: [Datasource] = []
    
    public var contactJid: String = ""
    public var contactNickname: String = ""
    public var contactNicknamePlaceholder: String? = nil
    internal var groups: [String] = []
    internal var groupsChecked: Set<String> = Set<String>()
    
    internal var doneButtonActive: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var tableViewBottomInset: CGFloat = 8 {
        didSet {
            tableView.contentInset.bottom = tableViewBottomInset
            tableView.scrollIndicatorInsets.bottom = tableViewBottomInset
        }
    }
    
    internal var automaticallyAddedBottomInset: CGFloat {
        if #available(iOS 11.0, *) {
            return tableView.adjustedContentInset.bottom - tableView.contentInset.bottom
        } else {
            return 0
        }
    }
    
    internal var additionalBottomInset: CGFloat = 8 {
        didSet {
            let delta = additionalBottomInset - oldValue
            tableViewBottomInset += delta
        }
    }
    
    internal var initialBottomInset: CGFloat {
        if #available(iOS 11, *) {
            return 0
        } else {
            return 8
        }
    }
    
    @objc
    internal func dismissScreen(_ sender: AnyObject) {
        if isModal {
            self.dismiss(animated: true, completion: nil)
        } else {
            self.navigationController?.popToRootViewController(animated: true)
        }
    }
    
    internal func updateDatasource(for jid: String) {
        if jid.isEmpty {
            datasource = []
            return
        }
        if AccountManager.shared.find(for: jid) != nil {
            do {
                let realm = try WRealm.safe()
                groups = realm
                    .objects(RosterGroupStorageItem.self)
                    .filter("owner == %@ AND isSystemGroup == false", jid)
                    .toArray()
                    .compactMap({ return $0.name })
                    .sorted()
            } catch {
                DDLogDebug("AddContactViewController: \(#function). \(error.localizedDescription)")
            }
            groupsChecked.forEach {
                if !groups.contains($0) {
                    groupsChecked.remove($0)
                }
            }
            var items = groups.map { return Datasource(.group, title: $0)}
            items.append(Datasource(.field, title: "New circle".localizeString(id: "new_circle", arguments: []),
                                    key: "new_group_field"))
            if CommonConfigManager.shared.config.app_name == "Clandestino" {
                datasource = [
                    Datasource(.account,
                               title: "Select XMPP account".localizeString(id: "select_xmpp_account", arguments: []),
                               value: "Contact will be added to this account".localizeString(id: "contact_will_be_added", arguments: []),
                               childs: [Datasource(.account,
                                                   title: owner,
                                                   value: "")]),
                    Datasource(.field,
                               title: "Contact username",
                               childs: [Datasource(.field,
                                                   title: "Username",
                                                   value: contactJid,
                                                   key: "xmpp_id_field")]),
                    Datasource(.field,
                               title: "Nickname".localizeString(id: "vcard_nick_name", arguments: []),
                               value: "You can set custom nickname for this contact",
                               key: "nickname_field",
                               childs: [Datasource(.field,
                                                   title: "Custom nickname",
                                                   value: contactNickname,
                                                   key: "nickname_field")]),
                    Datasource(.group,
                               title: "Circles".localizeString(id: "contact_circle", arguments: []),
                               value: "You can add contact to more than one circle".localizeString(id: "contact_more_than_one_circle", arguments: []),
                               childs: items)
                ]
            } else {
                datasource = [
                    Datasource(.account,
                               title: "Select XMPP account".localizeString(id: "select_xmpp_account", arguments: []),
                               value: "Contact will be added to this account".localizeString(id: "contact_will_be_added", arguments: []),
                               childs: [Datasource(.account,
                                                   title: owner,
                                                   value: "")]),
                    Datasource(.field,
                               title: "Contact XMPP ID".localizeString(id: "dialog_add_contact__label_jid", arguments: []),
                               value: "Example: username".localizeString(id: "devices_dialog_device_example", arguments: ["username"]),
                               childs: [Datasource(.field,
                                                   title: "XMPP Id",
                                                   value: contactJid,
                                                   key: "xmpp_id_field")]),
                    Datasource(.field,
                               title: "Nickname".localizeString(id: "vcard_nick_name", arguments: []),
                               value: "You can set custom nickname for this contact",
                               key: "nickname_field",
                               childs: [Datasource(.field,
                                                   title: "Custom nickname",
                                                   value: contactNickname,
                                                   key: "nickname_field")]),
                    Datasource(.group,
                               title: "Circles".localizeString(id: "contact_circle", arguments: []),
                               value: "You can add contact to more than one circle".localizeString(id: "contact_more_than_one_circle", arguments: []),
                               childs: items)
                ]
            }
            if AccountManager.shared.users.count < 2 {
                _ = datasource.removeFirst()
            }
            self.tableView.reloadData()
        } else {
            datasource = []
        }
    }
    
    internal func subscribe() {
        addObservers()
        bag = DisposeBag()
        doneButton.rx.tap.bind {
            self.onAdd()
        }.disposed(by: bag)
        
        doneButtonActive.asObservable().subscribe(onNext: { (value) in
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.33, animations: {
                    self.doneButton.isEnabled = value
                })
            }
        }).disposed(by: bag)
        
        inSaveMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    self.tableView.isUserInteractionEnabled = !value
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(self.doneButton, animated: true)
                    }
                }
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        removeObservers()
        bag = DisposeBag()
        subscribtionBag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        title = "Add contact".localizeString(id: "application_action_no_contacts", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        if owner.isEmpty {
            do {
                let realm = try WRealm.safe()
                owner = realm.objects(AccountStorageItem.self).filter("enabled == true").sorted(byKeyPath: "order", ascending: true).first?.jid ?? ""
            } catch {
                DDLogDebug("AddContactViewController: \(#function). \(error.localizedDescription)")
            }
        }
        navigationItem.setRightBarButton(doneButton, animated: true)
        hideKeyboardWhenTappedAround()
        if isModal {
            navigationItem.setHidesBackButton(true, animated: false)
            navigationItem.setLeftBarButton(UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                                            style: .plain, target: self,
                                                            action: #selector(self.dismissScreen)), animated: true)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        activateConstraints()
        tableView.tableHeaderView = UIView()
        tableView.tableFooterView = UIView()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
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
