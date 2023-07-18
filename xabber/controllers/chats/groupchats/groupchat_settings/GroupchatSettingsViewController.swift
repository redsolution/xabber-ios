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
import TOInsetGroupedTableView

class GroupchatSettingsViewController: BaseViewController {
    
    internal class Datasource {
        enum Kind {
            case textSingle
            case textMulti
            case listSingle
            case delete
        }
        
        var kind: Kind
        var itemId: String
        var header: String
        var footer: String
        var placeholder: String
        var value: String
        var values: [String]
        var options: [[String: String]]
        var raw: [String: Any]
        
        init(_ kind: Kind, itemId: String, header: String, footer: String, placeholder: String, value: String, values: [String], options: [[String: String]], raw: [String: Any]) {
            self.kind = kind
            self.itemId = itemId
            self.header = header
            self.footer = footer
            self.placeholder = placeholder
            self.value = value
            self.values = values
            self.options = options
            self.raw = raw
        }
    }
    
    open var isStatus: Bool = false
    
//    internal var jid: String = ""
//    internal var owner: String = ""
    
    open var entity: RosterItemEntity = .groupchat
    
    internal var datasource: [Datasource] = []
    
    internal var form: [[String: Any]] = []
    internal var changedValues: BehaviorRelay<[[String: Any]]> = BehaviorRelay(value: [])
    
    internal var formLoadError: String? = nil
    
    var formId: String? = nil
    var updateFormId: String? = nil
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    
    internal var bag: DisposeBag = DisposeBag()
    
    private var tableViewBottomInset: CGFloat = 8 {
        didSet {
            tableView.contentInset.bottom = tableViewBottomInset
            tableView.scrollIndicatorInsets.bottom = tableViewBottomInset
        }
    }
    private var automaticallyAddedBottomInset: CGFloat {
        if #available(iOS 11.0, *) {
            return tableView.adjustedContentInset.bottom - tableView.contentInset.bottom
        } else {
            return 0
        }
    }
    
    private var additionalBottomInset: CGFloat = 8 {
        didSet {
            let delta = additionalBottomInset - oldValue
            tableViewBottomInset += delta
        }
    }
    
    private var initialBottomInset: CGFloat {
        if #available(iOS 11, *) {
            return 0
        } else {
            return 8
        }
    }
    
    internal let createIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        return button
    }()
    
    internal let editButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Edit".localizeString(id: "groupchat_member_edit", arguments: []),
                                     style: .plain, target: nil, action: nil)
        return button
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.remembersLastFocusedIndexPath = true
        view.keyboardDismissMode = .onDrag
        
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        view.register(InfoCell.self, forCellReuseIdentifier: InfoCell.cellName)
        view.register(TextItemCell.self, forCellReuseIdentifier: TextItemCell.cellName)
        view.register(LargeTextItemCell.self, forCellReuseIdentifier: LargeTextItemCell.cellName)
        
        return view
    }()
    
    internal func requiredScrollViewBottomInset(forKeyboardFrame keyboardFrame: CGRect) -> CGFloat {
        let intersection = tableView.frame.intersection(keyboardFrame)
        if intersection.isNull || intersection.maxY < tableView.frame.maxY {
            return max(initialBottomInset, additionalBottomInset - automaticallyAddedBottomInset)
        } else {
            return max(initialBottomInset, intersection.height + additionalBottomInset - automaticallyAddedBottomInset)
        }
    }
    
    @objc
    internal func handleKeyboardDidChangeState(_ notification: Notification) {
        guard let keyboardStartFrameInScreenCoords = notification
            .userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect,
            !keyboardStartFrameInScreenCoords.isEmpty,
            let keyboardEndFrameInScreenCoords = notification
                .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardEndFrame = view.convert(keyboardEndFrameInScreenCoords, from: view.window)
        let newBottomInset = requiredScrollViewBottomInset(forKeyboardFrame: keyboardEndFrame)
        tableViewBottomInset = newBottomInset
    }
    
    func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleKeyboardDidChangeState(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    internal func subscribe() {
        addObservers()
        bag = DisposeBag()
        inSaveMode
            .asObservable()
//            .debug()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    self.tableView.allowsSelection = !value
                    if value {
                        self.navigationItem.setRightBarButtonItems([self.createIndicator], animated: true)
                    } else {
                        self.navigationItem.setRightBarButtonItems([self.saveButton], animated: true)
                    }
                    if self.datasource.isNotEmpty {
                        self.tableView.reloadData()
                    }
                }
            })
            .disposed(by: bag)
        
        changedValues
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.33) {
                        if self.saveButton.isEnabled {
                            if value.isEmpty {
                                self.saveButton.isEnabled = false
                            }
                        } else {
                            if value.isNotEmpty {
                                self.saveButton.isEnabled = true
                            }
                        }
                    }
                }
            })
            .disposed(by: bag)
        
        saveButton
            .rx
            .tap
            .subscribe(onNext: { _ in
                self.onSave()
            })
            .disposed(by: bag)
        
        editButton
            .rx
            .tap
            .subscribe(onNext: { (_) in
                self.onEditGroups()
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        removeObservers()
        bag = DisposeBag()
        if let formId = formId {
            AccountManager.shared.find(for: owner)?.groupchats.invalidateCallback(formId)
            XMPPUIActionManager.shared.groupchat?.invalidateCallback(formId)
        }
        if let updateFormId = updateFormId {
            AccountManager.shared.find(for: owner)?.groupchats.invalidateCallback(updateFormId)
            XMPPUIActionManager.shared.groupchat?.invalidateCallback(updateFormId)
        }
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(_ owner: String, jid: String) {
        if isStatus {
            self.title = "Status".localizeString(id: "groupchat_status", arguments: [])
        } else {
            self.title = "Settings".localizeString(id: "settings", arguments: [])
        }
        
        self.owner = owner
        self.jid = jid
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        if isStatus {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                self.formId = session.groupchat?.requestChatStatusForm(stream, groupchat: self.jid, callback: self.onFormCallback)
            }) {
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    self.formId = user.groupchats.requestChatStatusForm(stream, groupchat: self.jid, callback: self.onFormCallback)
                })
            }
        } else {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                self.formId = session.groupchat?.requestChatSettingsForm(stream, groupchat: self.jid, callback: self.onFormCallback)
            }) {
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    self.formId = user.groupchats.requestChatSettingsForm(stream, groupchat: self.jid, callback: self.onFormCallback)
                })
            }
        }
        if isStatus {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
            self.navigationItem.setLeftBarButton(cancelButton, animated: true)
        }
    }
    
    @objc
    internal func close(_ sender: AnyObject) {
        self.dismiss(animated: true, completion: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
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
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
