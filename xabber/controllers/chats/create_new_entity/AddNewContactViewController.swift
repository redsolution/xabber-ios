//
//  AddNewContactViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 29.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift

import RxSwift
import RxCocoa
import RxRealm

import XMPPFramework.XMPPJID

class AddNewContactViewController: UIViewController {
    
    class FieldWithCheckmarkTableCell: BaseTableCell {
        static let cellName: String = "FieldWithCheckmarkTableCell"
        
        open var textFieldDelegate: UITextFieldDidChangeProtocol? = nil
        
        internal let textField: UITextField = {
            let field = UITextField()
            
            let placeholderDomain = CommonConfigManager.shared.config.domain
            field.placeholder = "john.doe@\(placeholderDomain.isEmpty ? "example.com" : placeholderDomain)"
            field.keyboardType = .emailAddress
            field.returnKeyType = .done
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.restorationIdentifier = "NewAccountJIDFieldRID"
            
            return field
        }()
                
        open func configure() {
            
        }
        
        override func setupSubviews() {
            super.setupSubviews()
            contentView.addSubview(textField)
            textField.fillSuperviewWithOffset(top: 4, bottom: 4, left: 16, right: 20)
            textField.addTarget(self, action: #selector(textFieldEditingChange), for: .editingChanged)
        }
        
        @objc
        private func textFieldEditingChange(_ sender: UITextField) {
            self.textFieldDelegate?.textField(didChangeValueTo: sender.text, forField: "add_contact")
        }
    }
    
    enum ValidateErrors {
        case noError
        case fullJid
        case notJid
        case notFound
        case unexpected
    }
    
    var errorsObserver: BehaviorRelay<ValidateErrors?> = BehaviorRelay(value: nil)
    var bag: DisposeBag = DisposeBag()
    
    var accountJid: String = AccountManager.shared.users.first?.jid ?? ""
    var contactJid: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(FieldWithCheckmarkTableCell.self, forCellReuseIdentifier: FieldWithCheckmarkTableCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        
        return view
    }()
    
    private func loadDatasource() {
        
        
    }
    
    func subscribe() {
        self.bag = DisposeBag()
        
        self.errorsObserver.asObservable().debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance).subscribe { error in
                guard let error = error else {
                    self.addButton.isEnabled = false
                    return
                }
                switch error {
                    case .fullJid:
                        self.addButton.isEnabled = false
                    case .notJid:
                        self.addButton.isEnabled = false
                    case .notFound:
                        self.addButton.isEnabled = false
                    case .unexpected:
                        self.addButton.isEnabled = false
                    case .noError:
                        self.addButton.isEnabled = true
                }
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

        
        self.contactJid
            .asObservable()
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { text in
                guard let text = text else {
                    self.errorsObserver.accept(nil)
                    return
                }
                guard text.contains("@") else {
                    self.errorsObserver.accept(nil)
                    return
                }
                guard let jid = XMPPJID(string: text) else {
                    self.errorsObserver.accept(.notJid)
                    return
                }
                guard jid.resource == nil else {
                    self.errorsObserver.accept(.fullJid)
                    return
                }
                self.addButton.isEnabled = true
                self.errorsObserver.accept(.noError)
//                self.tableView.reload
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }
    
    internal let addButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Add", style: .done, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
    
    
    
    internal let indicatorButton: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    public func configure() {
        navigationController?.navigationBar.prefersLargeTitles = false
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
        self.navigationItem.setRightBarButton(addButton, animated: true)
        self.addButton.target = self
        self.addButton.action = #selector(onAddButtonTouchUpInside)
    }
    
    func changeElementsState(enabled: Bool) {
        DispatchQueue.main.async {
            (self.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FieldWithCheckmarkTableCell)?.textField.isEnabled = enabled
            self.addButton.isEnabled = enabled
            self.navigationItem.setRightBarButton(enabled ? self.addButton : self.indicatorButton, animated: true)
        }
    }
    
    func closeAndDisplayContact(jid: String, owner: String) {
        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                let splitVc = (UIApplication.shared.delegate as? AppDelegate)?.splitController
                let vc = ChatViewController()
                vc.jid = jid
                vc.owner = owner
                vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                
                splitVc?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                splitVc?.hide(.primary)
            }
        }
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: UIBarButtonItem) {
        guard let jidRaw = self.contactJid.value,
              jidRaw.isNotEmpty,
              let jid = XMPPJID(string: jidRaw)?.bare else {
            return
        }
        let owner = accountJid
        let conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.changeElementsState(enabled: false)
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.vcards.requestItem(stream, jid: jid) { vcardJid, result in
                self.changeElementsState(enabled: true)
                if vcardJid == self.contactJid.value {
                    if result {
                        user.presences.subscribe(stream, jid: jid)
                        user.presences.subscribed(stream, jid: jid)
                        user.roster.setContact(stream, jid: jid, shouldAddSystemMessage: true) { resultJid, error, result in
                            if result {
                                user.lastChats.initChat(jid: jid, conversationType: conversationType)
                                self.closeAndDisplayContact(jid: jid, owner: owner)
                            } else {
                                self.errorsObserver.accept(.notFound)
                                DispatchQueue.main.async {
                                    self.view.makeToast("Contact server not found")
                                }
                            }
                        }
                    } else {
                        self.errorsObserver.accept(.notFound)
                        DispatchQueue.main.async {
                            self.tableView.reloadData()
                        }
                    }
                } else {
                    self.errorsObserver.accept(.unexpected)
                }
            }
        })
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
    }
    
    
    private func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
    }

    @objc
    func languageChanged() {
        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        removeNotificationObserer()
    }
    
    internal var randTitle: String = RandomTitleManager.shared.title()
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.title = "Add contact"
        self.subscribe()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.unsubscribe()
    }
}


extension AddNewContactViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: FieldWithCheckmarkTableCell.cellName, for: indexPath) as? FieldWithCheckmarkTableCell else {
                fatalError()
            }
            
            cell.configure()
            cell.textField.text = self.contactJid.value
            cell.textFieldDelegate = self
            
            return cell
        } else {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "tablecell")
            
            cell.textLabel?.text = self.accountJid
            cell.selectionStyle = .none
            cell.accessoryType = .disclosureIndicator
            
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 1 {
            return "Selected XMPP Account"
        }
        return "Contact XMPP ID"
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return nil
    }
}

extension AddNewContactViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return tableView.estimatedRowHeight
    }
        
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 1 {
            let vc = NewContactSelectAccountViewController()
            vc.configure(
                AccountManager.shared.users.compactMap { return $0.jid },
                title: "Select account".localizeString(id: "choose_account", arguments: []),
                header: nil,
                footer: nil,
                current: self.accountJid
            ) {
                (value) in
                self.accountJid = value
                DispatchQueue.main.async {
                    self.tableView.reloadRows(at: [IndexPath(row: 0, section: 1)],with: .none)
                }
            }
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}

protocol UITextFieldDidChangeProtocol {
    func textField(didChangeValueTo text: String?, forField key: String)
}

extension AddNewContactViewController: UITextFieldDidChangeProtocol {
    func textField(didChangeValueTo text: String?, forField key: String) {
        switch key {
            case "add_contact":
                self.contactJid.accept(text)
            default:
                break
        }
    }
}
