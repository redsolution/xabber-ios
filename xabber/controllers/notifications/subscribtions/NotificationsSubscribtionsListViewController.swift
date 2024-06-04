//
//  NotificationsSubscribtionsListViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 11.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RxRealm
import RxSwift
import RxCocoa
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class NotificationsSubscribtionsListViewController: SimpleBaseViewController {
    
    class EmptyView: UIView {
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        let centerStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 16
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .title2)
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
//            }//MDCPalette.grey.tint900
            
            return label
        }()
        
        let newChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
            
            return button
        }()
        
        internal var callback: (() -> Void)? = nil
        
        internal func activaateConstraints() {
//            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
        }
        
        open func configure(onCreateChatCallback: @escaping (() -> Void)) {
            backgroundColor = .systemBackground
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(titleLabel)
//            centerStack.addArrangedSubview(newChatButton)
            titleLabel.text = "You don't have any subscribtion requests"
            newChatButton.titleLabel?.numberOfLines = 0
            newChatButton.titleLabel?.textAlignment = .center
            activaateConstraints()
            callback = onCreateChatCallback
        }
        
        
        @objc
        internal func onButtonPressed(_ sender: UIButton) {
            callback?()
        }
    }
    
    internal let emptyView: EmptyView = {
        let view = EmptyView()
        
        return view
    }()
    
    var emptyScreenShowObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
        self.emptyView.isHidden = !self.emptyScreenShowObserver.value
        self.view.addSubview(self.emptyView)
        self.emptyView.fillSuperview()
        self.view.bringSubviewToFront(self.emptyView)
    }
    
    override func configure() {
        super.configure()
        self.title = "Subscribtions"
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.emptyView.configure {
            
        }
    }
    
    struct Datasource {
        let owner: String
        let jid: String
        let displayNick: String
        let avatarUrl: String?
    }
    
    var datasource: [Datasource] = []
    
    override func subscribe() {
        super.subscribe()
        
        do {
            let realm = try WRealm.safe()
            let collectionObserver = realm.objects(NotificationStorageItem.self).filter("owner == %@", self.owner)
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.loadDatasource()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.emptyScreenShowObserver
                .asObservable()
                .debounce(.milliseconds(1), scheduler: MainScheduler.asyncInstance)
                .subscribe { value in
                    self.emptyView.isHidden = !value
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
        } catch {
            
        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            let collection = realm
                .objects(NotificationStorageItem.self)
                .filter("category_ == %@", XMPPNotificationsManager.Category.contact.rawValue)
                .toArray()
            
            self.datasource = collection.compactMap {
                item -> Datasource? in
                guard let jid = item.associatedJid else {
                    return nil
                }
                var nick: String = ""
                var avatarUrl: String? = nil
                let rosterItem = realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: item.owner)
                )
                nick = rosterItem?.displayName ?? jid
                avatarUrl = rosterItem?.avatarMaxUrl ?? rosterItem?.avatarMinUrl ?? rosterItem?.oldschoolAvatarKey
                return Datasource(
                    owner: item.owner,
                    jid: jid,
                    displayNick: item.displayedNick ?? nick,
                    avatarUrl: avatarUrl
                )
            }
            self.emptyScreenShowObserver.accept(datasource.isEmpty)
        } catch {
            DDLogDebug("NotificationsSubscribtionsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
}

extension NotificationsSubscribtionsListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return UITableViewCell()
    }
    
    
}

extension NotificationsSubscribtionsListViewController: UITableViewDelegate {
    
}
