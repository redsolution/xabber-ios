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
import CocoaLumberjack

class InviteSearchViewController: BaseViewController {

    open var onSelectCallback: ((String) -> Void)? = nil
    open var onDeselectCallback: ((String) -> Void)? = nil
    
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
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.keyboardDismissMode = .onDrag
        
        view.register(GroupchatInviteViewController.ContactCell.self,
                      forCellReuseIdentifier: GroupchatInviteViewController.ContactCell.cellName)
        
        view.tableHeaderView = UIView()
        view.tableFooterView = UIView()
        
        return view
    }()
    
    internal var contacts: Results<RosterStorageItem>? = nil
    internal var bag: DisposeBag = DisposeBag()
    
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
    
    internal func updateSearchResults(with text: String) {
        do {
            let realm = try WRealm.safe()
            contacts = realm
                .objects(RosterStorageItem.self)
//                .filter("isHidden == %@ AND removed == %@", false, false)
                .filter("customUsername CONTAINS[c] %@ OR username CONTAINS[c] %@ OR jid CONTAINS[c] %@", text, text, text)
                .sorted(byKeyPath: "jid", ascending: true)
            self.tableView.reloadData()
            subscribe()
        } catch {
            DDLogDebug("NewEntitySearchViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        if contacts != nil {
            Observable
                .changeset(from: contacts!)
//                .debug()
                .subscribe(onNext: { (results) in
                    guard let changeset = results.1 else { return }
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
    
    func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleKeyboardDidChangeState(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.delegate = self
        tableView.dataSource = self
        
        tableView.isEditing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.isUserInteractionEnabled = true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addObservers()
        configure()
        
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
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeObservers()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
