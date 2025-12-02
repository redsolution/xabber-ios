
//
//  GroupchatSettingsPromoteAdminViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 13.11.2025.
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

class GroupchatSettingsPromoteAdminViewController: SimpleBaseViewController {
    
    class SettingsItemCell: UITableViewCell {
        static let cellName: String = "SettingsItemCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
            stack.isLayoutMarginsRelativeArrangement = true
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let textField: DateTimePickerTextField = {
            let field = DateTimePickerTextField()
            
            return field
        }()
        
        func configure(title: String, badge: String, icon: String, isCustom: Bool, selectedDate: Date?) {
            self.titleLabel.text = title
            if isCustom {
                self.textField.isHidden = false
                self.textField.configureDatePicker(for: .date, key: "custom", withPlaceholder: true)
            } else {
                self.textField.isHidden = true
            }
            if let date = selectedDate {
                self.textField.setMinimumDate(date)
            }
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.textField)
            self.accessoryType = .none
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
    }
    
    
//    class SettingsSwitchCell: UITableViewCell {
//        static let cellName: String = "SettingsSwitchCell"
//        
//        let stack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.distribution = .fill
//            stack.alignment = .center
//            stack.spacing = 4
//            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
//            stack.isLayoutMarginsRelativeArrangement = true
//            
//            return stack
//        }()
//        
//        let titleLabel: UILabel = {
//            let label = UILabel()
//            
//            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            
//            return label
//        }()
//                
//        let switchView: UISwitch = {
//            let view = UISwitch()
//            
//            view.isOn = false
//            view.tintColor = .green
//            view.preferredStyle = .sliding
//            
//            return view
//        }()
//        
//        let customPeriodButton: UIButton = {
//            var conf = UIButton.Configuration.plain()
//            
//            conf.attributedTitle = AttributedString(NSAttributedString(string: "2d 13h 11m", attributes: [
//                .font: UIFont.systemFont(ofSize: 13)
//            ]))
//            
//            let button = UIButton(configuration: conf, primaryAction: nil)
//            
//            return button
//        }()
//        
//        var key: String = ""
//        var originalStatus: Bool = false
//        var customString: String = ""
//        
//        public final func updateTimer(isForever: Bool, day: Int?, hour: Int?, mins: Int?) {
//            customString = ""
//            if isForever {
//                customString = "Forever"
//            } else if let value = day, value > 0 {
//                customString = "\(value) \(value == 1 ? "Day" : "days")"
//            } else if let value = hour, value > 0 {
//                customString = "\(value) \(value == 1 ? "Hour" : "Hours")"
//            } else if let value = mins, value > 0 {
//                customString = "\(value) \(value == 1 ? "Minute" : "Minutes")"
//            }
//            
//            var conf = UIButton.Configuration.plain()
//            conf.attributedTitle = AttributedString(NSAttributedString(string: customString, attributes: [
//                .font: UIFont.systemFont(ofSize: 13),
//                .foregroundColor: isChanged ? UIColor.tintColor : UIColor.secondaryLabel
//            ]))
//            self.customPeriodButton.configuration = conf
//            self.customPeriodButton.updateConfiguration()
//            self.customPeriodButton.sizeToFit()
//            self.stack.layoutSubviews()
//        }
//        
//        func configure(title: String, isOn: Bool, key: String, isChanged: Bool, originalStatus: Bool, isForever: Bool, day: Int?, hour: Int?, mins: Int?) {
//            self.titleLabel.text = title
//            self.switchView.isOn = isOn
//            self.key = key
//            self.isChanged = isChanged
//            self.originalStatus = originalStatus
//            self.updateTimer(isForever: isForever, day: day, hour: hour, mins: mins)
//            if originalStatus != isOn {
//                self.switchView.backgroundColor = .systemGreen
//                self.switchView.onTintColor = .systemGreen
//            } else {
//                self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
//                self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
//            }
//        }
//        
//        open var isChanged: Bool = false
//        open var onSwitchValueChangedCallback: ((String, Bool) -> Void)? = nil
//        
//        @objc
//        func onChangeSwitchValue(_ sender: UISwitch) {
////            print()
//            self.isChanged = self.originalStatus != sender.isOn
//            UIView.animate(withDuration: 0.33) {
//                if self.originalStatus != sender.isOn {
//                    self.switchView.backgroundColor = .systemGreen
//                    self.switchView.onTintColor = .systemGreen
//                } else {
//                    self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
//                    self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
//                }
//                var conf = UIButton.Configuration.plain()
//                conf.attributedTitle = AttributedString(NSAttributedString(string: self.customString, attributes: [
//                    .font: UIFont.systemFont(ofSize: 13),
//                    .foregroundColor: self.isChanged ? UIColor.tintColor : UIColor.secondaryLabel
//                ]))
//                self.customPeriodButton.configuration = conf
//                self.customPeriodButton.updateConfiguration()
//                self.customPeriodButton.sizeToFit()
//            }
//            self.onSwitchValueChangedCallback?(self.key, sender.isOn)
//        }
//        
//        func setupSubviews() {
//            self.contentView.addSubview(stack)
//            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
//            self.stack.addArrangedSubview(self.titleLabel)
//            self.stack.addArrangedSubview(self.customPeriodButton)
//            self.stack.addArrangedSubview(self.switchView)
//            self.switchView.backgroundColor = .red
//            self.switchView.layer.cornerRadius = self.switchView.bounds.height / 2
//            self.switchView.layer.masksToBounds = true
//            self.switchView.addTarget(self, action: #selector(onChangeSwitchValue), for: .valueChanged)
//            self.customPeriodButton.addTarget(self, action: #selector(onCustomPeriodButtonTouchUpInside), for: .touchUpInside)
//        }
//        
//        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
//            super.init(style: style, reuseIdentifier: reuseIdentifier)
//            self.setupSubviews()
//        }
//        
//        required init?(coder: NSCoder) {
//            super.init(coder: coder)
//            self.setupSubviews()
//        }
//        
//        open var onCustomPeriodCallback: ((String) -> Void)? = nil
//        
//        @objc
//        private func onCustomPeriodButtonTouchUpInside(_ sender: UIButton) {
//            self.onCustomPeriodCallback?(self.key)
//        }
//    }
//    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    class SettingsSwitchWithKeyboardCell: UITableViewCell {
        static let cellName: String = "SettingsSwitchWithKeyboardCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 4
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
            stack.isLayoutMarginsRelativeArrangement = true
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
                
        let switchView: UISwitch = {
            let view = UISwitch()
            
            view.isOn = false
            view.tintColor = .green
            view.preferredStyle = .sliding
            
            return view
        }()
        
        let textField: DateTimePickerTextField = {
            let field = DateTimePickerTextField()
            
            return field
        }()
        
        var key: String = ""
        var originalStatus: Bool = false
        var customString: String = ""
        var currentDate: Date? = nil
        var isForever: Bool = false
        
        public final func update(with date: Date?, isForever: Bool) {
            self.textField.updateTextField(with: date, isForever: isForever)
            self.textField.sizeToFit()
            self.stack.layoutSubviews()
        }
        
        func configure(title: String, isOn: Bool, key: String, isChanged: Bool, originalStatus: Bool, isForever: Bool, date: Date?) {
            self.titleLabel.text = title
            self.switchView.isOn = isOn
            self.key = key
            self.isChanged = isChanged
            self.originalStatus = originalStatus
            self.currentDate = date
            self.isForever = isForever
            self.update(with: date, isForever: isForever)
            self.textField.isEnabled = originalStatus == isOn
            if originalStatus != isOn {
                self.switchView.backgroundColor = .systemGreen
                self.switchView.onTintColor = .systemGreen
            } else {
                self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
            }
            self.textField.configureDatePicker(for: .date, key: key)
        }
        
        open var isChanged: Bool = false
        open var onSwitchValueChangedCallback: ((String, Bool) -> Void)? = nil
        
        @objc
        func onChangeSwitchValue(_ sender: UISwitch) {
            self.isChanged = self.originalStatus != sender.isOn
            UIView.animate(withDuration: 0.33) {
                self.textField.isHidden = !(self.originalStatus != sender.isOn)
                if self.originalStatus != sender.isOn {
                    self.switchView.backgroundColor = .systemGreen
                    self.switchView.onTintColor = .systemGreen
                } else {
                    self.switchView.backgroundColor = MDCPalette.green.tint100
                    self.switchView.onTintColor = MDCPalette.green.tint100
                }
                self.update(with: self.currentDate, isForever: self.isForever)
            }
            self.onSwitchValueChangedCallback?(self.key, sender.isOn)
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.textField)
            self.stack.addArrangedSubview(self.switchView)
            self.switchView.backgroundColor = .systemGreen
            self.switchView.layer.cornerRadius = self.switchView.bounds.height / 2
            self.switchView.layer.masksToBounds = true
            self.switchView.addTarget(self, action: #selector(onChangeSwitchValue), for: .valueChanged)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
        
        open var onCustomPeriodCallback: ((String) -> Void)? = nil
        
        @objc
        private func onCustomPeriodButtonTouchUpInside(_ sender: UIButton) {
            self.onCustomPeriodCallback?(self.key)
        }
    }
    
    class Datasource {
        enum Kind {
            case permission
            case button
        }
        
        var kind: Kind
        var title: String
        var value: String
        var status: Bool
        var originalStatus: Bool
        var key: String
        var icon: String
        
        var defaultStatus: Bool
        
        var changed: Bool = false
        
        var customDate: Date? = nil
        
        var selectedForever: Bool = false
        
        var isSelected: Bool = false
        
        init(kind: Kind, title: String, value: String, status: Bool = false, defaultStatus: Bool = false, key: String = "", icon: String = "", isSelected: Bool = false) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.originalStatus = status
            self.defaultStatus = defaultStatus
            self.key = key
            self.icon = icon
            self.isSelected = isSelected
        }
        
        var period: Double? {
            if let date = self.customDate {
                return date.timeIntervalSince1970 - Date().timeIntervalSince1970
            }
            return nil
        }
    }
    
    open var userId: String = ""
    
    internal var datasource: [[Datasource]] = []
    
    internal var currentValue: String = ""
    
    internal var defaultPermissions: [GroupchatPermission] = []
    
    var customDate: Date? = nil
    var predefinedDate: Date? = nil
    var selectedForever: Bool = true
        
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsSwitchWithKeyboardCell.self, forCellReuseIdentifier: SettingsSwitchWithKeyboardCell.cellName)
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        
        return view
    }()
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .save)
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    var userPermissions: [GroupchatPermission] = []
//    open var permissionsScope = "admin"
    var permissionsScope: String {
        get {
            return "admin"
        }
    }
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.currentValue = instance.membership_
                self.defaultPermissions = instance.defaultPermissions.filter({ $0.role == self.permissionsScope })
            }
            if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: self.userId, groupchat: self.jid, owner: self.owner)) {
                self.userPermissions = instance.userPermissions.filter({ $0.role == self.permissionsScope })
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        self.datasource = [
            self.userPermissions.compactMap {
                item in
                let defaultPermissionStatus = self.defaultPermissions.first(where: { $0.name == item.name })?.status ?? false
                var out = Datasource(kind: .permission, title: item.displayName, value: item.name, status: item.status, defaultStatus: defaultPermissionStatus, key: item.name)
                if let expires = item.expires, expires > 0 {
                    out.customDate = Date(timeIntervalSince1970: expires)
                }
                return out
            },
            [
                Datasource(kind: .button, title: "Forever", value: "", key: "forever", icon: "1.square.fill", isSelected: true),
                Datasource(kind: .button, title: "1 Hour", value: "", key: "1_hour", icon: "1.square.fill"),
                Datasource(kind: .button, title: "4 Hours", value: "", key: "4_hours", icon: "12.square.fill"),
                Datasource(kind: .button, title: "1 Day", value: "", key: "1_day", icon: "24.square.fill"),
                Datasource(kind: .button, title: "7 Days", value: "", key: "7_day", icon: "24.square.fill"),
                Datasource(kind: .button, title: "Custom", value: "", key: "custom", icon: "custom.clock.square.fill")
            ]
        ]
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        if self.permissionsScope == "admin" {
            self.title = "Promote admin"
        } else {
            self.title = "Restrict member"
        }
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }
    override func onAppear() {
        super.onAppear()
        if self.permissionsScope == "admin" {
            self.title = "Promote admin"
        } else {
            self.title = "Restrict member"
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.requestUserPermissions(stream, groupchat: self.jid, user: self.userId)
            session.groupchat?.requestUsers(stream, groupchat: self.jid, userId: self.userId)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.requestUserPermissions(stream, groupchat: self.jid, user: self.userId)
                user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
            }
        }
//        do {
//            var changedRole: String? = nil
//            if self.permissionsScope == "admin" {
//                if self.datasource[0]
//            } else {
//                
//            }
//        } catch {
//            
//        }
    }
    
    internal func updateValue() {
        
    }
    
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
    
    @objc
    internal func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        self.navigationController?.popViewController(animated: true)
    }
    
    internal var saveRequestId: String? = nil
    
    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        let changes = self.datasource[0].filter({ $0.changed }).compactMap({
            return GroupchatPermission(role: self.permissionsScope, name: $0.key, status: $0.status, displayName: $0.title, expires: $0.period)
        })
        guard changes.isNotEmpty else {
            return
        }
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.updateUserPermissions(stream, groupchat: self.jid, user: self.userId, changes: changes)
            session.groupchat?.requestUsers(stream, groupchat: self.jid, userId: self.userId)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.updateUserPermissions(stream, groupchat: self.jid, user: self.userId, changes: changes)
                user.groupchats.requestUsers(stream, groupchat: self.jid, userId: self.userId)
            }
        }
        self.navigationController?.popViewController(animated: true)
    }
}

extension GroupchatSettingsPromoteAdminViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    func deselectCellsFor(indexPath: IndexPath) {
        (0..<self.datasource[indexPath.section].count).forEach({
            self.tableView.cellForRow(at: IndexPath(row: $0, section: indexPath.section))?.accessoryType = .none
        })
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.key {
            case "forever":
                self.predefinedDate = nil
                self.selectedForever = true
            case "1_hour":
                self.predefinedDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
                self.selectedForever = false
            case "4_hours":
                self.predefinedDate = Calendar.current.date(byAdding: .hour, value: 4, to: Date())
                self.selectedForever = false
            case "1_day":
                self.predefinedDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                self.selectedForever = false
            case "7_day":
                self.predefinedDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                self.selectedForever = false
            default:
                break
        }
        if item.key != "custom" && item.kind == .button {
            deselectCellsFor(indexPath: indexPath)
            self.datasource[0].filter({ $0.changed }).forEach {
                $0.customDate = self.predefinedDate
                $0.selectedForever = self.selectedForever
            }
            self.customDate = nil
            self.tableView.reconfigureRows(at: (0..<self.datasource[0].count).compactMap({ return IndexPath(row: $0, section: 0) }))
            self.tableView.cellForRow(at: indexPath)?.accessoryType = .checkmark
        }
    }
}

extension GroupchatSettingsPromoteAdminViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
            case 0:
                return "Set a trial period: These rules govern new members for selected period, helping prevent spam while welcoming them fully afterward."
            default:
                return nil
        }
        
    }
    
    
    func onSwitchValueChangedCallback(key: String, value: Bool) {
        guard let index = self.datasource[0].firstIndex(where: { $0.key == key }) else {
            return
        }
        self.datasource[0][index].status = value
        if self.datasource[0][index].originalStatus != value {
            self.datasource[0][index].changed = true
            self.datasource[0][index].customDate = self.customDate ?? self.predefinedDate
            self.datasource[0][index].selectedForever = self.selectedForever
            
        } else {
            self.datasource[0][index].changed = false
            self.datasource[0][index].customDate = nil
            self.datasource[0][index].selectedForever = false
        }
        let item = self.datasource[0][index]
        (self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? SettingsSwitchWithKeyboardCell)?.update(with: item.customDate, isForever: item.selectedForever)
        self.changesObserver.accept(self.datasource[0].filter({ $0.changed }).isNotEmpty)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .permission:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsSwitchWithKeyboardCell.cellName, for: indexPath) as? SettingsSwitchWithKeyboardCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, isOn: item.status, key: item.value, isChanged: item.changed, originalStatus: item.originalStatus, isForever: item.selectedForever, date: item.customDate)
                cell.textField.dateDelegate = self
                cell.onSwitchValueChangedCallback = self.onSwitchValueChangedCallback
                cell.selectionStyle = .none
                cell.accessoryType = .none
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, badge: "", icon: item.icon, isCustom: item.key == "custom", selectedDate: self.customDate)
                cell.selectionStyle = .none
                
                if item.key == "custom" {
                    cell.textField.dateDelegate = self
                }
                if item.isSelected {
                    cell.accessoryType = .checkmark
                } else {
                    cell.accessoryType = .none
                }
                
                return cell
        }
    }
    
    
}

extension GroupchatSettingsPromoteAdminViewController: DateTimePickerTextFieldDelegate {
    func dateTimePickerTextField(_ sender: DateTimePickerTextField, didSet date: Date, key: String) {
        let calendar = Calendar.current
        let now = Date()
        
        if date <= now {
            return
        }
        
        switch key {
            case "custom":
                let section = 1
                
                self.deselectCellsFor(indexPath: IndexPath(row: 0, section: section))
                self.datasource[0].filter({ $0.changed }).forEach {
                    $0.customDate = date
                    $0.selectedForever = false
                }
                self.tableView.reconfigureRows(at: (0..<self.datasource[0].count).compactMap({ return IndexPath(row: $0, section: 0) }))
                guard let row = self.datasource[section].firstIndex(where: { $0.key == "custom" }) else {
                    return
                }
                self.tableView.cellForRow(at: IndexPath(row: Int(row), section: section))?.accessoryType = .checkmark
                
                self.customDate = date
                self.predefinedDate = nil
                self.selectedForever = false
            default:
                if let index = self.datasource[0].firstIndex(where: { $0.key == key }) {
                    self.datasource[0][index].customDate = date
                    if let cell = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? SettingsSwitchWithKeyboardCell {
                        let item = self.datasource[0][index]
                        cell.configure(title: item.title, isOn: item.status, key: item.value, isChanged: item.changed, originalStatus: item.originalStatus, isForever: item.selectedForever, date: item.customDate)
                    }
                }
                break
        }
    }
    
    func dateTimePickerTextFieldDidCancel(_ sender: DateTimePickerTextField, key: String) {
        print("cancel")
    }
}
