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
import XMPPFramework.XMPPJID

protocol CreateNewGroupSelectJIDViewControllerDelegate {
    func onUpdateLocalPart(_ localPart: String)
    func onUpdateServer(_ server: String)
}

class CreateNewGroupSelectJIDViewController: SimpleBaseViewController {
    
    class TextCell: UITableViewCell {
        public static let cellName = "CreateNewGroupSelectJIDViewControllerTextCell"
                
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
            
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.keyboardType = .URL
            field.returnKeyType = .done
            
            return field
        }()
        
        var callback: ((UITextField) -> Void)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ title: String, value: String) {
            field.text = value.isEmpty ? nil : value
            field.placeholder = title
            field.clearButtonMode = .always
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
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
            callback?(sender)
        }
    }
    
    open var delegate: CreateNewGroupSelectJIDViewControllerDelegate? = nil
    
    class Datasource {
        enum Kind {
            case localpart
            case server
            case customServer
        }
        var kind: Kind
        var title: String?
        var value: String?
        var selected: Bool
        
        init(kind: Kind, title: String? = nil, value: String? = nil, selected: Bool = false) {
            self.kind = kind
            self.title = title
            self.value = value
            self.selected = selected
        }
    }
    
    internal var datasource: [[Datasource]] = []
    internal var header: [String] = []
    internal var footer: [String] = []
    
    static let servers: [String] = [
        "redsolution.com",
        "xmppdev01.xabber.com"
    ]
    
    open var selectedServer: String = CreateNewGroupSelectJIDViewController.servers[0]
    open var selectedLocalPart: String = ""
    open var customServer: String? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(TextCell.self, forCellReuseIdentifier: TextCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")
        
        return view
    }()
    
    
    open func localPartFieldCallback(_ sender: UITextField) {
        if let text = sender.text,
           text.isNotEmpty,
           let jid = XMPPJID(user: text, domain: self.selectedServer, resource: nil),
           let local = jid.user {
            self.selectedLocalPart = local
            self.delegate?.onUpdateLocalPart(local)
        }
    }
    
    open func customServerFieldCallback(_ sender: UITextField) {
        if let text = sender.text,
            text.isNotEmpty,
            let jid = XMPPJID(user: nil, domain: text, resource: nil) {
            self.customServer = jid.domain
            self.delegate?.onUpdateServer(jid.domain)
        }
    }
    
    open func onServerSelect(_ server: String?) {
        if let text = server,
            text.isNotEmpty,
            let jid = XMPPJID(user: nil, domain: text, resource: nil) {
            self.selectedServer = jid.domain
            self.delegate?.onUpdateServer(jid.domain)
        }
    }
    
    open func onLocalPartSelected(_ sender: UITextField) {
        
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        var serversDatasource = CreateNewGroupSelectJIDViewController.servers.compactMap {
            return Datasource(kind: .server, title: $0, value: $0, selected: $0 == self.selectedServer)
        }
        serversDatasource.append(Datasource(kind: .customServer, title: "You can select tour custom server", value: self.customServer))
        self.datasource = [
            [
                Datasource(kind: .localpart, title: "Group XMPP ID", value: self.selectedLocalPart)
            ],
            serversDatasource
        ]
        
        self.header = [
            "Group XMPP ID".localizeString(id: "groupchats_group_xmpp_id", arguments: []),
            "Select groupchat domain".localizeString(id: "select_groupchat_domain", arguments: [])
        ]
        
        self.footer = [
            "",
            "You can also choose your own domain".localizeString(id: "choose_own_domain_tint", arguments: [])
        ]
    }
    
    open override func configure() {
        super.configure()
        self.view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        self.title = "Server".localizeString(id: "account_server_name", arguments: [])
    }
    
    
}

extension CreateNewGroupSelectJIDViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return header[section]
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return footer[section]
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .localpart:
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: TextCell.cellName,
                                         for: indexPath) as? TextCell else {
                    fatalError()
                }
                
                cell.configure(self.selectedLocalPart, value: self.selectedLocalPart)
                cell.callback = localPartFieldCallback
                cell.selectionStyle = .none
                return cell
            case .server:
                let cell = tableView
                    .dequeueReusableCell(withIdentifier: "UITableViewCell",
                                         for: indexPath)
                cell.textLabel?.text = item.title
                cell.accessoryType = item.selected ? .checkmark : .none
                cell.selectionStyle = .none
                return cell
            case .customServer:
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: TextCell.cellName,
                                         for: indexPath) as? TextCell else {
                    fatalError()
                }
                
                cell.configure("Custom server".localizeString(id: "contact_custom_server", arguments: []), value: self.customServer ?? "")
                cell.callback = customServerFieldCallback
                cell.selectionStyle = .none
                return cell
        }
    }
}

extension CreateNewGroupSelectJIDViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]

        if item.kind == .server {
            self.datasource[indexPath.section].forEach {
                $0.selected = false
            }
            self.datasource[indexPath.section][indexPath.row].selected = true
            self.onServerSelect(item.value)
            self.tableView.reloadSections([indexPath.section], with: .none)
        } else {
            (tableView.cellForRow(at: indexPath) as? TextCell)?.field.becomeFirstResponder()
        }
    }
}

