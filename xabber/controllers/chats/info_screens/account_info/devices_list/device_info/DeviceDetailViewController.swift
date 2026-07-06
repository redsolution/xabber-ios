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
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack

enum DeviceDetailSessionTerminationEffect: Equatable {
    case none
    case terminateSession(uid: String)
}

struct DeviceDetailSessionTerminationConfirmation: Equatable {
    let uid: String
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String

    static func `default`(uid: String) -> DeviceDetailSessionTerminationConfirmation {
        DeviceDetailSessionTerminationConfirmation(
            uid: uid,
            title: "Terminate session?".localizeString(id: "terminate_session_question", arguments: []),
            message: "Terminate the selected device session. Current device remains signed in. Account and server data is not deleted.".localizeString(id: "device_detail_terminate_session_message", arguments: []),
            confirmTitle: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
            cancelTitle: "Cancel".localizeString(id: "cancel", arguments: [])
        )
    }

    func effect(confirmed: Bool) -> DeviceDetailSessionTerminationEffect {
        confirmed ? .terminateSession(uid: uid) : .none
    }
}

enum DeviceDetailPrimaryAction: Equatable {
    case none
    case rename
    case showStatusResource
    case showAccountConnection
    case terminateSession(DeviceDetailSessionTerminationConfirmation)
}

enum DeviceDetailFingerprintFormatter {
    private static let octetLength = 8

    static func twoLineOctets(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let compactValue = value.replacingOccurrences(
            of: "[\\s:]",
            with: "",
            options: .regularExpression
        )
        guard compactValue.count >= octetLength * 2,
              compactValue.count % octetLength == 0 else {
            return value
        }

        let octets = compactValue.split(by: octetLength)
        let octetsPerLine = Int(ceil(Double(octets.count) / 2.0))
        let firstLine = octets.prefix(octetsPerLine).joined(separator: " ")
        let secondLine = octets.dropFirst(octetsPerLine).joined(separator: " ")

        guard secondLine.isNotEmpty else {
            return firstLine
        }

        return "\(firstLine)\n\(secondLine)"
    }
}

final class DeviceDetailValueTableViewCell: UITableViewCell {
    static let cellName = "DeviceDetailValueTableViewCell"

    let stack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    let valueLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        titleLabel.text = nil
        titleLabel.textAlignment = .left
        valueLabel.text = nil
        valueLabel.textAlignment = .natural
        valueLabel.font = UIFont.preferredFont(forTextStyle: .body)
        valueLabel.lineBreakMode = .byWordWrapping
        valueLabel.numberOfLines = 0
        valueLabel.adjustsFontSizeToFitWidth = false
        valueLabel.minimumScaleFactor = 1.0
        selectionStyle = .none
        accessoryType = .none
        accessibilityLabel = nil
        accessibilityTraits = .staticText
    }

    func configure(
        title: String,
        value: String?,
        isFingerprint: Bool = false,
        selectionStyle: UITableViewCell.SelectionStyle = .none,
        accessoryType: UITableViewCell.AccessoryType = .none
    ) {
        titleLabel.text = title
        valueLabel.text = isFingerprint ? DeviceDetailFingerprintFormatter.twoLineOctets(value) : value
        valueLabel.isHidden = value?.isEmpty ?? true
        if isFingerprint {
            configureFingerprintLayout()
        } else {
            configureInlineValueLayout()
        }
        titleLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontForContentSizeCategory = true
        self.selectionStyle = selectionStyle
        self.accessoryType = accessoryType
        isAccessibilityElement = true
        accessibilityTraits = selectionStyle == .none ? .staticText : [.staticText, .button]
        accessibilityLabel = [title, value]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func configureInlineValueLayout() {
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        titleLabel.textAlignment = .left
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.font = UIFont.preferredFont(forTextStyle: .body)
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byWordWrapping
        valueLabel.adjustsFontSizeToFitWidth = false
        valueLabel.minimumScaleFactor = 1.0
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureFingerprintLayout() {
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        titleLabel.textAlignment = .left
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        valueLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        valueLabel.textAlignment = .left
        valueLabel.numberOfLines = 2
        valueLabel.lineBreakMode = .byClipping
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.75
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func setupSubviews() {
        contentView.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
}

class DeviceDetailViewController: SimpleBaseViewController {
    
    class Datasource: Hashable, Equatable {
        static func == (lhs: DeviceDetailViewController.Datasource, rhs: DeviceDetailViewController.Datasource) -> Bool {
            return lhs.key == rhs.key
        }
        
        var title: String
        var value: String?
        var key: String
        
        init(title: String, value: String?, key: String) {
            self.title = title
            self.value = value
            self.key = key
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
        }
    }
    
    open var uid: String = ""
    open var canEdit: Bool = false
    internal var datasource: [[Datasource]] = []
    
    open var omemoDeviceID: Int = -1
    
    internal var resource: String? = nil
    private var statusTitle: String? = nil
    private var status: ResourceStatus = .offline
    
    internal var accountResources: Results<ResourceStorageItem>? = nil
    
    open var delegate: XabberUpdateIfNeededDelegate? = nil
    
    private var currentDeviceDescription: String? = nil
    
    internal var dangerInEncryption: Bool = false
    internal var issuedFor: String? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DangerCell")
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        view.register(DeviceDetailValueTableViewCell.self, forCellReuseIdentifier: DeviceDetailValueTableViewCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        DevicesSecurityTableLayout.apply(to: view)
        
        return view
    }()
    
    override func configure() {
        super.configure()
        self.title = "Device information"
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            guard let deviceInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, jid].prp()) else {
                return
            }
            self.omemoDeviceID = deviceInstance.omemoDeviceId
            let resourceInstance = realm.objects(AccountStorageItem.self).filter("jid == %@", jid)
            
            let deviceTitle = deviceInstance.descr.isNotEmpty ? deviceInstance.descr : deviceInstance.client
            let deviceDescr = deviceInstance.descr.isNotEmpty ? deviceInstance.descr : nil
            
            self.currentDeviceDescription = deviceDescr
            self.resource = deviceInstance.resource
            
            if let resource = self.resource {
                if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: self.jid, owner: self.jid, resource: resource)) {
                    self.statusTitle = instance.displayedStatus
                    self.status = instance.status
                }
            }
            
            var encryptionDatasource: [Datasource] = [
                Datasource(title: "Bundle not found", value: "", key: "omemo_bundle_not_found")
            ]
            
            if deviceInstance.encryptionEnabled {
                
                if let omemoDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: deviceInstance.omemoDeviceId)),
                   realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.jid, deviceId: deviceInstance.omemoDeviceId)) != nil {
                    var trustElement: Datasource
                    switch omemoDevice.state {
                    case .ignore:
                        trustElement = Datasource(title: "Device ignored", value: "Ignored", key: "omemo_state_ignore")
                    case .trusted:
                            trustElement = Datasource(
                                title: omemoDevice.isTrustedByCertificate ? "Device signed" : "Device trusted",
                                value: omemoDevice.isTrustedByCertificate ? "Signed" : "Trusted",
                                key: omemoDevice.isTrustedByCertificate ? "omemo_state_signed" : "omemo_state_trusted"
                            )
                    case .fingerprintChanged:
                        trustElement = Datasource(title: "Fingerprint changed", value: "Fingerprint changed", key: "omemo_state_fingerprint_changed")
                    case .revoked:
                        trustElement = Datasource(title: "Revoked", value: "Revoked", key: "omemo_state_revoked")
                    case .unknown, .distrusted:
                        trustElement = Datasource(title: "Action required", value: "Undefined", key: "omemo_state_undefined")
                    }
                    encryptionDatasource = [
                        Datasource(title: "Device ID", value: "\(omemoDevice.deviceId)", key: "omemo_deviceId")
                    ]
                    
                    if omemoDevice.name != nil {
                        encryptionDatasource.append(Datasource(title: "Name", value: "\(omemoDevice.name!)", key: "omemo_device_name"))
                    }
                    encryptionDatasource.append(Datasource(title: "Fingerprint", value: omemoDevice.fingerprint, key: "omemo_fingerprint"))
                    
                    if omemoDevice.signature != nil {
                        self.dangerInEncryption = omemoDevice.signedBy != self.jid
                        self.issuedFor = omemoDevice.signedBy
                        encryptionDatasource.append(
                            Datasource(
                                title: omemoDevice.signedBy == self.jid ? "Verified by" : "Not verified",
                                value: omemoDevice.signedBy == self.jid ? "Clandestino" : "",
                                key: "omemo_signed_by"
                            )
                        )
                    }
                    if omemoDevice.trustedByDeviceId != nil {
                        encryptionDatasource.append(
                            Datasource(title: "Trusted by", value: omemoDevice.trustedByDeviceId, key: "omemo_trusted_by")
                        )
                    }
                    if !canEdit {
                        encryptionDatasource.append(trustElement)
                    }
                }
            }
            
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy HH:mm"
            if canEdit {
                datasource = [
                    [
                        Datasource(title: "Device", value: deviceTitle, key: "title"),
//                        Datasource(title: "Description", value: deviceDescr, key: "descr")
                    ],
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value:  dateFormatter.string(from: deviceInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: deviceInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "device__info__client__label", arguments: []),
                                   value: deviceInstance.client, key: "client"),
                        Datasource(title: "Resource".localizeString(id: "account_resource", arguments: []),
                                   value: resourceInstance.first?.resource?.resource, key: "resource"),
                        Datasource(title: "IP", value: deviceInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.expire), key: "expire")
                    ],
                    encryptionDatasource,
                    [
                        Datasource(title: "Rename".localizeString(id: "input_widget__button_rename", arguments: []),
                                   value: nil, key: "rename")
                    ],
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
                                   value: nil, key: "terminate")
                    ],
                ]
            } else {
                datasource = [
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: deviceInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "contact_viewer_client", arguments: []),
                                   value: deviceInstance.client, key: "client"),
                        Datasource(title: "IP", value: deviceInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.expire), key: "expire")
                    ],
                    encryptionDatasource,
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []), value: nil, key: "terminate")
                    ],
                ]
            }
        } catch {
            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func onRename() {
        TextViewPresenter().present(
            in: self,
            title: "Rename device".localizeString(id: "device_info_rename_device", arguments: []),
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Rename".localizeString(id: "device__info__rename__button", arguments: []),
            currentValue: self.currentDeviceDescription,
            animated: true) { value in
            if value != self.currentDeviceDescription {
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.update(stream, descr: value)
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.update(stream, descr: value)
                    })
                }
            }
            DispatchQueue.main.async {
                self.goBack()
            }
        }
    }
    
    private final func onTerminate() {
        let confirmation = DeviceDetailSessionTerminationConfirmation.default(uid: uid)
        YesNoPresenter().present(
            in: self,
            style: .actionSheet,
            title: confirmation.title,
            message: confirmation.message,
            yesText: confirmation.confirmTitle,
            dangerYes: true,
            noText: confirmation.cancelTitle,
            animated: true) { [weak self] confirmed in
            guard let self else {
                return
            }
            guard case .terminateSession(let uid) = confirmation.effect(confirmed: confirmed) else {
                return
            }
            self.terminateDeviceSession(uid: uid)
            DispatchQueue.main.async {
                self.goBack()
            }
        }
    }

    private func terminateDeviceSession(uid: String) {
        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
            session.devices?.revoke(stream, uids: [uid])
        } fail: {
            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                user.devices.revoke(stream, uids: [uid])
            })
        }
    }
    
    override func onAppear() {
        self.loadDatasource()
        self.tableView.reloadData()
    }
}

extension DeviceDetailViewController: UITableViewDelegate {
    func deviceDetailPrimaryAction(at indexPath: IndexPath) -> DeviceDetailPrimaryAction {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].indices.contains(indexPath.row) else {
            return .none
        }

        switch datasource[indexPath.section][indexPath.row].key {
        case "rename":
            return .rename
        case "terminate":
            return .terminateSession(DeviceDetailSessionTerminationConfirmation.default(uid: uid))
        case "status":
            return .showStatusResource
        case "resource":
            return .showAccountConnection
        default:
            return .none
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "rename":
            onRename()
        case "terminate":
            onTerminate()
        case "status":
            do {
                let realm = try WRealm.safe()
                if let resource = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: self.uid, owner: self.jid))?.resource {
                    let vc = ContactInfoResourceController()
                    vc.jid = self.jid
                    vc.owner = self.jid
                    vc.resource = resource
                    vc.isModal = false
                    self.navigationController?.pushViewController(vc, animated: true)
//                    let nvc = UINavigationController(rootViewController: vc)
//                    nvc.modalPresentationStyle = .fullScreen
//                    nvc.modalTransitionStyle = .coverVertical
//                    self.definesPresentationContext = true
//                    self.present(nvc, animated: true, completion: nil)
                }
            } catch {
                DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
            }
        case "resource":
            let vc = AccountConnectionViewController()
            vc.configure(for: jid)
            self.navigationController?.pushViewController(vc, animated: true)
        case "omemo_signed_by":
            if self.dangerInEncryption {
                ActionSheetPresenter().present(
                    in: self,
                    title: "Encription not secured",
                    message: "Encryption key signed by certificate issued for \(self.issuedFor ?? "unknown user")",
                    cancel: "Close",
                    values: [],
                    animated: true) { _ in
                        
                    }
            } else {
                ActionSheetPresenter().present(
                    in: self,
                    title: "Encription secured",
                    message: "Encryption key verified by certificate issued by Clandestino for \(self.issuedFor ?? "")",
                    cancel: "Close",
                    values: [],
                    animated: true) { _ in
                        
                    }
            }
            
        case "omemo_state_trusted":
            let items: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete"),
                ActionSheetPresenter.Item(destructive: false, title: "Untrust", value: "untrust")
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Untrust this device",
                message: nil,
                cancel: "Cancel",
                values: items,
                animated: true) { value in
                    switch value {
                    case "trust":
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) {
                                try realm.write {
                                    instance.state = .trusted
                                    instance.trustDate = Date()
                                }
                            }
                            
                            DispatchQueue.main.async {
                                self.goBack()
                            }
                        } catch {
                            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
                        }
                    case "delete":
                        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                            session.devices?.revoke(stream, uids: [self.uid])
                        } fail: {
                            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                                user.devices.revoke(stream, uids: [self.uid])
                            })
                        }
                        DispatchQueue.main.async {
                            self.goBack()
                        }
                    case "untrust":
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) {
                                try realm.write {
                                    instance.state = .unknown
                                    instance.trustDate = Date(timeIntervalSince1970: -1)
                                    instance.trustedByDeviceId = nil
                                    instance.lastTrustedItemsUpdateTimestamp = ""
                                }
                            }
                            
                            guard let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager,
                                  let localStore = AccountManager.shared.find(for: self.owner)?.omemo.localStore else {
                                fatalError()
                            }
                            trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(localStore.localDeviceId()))
                            
                            DispatchQueue.main.async {
                                self.goBack()
                            }
                        } catch {
                            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
                        }
                    default:
                        break
                    }
                }
        case "omemo_state_fingerprint_changed", "omemo_state_undefined":
            let items: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Verify", value: "verify"),
                ActionSheetPresenter.Item(destructive: false, title: "Trust", value: "trust"),
                ActionSheetPresenter.Item(destructive: true, title: "Delete device", value: "delete")
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Trust this device",
                message: nil,
                cancel: "Cancel",
                values: items,
                animated: true) { value in
                    switch value {
                    case "trust":
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) {
                                try realm.write {
                                    instance.trustDate = Date()
                                    instance.state = .trusted
                                }
                            }
                            
                            guard let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager,
                                  let localStore = AccountManager.shared.find(for: self.owner)?.omemo.localStore else {
                                fatalError()
                            }
                            trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(localStore.localDeviceId()))
                            
                            DispatchQueue.main.async {
                                self.goBack()
                            }
                        } catch {
                            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
                        }
                    case "delete":
                        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                            session.devices?.revoke(stream, uids: [self.uid])
                        } fail: {
                            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                                user.devices.revoke(stream, uids: [self.uid])
                            })
                        }
                        DispatchQueue.main.async {
                            self.goBack()
                        }
                    case "verify":
                        AccountManager.shared.find(for: self.owner)?.action { user, stream in
                            user.akeManager.sendVerificationRequest(jid: self.jid, deviceId: String(self.omemoDeviceID))
                        }
                        DispatchQueue.main.async {
                            self.goBack()
                        }
                        break
                    default:
                        break
                    }
                }
        case "manual_verification":
            let vc = ManualVerificationDeviceViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.deviceId = String(self.omemoDeviceID)
            self.navigationController?.pushViewController(vc, animated: true)
            return
        default:
            break
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if datasource[section].first?.key == "status" {
            return "Private information"
        } else if datasource[section].first?.key == "omemo_deviceId" {
            return "Public information"
        } else {
            return nil
        }
    }
}

extension DeviceDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "terminate":
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(for: item.title, style: .danger)
            cell.accessibilityIdentifier = "device_detail_terminate_session_button"
            cell.accessibilityHint = "Requires confirmation.".localizeString(id: "device_detail_terminate_session_accessibility_hint", arguments: [])
            return cell
        case "rename":
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(for: item.title, style: .normal)
            cell.accessibilityIdentifier = "device_detail_rename_button"
            return cell
        case "status":
            if self.resource != nil {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
                    fatalError()
                }
                
                cell.configure(
                    title: self.statusTitle ?? "Offline".localizeString(id: "unavailable", arguments: []),
                    status: self.status,
                    entity: .contact,
                    isTemporary: false
                )
                
                return cell
            } else {
                return valueCell(tableView, for: indexPath, item: item)
            }
        case "resource":
            return valueCell(
                tableView,
                for: indexPath,
                item: item,
                selectionStyle: .default,
                accessoryType: .disclosureIndicator
            )
            
        case "omemo_state_ignore":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemGray
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(systemName: "checkerboard.shield")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemGray
            
            return cell
        case "omemo_state_signed":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemGreen
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "lock.circle.fill")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemGreen
            
            return cell
        case "omemo_state_trusted":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemGreen
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "lock.fill")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemGreen
            
            return cell
        case "omemo_state_fingerprint_changed", "omemo_state_revoked":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemRed
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemRed
            
            return cell
        case "omemo_state_undefined":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemOrange
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemOrange
            
            return cell
        case "omemo_fingerprint":
            return valueCell(tableView, for: indexPath, item: item, isFingerprint: true)
        case "omemo_trusted_by":
            return valueCell(tableView, for: indexPath, item: item)
        case "manual_verification":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemOrange
            configureWrappingText(in: cell)
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemOrange
            
            return cell
        default:
            return valueCell(tableView, for: indexPath, item: item)
        }
    }

    private func valueCell(
        _ tableView: UITableView,
        for indexPath: IndexPath,
        item: Datasource,
        isFingerprint: Bool = false,
        selectionStyle: UITableViewCell.SelectionStyle = .none,
        accessoryType: UITableViewCell.AccessoryType = .none
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceDetailValueTableViewCell.cellName, for: indexPath) as? DeviceDetailValueTableViewCell else {
            return UITableViewCell(frame: .zero)
        }
        cell.configure(
            title: item.title,
            value: item.value,
            isFingerprint: isFingerprint,
            selectionStyle: selectionStyle,
            accessoryType: accessoryType
        )
        return cell
    }

    private func configureWrappingText(in cell: UITableViewCell) {
        cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.lineBreakMode = .byWordWrapping
        cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.lineBreakMode = .byWordWrapping
    }
}
