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

import UIKit
import TOInsetGroupedTableView
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import XMPPFramework.XMPPJID
import LocalAuthentication

class SimpleTableViewController: BaseViewController {
    
    var datasource: SettingsViewController.Datasource?
    var resources: Results<ResourceStorageItem>? = nil
    var currentResource: String? = nil
    
    let deleteSpinner: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.medium)
        spinner.startAnimating()
        let button = UIBarButtonItem(customView: spinner)
        
        return button
    }()
    
    let whiteView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.alpha = 0.0
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        return view
    }()
    
    init?(coder: NSCoder, datasource: SettingsViewController.Datasource?) {
        self.datasource = datasource
        super.init(coder: coder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        self.view.addSubview(self.whiteView)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.navigationItem.title = datasource?.title
        self.tabBarController?.tabBar.isHidden = true
        self.navigationController?.isNavigationBarHidden = false
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.tableView.reloadData()
        self.whiteView.frame = self.view.frame
    }
}

extension SimpleTableViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource?.childs.count ?? 0
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource?.childs[section].childs.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let datasource = self.datasource else { return UITableViewCell() }
        let menuItem = datasource.childs[indexPath.section].childs[indexPath.row]
        
        if let key = menuItem.key {
            switch key {
            case .accountStatus:
                let cell = StatusInfoCell()
                if let currentResource = self.currentResource,
                    let resource = self.resources?.first(where: { $0.resource == currentResource }) {
                    cell.configure(title: resource.displayedStatus, status: resource.status, entity: resource.entity, isTemporary: resource.isTemporary)
                } else {
                    cell.configure(title: "Offline".localizeString(id: "unavailable", arguments: []), status: .offline, entity: .contact, isTemporary: false)
                }
                return cell
            
            case .accountColor:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let colorItem = AccountColorManager.shared.colorItem(for: self.jid)
                cell.detailTextLabel?.text = colorItem.title
                cell.detailTextLabel?.textColor = colorItem.primary
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .passcodeTimer:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let seconds = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = seconds > 0 ? "\(seconds / 60) min" : "Never"
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .passcodeAttempts:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let attempts = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = attempts > 0 ? "\(attempts)" : "Unlimited"
                cell.accessoryType = .disclosureIndicator
                return cell
            
            case .displayedAttempts:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let displayedAttempts = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = "+ \(displayedAttempts)"
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .chatChooseBackgroundColor:
                let cell = ChatBackgroundColorSelectionCell()
                cell.configure()
                
                guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
                    return UITableViewCell(frame: .zero)
                }
                let dict = userDefaults.dictionaryRepresentation()
                cell.currentColor = ChatViewController.BackgroundColor(rawValue: dict["chat_chooseBackgroundColor"] as? String ?? "purple")
                
                return cell
                
            default:
                break
            }
        }
        
        switch menuItem.itemType {
        case .selector:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
            cell.textLabel?.text = menuItem.title
            if let key = menuItem.key, key == .chatChooseMessageSound || key == .chatChooseSubscriptionSound,
               let fileName = menuItem.current.split(separator: "/").last,
               let pointIndex =  fileName.lastIndex(of: ".") {
                let fileNameWithoutExtesion = fileName.prefix(upTo: pointIndex)
                cell.detailTextLabel?.text = String(fileNameWithoutExtesion)
            } else {
                cell.detailTextLabel?.text = menuItem.current.split(separator: "_").joined(separator: " ").capitalized
            }
            cell.accessoryType = .disclosureIndicator
            return cell
        
        case .toggle:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SwitchCell.cellName, for: indexPath) as? SwitchCell else {
                return UITableViewCell()
            }
            cell.switchCallback = onBoolItemDidChange
            cell.configure(key: menuItem.key?.rawValue ?? "", for: menuItem.title ?? "", active: menuItem.toggle)
            return cell
            
        default:
            let cell = UITableViewCell()
            if let key = menuItem.key, key == .turnBiometricsOnOff {
                cell.textLabel?.textColor = .systemBlue
                cell.accessoryType = .none
                let biometricsSuport = SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false
                cell.textLabel?.text = biometricsSuport ? "Turn Biometrics Off" : "Turn Biometrics On"
                return cell
            }
            cell.textLabel?.text = menuItem.title
            cell.accessoryType = .disclosureIndicator
            if menuItem.section == .exceptions {
                if indexPath.row == 0 {
                    cell.textLabel?.textColor = .systemBlue
                } else {
                    cell.textLabel?.textColor = .systemRed
                }
                cell.accessoryType = .none
            } else if menuItem.section == .security {
                cell.textLabel?.textColor = .systemBlue
                cell.accessoryType = .none
            } else if menuItem.section == .delete {
                cell.textLabel?.textColor = .systemRed
                cell.accessoryType = .none
                cell.textLabel?.textAlignment = .center
            }
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.datasource?.childs[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return self.datasource?.childs[section].subtitle
    }
}

extension SimpleTableViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let menuItem = datasource?.childs[indexPath.section].childs[indexPath.row]
        
        if menuItem?.key == .chatChooseBackgroundColor {
            return 140
        }
        
        return 44
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
         
        guard let datasource = self.datasource else { return }
         
        let menuItem = datasource.childs[indexPath.section].childs[indexPath.row]
         
        if let key = menuItem.key {
            switch key {
            case .accountStatus:
                let vc = AccountNewStatusViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
                 
            case .accountVcard:
                let vc = AccountEditViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
                 
            case .accountColor:
                let vc = AccountColorViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
                 
            case .accountBlockedContacts:
                let vc = AccountBlockListViewController()
                vc.configure(for: jid, isGroupchatInvitation: false)
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .turnBiometricsOnOff:
                let biometricsSuport = SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false
                if biometricsSuport {
                    let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                    let turnBiometricsOffAction = UIAlertAction(title: "Turn Biometrics Off", style: .destructive) { _ in
                        SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                        return
                    }
                    alert.addAction(turnBiometricsOffAction)
                    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                    alert.addAction(cancelAction)
                    alert.iPadPopoverControllerInit(viewController: self)
                    self.present(alert, animated: true)
                    return
                }
                let context = LAContext()
                context.localizedCancelTitle = "Use only passcode"
                let reason = "Unlock application with biometrics"
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { success, error in
                    SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: success)
                    if success {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [indexPath], with: .none)
                            //self.navigationController?.popViewController(animated: true)
                        }
                    }
                }
                return
                
            case .turnPasscodeOff:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let turnPasscodeOffAction = UIAlertAction(title: "Turn Passcode Off", style: .destructive, handler: { _ in
                    CredentialsManager.shared.clearPincodes()
                    SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
                    self.navigationController?.popViewController(animated: true)
                })
                alert.addAction(turnPasscodeOffAction)
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true, completion: nil)
                return
                
            case .passcodeTimer:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let items = ["Never", "1 min", "2 min", "5 min", "10 min"]
                for item in items {
                    let action = UIAlertAction(title: item, style: .default, handler: { item in
                        guard let selected = item.title,
                              let prefix = selected.split(separator: " ").first else { return }
                        let minutes = Int(prefix) ?? 0
                        let seconds = minutes * 60
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: seconds)
                        ApplicationStateManager.shared.period = TimeInterval(seconds)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true, completion: nil)
                return
                
            case .passcodeAttempts:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let items = ["1", "2", "3", "4", "5"]
                for item in items {
                    let action = UIAlertAction(title: item, style: .default, handler: { item in
                        guard let selected = item.title else { return }
                        let attempts = Int(selected) ?? 0
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: attempts)
                        CredentialsManager.shared.setPasscodeAttemptsLeft(attempts)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true)
                return
            
            case .displayedAttempts:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let items = ["+ 0", "+ 1", "+ 2", "+ 3", "+ 4", "+ 5", "+ 10"]
                for item in items {
                    let action = UIAlertAction(title: item, style: .default, handler: { item in
                        guard let selected = item.title else { return }
                        let displayedAttempts = Int(selected.dropFirst(2)) ?? 0
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: displayedAttempts)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true)
                return

            case .accountDelete:
                let alertMessage: String
                
                if CommonConfigManager.shared.config.locked_host.isNotEmpty {
                    alertMessage = "Enter your password to permanently delete \(self.jid) from Clandestino.\n\nThis action can not be undone."
                } else {
                    if let host = XMPPJID(string: self.jid)?.domain {
                        alertMessage = "Enter your password to permanently delete \(self.jid) from \(host).\n\nThis action can not be undone."
                    } else {
                        alertMessage = "Enter your password to permanently delete \(self.jid) from server.\n\nThis action can not be undone."
                    }
                }
                let alert = UIAlertController(title: "Delete account".localizeString(id: "account_delete", arguments: []),
                                              message: alertMessage, preferredStyle: .alert)
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
                alert.addAction(cancelAction)
                let deleteAction = UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
                    let password = alert.textFields?.first?.text ?? ""
                    self.navigationItem.setRightBarButton(self.deleteSpinner, animated: true)
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    UIView.animate(withDuration: 0.5, animations: { self.whiteView.alpha = 1.0 } )
                    
                    AccountManager.shared.find(for: self.jid)?.action({ user, _ in
                        user.cloudStorage.deleteGallery(jid: self.jid)
                    })
                    XMPPAccountDeleteManager.shared.deleteAccount(jid: self.jid, password: password, delegate: self)
                })
                alert.addAction(deleteAction)
                deleteAction.isEnabled = false
                alert.addTextField()

                if let textField = alert.textFields?.first {
                    textField.textContentType = .password
                    textField.isSecureTextEntry = true
                    textField.keyboardType = .asciiCapable
                    textField.placeholder = "password"
                    textField.clearButtonMode = .always
                    textField.addTarget(alert, action: #selector(alert.textDidChange), for: .editingChanged)
                }
                self.present(alert, animated: true, completion: nil)
                return
            default: break
            }
        }
        
        if menuItem.values.isNotEmpty {
            let selectorVC = SelectorViewController()
            selectorVC.configure(for: menuItem)
            selectorVC.title = menuItem.title
            navigationController?.pushViewController(selectorVC, animated: true)
            return
        }
         
        guard let viewController = menuItem.viewController else {
            return
        }
        
        if let tableVC = viewController.init() as? SimpleTableViewController {
            tableVC.datasource = menuItem
            navigationController?.pushViewController(tableVC, animated: true)
        } else {
            if viewController.init() is ChangePasswordTableViewController {
                var style: UITableView.Style
                if #available(iOS 13.0, *) {
                    style = UITableView.Style.insetGrouped
                } else {
                    style = UITableView.Style.grouped
                }
                let vc = ChangePasswordTableViewController(style: style)
                vc.jid = self.jid
                navigationController?.pushViewController(vc, animated: true)
            } else {
                navigationController?.pushViewController(viewController.init(), animated: true)
            }
        }
        return
    }
}

extension SimpleTableViewController: XMPPAccountDeleteManagerDelegate {
    func didReceiveResponse(title: String?, description: String?) {
        DispatchQueue.main.async {
            self.navigationItem.setRightBarButton(nil, animated: true)
            if !AccountManager.shared.emptyAccountsList() {
                self.navigationItem.setHidesBackButton(false, animated: true)
                UIView.animate(withDuration: 0.5, animations: { self.whiteView.alpha = 0.0 })
            }
            let alert = UIAlertController(title: title, message: description, preferredStyle: .alert)
            let action = UIAlertAction(title: "OK", style: .default, handler: {_ in
                if AccountManager.shared.emptyAccountsList() {
                    DispatchQueue.main.async {
                        let vc = OnboardingViewController()
                        let navigationController = UINavigationController(rootViewController: vc)
                        navigationController.isNavigationBarHidden = true
                        (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                    }
                }
            })
            alert.addAction(action)
            self.present(alert, animated: true, completion: nil)
        }
    }
}

extension SimpleTableViewController {
    internal func onBoolItemDidChange(_ key: String, value: Bool) {
        SettingManager.shared.saveItem(key: key, bool: value)
    }
}

extension UIAlertController {
    func iPadPopoverControllerInit(viewController: UIViewController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = self.popoverPresentationController {
                popoverController.sourceView = viewController.view
                popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
    }
}

extension UIAlertController {
    @objc func textDidChange() {
        guard let textField = textFields?.first,
              let deleteAction = actions.first(where: { $0.title == "Delete" }) else {
            return
        }
        let text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        deleteAction.isEnabled = text.count > 2
    }
}
