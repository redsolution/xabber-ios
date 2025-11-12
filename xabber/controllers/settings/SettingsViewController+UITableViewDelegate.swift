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
import YubiKit

extension SettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch datasource[indexPath.section].section {
        case .xmppAccounts:
            if indexPath.row == (accounts?.count ?? 0) {
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
            }
            return 64
        case .session:
            return tableView.estimatedRowHeight
        default:
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        tableView.deselectRow(at: indexPath, animated: true)
        
        guard datasource[indexPath.section].childs.isNotEmpty else {
            switch datasource[indexPath.section].section {
            case .xmppAccounts:
                if indexPath.row == (accounts?.count ?? 0) {
                    self.addAccount()
                } else {
                    if let item = accounts?[indexPath.row] {
                        self.showAccountInfo(item.jid, isEnabled: item.enabled)
                    }
                }
            default: break
            }
            return
        }
        
        let menuItem = datasource[indexPath.section].childs[indexPath.row]

        if let key = menuItem.key {
            switch key {
            case .accountSessions:
                let vc = DevicesListViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .manageStorage:
                let vc = CloudStorageViewController()
                vc.configure(jid: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
            
            case .accountEncryption:
                let vc = AccountEncryptionInfoViewController()
                vc.owner = self.jid
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .subscriptions:
                let vc = SubscribtionsListViewController()
                vc.owner = self.jid
                vc.controllerCloseReason = .navigationStack
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .developer:
                guard let datasource = SettingManager.shared.getDatasource(by: key.rawValue) else {
                    return
                }
                let vc = SettingsItemDetailViewController()
                self.hidesBottomBarWhenPushed = false
                vc.hidesBottomBarWhenPushed = true
                vc.configure(for: datasource)
                navigationController?.pushViewController(vc, animated: true)
                return
            
            case .yubikey:
                if SignatureManager.shared.certificate != nil {
                    let vc = YubikeySetupViewController()
                    vc.isFromOnboarding = false
                    vc.isModal = true
                    vc.owner = AccountManager.shared.users.first?.jid ?? ""
                    self.navigationController?.pushViewController(vc, animated: true)
                } else {
                    SignatureManager.shared.delegate = self
                    FeedbackManager.shared.tap()
                    if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                        YubiKitExternalLocalization.nfcScanAlertMessage = "Register Yubikey for account"
                        YubiKitManager.shared.startNFCConnection()
                        YubiKitManager.shared.delegate = SignatureManager.shared
                        SignatureManager.shared.currentAction = .certificate
                    }
                }
                return
            
            case .passcode:
                if !CredentialsManager.shared.isPincodeSetted() {
                    let vc = PasscodeViewController()
                    navigationController?.pushViewController(vc, animated: true)
                    return
                } else {
                    ApplicationStateManager.shared.isPincodeShowed = true
                    PincodePresenter().present(animated: true)
                }
                
            default: break
            }
        }
        
        if let viewController = menuItem.viewController {
            if let tableVC = viewController.init() as? SimpleTableViewController {
                tableVC.datasource = menuItem
                tableVC.jid = self.jid
                tableVC.resources = self.resources
                tableVC.currentResource = self.currentResource
                navigationController?.pushViewController(tableVC, animated: true)
                return
            } else {
                navigationController?.pushViewController(viewController.init(), animated: true)
            }
            return
        }
        
        switch datasource[indexPath.section].section {
        case .interface, .settings, .languages:
            self.showSettings(by: menuItem.key?.rawValue)
            return
        case .session:
            return
        default:
            self.view.makeToast("Feature is non implemented")
        }
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        switch editingStyle {
        case .none:
            break
        case .delete:
            if datasource[indexPath.section].section == .xmppAccounts,
                let jid = accounts?[indexPath.row].jid {
                self.onDeleteXMPPAccount(jid: jid)
            }
        case .insert:
            break
        @unknown default:
            break
        }
    }
    
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        print(sourceIndexPath, destinationIndexPath)
        var jids: [String] = accounts!.compactMap({ return $0.jid })
        if jids.count <= 1 { return }
        guard let sourceJid = accounts?[sourceIndexPath.row].jid else { return }
        
        jids.remove(at: sourceIndexPath.row)
        jids.insert(sourceJid, at: destinationIndexPath.row)
        
        do {
            let realm = try WRealm.safe()
            try realm.write {
                jids.enumerated().forEach { (item) in
                    realm.object(ofType: AccountStorageItem.self,
                                 forPrimaryKey: item.element)?.order = item.offset
                }
            }
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        if (accounts?.count ?? 0) <= 1 { return sourceIndexPath }
        if sourceIndexPath.section != proposedDestinationIndexPath.section {
            return sourceIndexPath
        }
        if proposedDestinationIndexPath.row == (accounts?.count ?? 0) {
            return sourceIndexPath
        }
        return proposedDestinationIndexPath
    }
}
