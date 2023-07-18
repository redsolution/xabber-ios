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

class GroupchatBlockedViewController: BaseViewController {
    
//    internal var owner: String = ""
//    internal var jid: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasource: Results<GroupchatUserStorageItem>? = nil
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var selectedIds: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var conflictIds: Set<String> = Set<String>()
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Unblock".localizeString(id: "contact_bar_unblock", arguments: []),
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
        
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
        view.isEditing = true
        view.allowsMultipleSelectionDuringEditing = true
        
        return view
    }()
    
    internal let emptyStateLabel: UILabel = {
        let label = UILabel()
        
        label.text = "Block list is empty".localizeString(id: "groupchat_blocklist_empty", arguments: [])
        label.isHidden = true
        label.textAlignment = .center
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            datasource = realm
                .objects(GroupchatUserStorageItem.self)
                .filter("groupchatId == %@ AND owner == %@ AND isBlocked == %@", [jid, owner].prp(), owner, true)
                .sorted(byKeyPath: "nickname", ascending: true)
        } catch {
            DDLogDebug("GroupchatBlockedViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        selectedIds
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    if value.isNotEmpty {
                        if !self.saveButton.isEnabled {
                            self.saveButton.isEnabled = true
                        }
                    } else {
                        if self.saveButton.isEnabled {
                            self.saveButton.isEnabled = false
                        }
                    }
                }
            })
            .disposed(by: bag)
        
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
        
        saveButton
            .rx
            .tap
            .asObservable()
            .subscribe(onNext: { _ in
                self.onUnblock()
            })
            .disposed(by: bag)
        
        if datasource != nil {
            Observable
                .changeset(from: datasource!)
                .subscribe(onNext: { results in
                    guard let changeset = results.1 else {
                        return
                    }
                    if results.0.isEmpty {
                        self.tableView.reloadData()
                        return
                    }
                    func updateDatasource() {
                        if changeset.updated.isNotEmpty {
                        self.tableView.reloadRows(at: changeset.updated.map { return IndexPath(row: $0, section: 0) },
                                                  with: .none)
                        }
                        if changeset.inserted.isNotEmpty {
                        self.tableView.insertRows(at: changeset.inserted.map { return IndexPath(row: $0, section: 0) },
                                                  with: .none)
                        }
                        if changeset.deleted.isNotEmpty {
                        self.tableView.deleteRows(at: changeset.deleted.map { return IndexPath(row: $0, section: 0) },
                                                  with: .none)
                        }
                    }
                    if #available(iOS 11.0, *) {
                        self.tableView.performBatchUpdates({
                            updateDatasource()
                        }, completion: nil)
                    } else {
                        self.tableView.beginUpdates()
                        updateDatasource()
                        self.tableView.endUpdates()
                    }
                })
                .disposed(by: bag)
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(_ jid: String, owner: String) {
        title = "Blocked members".localizeString(id: "account_blocked_members", arguments: [])
        
        self.jid = jid
        self.owner = owner
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        emptyStateLabel.frame = CGRect(width: view.frame.width, height: 88)
        tableView.backgroundView = emptyStateLabel
        activateConstraints()
        load()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.blockList(stream, groupchat: self.jid)
        })
        
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
        navigationController?.setNavigationBarHidden(false, animated: true)
        subscribe()
        navigationController?
            .navigationBar
            .titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.darkText]
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
