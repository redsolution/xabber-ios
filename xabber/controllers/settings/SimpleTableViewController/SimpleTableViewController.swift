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
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import XMPPFramework.XMPPJID
import LocalAuthentication

enum PasscodeSettingsOptionLocalization {
    static let autoLockSeconds = [0, 60, 120, 300, 600]
    static let attemptLimits = [0, 1, 2, 3, 4, 5]
    static let displayedAttemptOffsets = [0, 1, 2, 3, 4, 5, 10]

    static func autoLockTitle(
        seconds: Int,
        localizer: Localizing
    ) -> String {
        guard seconds > 0 else {
            return localizer.text(key: "never", fallback: "Never")
        }
        return localizer.plural(
            key: "settings__passcode__auto_lock_minutes_count",
            count: seconds / 60,
            fallback: "%lld minutes"
        )
    }

    static func attemptLimitTitle(
        attempts: Int,
        localizer: Localizing
    ) -> String {
        guard attempts > 0 else {
            return localizer.text(
                key: "simple__text__unlimited",
                fallback: "Unlimited"
            )
        }
        return localizer.formatters
            .numberFormatter()
            .string(from: NSNumber(value: attempts)) ?? String(attempts)
    }

    static func displayedAttemptOffsetTitle(
        offset: Int,
        localizer: Localizing
    ) -> String {
        let number = localizer.formatters
            .numberFormatter()
            .string(from: NSNumber(value: offset)) ?? String(offset)
        return "+ \(number)"
    }
}

class SimpleTableViewController: BaseViewController {

    final class ProfileMenuCell: UITableViewCell {
        static let cellName = "SimpleTableViewControllerProfileMenuCell"

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .default, reuseIdentifier: reuseIdentifier)
            textLabel?.font = .preferredFont(forTextStyle: .body)
            imageView?.contentMode = .scaleAspectFit
            accessoryType = .disclosureIndicator
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            textLabel?.text = nil
            imageView?.image = nil
            tintColor = .label
            accessibilityIdentifier = nil
            accessoryType = .disclosureIndicator
        }

        func configure(
            title: String,
            icon: String,
            color: UIColor,
            accessibilityIdentifier: String
        ) {
            textLabel?.text = title
            imageView?.image = imageLiteral(
                icon,
                dimension: SettingsMenuIconMetrics.dimension
            )
            tintColor = color
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }
    
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
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(ProfileMenuCell.self, forCellReuseIdentifier: ProfileMenuCell.cellName)
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
                if let currentResource = self.currentResource,
                    let resource = self.resources?.first(where: { $0.resource == currentResource }) {
                    let cell = StatusInfoCell()
                    cell.configure(
                        title: resource.displayedStatus,
                        status: resource.status,
                        entity: resource.entity,
                        isTemporary: resource.isTemporary
                    )
                    configureProfileStatusIcon(on: cell, for: menuItem)
                    return cell
                }
                let offline = "Offline".localizeString(id: "unavailable", arguments: [])
                let cell = StatusInfoCell()
                cell.configure(
                    title: offline,
                    status: .offline,
                    entity: .contact,
                    isTemporary: false
                )
                configureProfileStatusIcon(on: cell, for: menuItem)
                return cell
            
            case .accountColor:
                let colorItem = AccountColorManager.shared.colorItem(for: self.jid)
                if menuItem.icon != nil {
                    return makeProfileMenuCell(for: menuItem, at: indexPath)
                }
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                cell.detailTextLabel?.text = colorItem.title
                cell.detailTextLabel?.textColor = colorItem.primary
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .passcodeTimer:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let seconds = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = PasscodeSettingsOptionLocalization.autoLockTitle(
                    seconds: seconds,
                    localizer: LocalizationRuntime.shared.service
                )
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .passcodeAttempts:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let attempts = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = PasscodeSettingsOptionLocalization.attemptLimitTitle(
                    attempts: attempts,
                    localizer: LocalizationRuntime.shared.service
                )
                cell.accessoryType = .disclosureIndicator
                return cell
            
            case .displayedAttempts:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = menuItem.title
                let displayedAttempts = SettingManager.shared.getInt(for: "", scope: .security, key: key.rawValue)
                cell.detailTextLabel?.text = PasscodeSettingsOptionLocalization.displayedAttemptOffsetTitle(
                    offset: displayedAttempts,
                    localizer: LocalizationRuntime.shared.service
                )
                cell.accessoryType = .disclosureIndicator
                return cell
                
            case .chatChooseBackgroundColor:
                let cell = ChatBackgroundColorSelectionCell()
                cell.configure()
                
                guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
                    return UITableViewCell(frame: .zero)
                }
                let dict = userDefaults.dictionaryRepresentation()
                cell.currentColor = ChatViewController.BackgroundColor(rawValue: dict["chat_chooseBackgroundColor"] as? String ?? "purple")
                
                return cell
                
            default:
                break
            }
        }

        if menuItem.icon != nil {
            return makeProfileMenuCell(for: menuItem, at: indexPath)
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
                cell.textLabel?.text = biometricsSuport ? L10n.text("settings_security__title__turn_biometrics_off", fallback: "Turn Biometrics Off") : L10n.text("simple__text__turn_biometrics_on", fallback: "Turn Biometrics On")
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
                if menuItem.key == .turnPasscodeOff {
                    cell.textLabel?.textColor = .systemRed
                } else {
                    cell.textLabel?.textColor = .systemBlue
                }
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
            return 150
        }

        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
         
        guard let datasource = self.datasource else { return }
         
        let menuItem = datasource.childs[indexPath.section].childs[indexPath.row]
         
        if let key = menuItem.key {
            if isPasscodeConfigurationKey(key), !handlePasscodeConfigurationAccess() {
                return
            }

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

            case .accountCircles:
                let vc = AccountCirclesViewController()
                vc.configure(for: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .turnBiometricsOnOff:
                guard CredentialsManager.shared.isPincodeSetted() else {
                    self.view.makeToast(L10n.text("settings_security__toast__create_a_passcode_first", fallback: "Create a passcode first"))
                    return
                }
                let biometricsSuport = SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false
                if biometricsSuport {
                    let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                    let turnBiometricsOffAction = UIAlertAction(title: L10n.text("settings_security__title__turn_biometrics_off", fallback: "Turn Biometrics Off"), style: .destructive) { _ in
                        SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                        return
                    }
                    alert.addAction(turnBiometricsOffAction)
                    let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel)
                    alert.addAction(cancelAction)
                    alert.iPadPopoverControllerInit(viewController: self)
                    self.present(alert, animated: true)
                    return
                }
                let context = LAContext()
                context.localizedCancelTitle = L10n.text("settings__biometrics__use_passcode_only", fallback: "Use only passcode")
                let reason = L10n.text("settings__biometrics__unlock_reason", fallback: "Unlock application with biometrics")
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

            case .changePasscode:
                let vc = PasscodeViewController(mode: .verifyCurrent(.change))
                navigationController?.pushViewController(vc, animated: true)
                return
                
            case .turnPasscodeOff:
                guard CredentialsManager.shared.isPincodeSetted() else {
                    CredentialsManager.shared.clearPincodes()
                    SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
                    self.navigationController?.popToRootViewController(animated: true)
                    return
                }
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let turnPasscodeOffAction = UIAlertAction(title: L10n.text("settings_security__title__turn_passcode_off", fallback: "Turn Passcode Off"), style: .destructive, handler: { _ in
                    let vc = PasscodeViewController(mode: .verifyCurrent(.remove))
                    self.navigationController?.pushViewController(vc, animated: true)
                })
                alert.addAction(turnPasscodeOffAction)
                let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true, completion: nil)
                return
                
            case .passcodeTimer:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let localizer = LocalizationRuntime.shared.service
                for seconds in PasscodeSettingsOptionLocalization.autoLockSeconds {
                    let title = PasscodeSettingsOptionLocalization.autoLockTitle(
                        seconds: seconds,
                        localizer: localizer
                    )
                    let action = UIAlertAction(title: title, style: .default, handler: { _ in
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: seconds)
                        ApplicationStateManager.shared.period = TimeInterval(seconds)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true, completion: nil)
                return
                
            case .passcodeAttempts:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let localizer = LocalizationRuntime.shared.service
                for attempts in PasscodeSettingsOptionLocalization.attemptLimits {
                    let title = PasscodeSettingsOptionLocalization.attemptLimitTitle(
                        attempts: attempts,
                        localizer: localizer
                    )
                    let action = UIAlertAction(title: title, style: .default, handler: { _ in
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: attempts)
                        CredentialsManager.shared.setPasscodeAttemptsLeft(attempts)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true)
                return
            
            case .displayedAttempts:
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                let localizer = LocalizationRuntime.shared.service
                for offset in PasscodeSettingsOptionLocalization.displayedAttemptOffsets {
                    let title = PasscodeSettingsOptionLocalization.displayedAttemptOffsetTitle(
                        offset: offset,
                        localizer: localizer
                    )
                    let action = UIAlertAction(title: title, style: .default, handler: { _ in
                        SettingManager.shared.saveItem(for: "", scope: .security, key: key.rawValue, value: offset)
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    })
                    alert.addAction(action)
                }
                let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel)
                alert.addAction(cancelAction)
                alert.iPadPopoverControllerInit(viewController: self)
                self.present(alert, animated: true)
                return

            case .accountDelete:
                let alertMessage: String
                
                if CommonConfigManager.shared.config.locked_host.isNotEmpty {
                    alertMessage = L10n.format("simple__alert_message__enter_your_password_to_permanently_delete_value_from_clandestino_this_action_can", fallback: "Enter your password to permanently delete %@ from Clandestino.\n\nThis action can not be undone.", arguments: [String(describing: self.jid)])
                } else {
                    if let host = XMPPJID(string: self.jid)?.domain {
                        alertMessage = L10n.format("simple__alert_message__enter_your_password_to_permanently_delete_value_from_value_this_action_can", fallback: "Enter your password to permanently delete %@ from %@.\n\nThis action can not be undone.", arguments: [String(describing: self.jid), String(describing: host)])
                    } else {
                        alertMessage = L10n.format("simple__alert_message__enter_your_password_to_permanently_delete_value_from_server_this_action_can", fallback: "Enter your password to permanently delete %@ from server.\n\nThis action can not be undone.", arguments: [String(describing: self.jid)])
                    }
                }
                let alert = UIAlertController(title: "Delete account".localizeString(id: "account_delete", arguments: []),
                                              message: alertMessage, preferredStyle: .alert)
                let cancelAction = UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel, handler: nil)
                alert.addAction(cancelAction)
                let deleteAction = UIAlertAction(title: L10n.text("common__action__delete", fallback: "Delete"), style: .destructive, handler: { _ in
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
                    textField.placeholder = L10n.text("settings_security__field__password", fallback: "password")
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

private extension SimpleTableViewController {
    func configureProfileStatusIcon(
        on cell: StatusInfoCell,
        for item: SettingsViewController.Datasource
    ) {
        let image = item.icon.flatMap {
            imageLiteral($0, dimension: SettingsMenuIconMetrics.dimension)
        }
        cell.configureLeadingIcon(
            image: image,
            tintColor: item.color ?? .systemBlue,
            leadingInset: SettingsMenuIconMetrics.leadingInset
        )
    }

    func makeProfileMenuCell(
        for item: SettingsViewController.Datasource,
        at indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ProfileMenuCell.cellName,
            for: indexPath
        ) as? ProfileMenuCell,
        let icon = item.icon else {
            return UITableViewCell()
        }

        cell.configure(
            title: item.title ?? "",
            icon: icon,
            color: item.color ?? .systemBlue,
            accessibilityIdentifier: "settings_profile_\(item.key?.rawValue ?? "item")"
        )
        return cell
    }
}

private extension SimpleTableViewController {
    func isPasscodeConfigurationKey(_ key: SettingsViewController.Datasource.Keys) -> Bool {
        switch key {
        case .changePasscode,
             .turnPasscodeOff,
             .turnBiometricsOnOff,
             .passcodeTimer,
             .passcodeAttempts,
             .displayedAttempts,
             .showAttempts:
            return true
        default:
            return false
        }
    }

    func handlePasscodeConfigurationAccess() -> Bool {
        switch PasscodeLockPolicy.accessForCurrentState(jid: self.jid) {
        case .available:
            return true
        case .premiumRequired:
            let vc = PremiumSubscribtionViewController()
            vc.owner = self.jid
            vc.jid = self.jid
            navigationController?.pushViewController(vc, animated: true)
            return false
        case .disabledByConfig:
            self.view.makeToast(L10n.text("settings_security__toast__passcode_lock_is_unavailable", fallback: "Passcode Lock is unavailable"))
            return false
        }
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
            let action = UIAlertAction(title: L10n.text("common__action__ok", fallback: "OK"), style: .default, handler: {_ in
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
        if key == SettingsViewController.Datasource.Keys.showAttempts.rawValue,
           !handlePasscodeConfigurationAccess() {
            tableView.reloadData()
            return
        }
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
              let deleteAction = actions.first(where: { $0.title == L10n.text("common__action__delete", fallback: "Delete") }) else {
            return
        }
        let text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        deleteAction.isEnabled = text.count > 2
    }
}
