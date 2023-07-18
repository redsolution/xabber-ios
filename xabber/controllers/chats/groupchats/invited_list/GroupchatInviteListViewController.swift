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

class GroupchatInviteListViewController: BaseViewController {
    
//    internal var jid: String = ""
//    internal var owner: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasource: [String] = []
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var selectedJids: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var revokedJids: Set<String> = Set<String>()
    internal var conflictJids: Set<String> = Set<String>()
    
    internal var revokeErrorMessage: String? = nil
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Revoke".localizeString(id: "groupchat_revoke", arguments: []),
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
        
        label.text = "No pending invitations"
            .localizeString(id: "group_settings__invitations__no_pending_invitations", arguments: [])
        label.isHidden = true
        label.textAlignment = .center
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
    
    internal func subscribe() {
        bag = DisposeBag()
        selectedJids
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
                self.onRevoke()
            })
            .disposed(by: bag)
        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm
                    .objects(GroupChatStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, jid))
                .subscribe(onNext: { (results) in
                    if results.isEmpty {
                        self.tableView.reloadData()
                        return
                    }
                    if let invitesList = results.first?.invited.sorted().toArray() {
                        UIView.performWithoutAnimation {
                            self.tableView.reload(changes: diff(old: self.datasource, new: invitesList),
                                                  section: 0,
                                                  insertionAnimation: .none,
                                                  deletionAnimation: .none,
                                                  replacementAnimation: .none,
                                                  updateData: {
                                                    self.datasource = invitesList
                            }, completion: nil)
                        }
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("GroupchatInviteListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configure(_ jid: String, owner: String) {
        title = "Invitations".localizeString(id: "groupchat_invitations", arguments: [])
        self.jid = jid
        self.owner = owner
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        emptyStateLabel.frame = CGRect(width: view.frame.width, height: 88)
        tableView.backgroundView = emptyStateLabel
        activateConstraints()
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.requestInvitedUsers(stream, groupchat: self.jid)
        })
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
        navigationController?.setNavigationBarHidden(false, animated: true)
        subscribe()
//        if #available(iOS 13.0, *) {
//            navigationController?
//                .navigationBar
//                .titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.label]
//        } else {
        
            navigationController?
                .navigationBar
                .titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.darkText]
//        }
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
}
