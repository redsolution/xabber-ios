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
                return 44
            }
            return 64
        case .session:
            return tableView.estimatedRowHeight
        default:
            return 44
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
        
//        let subscribtion = SubscribtionsManager.shared.subscribtionEnd
//        
//        if menuItem.premiumOnly {
//            guard subscribtion != nil else {
//                self.view.makeToast("Premium account only")
//                return
//            }
//        }
        
        
        if let key = menuItem.key {
            switch key {
            case .accountSessions:
                let vc = DevicesListViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                return
                
            case .manageStorage:
                let vc = CloudStorageViewController()
                vc.configure(jid: jid)
                navigationController?.pushViewController(vc, animated: true)
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                return
            
            case .accountEncryption:
                let vc = AccountEncryptionInfoViewController()
                vc.owner = self.jid
                navigationController?.pushViewController(vc, animated: true)
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                return
                
            case .subscriptions:
                let vc = SubscribtionsListViewController()
                vc.owner = self.jid
                vc.controllerCloseReason = .navigationStack
                navigationController?.pushViewController(vc, animated: true)
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
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
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                return
            
            case .yubikey:
                if SignatureManager.shared.certificate != nil {
                    let vc = YubikeySetupViewController()
                    vc.isFromOnboarding = false
                    vc.isModal = true
                    vc.owner = AccountManager.shared.users.first?.jid ?? ""
                    self.navigationController?.pushViewController(vc, animated: true)
//                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
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
//                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
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
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: tableVC), sender: self)
                
                return
            } else {
                navigationController?.pushViewController(viewController.init(), animated: true)
//                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: viewController.init()), sender: self)
            }
            return
        }
        
        switch datasource[indexPath.section].section {
        case .interface, .settings, .languages:
            self.showSettings(by: menuItem.key?.rawValue)
            return
        case .session:
            let item = datasource[indexPath.section].childs[indexPath.row]
            switch item.values.first {
            case "accept_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                      let sid = item.verificationSid else {
                    fatalError()
                }
                guard let code = akeManager.acceptVerificationRequest(jid: self.owner, sid: sid) else {
                    return
                }
                let vc = ShowCodeViewController()
                vc.configure(owner: self.owner, jid: self.jid, code: code, sid: sid, isVerificationWithOwnDevice: true)
                self.navigationController!.present(vc, animated: true)
                
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
                
                let vc = ShowCodeViewController()
                vc.configure(owner: self.owner, jid: self.owner, code: code, sid: item.verificationSid!, isVerificationWithOwnDevice: true)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "enter_verification_code":
                let vc = AuthenticationCodeInputViewController()
                vc.configure(owner: self.owner, jid: self.owner, sid: item.verificationSid!, isVerificationWithUsersDevice: true)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "reject_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                    fatalError()
                }
                akeManager.rejectRequestToVerify(jid: self.jid, sid: item.verificationSid!)
                
                return
            default:
                fatalError()
            }
        default:
            self.view.makeToast("Feature is non implemented")
            return
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
