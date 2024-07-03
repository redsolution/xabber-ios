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
                
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                    return UITableViewCell(frame: .zero)
                }
                cell.configure(for: item.title, style: .danger)
                return cell
            case .session:
                fatalError()
            }
        case .token:
            if indexPath.row == 0 && item.childs.first?.kind == .session {
                item = item.childs[0]
                let cell = VerificationSessionTableViewCell()
                cell.configure(title: item.title, subtitle: item.value)
                
                if activeVerificationSession == nil {
                    cell.closeButton.removeFromSuperview()
                    cell.blueButton.setTitle("Verify", for: .normal)
                    cell.labelsStack.addArrangedSubview(cell.blueButton)
                    cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                    cell.blueButton.addTarget(self, action: #selector(onVerifyButtonPressed), for: .touchUpInside)
                    
                    return cell
                }
                
                cell.closeButton.addTarget(self, action: #selector(onCloseButtonPressed), for: .touchUpInside)
                
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
            
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            
            var deviceItem: DeviceStorageItem? = nil
            if isVerificationRequired || activeVerificationSession != nil {
                deviceItem = devices[indexPath.row - 1]
            } else {
                deviceItem = devices[indexPath.row]
            }
            
            var trustState: SignalDeviceStorageItem.TrustState? = nil
            var isTrustedByCert: Bool = false
            if let omemoDevice = omemoDevices.first(where: { $0.deviceId == deviceItem!.omemoDeviceId }) {
                trustState = omemoDevice.state
                isTrustedByCert = omemoDevice.isTrustedByCertificate
            }
            
            let hasBundle = deviceItem!.encryptionEnabled
            cell.configure(
                client: deviceItem!.client,
                device: deviceItem!.device,
                description: deviceItem!.descr,
                ip: deviceItem!.ip,
                lastAuth: deviceItem!.authDate,
                current: false,
                editable: true,
                isOnline: deviceItem!.resource != nil,
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
        default:
            let cell = UITableViewCell()
            
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let item = datasource[section]
        switch item.kind {
        case .current, .button: return item.childs.count
        case .token: 
            if isVerificationRequired || activeVerificationSession != nil {
                return devices.count + 1
            }
            
            return devices.count
        case .broken: return brokenOmemoDevices.count
        case .session: return item.childs.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 1 && self.devices.count == 1 {
            return nil
        }
        if datasource[section].kind == .session {
            return nil
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
