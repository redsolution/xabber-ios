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
import TOInsetGroupedTableView
import CocoaLumberjack
import RealmSwift

class MessageSigningInfoViewController: SimpleBaseViewController {
    
    class CheckomarkTableViewCell: UITableViewCell {
        static let cellName: String = "CheckomarkTableViewCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 8)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = .gray
            }
            
            return label
        }()
        
        internal let indicator: UIImageView = {
            let view = UIImageView()
            
            view.frame = CGRect(square: 24)
            
            return view
        }()
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([

                indicator.heightAnchor.constraint(equalToConstant: 18),
                indicator.widthAnchor.constraint(equalToConstant: 18)
            ])
        }
        
        open func configure(title: String, subtitle: String, value: Bool) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            
            if value {
                indicator.image = UIImage(named: "check-circle")?.withRenderingMode(.alwaysTemplate)
                indicator.tintColor = .systemGreen
            } else {
                indicator.image = UIImage(named: "alert-circle")?.withRenderingMode(.alwaysTemplate)
                indicator.tintColor = .systemRed
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            stack.addArrangedSubview(indicator)
            activateConstraints()
            selectionStyle = .none
            accessoryType = .none
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
    
    open var isFromOnboarding: Bool = true
    open var isModal: Bool = false
    
    public var messagePrimary: String = ""
    
    class Datasource {
        enum Kind {
            case lbael
            case checkmark
            case button(String)
        }
        
        var title: String
        var subtitle: String
        var kind: Kind
        var isTimeField: Bool
        var value: Bool
        
        init(title: String, subtitle: String, kind: Kind, isTimeField: Bool = false, value: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.kind = kind
            self.isTimeField = isTimeField
            self.value = value
        }
    }
    
    internal var datasource: [[Datasource]] = []
    var timer: Timer? = nil
    
    private let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "YKTableCell")
        view.register(CheckomarkTableViewCell.self, forCellReuseIdentifier: CheckomarkTableViewCell.cellName)
        
        
        return view
    }()
    
    internal let skipButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Skip", style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    var state: SignatureManager.ActionKind = .certificate

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        
        
        do {
            let realm = try WRealm.safe()
            guard let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.messagePrimary) else {
                return
            }
            var signatureDatasource: [Datasource] = []
            
            
            var certDatasource: [Datasource] = []
//
//            if let subjectSummary = message.errorMetadata?["certSubject"] as? String {
//                certDatasource.append(Datasource(
//                    title: "Subject",
//                    subtitle: subjectSummary,
//                    kind: .lbael
//                ))
//            }
            if let commonName = message.errorMetadata?["certCommonName"] as? String {
                certDatasource.append(Datasource(
                    title: "Account",
                    subtitle: commonName,
                    kind: .lbael
                ))
            }
            
            if let value = message.errorMetadata?["certConfirmed"] as? Bool {
                certDatasource.append(Datasource(
                    title: "Certificate signed by Xabber",
                    subtitle: "",
                    kind: .checkmark,
                    value: value
                ))
            }
            if let value = message.errorMetadata?["certValid"] as? Bool {
                certDatasource.append(Datasource(
                    title: "Certificate valid for user",
                    subtitle: "",
                    kind: .checkmark,
                    value: value
                ))
            }
            if let value = message.errorMetadata?["signed"] as? Bool {
                signatureDatasource.append(Datasource(
                    title: "Message signed",
                    subtitle: "",
                    kind: .checkmark,
                    value: value
                ))
            }
            if let value = message.errorMetadata?["signDecrypted"] as? Bool {
                signatureDatasource.append(Datasource(
                    title: "Signature decrypted",
                    subtitle: "",
                    kind: .checkmark,
                    value: value
                ))
            }
            if let value = message.errorMetadata?["signValid"] as? Bool {
                signatureDatasource.append(Datasource(
                    title: "Signature valid",
                    subtitle: "",
                    kind: .checkmark,
                    value: value
                ))
                
            }
            
            
            
            
            self.datasource = [
                certDatasource,
                signatureDatasource,
//                [
//                    Datasource(title: "Confirm identity for message", subtitle: "", kind: .button("confirm")),
//                    Datasource(title: "Delete message", subtitle: "", kind: .button("delete")),
//                ]
            ]
            
        } catch {
            DDLogDebug("MessageSigningInfoViewController: \(#function). \(error.localizedDescription)")
        }
        
        
    }
    
    override func configure() {
        super.configure()
        self.title = "Signed message info"
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.skipButton.title = "Cancel"
        
        self.navigationItem.setLeftBarButton(skipButton, animated: true)
        skipButton.target = self
        skipButton.action = #selector(onSkipButtonTouchUpInside)
        if self.messagePrimary.isEmpty {
            self.navigationController?.dismiss(animated: true, completion: nil)
        }
    }
    
    @objc
    internal func onSkipButtonTouchUpInside(_ sender: UIBarButtonItem) {
        dismissView()
    }
    
    override func onAppear() {
        super.onAppear()
        self.timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateTsCell), userInfo: nil, repeats: true)
    }
    
    @objc
    internal func updateTsCell(_ sender: AnyObject) {
        DispatchQueue.main.async {
            let section = 1
            if let row = self.datasource[section].firstIndex(where: { $0.isTimeField }) {
                let path = IndexPath(row: row, section: section)
                self.tableView.performBatchUpdates {
                    self.tableView.reloadRows(at: [path], with: .none)
                } completion: { result in
                    self.tableView.beginUpdates()
                    self.tableView.reloadRows(at: [path], with: .none)
                    self.tableView.endUpdates()
                }
            }
        }
    }
    
    
    private final func dismissView() {
        self.navigationController?.dismiss(animated: true, completion: nil)
    }
}

extension MessageSigningInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button(let value):
            switch value {
            case "confirm":
                YesNoPresenter().present(
                    in: self,
                    style: .actionSheet,
                    title: "Do you trust this message?",
                    message: "",
                    yesText: "Confirm",
                    dangerYes: false,
                    noText: "Cancel",
                    animated: true) { value in
                        if value {
                            do {
                                let realm = try WRealm.safe()
                                if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.messagePrimary) {
                                    if let metadata = instance.errorMetadata {
                                        let meta = SignatureManager.MessageError(from: metadata)
                                        meta.confirm()
                                        try realm.write {
                                            if instance.isInvalidated { return }
                                            instance.errorMetadata = meta.errorMetadata
                                        }
                                    }
                                    
                                }
                            } catch {
                                DDLogDebug("MessageSigningInfoViewController: \(#function). \(error.localizedDescription)")
                            }
                        }
                        DispatchQueue.main.async {
                            self.loadDatasource()
                            self.tableView.reloadData()
                        }
                    }
            case "delete":
                do {
                    let realm = try WRealm.safe()
                    let displayName = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner))?.displayName ?? self.jid
                    DeleteMessagePresenter(
                        username: displayName,
                        groupchat: false,
                        sended: true)
                        .present(in: self, animated: true) { (result) in
                            if let result = result {
                                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                                    session.retract?.deleteMessage(
                                        stream,
                                        primary: self.messagePrimary,
                                        jid: "",
                                        symmetric: result,
                                        callback: { (errorMessage, success) in
                                            DispatchQueue.main.async {
                                                self.view.hideToastActivity()
                                            }
                                            if let error = errorMessage {
                                                DispatchQueue.main.async {
                                                    self.view.makeToast(error)
                                                }
                                            }
                                        })
                                }, fail: {
                                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                        user.msgDeleteManager
                                            .deleteMessage(stream,
                                                           primary: self.messagePrimary,
                                                           jid: "",
                                                           symmetric: result)
                                            { (errorMessage, success) in
                                                DispatchQueue.main.async {
                                                    self.view.hideToastActivity()
                                                }
                                                if let error = errorMessage {
                                                    DispatchQueue.main.async {
                                                        self.view.makeToast(error)
                                                    }
                                                }
                                            }
                                    })
                                })
                            }
                        }
                } catch {
                    DDLogDebug("MessageSigningInfoViewController: \(#function). \(error.localizedDescription)")
                }
            default: break
            }
        default: break
        }
    }
}

extension MessageSigningInfoViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        
        switch item.kind {
        case .checkmark:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: CheckomarkTableViewCell.cellName, for: indexPath) as? CheckomarkTableViewCell else {
                fatalError()
            }
            
            cell.configure(title: item.title, subtitle: item.subtitle, value: item.value)
            
            return cell
        case .lbael:
            let cell = UITableViewCell(style: UITableViewCell.CellStyle.value1, reuseIdentifier: "YKTableCell")
            cell.selectionStyle = .none
            cell.accessoryType = .none
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.subtitle
            
            return cell
        case .button(let value):
            let cell = UITableViewCell(style: UITableViewCell.CellStyle.value1, reuseIdentifier: "YKTableCell")
            cell.selectionStyle = .none
            cell.accessoryType = .none
            cell.textLabel?.text = item.title
            if value == "delete" {
                cell.textLabel?.textColor = .systemRed
            } else {
                cell.textLabel?.textColor = .systemBlue
            }
            
            return cell
            
        }
        
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Certificate"
        case 1: return "Signature"
        default: return nil
        }
    }
}
