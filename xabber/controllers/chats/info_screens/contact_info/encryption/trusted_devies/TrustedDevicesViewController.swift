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
        
        init(_ kind: Kind, name: String, state: SignalDeviceStorageItem.TrustState? = nil, fingerprint: String? = nil, deviceId: Int? = nil, editable: Bool? = nil, subtitle: String? = nil, key: String = "", signed: Bool = false, trustedBy: String? = nil) {
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
        }
    }
    
    var datasource: [[Datasource]] = []
    var activeVerificationSession: VerificationSessionStorageItem? = nil
    
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
        title = "Identity Verification"
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = self.title
        self.navigationItem.largeTitleDisplayMode = .never
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
        
        datasource = []
        activeVerificationSession = nil
        
        do {
            let realm = try Realm()
            guard let myDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
                DDLogDebug("TrustedDevicesViewController: \(#function).")
                return
            }
            let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND jid == %@", argumentArray: [
                self.owner,
                myDeviceId,
                self.jid
            ])
            
            let verificationSession = realm.objects(VerificationSessionStorageItem.self).filter(predicate).first
            let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            
            var isVerificationNeeded = false
            for device in devices {
                if device.state == .unknown || device.state == .distrusted {
                    isVerificationNeeded = true
                    break
                }
            }
            
            var devicesDatasource: [Datasource] = []
            if isVerificationNeeded && verificationSession == nil {
                devicesDatasource.append(Datasource(.session, name: "Secure Your Conversation", subtitle: "Your contact has devices that need to be verified to ensure encrypted and secure communication. Perform an identity verification procedure by exchanging a verification code through a secure channel. Enter the received code to confirm that each device is trusted and secure.\n\nPress 'Verify' to begin the verification process and ensure the integrity of your conversation."))
            } else if verificationSession != nil && verificationSession?.state != .trusted {
                let text: String
                let secondaryText: String?
                
                (text, secondaryText) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(verificationState: verificationSession!.state)
                
                self.activeVerificationSession = verificationSession
                devicesDatasource.append(Datasource(.session, name: text, subtitle: secondaryText))
            }
            
            for device in devices {
                devicesDatasource.append(
                    Datasource(
                        .device,
                        name: device.name ?? "\(device.deviceId)",
                        state: device.state,
                        fingerprint: device.fingerprint,
                        deviceId: device.deviceId,
                        editable: true,
                        signed: device.isTrustedByCertificate,
                        trustedBy: device.trustedByDeviceId
                    )
                )
            }
            
            datasource.append(devicesDatasource)
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    func onVerifyButtonPressed() {
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.sendVerificationRequest(jid: self.jid)
        }
        
        self.loadDatasource()
        tableView.reloadData()
    }
    
    @objc
    func onCloseButtonPressed() {
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
              let jid = XMPPJID(string: self.jid),
              let sid = activeVerificationSession?.sid else {
            DDLogDebug("TrustedDevicesViewController: \(#function).")
            return
        }
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
            
            if instance?.state == .receivedRequest {
                akeManager.rejectRequestToVerify(jid: self.jid, sid: sid)
                
                return
            } else if instance?.state != VerificationSessionStorageItem.VerififcationState.failed && instance?.state != VerificationSessionStorageItem.VerififcationState.trusted && instance?.state != VerificationSessionStorageItem.VerififcationState.rejected {
                akeManager.sendErrorMessage(fullJID: jid, sid: sid, reason: "Сontact canceled verification session")
            }
            try realm.write {
                realm.delete(instance!)
            }
            
            return
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }

    
    static func getCellPropertiesForVerificationSession(verificationState: VerificationSessionStorageItem.VerififcationState) -> (String, String?) {
        let text: String
        let secondaryText: String?
        
        switch verificationState {
        case .sentRequest:
            text = "Verification In Progress"
            secondaryText = "A verification request has been sent to your contact's devices. Wait for your contact to provide the verification code, then you will need to enter it to complete the identity verification."
        case .receivedRequest:
            text = "Identity Verification Request Received"
            secondaryText = "You have received an identity verification request from this contact. This step is crucial to establish a trusted connection between your devices, ensuring secure and encrypted communications.\n\nPress the button below to display a verification code. Once generated, securely communicate this code to this contact to finalize the identity verification."
        case .acceptedRequest:
            text = "Incoming Verification Request"
            secondaryText = "You have accepted the verification request."
        case .trusted:
            text = "Verification successful"
            secondaryText = "The verification session was completed successfully. Now you trust this contact's devices."
        case .rejected:
            text = "Verification rejected"
            secondaryText = "The verification session rejected."
        case .failed:
            text = "Verification failed"
            secondaryText = "The verification session failed."
        case .receivedRequestAccept:
            text = "Outgoing Verification Request"
            secondaryText = "The contact accepted the verification request."
        default:
            text = "In process..."
            secondaryText = nil
        }
        
        return (text, secondaryText)
    }
    
    @objc
    func onAcceptButtonPressed() {
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            DispatchQueue.main.async {
                _ = user.akeManager.acceptVerificationRequest(jid: self.jid, sid: self.activeVerificationSession!.sid)
                
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "show_VerificationCodeViewController"),
                                                object: self,
                                                userInfo: [
                                                    "owner": self.owner,
                                                    "sid": self.activeVerificationSession!.sid
                                                ])
            }
        }
    }
    
    @objc
    func onShowCodePressed() {
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "show_VerificationCodeViewController"),
                                        object: self,
                                        userInfo: [
                                            "owner": self.owner,
                                            "sid": activeVerificationSession!.sid
                                        ])
    }
    
    @objc
    func onEnterCodePressed() {
        NotificationCenter.default.post(
            name: NSNotification.Name(rawValue: "show_AuthenticationCodeInputViewController"),
            object: self,
            userInfo: ["owner": self.owner, "sid": activeVerificationSession!.sid]
        )
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
            case "revoke_trust":
                do {
                    var untrustedDevicesList: [Int] = []
                    let realm = try Realm()
                    let instances = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
                    for instance in instances {
                        if instance.state == .distrusted {
                            continue
                        }
                        try realm.write {
                            instance.state = .distrusted
                            instance.trustDate = Date(timeIntervalSince1970: -1)
                            instance.trustedByDeviceId = nil
                        }
                        
                        untrustedDevicesList.append(instance.deviceId)
                    }
                    
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.trustSharingManager.sendUpdateOfContactsDevices(jid: self.jid, updatedDevicesIds: untrustedDevicesList)
                    })
                    
                } catch {
                    DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
                    return
                }
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
            break
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
        default:
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        
        switch item.kind {
        case .button:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleButtonCell")
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = item.subtitle
            cell.textLabel?.textColor = .systemBlue
            
            if item.key == "open_devices_danger" {
                cell.textLabel?.textColor = .systemOrange
                cell.detailTextLabel?.textColor = .systemOrange
            } else if item.key == "revoke_trust" {
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
            let cell = VerificationSessionTableViewCell()
            cell.configure(title: item.name, subtitle: item.subtitle)
            cell.closeButton.addTarget(self, action: #selector(onCloseButtonPressed), for: .touchUpInside)
            
            if activeVerificationSession == nil {
                cell.closeButton.removeFromSuperview()
                cell.blueButton.setTitle("Verify", for: .normal)
                cell.labelsStack.addArrangedSubview(cell.blueButton)
                cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                cell.blueButton.addTarget(self, action: #selector(onVerifyButtonPressed), for: .touchUpInside)
                
                return cell
            }
            
            switch activeVerificationSession?.state {
            case .receivedRequest:
                cell.blueButton.setTitle("Proceed to Verification", for: .normal)
                cell.blueButton.addTarget(self, action: #selector(onAcceptButtonPressed), for: .touchUpInside)
                cell.labelsStack.addArrangedSubview(cell.blueButton)
                cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                break
            case .acceptedRequest:
                cell.blueButton.setTitle("Show the code", for: .normal)
                cell.blueButton.addTarget(self, action: #selector(onShowCodePressed), for: .touchUpInside)
                cell.labelsStack.addArrangedSubview(cell.blueButton)
                cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                break
            case .receivedRequestAccept:
                cell.blueButton.setTitle("Enter the code", for: .normal)
                cell.blueButton.addTarget(self, action: #selector(onEnterCodePressed), for: .touchUpInside)
                cell.labelsStack.addArrangedSubview(cell.blueButton)
                cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                break
            default:
                break
            }
            
            return cell
        }
    }
}

extension TrustedDevicesViewController: XabberUpdateIfNeededDelegate {
    func updateIfNeeded() {
        self.subscribe()
    }
}
