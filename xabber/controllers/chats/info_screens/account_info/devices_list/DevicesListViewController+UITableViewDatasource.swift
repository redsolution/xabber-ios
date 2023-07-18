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

extension DevicesListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
//        if tokens?.isEmpty ?? true {
//            return 0
//        } else if tokens?.count == 1 {
//            return 1
//        }
//        if tokens?.isEmpty ?? true {
//            return 1
//        }
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
                cell.configure(
                    client: device.client,
                    device: device.device,
                    description: device.descr,
                    ip: device.ip,
                    lastAuth: device.authDate,
                    current: true,
                    editable: false,
                    isOnline: device.resource != nil,
                    trustState: nil
                )
//                cell.accessoryType = .disclosureIndicator
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                    return UITableViewCell(frame: .zero)
                }
                cell.configure(for: item.title, style: .danger)
                return cell
            }
        case .token:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            let deviceItem = devices[indexPath.row]
            var trustState: SignalDeviceStorageItem.TrustState? = nil
                if let omemoDevice = omemoDevices.first(where: { $0.deviceId == deviceItem.omemoDeviceId }) {
                trustState = omemoDevice.state
            }
            let hasBundle = deviceItem.encryptionEnabled
            cell.configure(
                client: deviceItem.client,
                device: deviceItem.device,
                description: deviceItem.descr,
                ip: deviceItem.ip,
                lastAuth: deviceItem.authDate,
                current: false,
                editable: false,
                isOnline: deviceItem.resource != nil,
                trustState: hasBundle ? trustState : nil,
                hasBundle: hasBundle
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
                trustState: brokenItem.state
            )
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let item = datasource[section]
        switch item.kind {
        case .current, .button: return item.childs.count
        case .token: return devices.count
        case .broken: return brokenOmemoDevices.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 1 && self.devices.count == 1 {
            return nil
        }
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.devices.isEmpty {
            return nil
        }
        return datasource[section].value
    }
    
}
