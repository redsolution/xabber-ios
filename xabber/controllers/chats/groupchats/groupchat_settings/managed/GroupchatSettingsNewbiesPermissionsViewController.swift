//
//  GroupchatSettingsNewbiesPermissionsViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 31.10.2025.
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

class GroupchatSettingsNewbiesPermissionsViewController: SimpleBaseViewController {
    
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
        
        let badgeView: UIButton = {
            let view = UIButton()

            return view
        }()
        
        func configure(title: String, badge: String, icon: String) {
            self.titleLabel.text = title
//            self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate)
            self.badgeView.setTitle("\(badge)", for: .normal)
            self.badgeView.isHidden = false/*badge == "0" ? true : false*/
            var configuration = UIButton.Configuration.filled()
            configuration.baseBackgroundColor = .clear
            configuration.baseForegroundColor = .secondaryLabel
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            self.badgeView.configuration = configuration
            self.badgeView.updateConfiguration()
            self.badgeView.setNeedsLayout()
            self.badgeView.layoutIfNeeded()
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.badgeView)
            self.accessoryType = .disclosureIndicator
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
        
        public final func updateTimer(day: Int?, hour: Int?, mins: Int?) {
            var customString = ""
            if let value = day, value > 0 {
                customString += "\(value)d "
            } else if let value = hour, value > 0 {
                customString += "\(value)h "
            } else if let value = mins, value > 0 {
                customString += "\(value)m"
            }
            
            var conf = UIButton.Configuration.plain()
            conf.attributedTitle = AttributedString(NSAttributedString(string: customString, attributes: [
                .font: UIFont.systemFont(ofSize: 13)
            ]))
            self.badgeView.configuration = conf
            self.badgeView.updateConfiguration()
            self.badgeView.sizeToFit()
            self.stack.layoutSubviews()
        }
        
    }
    
    class SettingsSwitchCell: UITableViewCell {
        static let cellName: String = "SettingsSwitchCell"
        
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
        
        let customPeriodButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            
            conf.attributedTitle = AttributedString(NSAttributedString(string: "2d 13h 11m", attributes: [
                .font: UIFont.systemFont(ofSize: 13)
            ]))
            
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        var key: String = ""
        var originalStatus: Bool = false
        
        public final func updateTimer(day: Int?, hour: Int?, mins: Int?, isChanged: Bool) {
            var customString = ""
            if let value = day, value > 0 {
                customString += "\(value)d "
            }
            if let value = hour, value > 0 {
                customString += "\(value)h "
            }
            if let value = mins, value > 0 {
                customString += "\(value)m"
            }
            
            var conf = UIButton.Configuration.plain()
            var color: UIColor = .secondaryLabel
            if self.originalStatus != switchView.isOn  {
                color = .tintColor
            }
            if isChanged {
                color = .tintColor
            }
            conf.attributedTitle = AttributedString(NSAttributedString(string: customString, attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: color
            ]))
            self.customPeriodButton.configuration = conf
            self.customPeriodButton.updateConfiguration()
            self.customPeriodButton.sizeToFit()
            self.stack.layoutSubviews()
        }
        
        func configure(title: String, isOn: Bool, key: String, isChanged: Bool, originalStatus: Bool, day: Int?, hour: Int?, mins: Int?) {
            self.titleLabel.text = title
            self.switchView.isOn = isOn
            self.key = key
            self.originalStatus = originalStatus
            self.updateTimer(day: day, hour: hour, mins: mins, isChanged: isChanged)
            if originalStatus != isOn {
                self.switchView.backgroundColor = .systemGreen
                self.switchView.onTintColor = .systemGreen
            } else {
                self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
            }
        }
        
        open var onSwitchValueChangedCallback: ((String, Bool) -> Void)? = nil
        
        @objc
        func onChangeSwitchValue(_ sender: UISwitch) {
//            print()
            UIView.animate(withDuration: 0.33) {
                if self.originalStatus != sender.isOn {
                    self.switchView.backgroundColor = .systemGreen
                    self.switchView.onTintColor = .systemGreen
                } else {
                    self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                    self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                }
            }
            self.onSwitchValueChangedCallback?(self.key, sender.isOn)
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.customPeriodButton)
            self.stack.addArrangedSubview(self.switchView)
            self.switchView.backgroundColor = .red
            self.switchView.layer.cornerRadius = self.switchView.bounds.height / 2
            self.switchView.layer.masksToBounds = true
            self.switchView.addTarget(self, action: #selector(onChangeSwitchValue), for: .valueChanged)
            self.customPeriodButton.addTarget(self, action: #selector(onCustomPeriodButtonTouchUpInside), for: .touchUpInside)
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
        
        var changed: Bool = false
        
        var customiPeriodDay: Int? = nil
        var customiPeriodHour: Int? = nil
        var customiPeriodMins: Int? = nil
        
        var defaultPeriodDay: Int? = nil
        var defaultPeriodHour: Int? = nil
        var defaultPeriodMins: Int? = nil
        
        init(kind: Kind, title: String, value: String, status: Bool = false, key: String = "", icon: String = "") {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.originalStatus = status
            self.key = key
            self.icon = icon
        }
        
        var period: Double? {
            return Double(self.customiPeriodDay ?? 0) * 24 * 60 * 60 + Double(self.customiPeriodHour ?? 0) * 60 * 60 + Double(self.customiPeriodMins ?? 0) * 60
        }
        
        func isCustomDatedifferToDefaultDate() -> Bool {
            if (self.customiPeriodDay ?? 0) != (self.defaultPeriodDay ?? 0) {
                return true
            } else if (self.customiPeriodHour ?? 0) != (self.defaultPeriodHour ?? 0) {
                return true
            } else if (self.customiPeriodMins ?? 0) != (self.defaultPeriodMins ?? 0) {
                return true
            }
            return false
        }
        
        func updateCustomPeriod(with seconds: Double?) {
            guard let totalSeconds = seconds, totalSeconds >= 0 else {
                self.customiPeriodDay = nil
                self.customiPeriodHour = nil
                self.customiPeriodMins = nil
                self.defaultPeriodDay = nil
                self.defaultPeriodHour = nil
                self.defaultPeriodMins = nil
                return
            }
            let totalSec = Int(totalSeconds)
            
            let days = totalSec / 86400
            let remainingAfterDays = totalSec % 86400
            
            let hours = remainingAfterDays / 3600
            let remainingAfterHours = remainingAfterDays % 3600
            
            let minutes = remainingAfterHours / 60
            self.customiPeriodDay = days
            self.customiPeriodHour = hours
            self.customiPeriodMins = minutes
            self.defaultPeriodDay = days
            self.defaultPeriodHour = hours
            self.defaultPeriodMins = minutes
        }
    }
    
    internal var datasource: [[Datasource]] = []
    
    internal var currentValue: String = ""
    
    internal var defaultPermissions: [GroupchatPermission] = []
    
    var customiPeriodDay: Int? = nil
    var customiPeriodHour: Int? = nil
    var customiPeriodMins: Int? = nil
    
    var predefinedPeriodDay: Int? = nil
    var predefinedPeriodHour: Int? = nil
    var predefinedPeriodMins: Int? = nil
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsSwitchCell.self, forCellReuseIdentifier: SettingsSwitchCell.cellName)
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
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.defaultPermissions = instance.defaultPermissions
                instance.newbiesPermissions.forEach {
                    item in
                    if let index = self.defaultPermissions.firstIndex(where: { $0.name == item.name }) {
                        self.defaultPermissions[index].status = item.status
                        self.defaultPermissions[index].expires = item.expires
                        self.defaultPermissions[index].seconds = item.seconds
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        self.datasource = [
            self.defaultPermissions.compactMap {
                let item = Datasource(kind: .permission, title: $0.displayName, value: $0.name, status: $0.status, key: $0.name)
                if let seconds = $0.seconds {
                    item.updateCustomPeriod(with: seconds)
                }
                return item
            },
            [
                Datasource(kind: .button, title: "1 Hour", value: "", key: "1_hour", icon: "1.square.fill"),
                Datasource(kind: .button, title: "4 Hours", value: "", key: "4_hours", icon: "12.square.fill"),
                Datasource(kind: .button, title: "1 Day", value: "", key: "1_day", icon: "24.square.fill"),
                Datasource(kind: .button, title: "1 Week", value: "", key: "1_week", icon: "24.square.fill"),
                Datasource(kind: .button, title: "2 Week", value: "", key: "2_week", icon: "24.square.fill"),
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
        self.title = "Permissions for new members"
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }
    override func onAppear() {
        super.onAppear()
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.getNewbiesPermissions(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.getNewbiesPermissions(stream, groupchat: self.jid)
            }
        }
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
    
    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        var changes = self.datasource[0].filter({ $0.changed }).compactMap({
            return GroupchatPermission(role: "member", name: $0.key, status: $0.status, displayName: $0.title, expires: $0.period)
        })
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                instance.newbiesPermissions.forEach {
                    item in
                    if changes.firstIndex(where: { $0.name == item.name }) == nil {
                        changes.append(item)
                    }
                }
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        guard changes.isNotEmpty else {
            return
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.updateNewbiesPermissions(stream, groupchat: self.jid, changes: changes)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.updateNewbiesPermissions(stream, groupchat: self.jid, changes: changes)
            }
        }
        self.navigationController?.popViewController(animated: true)
    }
}

extension GroupchatSettingsNewbiesPermissionsViewController: UITableViewDelegate {
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
            case "1_hour":
                self.predefinedPeriodDay = 0
                self.predefinedPeriodHour = 1
                self.predefinedPeriodMins = 0
            case "12_hours":
                self.predefinedPeriodDay = 0
                self.predefinedPeriodHour = 12
                self.predefinedPeriodMins = 0
            case "4_hours":
                self.predefinedPeriodDay = 0
                self.predefinedPeriodHour = 4
                self.predefinedPeriodMins = 0
            case "1_day":
                self.predefinedPeriodDay = 1
                self.predefinedPeriodHour = 0
                self.predefinedPeriodMins = 0
            case "1_week":
                self.predefinedPeriodDay = 7
                self.predefinedPeriodHour = 0
                self.predefinedPeriodMins = 0
            case "2_week":
                self.predefinedPeriodDay = 14
                self.predefinedPeriodHour = 0
                self.predefinedPeriodMins = 0
            case "custom":
                let picker = TimePickerPresenter()
                picker.delegate = self
                picker.present(
                    in: self,
                    title: "Select custom duration",
                    message: "\n\n\n\n\n\n",
                    cancel: "Cancel",
                    animated: true,
                    key: nil
                )
            default:
                break
        }
        if item.key != "custom" {
            deselectCellsFor(indexPath: indexPath)
            self.datasource[0].filter({ $0.changed }).forEach {
                $0.customiPeriodDay = self.predefinedPeriodDay
                $0.customiPeriodHour = self.predefinedPeriodHour
                $0.customiPeriodMins = self.predefinedPeriodMins
            }
            self.customiPeriodDay = nil
            self.customiPeriodHour = nil
            self.customiPeriodMins = nil
            self.tableView.reconfigureRows(at: (0..<self.datasource[0].count).compactMap({ return IndexPath(row: $0, section: 0) }))
            self.tableView.cellForRow(at: indexPath)?.accessoryType = .checkmark
        }
    }
}

extension GroupchatSettingsNewbiesPermissionsViewController: UITableViewDataSource {
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
    
    func onCustomPeriodButtonCallback(key: String) {
        let picker = TimePickerPresenter()
        picker.delegate = self
        picker.present(
            in: self,
            title: "Select custom duration",
            message: "\n\n\n\n\n\n",
            cancel: "Cancel",
            animated: true,
            key: key
        )
    }
    
    func onSwitchValueChangedCallback(key: String, value: Bool) {
        guard let index = self.datasource[0].firstIndex(where: { $0.key == key }) else {
            return
        }
        self.datasource[0][index].status = value
        if self.datasource[0][index].originalStatus != value {
            self.datasource[0][index].changed = true
            self.datasource[0][index].customiPeriodDay = self.customiPeriodDay ?? self.predefinedPeriodDay
            self.datasource[0][index].customiPeriodHour = self.customiPeriodHour ?? self.predefinedPeriodHour ?? 1
            self.datasource[0][index].customiPeriodMins = self.customiPeriodMins ?? self.predefinedPeriodMins
            let item = self.datasource[0][index]
            (self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? SettingsSwitchCell)?.updateTimer(day: item.customiPeriodDay, hour: item.customiPeriodHour, mins: item.customiPeriodMins, isChanged: item.changed)
        } else {
            self.datasource[0][index].changed = false
            self.datasource[0][index].updateCustomPeriod(with: self.defaultPermissions.first(where: { self.datasource[0][index].value == $0.name })?.seconds)
            let item = self.datasource[0][index]
            (self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? SettingsSwitchCell)?.updateTimer(day: item.customiPeriodDay, hour: item.customiPeriodHour, mins: item.customiPeriodMins, isChanged: item.changed)
        }
        self.changesObserver.accept(self.datasource[0].filter({ $0.changed }).isNotEmpty)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .permission:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsSwitchCell.cellName, for: indexPath) as? SettingsSwitchCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, isOn: item.status, key: item.value, isChanged: item.changed, originalStatus: item.originalStatus, day: item.customiPeriodDay, hour: item.customiPeriodHour, mins: item.customiPeriodMins)
                cell.onCustomPeriodCallback = self.onCustomPeriodButtonCallback
                cell.onSwitchValueChangedCallback = self.onSwitchValueChangedCallback
                cell.selectionStyle = .none
                cell.accessoryType = .none
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, badge: "", icon: item.icon)
                cell.selectionStyle = .none
                cell.accessoryType = .none
                if item.key == "custom" {
                    cell.updateTimer(day: self.customiPeriodDay, hour: self.customiPeriodHour, mins: self.customiPeriodMins)
                }
                return cell
        }
    }
    
    
}

extension GroupchatSettingsNewbiesPermissionsViewController: TimePickerAlertControllerDelegate {
    
    func timePickerAlertControllerDidCancel() {
        print("cancel")
    }
    
    func timePickerAlertControllerDidSet(key: String?, days: Int?, hours: Int?, minutes: Int?) {
        if let key = key {
            guard let index = self.datasource[0].firstIndex(where: { $0.key == key }) else {
                return
            }
            self.datasource[0][index].customiPeriodDay = days
            self.datasource[0][index].customiPeriodHour = hours
            self.datasource[0][index].customiPeriodMins = minutes
            self.datasource[0][index].changed = self.datasource[0][index].isCustomDatedifferToDefaultDate()
            self.tableView.reconfigureRows(at: [IndexPath(row: index, section: 0)])
        } else {
            let section = 1
            self.deselectCellsFor(indexPath: IndexPath(row: 0, section: section))
            self.datasource[0].filter({ $0.changed }).forEach {
                $0.customiPeriodDay = days
                $0.customiPeriodHour = hours
                $0.customiPeriodMins = minutes
            }
            self.tableView.reconfigureRows(at: (0..<self.datasource[0].count).compactMap({ return IndexPath(row: $0, section: 0) }))
            guard let row = self.datasource[section].firstIndex(where: { $0.key == "custom" }) else {
                return
            }
            self.tableView.cellForRow(at: IndexPath(row: Int(row), section: section))?.accessoryType = .checkmark
            
            self.customiPeriodDay = days
            self.customiPeriodHour = hours
            self.customiPeriodMins = minutes
            self.predefinedPeriodDay = nil
            self.predefinedPeriodHour = nil
            self.predefinedPeriodMins = nil
            self.updateCustomTimer()
        }
    }
    
    func updateCustomTimer() {
        guard let index = self.datasource[1].firstIndex(where: { $0.key == "custom" }) else {
            return
        }
        
        (self.tableView.cellForRow(at: IndexPath(row: index, section: 1)) as? SettingsItemCell)?
            .updateTimer(day: self.customiPeriodDay, hour: self.customiPeriodHour, mins: self.customiPeriodMins)
        
    }
    
}
