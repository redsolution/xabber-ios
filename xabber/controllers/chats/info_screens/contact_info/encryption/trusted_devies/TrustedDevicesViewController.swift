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
import CocoaLumberjack
import TOInsetGroupedTableView
import CoreMedia
import RxSwift
import XMPPFramework


class TrustedDevicesViewController: SimpleBaseViewController {
    
    class Datasource {
        enum Kind {
            case device
            case button
            case session
        }
        
        var kind: Kind
        var name: String
        var state: SignalDeviceStorageItem.TrustState?
        var fingerprint: String?
        var deviceId: Int?
        var editable: Bool?
        var subtitle: String?
        var key: String?
        var signed: Bool
        var trustedBy: String?
        var verificationSid: String?
        var verificationJid: String?
        
        init(_ kind: Kind, name: String, state: SignalDeviceStorageItem.TrustState? = nil, fingerprint: String? = nil, deviceId: Int? = nil, editable: Bool? = nil, subtitle: String? = nil, key: String = "", signed: Bool = false, trustedBy: String? = nil, verificationSid: String? = nil, verificationJid: String? = nil) {
            self.kind = kind
            self.name = name
            self.state = state
            self.fingerprint = fingerprint
            self.deviceId = deviceId
            self.editable = editable
            self.subtitle = subtitle
            self.key = key
            self.signed = signed
            self.trustedBy = trustedBy
            self.verificationSid = verificationSid
            self.verificationJid = verificationJid
        }
    }
    
    var datasource: [[Datasource]] = []
    
    let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleButtonCell")
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    let refreshControl = UIRefreshControl()
    
    override func configure() {
        super.configure()
        title = "Identity verification"
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = self.title
        tableView.delegate = self
        tableView.dataSource = self
        refreshControl.attributedTitle = NSAttributedString(string: "Pull to refresh")
        refreshControl.addTarget(self, action: #selector(self.refresh), for: .valueChanged)
        tableView.addSubview(refreshControl)
    }
    
    @objc
    private func refresh(_ sender: AnyObject) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.isRefreshRequest = true
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })
        refreshControl.endRefreshing()
    }
    
    override func subscribe() {
        super.subscribe()
        do {
            let realm = try Realm()
            let theirs = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            Observable
                .collection(from: theirs)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                DispatchQueue.main.async {
                    self.loadDatasource()
                    self.tableView.reloadData()
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)
            
            let verificationSessions = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            Observable
                .collection(from: verificationSessions)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                DispatchQueue.main.async {
                    self.loadDatasource()
                    self.tableView.reloadData()
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try Realm()
            
            guard let myDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
                fatalError()
            }
            let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND jid == %@", argumentArray: [
                self.owner,
                myDeviceId,
                self.jid
            ])
            let verificationSession = realm.objects(VerificationSessionStorageItem.self).filter(predicate).first
            datasource = []
            if verificationSession != nil {
                let text: String
                let secondaryText: String?
                let buttonTitle: String?
                let buttonKey: String?
                
                let sid = verificationSession!.sid
                let fullJid = verificationSession!.fullJID != "" ? verificationSession!.fullJID : verificationSession!.jid
                
                switch verificationSession!.state {
                case .sentRequest:
                    text = "Outcoming verification request"
                    secondaryText = "Verification request has been sent to the contact."
                    buttonTitle = "Cancel"
                    buttonKey = "cancel_verification"
                case .receivedRequest:
                    text = "Incoming verification request"
                    secondaryText = "Contact want's to establish a trusted connection with you."
                    buttonTitle = "Accept"
                    buttonKey = "accept_verification"
                case .acceptedRequest:
                    text = "Incoming verification request"
                    secondaryText = "You have accepted the verification request."
                    buttonTitle = "Show code"
                    buttonKey = "show_verification_code"
                case .trusted:
                    text = "Verification successful"
                    secondaryText = "The verification session was completed successfully. Now you trust this contact's devices."
                    buttonTitle = "Close"
                    buttonKey = "hide_session"
                case .rejected:
                    text = "Verification rejected"
                    secondaryText = "The verification session rejected."
                    buttonTitle = "Close"
                    buttonKey = "hide_session"
                case .failed:
                    text = "Verification failed"
                    secondaryText = "The verification session failed."
                    buttonTitle = "Close"
                    buttonKey = "hide_session"
                case .receivedRequestAccept:
                    text = "Outcoming verification request"
                    secondaryText = "The contact accepted the verification request."
                    buttonTitle = "Enter the code"
                    buttonKey = "enter_verification_code"
                default:
                    text = "In process..."
                    secondaryText = nil
                    buttonTitle = nil
                    buttonKey = nil
                }
                
                datasource = [
                    [Datasource(.session, name: text, subtitle: secondaryText, verificationSid: sid, verificationJid: fullJid)]
                ]
                
                if buttonKey != nil {
                    datasource[0].append(Datasource(.button, name: buttonTitle!, key: buttonKey!, verificationSid: sid, verificationJid: fullJid))
                    if buttonKey == "accept_verification" {
                        datasource[0].append(Datasource(.button, name: "Reject", key: "reject_verification", verificationSid: sid, verificationJid: fullJid))
                    }
                }
            }
            
            let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            if datasource.isEmpty {
                datasource = [
                    devices.compactMap {
                        return Datasource(
                            .device,
                            name: $0.name ?? "\($0.deviceId)",
                            state: $0.state,
                            fingerprint: $0.fingerprint,
                            deviceId: $0.deviceId,
                            editable: true,
                            signed: $0.isTrustedByCertificate,
                            trustedBy: $0.trustedByDeviceId
                        )
                    }
                ]
            } else {
                datasource.append(
                    devices.compactMap {
                        return Datasource(
                            .device,
                            name: $0.name ?? "\($0.deviceId)",
                            state: $0.state,
                            fingerprint: $0.fingerprint,
                            deviceId: $0.deviceId,
                            editable: true,
                            signed: $0.isTrustedByCertificate,
                            trustedBy: $0.trustedByDeviceId
                        )
                    }
                )
            }
        datasource.append([Datasource(.button, name: "Untrust all", key: "untrust_all")])
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func onAppear() {
        super.onAppear()
        loadDatasource()
        self.tableView.reloadData()
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })

    }
    
}

extension TrustedDevicesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button:
            return 44
        case .device:
            return 60
        case .session:
            return tableView.estimatedRowHeight
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        switch item.kind {
        case .button:
            switch item.key {
            case "open_devices_danger", "open_devices":
                let vc = DevicesListViewController()
                vc.configure(for: self.owner)
                navigationController?.pushViewController(vc, animated: true)
                return
            case "cancel_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                      let fullJidString = item.verificationJid,
                      let fullJid = XMPPJID(string: fullJidString),
                      let sid = item.verificationSid else {
                    fatalError()
                }
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
                    try realm.write {
                        realm.delete(instance!)
                    }
                } catch {
                    fatalError()
                }
                akeManager.sendErrorMessage(fullJID: fullJid, sid: sid, reason: "Сontact canceled verification session")
                tableView.reloadData()
                return
            case "accept_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                      let fullJidString = item.verificationJid,
                      let fullJid = XMPPJID(string: fullJidString),
                      let sid = item.verificationSid else {
                    fatalError()
                }
                guard let code = akeManager.acceptVerificationRequest(jid: self.jid, sid: sid) else {
                    return
                }
                let vc = ShowCodeViewController(owner: self.owner, jid: self.jid, code: code, sid: sid, isVerificationWithUsersDevice: false)
                vc.configure()
                self.navigationController!.present(vc, animated: true)
                tableView.reloadData()
                return
            case "show_verification_code":
                let code: String
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!)) else {
                        fatalError()
                    }
                    code = instance.code
                } catch {
                    fatalError()
                }
                
                let vc = ShowCodeViewController(owner: self.owner, jid: self.jid, code: code, sid: item.verificationSid!, isVerificationWithUsersDevice: false)
                vc.configure()
                self.navigationController!.present(vc, animated: true)
                
                return
            case "hide_session":
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!))
                    try realm.write {
                        realm.delete(instance!)
                    }
                } catch {
                    fatalError()
                }
                tableView.reloadData()
                
                return
            case "enter_verification_code":
                let vc = AuthenticationCodeInputViewController(owner: self.owner, jid: self.jid, sid: item.verificationSid!, isVerificationWithUsersDevice: false)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "reject_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                      let fullJidString = item.verificationJid,
                      let fullJid = XMPPJID(string: fullJidString),
                      let sid = item.verificationSid else {
                    fatalError()
                }
                
                akeManager.rejectRequestToVerify(jid: self.jid, sid: item.verificationSid!)
                tableView.reloadData()
                
                return
            default:
                return
            }
        case .device:
            let vc = ContactDeviceDetailViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.canEdit = false
            vc.delegate = self
            vc.omemoDeviceID = item.deviceId!
            self.navigationController?.pushViewController(vc, animated: true)
        case .session:
            return
        }
    }
    
}

extension TrustedDevicesViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if datasource[section].isEmpty {
            return "Сontact hasn't published keys yet"
        }
        switch datasource[section].first?.kind {
        case .device:
            return "Contact`s devices"
        case .session:
            return "Active verification session"
        default:
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        if datasource[indexPath.section].first?.kind == .session {
            // if the button is from the verification session section
            if item.kind == .button {
                let cell = UITableViewCell()
                var cellConfig = cell.defaultContentConfiguration()
                cellConfig.text = item.name
                cellConfig.textProperties.color = .systemBlue
                cellConfig.textProperties.alignment = .center
                cell.contentConfiguration = cellConfig
                
                return cell
            }
        }
        
        switch item.kind {
        case .button:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleButtonCell")
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = item.subtitle
            
            if item.key == "open_devices_danger" {
                cell.textLabel?.textColor = .systemOrange
                cell.detailTextLabel?.textColor = .systemOrange
            } else if item.key == "untrust_all" {
                cell.textLabel?.textColor = .systemRed
            }
            
            return cell
        case .device:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            
            cell.configure(fingerprint: nil, client: "", device: item.name, description: "", ip: String(item.deviceId!), lastAuth: nil, current: false, editable: true, isOnline: false, trustState: item.state, hasBundle: true, isTrustebByCertificate: false, trustedBy: item.trustedBy)

            return cell
        case .session:
            let cell = UITableViewCell()
            var cellConfig = cell.defaultContentConfiguration()
            cellConfig.image = UIImage(systemName: "lock.circle.fill")?.upscale(dimension: 40).withTintColor(.systemBlue)
            cellConfig.text = item.name
            cellConfig.secondaryText = item.subtitle ?? nil
            
            cell.contentConfiguration = cellConfig
            return cell
        }
    }
    
}

extension TrustedDevicesViewController {
    private func trustStateChanged(_ value: Bool, deviceId: Int) {
        do {
            let realm = try Realm()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: deviceId)) {
                guard let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager else {
                    fatalError()
                }
                try realm.write {
                    if value {
                        instance.state = .trusted
                        instance.trustDate = Date()
                        trustSharingManager.getUserTrustedDevices(jid: XMPPJID(string: self.jid)!)
                    } else {
                        instance.state = .ignore
                        instance.trustDate = Date(timeIntervalSince1970: -1)
                        instance.trustedByDeviceId = nil
                    }
                }
                trustSharingManager.sendNotificationWithContactsDevices(opponentFullJid: XMPPJID(string: self.owner)!, deviceId: (AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId())!)
            }
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
}

extension TrustedDevicesViewController: XabberUpdateIfNeededDelegate {
    func updateIfNeeded() {
        self.subscribe()
    }
}
