//
//  ContactDeviceDetailViewController.swift
//  xabber
//
//  Created by Admin on 08.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class ContactDeviceDetailViewController: DeviceDetailViewController {
    override func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            guard let omemoDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) else {
                fatalError()
            }
            let resourceInstance = realm.objects(AccountStorageItem.self).filter("jid == %@", jid)
            let deviceTitle = omemoDevice.name ?? String(omemoDevice.deviceId)
            
            var encryptionDatasource: [Datasource] = [
                Datasource(title: "Bundle not found", value: "", key: "omemo_bundle_not_found")
            ]
            
                
            if realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.jid, deviceId: omemoDeviceID)) != nil {
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
                    trustElement = Datasource(title: "Manual verification", value: "Undefined", key: "manual_verification")
                }
                encryptionDatasource = [
                    Datasource(title: "Device ID", value: "\(omemoDevice.deviceId)", key: "omemo_deviceId"),
                    Datasource(title: "Fingerprint", value: omemoDevice.fingerprint, key: "omemo_fingerprint")
                    
                ]
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
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy HH:mm"
            datasource = [
                [
                    Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                               value: dateFormatter.string(from: omemoDevice.updateDate), key: "status"),
                    Datasource(title: "Device".localizeString(id: "device", arguments: []),
                               value: deviceTitle, key: "device")
                ],
                encryptionDatasource
            ]
        } catch {
            fatalError()
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .none
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }
}
