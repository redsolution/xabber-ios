//
//  AbuseReportViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 12.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
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
import XMPPFramework.XMPPJID


class AbuseReportViewController: SimpleBaseViewController {
    class CustomAbuseTextFieldCell: UITableViewCell {
        static let cellName: String = "CustomAbuseTextFieldCell"
        
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
    
    class AbuseGroupItemCell: UITableViewCell {
        static let cellName: String = "AbuseGroupItemCell"
                
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
        
        view.register(CustomAbuseTextFieldCell.self, forCellReuseIdentifier: CustomAbuseTextFieldCell.cellName)
        view.register(AbuseGroupItemCell.self, forCellReuseIdentifier: AbuseGroupItemCell.cellName)
        
        return view
    }()
    
    open var message: String = ""
    
    open var conversationType: ClientSynchronizationManager.ConversationType = .regular
    
    var datasource: [Datasource] = []
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Send")
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let keyboardFrameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        
        if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let frame = frameValue.cgRectValue
            let keyboardVisibleHeight = frame.size.height
//                print("keyboardVisibleHeight", keyboardVisibleHeight)
            switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                    guard let window = self.view.window else { return }
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    let keyboardFrameInScreen = keyboardFrameValue.cgRectValue
                    let keyboardFrameInView = self.view.convert(keyboardFrameInScreen, from: window)
                    let overlapHeight = max(0, self.view.bounds.height - keyboardFrameInView.minY)
                    let bottomInset = overlapHeight
                    let contentInsets = UIEdgeInsets(top: self.tableView.contentInset.top,
                                                     left: self.tableView.contentInset.left,
                                                     bottom: bottomInset,
                                                     right: self.tableView.contentInset.right)
                    UIView.animate(withDuration: TimeInterval(duration.doubleValue),
                                   delay: 0,
                                   options: options,
                                   animations: {
                        self.tableView.contentInset = contentInsets
                        self.tableView.scrollIndicatorInsets = contentInsets
                    })
            default:
                break
            }
        }
        
        
    }
    
    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
        if let userInfo = notification.userInfo {
            
            switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
            case let (.some(duration), .some(curve)):
                let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                
                UIView.animate(
                    withDuration: TimeInterval(duration.doubleValue),
                    delay: 0,
                    options: options,
                    animations: {
                        self.tableView.contentInset.bottom = 0
                        self.tableView.scrollIndicatorInsets.bottom = 0
                    }, completion: { finished in
                })
            default:
                break
            }
        }
    }
    
    override func subscribe() {
        super.subscribe()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillShowNotification(_:)),
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillHideNotification(_:)),
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
        
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
        
        self.datasource = [
            Datasource(.group, value: "Spam or unsolicited advertising", isChecked: false, isChanged: false),
            Datasource(.group, value: "Harassment or bullying", isChecked: false, isChanged: false),
            Datasource(.group, value: "Hate speech or discrimination", isChecked: false, isChanged: false),
            Datasource(.group, value: "Threats or violence", isChecked: false, isChanged: false),
            Datasource(.group, value: "Illegal content (e.g., drugs, weapons)", isChecked: false, isChanged: false),
            Datasource(.group, value: "Misinformation or scams", isChecked: false, isChanged: false),
            Datasource(.group, value: "Inappropriate or explicit material", isChecked: false, isChanged: false),
            Datasource(.field, value: "", isChecked: false, isChanged: false),
        ]
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.title = "Report Message"
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
            if $0.kind == .field {
                return "Other - \($0.value)"
            }
            return "\($0.value),"
        })
        guard changes.isNotEmpty else {
            return
        }
        let report = changes.joined(separator: "\n")
        print(report)
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.abuse.report(stream, message: self.message, reason: report)
        }
        

        self.dismiss(animated: true)
    }
}

extension AbuseReportViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        self.datasource.count
    }
    
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "This report will go to the abuse service of \(XMPPJID(string: jid)?.domain ?? jid) — the server that hosts this \(self.conversationType == .group ? "group" : "user"). It will include your XMPP address, so the administrators can handle it properly.\nChoose one or more reasons below to assist with keeping things safe:"
    }
    internal func onAddNewGroup(_ textField: UITextField?, key: String, value: String?) {
//        if let value = value {
            
//            self.tableView.performBatchUpdates {
//                self.datasource.insert(Datasource(.group, value: value, isChecked: true, isChanged: true), at: 1)
//                self.tableView.insertRows(at: [IndexPath(row: 1, section: 0)], with: .automatic)
//            }
//            self.tableView.selectRow(at: IndexPath(row: 1, section: 0), animated: true, scrollPosition: .none)
//            textField?.text = nil
//            textField?.resignFirstResponder()
        if let index = self.datasource.firstIndex(where: { $0.kind == .field }) {
            self.datasource[index].isChanged = value != nil
            self.datasource[index].isChecked = value != nil
            self.datasource[index].value = value ?? ""
        }
        self.updateChanges()
        self.dismissKeyboard()
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if indexPath.row == self.datasource.count - 1 {
            return false
        }
        return true
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.row]
        switch item.kind {
            case .field:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: CustomAbuseTextFieldCell.cellName, for: indexPath) as? CustomAbuseTextFieldCell else {
                    fatalError()
                }
                
                cell.configure("Other", value: nil, key: "custom_abuse_text")
                cell.callback = onAddNewGroup
                cell.configureField { field in
                    field.delegate = self
                }
                
                cell.selectionStyle = .none
                
                
                return cell
            case .group:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: AbuseGroupItemCell.cellName, for: indexPath) as? AbuseGroupItemCell else {
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

extension AbuseReportViewController: UITableViewDelegate {
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

extension AbuseReportViewController: UITextFieldDelegate {
        
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.onAddNewGroup(textField, key: "", value: textField.text)
        return true
    }
}


