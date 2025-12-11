//
//  EditCirclesViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 10.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RxSwift
import RxCocoa
import RxRelay

class EditCirclesViewController: SimpleBaseViewController {
    
    class NewGroupTextFieldCell: UITableViewCell {
        static let cellName: String = "NewGroupTextFieldCell"
        
        var key: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var field: UITextField = {
            let field = UITextField()
            
            field.autocorrectionType = .default
            field.clearButtonMode = .never
            field.autocapitalizationType = .sentences
            field.spellCheckingType = .yes
            field.keyboardType = .default
            field.returnKeyType = .done
            
            return field
        }()
        
        var callback: ((UITextField?, String, String?) -> Void)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ title: String, value: String?, key: String) {
            field.text = value
            field.placeholder = title
            field.clearButtonMode = .always
            self.key = key
        }
        
        func configureField(_ block: ((UITextField) -> Void)) {
            block(field)
        }
        
        private func setupSubviews() {
            contentView.addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .systemBackground
            activateConstraints()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        internal func fieldDidChange(_ sender: UITextField) {
            callback?(self.field, self.key, sender.text)
        }
    }
    
    class GroupItemCell: UITableViewCell {
        static let cellName: String = "GroupItemCell"
                
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            
            return label
        }()
        
        private func activateConstraints() {
            
        }
        
        func configure(_ title: String) {
            self.titleLabel.text = title
        }
                
        private func setupSubviews() {
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            backgroundColor = .systemBackground
            activateConstraints()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
    }
    
    class Datasource {
        enum Kind {
            case group
            case field
        }
        
        var kind: Kind
        var value: String
        var originalStatus: Bool
        var isChecked: Bool
        var isChanged: Bool
        
        init(_ kind: Kind, value: String, isChecked: Bool, isChanged: Bool) {
            self.kind = kind
            self.value = value
            self.isChecked = isChecked
            self.originalStatus = isChecked
            self.isChanged = isChanged
        }
    }
    
    
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(NewGroupTextFieldCell.self, forCellReuseIdentifier: NewGroupTextFieldCell.cellName)
        view.register(GroupItemCell.self, forCellReuseIdentifier: GroupItemCell.cellName)
        
        return view
    }()
    
    var datasource: [Datasource] = []
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .save)
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    override func subscribe() {
        super.subscribe()
        self.changesObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    self.navigationItem.setLeftBarButton(self.cancelBarButton, animated: true)
                    self.navigationItem.setRightBarButton(self.saveBarButton, animated: true)
                } else {
                    self.navigationItem.setLeftBarButton(self.navigationItem.backBarButtonItem, animated: true)
                    self.navigationItem.setRightBarButton(nil, animated: true)
                }
            }
            .disposed(by: self.bag)

    }
    
    override func loadDatasource() {
        super.loadDatasource()
        
        do {
            let realm = try WRealm.safe()
            let groups = realm.objects(RosterGroupStorageItem.self).filter("owner == %@ AND isSystemGroup == false", self.owner).toArray()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                let checkedGroups = Set(instance.groups.toArray())
                self.datasource = [Datasource(.field, value: "", isChecked: false, isChanged: false)]
                self.datasource.append(contentsOf: groups.compactMap {
                    group in
                    return Datasource(.group, value: group.name, isChecked: checkedGroups.contains(group.name), isChanged: false)
                })
            }
            self.tableView.reloadData()
            self.datasource.enumerated().forEach {
                (offset, item) in
                if item.isChecked {
                    self.tableView.selectRow(at: IndexPath(row: offset, section: 0), animated: true, scrollPosition: .none)
                }
            }
        } catch {
            DDLogDebug("EditCirclesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.title = "Edit circles"
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.setEditing(true, animated: false)
        self.tableView.allowsMultipleSelection = true
        self.tableView.allowsMultipleSelectionDuringEditing = true
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }
    
    @objc
    internal func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        self.navigationController?.popViewController(animated: true)
    }
        
    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        let changes = self.datasource.filter({ $0.isChecked }).compactMap({
            return $0.value
        })
        guard changes.isNotEmpty else {
            return
        }
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.roster?.setContact(
                stream,
                jid: self.jid,
                getNickFromVCard: false,
                nickname: nil,
                groups: Array(Set(changes)),
                shouldAddSystemMessage: false,
                callback: nil
            )
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.roster.setContact(
                    stream,
                    jid: self.jid,
                    getNickFromVCard: false,
                    nickname: nil,
                    groups: Array(Set(changes)),
                    shouldAddSystemMessage: false,
                    callback: nil
                )
            }
        }
        self.navigationController?.popViewController(animated: true)
    }
}

extension EditCirclesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.datasource.count
    }
    
    internal func onAddNewGroup(_ textField: UITextField?, key: String, value: String?) {
        if let value = value {
            
            self.tableView.performBatchUpdates {
                self.datasource.insert(Datasource(.group, value: value, isChecked: true, isChanged: true), at: 1)
                self.tableView.insertRows(at: [IndexPath(row: 1, section: 0)], with: .automatic)
            }
            self.tableView.selectRow(at: IndexPath(row: 1, section: 0), animated: true, scrollPosition: .none)
            textField?.text = nil
            textField?.resignFirstResponder()
            self.updateChanges()
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if indexPath.row == 0 {
            return false
        }
        return true
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.row]
        switch item.kind {
            case .field:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NewGroupTextFieldCell.cellName, for: indexPath) as? NewGroupTextFieldCell else {
                    fatalError()
                }
                
                cell.configure("Add new circle", value: nil, key: "new_group")
                cell.callback = onAddNewGroup
                cell.configureField { field in
                    field.delegate = self
                }
                
                cell.selectionStyle = .none
                
                
                return cell
            case .group:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupItemCell.cellName, for: indexPath) as? GroupItemCell else {
                    fatalError()
                }
                
                cell.configure(item.value)
                
                let view = UIView()
                view.backgroundColor = .systemBackground
                cell.selectedBackgroundView = view
                
                return cell
        }
    }
    
    
}

extension EditCirclesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    private func updateChanges() {
        self.changesObserver.accept(self.datasource.filter({ $0.isChanged }).isNotEmpty)
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        self.datasource[indexPath.row].isChecked = true
        self.datasource[indexPath.row].isChanged = self.datasource[indexPath.row].isChecked != self.datasource[indexPath.row].originalStatus
        updateChanges()
    }
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        self.datasource[indexPath.row].isChecked = false
        self.datasource[indexPath.row].isChanged = self.datasource[indexPath.row].isChecked != self.datasource[indexPath.row].originalStatus
        updateChanges()
    }
}

extension EditCirclesViewController: UITextFieldDelegate {
        
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.onAddNewGroup(textField, key: "", value: textField.text)
        return true
    }
}
