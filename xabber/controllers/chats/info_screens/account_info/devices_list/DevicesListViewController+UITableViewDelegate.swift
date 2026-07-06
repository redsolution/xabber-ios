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
import XMPPFramework

extension DevicesListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let text = devicesSectionHeaderText(for: section) else {
            return nil
        }
        return makeSectionTextView(in: tableView, text: text, role: .header)
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let text = devicesSectionFooterText(for: section) else {
            return nil
        }
        return makeSectionTextView(in: tableView, text: text, role: .footer)
    }

    private func makeSectionTextView(in tableView: UITableView, text: String, role: DevicesSecuritySectionTextRole) -> DevicesSecuritySectionTextView {
        let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: DevicesSecuritySectionTextView.reuseIdentifier) as? DevicesSecuritySectionTextView
            ?? DevicesSecuritySectionTextView(reuseIdentifier: DevicesSecuritySectionTextView.reuseIdentifier)
        view.configure(text: text, role: role)
        return view
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch datasource[indexPath.section].kind {
        case .current:
            let item = datasource[indexPath.section].childs[indexPath.row]
            switch item.kind {
            case .button:
                onRevokeAll()
            case .token:
                showTokenInfo(uid: currentDevice, canEdit: true)
            default:
                break
            }
        case .token:
            if isDevicesVerificationRow(at: indexPath) {
                return
            }

            guard let item = deviceItemForDevicesRow(at: indexPath) else {
                return
            }
            showTokenInfo(uid: item.uid, canEdit: false)
        case .button:
            let item = datasource[indexPath.section].childs[indexPath.row]
            if item.value == "quit" {
                self.quitAccount()
            }
        case .broken:
                let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
                if hasConnection {
                    YesNoPresenter().present(
                        in: self,
                        style: .actionSheet,
                        title: "Delete broken device",
                        message: "",
                        yesText: "Delete",
                        dangerYes: true,
                        noText: "Cancel",
                        animated: true) { value in
                            if value {
                                let item = self.brokenOmemoDevices[indexPath.row]
                                let deviceId = item.deviceId
                                AccountManager.shared.find(for: self.jid)?.unsafeAction({ user, stream in
                                    user.omemo.deleteDevice(deviceId: deviceId)
                                })
                            }
                        }
                } else {
                    ActionSheetPresenter().present(
                        in: self,
                        title: "No connection",
                        message: "Please wait while connection established",
                        cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                        values: [],
                        animated: true) { _ in
                            
                        }
                }
        default:
            break
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return devicesSecuritySwipeAction(at: indexPath) != nil
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return false
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let devicesAction = devicesSecuritySwipeAction(at: indexPath) else {
            return nil
        }

        let action = UIContextualAction(style: .destructive, title: devicesAction.title) { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            switch devicesAction {
            case .terminateSession(let uid, let confirmation):
                self.presentSingleSessionTerminationConfirmation(uid: uid, confirmation: confirmation, completion: completion)
            case .deleteBrokenKey(let deviceId):
                self.deleteBrokenDeviceKey(deviceId: deviceId)
                completion(true)
            }
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

extension DevicesListViewController {
    func hasDevicesVerificationRow(in section: Int) -> Bool {
        guard datasource.indices.contains(section),
              datasource[section].kind == .token else {
            return false
        }
        return datasource[section].childs.first?.kind == .session
    }

    func isDevicesVerificationRow(at indexPath: IndexPath) -> Bool {
        return hasDevicesVerificationRow(in: indexPath.section) && indexPath.row == 0
    }

    func deviceIndexForDevicesRow(at indexPath: IndexPath) -> Int? {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].kind == .token,
              !isDevicesVerificationRow(at: indexPath) else {
            return nil
        }

        let deviceIndex = indexPath.row - (hasDevicesVerificationRow(in: indexPath.section) ? 1 : 0)
        guard devices.indices.contains(deviceIndex) else {
            return nil
        }
        return deviceIndex
    }

    func deviceItemForDevicesRow(at indexPath: IndexPath) -> DeviceStorageItem? {
        guard let deviceIndex = deviceIndexForDevicesRow(at: indexPath) else {
            return nil
        }
        return devices[deviceIndex]
    }

    func devicesSecuritySwipeAction(at indexPath: IndexPath) -> DevicesSecuritySwipeAction? {
        guard datasource.indices.contains(indexPath.section) else {
            return nil
        }

        switch datasource[indexPath.section].kind {
        case .token:
            guard let item = deviceItemForDevicesRow(at: indexPath) else {
                return nil
            }
            return .terminateSession(uid: item.uid, confirmation: .singleSession)
        case .broken:
            guard brokenOmemoDevices.indices.contains(indexPath.row) else {
                return nil
            }
            return .deleteBrokenKey(deviceId: brokenOmemoDevices[indexPath.row].deviceId)
        case .current, .button, .session:
            return nil
        }
    }

    private func presentSingleSessionTerminationConfirmation(
        uid: String,
        confirmation: DevicesSessionTerminationConfirmation,
        completion: @escaping (Bool) -> Void
    ) {
        let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
        guard hasConnection else {
            presentNoConnectionForSessionTermination()
            completion(false)
            return
        }

        YesNoPresenter().present(
            in: self,
            style: .actionSheet,
            title: confirmation.title,
            message: confirmation.message,
            yesText: confirmation.confirmTitle,
            dangerYes: true,
            noText: confirmation.cancelTitle,
            animated: true
        ) { [weak self] confirmed in
            guard confirmed else {
                completion(false)
                return
            }

            self?.revokeDeviceSession(uid: uid)
            completion(true)
        }
    }

    private func revokeDeviceSession(uid: String) {
        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
            user.devices.revoke(stream, uids: [uid])
        })
    }

    private func deleteBrokenDeviceKey(deviceId: Int) {
        AccountManager.shared.find(for: self.jid)?.unsafeAction({ user, stream in
            user.omemo.deleteDevice(deviceId: deviceId)
        })
    }

    private func presentNoConnectionForSessionTermination() {
        ActionSheetPresenter().present(
            in: self,
            title: "No connection",
            message: "Please wait while connection established",
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: [],
            animated: true) { _ in
        }
    }
}
