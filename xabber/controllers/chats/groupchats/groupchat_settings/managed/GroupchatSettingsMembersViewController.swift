//
//  GroupchatSettingsMembersViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 07.11.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import RxSwift
import RxCocoa
import RxRelay
import RxRealm
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import DeepDiff

class GroupchatSettingsMembersViewController: SimpleBaseViewController {
    
    
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
        
        func configure(title: String) {
            self.titleLabel.text = title
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
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
    
    
    class Datasource: DiffAware, Equatable, Hashable {
        typealias DiffId = String
        
        var diffId: String {
            get {
                return userId
            }
        }
        
        enum Kind {
            case contact
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.userId == rhs.userId
        }
        
        var owner: String
        var title: String
        var userId: String
        var subtitle: String
        var jid: String
        var avatarUrl: String?
        var status: ResourceStatus = .offline
        var role: GroupchatUserStorageItem.Role
        
        init(owner: String, title: String, userId: String, subtitle: String, jid: String, avatarUrl: String? = nil, status: ResourceStatus, role: GroupchatUserStorageItem.Role) {
            self.owner = owner
            self.title = title
            self.userId = userId
            self.subtitle = subtitle
            self.jid = jid
            self.avatarUrl = avatarUrl
            self.status = status
            self.role = role
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userId)
        }
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.userId == b.userId &&
            a.title == b.title &&
            a.avatarUrl == b.avatarUrl
        }
    }
    
    internal var datasource: [Datasource] = []
    
    internal var membersList: Results<GroupchatUserStorageItem>? = nil
    
    internal var currentValue: String = ""
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        
        return view
    }()
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
//            self.membersList = realm.objects(GroupchatUserStorageItem.self).filter("")
            
        } catch {
            DDLogDebug("GroupchatSettingsMembersViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.title = "Membership"
        self.tableView.dataSource = self
        self.tableView.delegate = self
    }
    override func onAppear() {
        super.onAppear()
    }
    
    override func subscribe() {
        super.subscribe()
    }
    
    internal func updateValue() {
        
    }
}

extension GroupchatSettingsMembersViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        let item = self.datasource[indexPath.section][indexPath.row]
//        self.currentValue = item.value
//        self.datasource[0].enumerated().forEach {
//            (index, item) in
//            if index == indexPath.row {
//                self.tableView.cellForRow(at: IndexPath(row: index, section: 0))?.accessoryType = .checkmark
//            } else {
//                self.tableView.cellForRow(at: IndexPath(row: index, section: 0))?.accessoryType = .none
//            }
//        }
    }
}

extension GroupchatSettingsMembersViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1//self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1//self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Select membership type for this group. Groups with open membership can be joined by any user, unless they are blocked.\n\nTo fight spam, consider setting some default restrictions which are applied to newly joined users."
    }
    
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
//        let item = self.datasource[indexPath.section][indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
            fatalError()
        }
        
//        cell.configure(title: item.title)
//        cell.selectionStyle = .none
//        if item.value == self.currentValue {
//            cell.accessoryType = .checkmark
//        } else {
//            cell.accessoryType = .none
//        }
        return cell
    }
    
    
}

