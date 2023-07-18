//
//  NewCallSearchViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 05.02.2021.
//  Copyright © 2021 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import CocoaLumberjack

class NewCallSearchViewController: BaseViewController {
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
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.keyboardDismissMode = .onDrag
        
        view.register(NewCallViewController.ItemCell.self,
                      forCellReuseIdentifier: NewCallViewController.ItemCell.cellName)
        
        return view
    }()
    
    internal var datasource: [NewCallViewController.Datasource] = []
    
    open var delegate: NewCallViewControllerDelegate? = nil
    
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
            
            let enabledAccounts = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .compactMap { return $0.jid }
            let contacts = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND subscription_ == %@ AND jid != owner AND customUsername CONTAINS[c] %@ OR username CONTAINS[c] %@ OR jid CONTAINS[c] %@",
                        Array(enabledAccounts),
                        RosterStorageItem.Subsccribtion.both.rawValue,
                        text, text, text)
                .sorted(by: [SortDescriptor(keyPath: "jid", ascending: true),
                             SortDescriptor(keyPath: "username", ascending: true),
                             SortDescriptor(keyPath: "customUsername", ascending: true)])
            self.datasource = contacts.compactMap({ (item) -> NewCallViewController.Datasource? in
                switch item.getPrimaryResource()?.entity ?? .contact {
                case .contact:
                    return NewCallViewController.Datasource(owner: item.owner, jid: item.jid, username: item.displayName)
                default:
                    return nil
                }
            })
            self.tableView.reloadData()
        } catch {
            DDLogDebug("NewEntitySearchViewController: \(#function). \(error.localizedDescription)")
        }
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
