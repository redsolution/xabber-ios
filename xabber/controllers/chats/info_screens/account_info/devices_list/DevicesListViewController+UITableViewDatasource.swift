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
import MaterialComponents.MDCPalettes

extension DevicesListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var item = datasource[indexPath.section]
        switch item.kind {
        case .current, .button:
            item = item.childs[indexPath.row]
            switch item.kind {
            case .token, .current, .broken
                :
                guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell,
                      let device = deviceInstance else {
                    return UITableViewCell(frame: .zero)
                }
                var isTrustedByCert: Bool = false
                if let omemoDevice = omemoDevices.first(where: { $0.deviceId == self.deviceInstance?.omemoDeviceId ?? -1 }) {
                    isTrustedByCert = omemoDevice.isTrustedByCertificate
                }
                cell.configure(
                    client: device.client,
                    device: device.device,
                    description: device.descr,
                    ip: device.ip,
                    lastAuth: device.authDate,
                    current: true,
                    editable: true,
                    isOnline: device.resource != nil,
                    trustState: .trusted,
                    isTrustebByCertificate: isTrustedByCert
                )
//                cell.accessoryType = .disclosureIndicator
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                    return UITableViewCell(frame: .zero)
                }
                switch item.value {
                case "verify_own_devices":
                    cell.configure(for: item.title, style: .normal)
                default:
                    cell.configure(for: item.title, style: .danger)
                }
                return cell
            case .session:
                fatalError()
            }
        case .token:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            let deviceItem = devices[indexPath.row]
            var trustState: SignalDeviceStorageItem.TrustState? = nil
            var isTrustedByCert: Bool = false
            if let omemoDevice = omemoDevices.first(where: { $0.deviceId == deviceItem.omemoDeviceId }) {
                trustState = omemoDevice.state
                isTrustedByCert = omemoDevice.isTrustedByCertificate
            }
            let hasBundle = deviceItem.encryptionEnabled
            cell.configure(
                client: deviceItem.client,
                device: deviceItem.device,
                description: deviceItem.descr,
                ip: deviceItem.ip,
                lastAuth: deviceItem.authDate,
                current: false,
                editable: true,
                isOnline: deviceItem.resource != nil,
                trustState: hasBundle ? trustState : nil,
                hasBundle: hasBundle,
                isTrustebByCertificate: isTrustedByCert
            )
            return cell
        case .broken:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            let brokenItem = brokenOmemoDevices[indexPath.row]
            cell.configure(
                client: brokenItem.name ?? "\(brokenItem.deviceId)",
                device: "Undefined",
                description: "Undefined",
                ip: "\(brokenItem.deviceId)",
                lastAuth: brokenItem.updateDate,
                current: false,
                editable: false,
                isOnline: false,
                trustState: brokenItem.state,
                isTrustebByCertificate: brokenItem.isTrustedByCertificate
            )
            return cell
        case .session:
            if item.childs.isEmpty || item.childs[indexPath.row].kind == .session {
                item = item.childs[indexPath.row]
                
                let cell = VerificationSessionTableViewCell()
                cell.configure(owner: self.jid, jid: self.jid, sid: item.verificationSid!, title: item.title, subtitle: item.value)
                
                return cell
            }
            
            item = item.childs[indexPath.row]
            
            let cell = UITableViewCell()
            var cellConfig = cell.defaultContentConfiguration()
            cellConfig.text = item.title
            if item.value == "reject_verification" {
                cellConfig.textProperties.color = .systemRed
            } else {
                cellConfig.textProperties.color = .systemBlue
            }
            cell.contentConfiguration = cellConfig
            
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let item = datasource[section]
        switch item.kind {
        case .current, .button: return item.childs.count
        case .token: return devices.count
        case .broken: return brokenOmemoDevices.count
        case .session: return item.childs.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 1 && self.devices.count == 1 {
            return nil
        }
        if datasource[section].kind == .session {
            return "Active verification session"
        }
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.devices.isEmpty || datasource[section].kind == .session {
            return nil
        }
        return datasource[section].value
    }
    
}
