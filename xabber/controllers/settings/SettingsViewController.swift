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
import RxSwift
import RxCocoa
import RxRealm
import XMPPFramework
import CocoaLumberjack
import TOInsetGroupedTableView
import SwiftUI
import CocoaLumberjack
import MaterialComponents.MDCPalettes

class SettingsViewController: BaseViewController {
    
    class Datasource {
        enum Keys: String {
            case accountStatus = "account_status"
            case accountVcard = "account_vcard"
            case accountColor = "account_color"
            case accountBlockedContacts = "account_blocked_contacts"
            case accountDelete = "account_delete"
            case accountSessions = "account_sessions"
            case accountQuota = "account_quota"
            case accountEncryption = "account_encryption"
            case subscriptions = "subscriptions"
            case manageStorage = "manage_storage"
            case chatChooseBackground = "chat_chooseBackground"
            case chatChooseMessageSound = "chat_choose_message_sound"
            case chatChooseSubscriptionSound = "chat_choose_subscription_sound"
            case developer = "developer"
            case languages = "languages"
            case turnPasscodeOff = "turn_passcode_off"
            case turnBiometricsOnOff = "turn_biometrics_on_off"
            case passcodeTimer = "passcode_timer"
            case passcodeAttempts = "passcode_attempts"
            case displayedAttempts = "displayed_attempts"
            case showAttempts = "show_attempts"
            case passcode = "passcode"
            case yubikey = "yubikey"
            case notificationInAppAlertLastChats = "notification_in_app_alert_last_chats"
            case notificationInAppSound = "notification_in_app_sound"
            case avatarMasksCurrentAvatarMask = "avatar_masks_current_avatar_mask_"
            case afterburnTimer = "afterburn_timer"
            case afterburnEnabled = "burn_messages_enabled"
//            case privacy
        }
        
        enum Section: Int {
            case xAccount = 0
            case xmppAccounts
            case interface
            case settings
            case languages
            case about
            case appearance
            case chat
            case contactList
            case chats
            case calls
            case attentionCalls
            case badgeCounter
            case inAppNotifications
            case exceptions
            case privacy
            case security
            case subscriptions
            case accountSettings
            case status
            case profile
            case server
            case autolock
            case delete
            case none
            case afterburn
            case session
            
            func description() -> String {
                switch self {
                case .xAccount:
                    return ""
                case .xmppAccounts:
                    return "XMPP Accounts".localizeString(id: "xmpp_accounts", arguments: [])
                case .interface:
                    return "Interface".localizeString(id: "category_interface", arguments: [])
                case .settings:
                    return "Settings".localizeString(id: "settings", arguments: [])
                case .languages:
                    return "Choose language".localizeString(id: "settings_choose_language", arguments: [])
                case .about:
                    return "About".localizeString(id: "about", arguments: [])
                case .appearance:
                    return "Appearance"
                case .chat:
                    return "Chat"
                case .contactList:
                    return "Contact list"
                case .chats:
                    return "Chats"
                case .calls:
                    return "Calls"
                case .attentionCalls:
                    return "Attention calls"
                case .badgeCounter:
                    return "Badge counter"
                case .inAppNotifications:
                    return "In-app notifications"
                case .exceptions:
                    return "Exceptions"
                case .privacy:
                    return "Privacy".localizeString(id: "privacy", arguments: [])
                case .security:
                    return "Security"
                case .subscriptions:
                    return "Subscriptions"
                case .accountSettings:
                    return "Account settings"
                case .status:
                    return "Status"
                case .profile:
                    return "Profile"
                case .server:
                    return "Server"
                case .autolock:
                    return "Auto-Lock"
                case .delete:
                    return "Delete account".localizeString(id: "account_delete", arguments: [])
                case .afterburn:
                    return "Burning messages"
                default:
                    return ""
                }
            }
            
            func secondaryDescription() -> String {
                switch self {
                case .security:
                    return "* Premium account only"
                case .delete:
                    return "This action will delete the account from the server."
                default:
                    return ""
                }
            }
        }
        
        enum ItemType {
            case plain
            case toggle
            case selector
        }
        
        var section: Section
        var title: String? = nil
        var subtitle: String? = nil
        var premiumOnly: Bool = false
        var key: Keys? = nil //String? = nil
        var childs: [Datasource] = []
        var assetReference: String? = nil
        var values: [String] = []
        var current: String = ""
        var toggle: Bool = false
        var viewController: UIViewController.Type?
        var itemType: ItemType = .plain
        var verificationSid: String?
        var icon: String?
        var color: UIColor?
        
        init(section: Section,
             title: String? = nil,
             subtitle: String? = nil,
             icon: String? = nil,
             color: UIColor? = nil,
             premiumOnly: Bool = false,
             viewController: UIViewController.Type? = nil,
             itemType: ItemType = .plain,
             values: [String] = [],
             current: String = "",
             toggle: Bool = false,
             childs: [Datasource] = [],
             key: Keys? = nil, //String? = nil,
             assetReference: String? = nil, verificationSid: String? = nil) {
            self.section = section
            self.title = title
            self.subtitle = subtitle
            self.premiumOnly = premiumOnly
            self.viewController = viewController
            self.childs = childs
            self.key = key
            self.assetReference = assetReference
            self.itemType = itemType
            self.values = values
            self.current = current
            self.toggle = toggle
            self.verificationSid = verificationSid
            self.icon = icon
            self.color = color
        }
    }
    
    class DeviceCell: UITableViewCell {
        static let cellName: String = "SettingsViewControllerrDeviceCell"
        
        
        let subtitleButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.setTitleColor(.secondaryLabel, for: .normal)
            
            return button
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            
            return stack
        }()
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 72, right: 8)
            stack.addArrangedSubview(self.titleLabel)
            stack.addArrangedSubview(self.subtitleButton)
            self.subtitleButton.isUserInteractionEnabled = false
            NSLayoutConstraint.activate([
                self.subtitleButton.widthAnchor.constraint(equalToConstant: 56)
            ])
            selectionStyle = .none
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
    }
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(AccountCell.self, forCellReuseIdentifier: AccountCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "AddAccountCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsItem")
        view.register(DeviceCell.self, forCellReuseIdentifier: DeviceCell.cellName)
        view.register(SettingsItemDetailViewController.SelectorCell.self, forCellReuseIdentifier: SettingsItemDetailViewController.SelectorCell.cellName)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "manageStorage")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "value1CellReuseID")
        
        return view
    }()
    
    lazy var spinner: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        activityIndicator.color = UIColor.gray
        activityIndicator.isHidden = false
        activityIndicator.startAnimating()
        activityIndicator.hidesWhenStopped = true
        return activityIndicator
    }()
    
    lazy var spinner2: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        activityIndicator.color = UIColor.gray
        activityIndicator.isHidden = false
        activityIndicator.startAnimating()
        activityIndicator.hidesWhenStopped = true
        return activityIndicator
    }()

    internal var bag: DisposeBag = DisposeBag()
    internal var accounts: Results<AccountStorageItem>? = nil
    internal let accountsSection: Int = 0
    internal var datasource: [Datasource] = []
    internal var editButton: UIBarButtonItem? = nil
    internal var doneEditButton: UIBarButtonItem? = nil
    internal var barButtonItemAddAccount: UIBarButtonItem? = nil
    
    var activeVerificationSession: VerificationSessionStorageItem? = nil
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        
        return view
    }()
    
//    var scrollViewContentOffsetYCopy: CGFloat = 0
    var headerHeightMax: CGFloat = 188
//    var headerHeightMin: CGFloat = 0
    var nickname = ""
    
    internal var resources: Results<ResourceStorageItem>? = nil
    internal var sessionsCount: Int = 0
    internal var omemoDeviceActionsRequired: Bool = false
    internal var omemoDeviceWarning: Bool = false
    internal var blockedContactsCount: Int = 0
    internal var groupchatInvitationsCount: Int = 0
    internal var currentResource: String? = nil
    
    var avatarUrl: String? = nil
    
    var quota: String = ""
    var used: String = ""
    
    var shouldShowTabBar: Bool = false
    
    internal func subscribe() {
    
        bag = DisposeBag()
        
        do {
            let realm = try Realm()
            
            self.accounts = realm
                .objects(AccountStorageItem.self)
                .sorted(byKeyPath: "order", ascending: true)
            
            self.resources = realm
                .objects(ResourceStorageItem.self)
                .filter("owner == %@ AND jid == %@", jid, jid)
                .sorted(by: [
                    SortDescriptor(keyPath: "isCurrentResourceForAccount", ascending: false),
                    SortDescriptor(keyPath: "timestamp", ascending: false)
                ])
            
            self.load()
            tableView.reloadData()
            
            let accountsObserver = realm
                .objects(AccountStorageItem.self)
                .filter("jid == %@", jid)
            
            Observable
                .collection(from: accountsObserver)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.nickname = item.username

                        if item.enabled {
                            self.currentResource = item.resource?.resource
                        } else {
                            self.currentResource = nil
                        }
                        self.headerView.configure(
                            avatarUrl: item.avatarUrl,
                            owner: self.jid,
                            jid: self.jid,
                            titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                            title: item.username,
                            subtitle: item.jid,
                            thirdLine: nil
                        )
                    } else {
                        self.nickname = XMPPJID(string: self.jid)?.user ?? self.jid
                    }
                    
                }).disposed(by: bag)
           
            if let item = accountsObserver.first {
                self.nickname = item.username

                if item.enabled {
                    self.currentResource = item.resource?.resource
                } else {
                    self.currentResource = nil
                }
                self.headerView.configure(
                    avatarUrl: item.avatarUrl,
                    owner: self.jid,
                    jid: self.jid,
                    titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                    title: item.username,
                    subtitle: item.jid,
                    thirdLine: nil
                )
            } else {
                self.nickname = XMPPJID(string: self.jid)?.user ?? self.jid
            }
            
            Observable
                .changeset(from: self.resources!)
                .debounce(.milliseconds(12), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if results.0.isEmpty {
                    } else {
                        self.tableView.reloadData()
                    }
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.jid, self.jid))
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.omemoDeviceWarning = false
                    self.omemoDeviceActionsRequired = false
                    if results.toArray().filter({ $0.state == .unknown }).isNotEmpty {
                        self.omemoDeviceActionsRequired = true
                    }
                    if results.toArray().filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).isNotEmpty {
                        self.omemoDeviceWarning = true
                    }
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)

            Observable
                .collection(from: realm.objects(DeviceStorageItem.self)
                    .filter("owner == %@", self.jid))
                .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.sessionsCount = results.count
                    DispatchQueue.main.async {
                        if let accounts = self.accounts, self.datasource.isNotEmpty {
                            let section = accounts.count > 1 ? 1 : 0
                            guard let row = self.datasource[section]
                                .childs
                                .firstIndex(where: { $0.key == .accountSessions }) else { return }
                            let indexPath = IndexPath(row: row, section: section)
                            if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                                visibleIndexPaths.contains(indexPath) {
                                self.tableView.reloadRows(at: [indexPath], with: .none)
                            }
                        }
                    }
                }).disposed(by: bag)
            
            Observable
                .changeset(from: self.accounts!)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    func updateDatasource() {
                        if let changeset = results.1 {
                            print(changeset)
                            self.tableView.deleteRows(
                                at: changeset.deleted
                                    .compactMap{return IndexPath(row: $0, section: self.accountsSection)},
                                with: .none
                            )
                            self.tableView.insertRows(
                                at: changeset.inserted
                                    .compactMap{return IndexPath(row: $0, section: self.accountsSection)},
                                with: .none
                            )
                            self.tableView.reloadRows(
                                at: changeset.updated
                                    .compactMap{return IndexPath(row: $0, section: self.accountsSection)},
                                with: .none
                            )
                        }
                    }
                    self.load()
                    self.tableView.reloadData()
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm
                    .objects(VerificationSessionStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.owner))
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if self.datasource.isEmpty {
                        return
                    }
                    
                    self.load()
                    self.tableView.reloadData()
                    
                }).disposed(by: bag)
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    func navigationBarButtonsConfigure(multiAccounts: Bool) {
        barButtonItemAddAccount = (CommonConfigManager.shared.config.supports_multiaccounts && !multiAccounts) ?
        UIBarButtonItem(image: imageLiteral( "contact-add")?.withRenderingMode(.alwaysTemplate),
                        style: .plain,
                        target: self,
                        action: #selector(addAccount)) : nil
        if (CommonConfigManager.shared.config.supports_multiaccounts && !multiAccounts) {
            navigationItem.leftItemsSupplementBackButton = true
            navigationItem.setLeftBarButtonItems([barButtonItemAddAccount].compactMap { $0 } , animated: false)
        }
        
        
        if multiAccounts {
            if self.tableView.isEditing {
                navigationItem.setRightBarButtonItems([doneEditButton].compactMap { $0 }, animated: false)
            } else {
                navigationItem.setRightBarButtonItems([editButton].compactMap { $0 }, animated: false)
            }
        } else {
            let qrCodeButton = UIBarButtonItem(image: imageLiteral( "qrcode")?.withRenderingMode(.alwaysTemplate),
                                               style: .plain,
                                               target: self,
                                               action: #selector(self.onQRCode))
            let paletteButton = UIBarButtonItem(image: imageLiteral( "palette")?.withRenderingMode(.alwaysTemplate),
                                                style: .plain,
                                                target: self,
                                                action: #selector(self.showAccountColorViewController))
            if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
                navigationItem.setRightBarButtonItems([qrCodeButton], animated: false)
            } else {
                navigationItem.setRightBarButtonItems([qrCodeButton, paletteButton], animated: false)
            }
        }
    }
    
    internal func load() {
        datasource = []
        activeVerificationSession = nil
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common")
            else { fatalError() }
        let dict = userDefaults.dictionaryRepresentation()
        
        guard let accounts = self.accounts,
              let item = accounts.first else { return }
        self.nickname = item.username
        self.jid = item.jid
        
        if accounts.count > 1 {
            datasource.append(Datasource(section: .xmppAccounts, title: Datasource.Section.xmppAccounts.description()))
            headerView.removeFromSuperview()
            tableView.fillSuperview()
            if #available(iOS 11.0, *) {
                let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top
                tableView.contentInset = UIEdgeInsets(top: topOffset ?? 0, bottom: 0, left: 0, right: 0)
            } else {
                tableView.contentInset = UIEdgeInsets.zero
            }
            tableView.contentInset = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
            navigationBarButtonsConfigure(multiAccounts: true)
        } else {
            tableView.setEditing(false, animated: false)
            navigationBarButtonsConfigure(multiAccounts: false)
//            headerViewConfig()
            
            do {
                let realm = try WRealm.safe()
                if let item = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                    self.headerView.configure(
                        avatarUrl: item.avatarUrl,
                        owner: self.jid,
                        jid: self.jid,
                        titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                        title: self.nickname,
                        subtitle: self.jid,
                        thirdLine: nil
                    )
                }
                
                if let sessionInstance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.owner).first {
                    self.activeVerificationSession = sessionInstance
                    let (text, secondaryText) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(withOwnDevice: true, verificationState: sessionInstance.state)
                    let verificationDatasource = Datasource(section: .session, childs: [Datasource(section: .session, title: text, subtitle: secondaryText)])
                    
                    datasource.append(verificationDatasource)
                }
            } catch {
                DDLogDebug("SettingsViewController:\(#function). \(error.localizedDescription)")
            }
            
            var profileChilds = [
                Datasource(section: .profile, title: "Profile", key: .accountVcard),
                Datasource(section: .profile, title: "Password", viewController: ChangePasswordTableViewController.self),
                Datasource(section: .profile, title: "Account color", key: .accountColor),
                Datasource(section: .profile, title: "Blocked contacts", key: .accountBlockedContacts),
            ]
            if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
                profileChilds = [
                    Datasource(section: .profile, title: "Profile", key: .accountVcard),
                    Datasource(section: .profile, title: "Password", viewController: ChangePasswordTableViewController.self),
                    Datasource(section: .profile, title: "Blocked contacts", key: .accountBlockedContacts),
                ]
            }
            if CommonConfigManager.shared.config.should_block_application_when_subscribtion_end {
                datasource.append(Datasource(section: .accountSettings, childs: [
                    Datasource(section: .accountSettings, title: "Profile, status, password", icon: "custom.person.square.fill", color: UIColor.systemBlue, viewController: SimpleTableViewController.self, childs: [
                        Datasource(section: .status, childs: [
                            Datasource(section: .status, title: Datasource.Section.status.description(), key: .accountStatus)
                        ]),
                        Datasource(section: .profile, childs: profileChilds),
                        Datasource(section: .delete, subtitle: Datasource.Section.delete.secondaryDescription(), childs: [
                            Datasource(section: .delete,
                                       title: Datasource.Section.delete.description(),
                                       key: .accountDelete)
                        ])
                    ]),
                    Datasource(section: .accountSettings, title: "Devices", icon: "xabber.devices.fill.square.fill", color: UIColor.systemBlue, key: .accountSessions),
                    Datasource(section: .accountSettings, title: "Subscriptions", icon: "xabber.lightbulb.square.fill", color: UIColor.systemBlue, key: .subscriptions)
                ]))
            } else {
                datasource.append(Datasource(section: .accountSettings, childs: [
                    Datasource(section: .accountSettings, title: "Profile, status, password", icon: "custom.person.square.fill", color: UIColor.systemBlue, viewController: SimpleTableViewController.self, childs: [
                        Datasource(section: .status, childs: [
                            Datasource(section: .status, title: Datasource.Section.status.description(), key: .accountStatus)
                        ]),
                        Datasource(section: .profile, childs: profileChilds),
                        Datasource(section: .delete, subtitle: Datasource.Section.delete.secondaryDescription(), childs: [
                            Datasource(section: .delete,
                                       title: Datasource.Section.delete.description(),
                                       key: .accountDelete)
                        ])
                    ]),
                    Datasource(section: .accountSettings, title: "Devices", icon: "xabber.devices.fill.square.fill", color: UIColor.systemBlue, key: .accountSessions)
                ]))
            }
            
            if AccountManager.shared.find(for: self.jid)?.cloudStorage.isAvailable() ?? false {
                let item = Datasource(section: .accountSettings, title: "Cloud storage", icon: "custom.cloud.square.fill", color: UIColor.systemBlue, key: .manageStorage)
                let sectionToInsert = datasource.firstIndex(where: { $0.section == .accountSettings })
                datasource[sectionToInsert!].childs.insert(item, at: 1)
            }
        }
        
        var interfaceChilds = [
            Datasource(section: .chat, title: Datasource.Section.chat.description(), childs: [
                Datasource(section: .chat, title: "Background", itemType: .selector,
                           values: ["None", "Honeycomb", "Aliens", "Summer", "Cats", "Flowers", "Flowers-daisy", "Hearts"],
                           current: (dict[Datasource.Keys.chatChooseBackground.rawValue] as? String) ?? "None",
                           key: .chatChooseBackground)
            ]),
            Datasource(section: .contactList, title: Datasource.Section.contactList.description(), childs: [
                Datasource(section: .contactList, title: "Avatars", itemType: .selector,
                           values: AccountMasksManager.shared.masksList(),
                           current: (dict[Datasource.Keys.avatarMasksCurrentAvatarMask.rawValue] as? String) ?? "None",
                           key: .avatarMasksCurrentAvatarMask)
            ])
        ]
        if CommonConfigManager.shared.config.locked_background.isNotEmpty {
            interfaceChilds = [
                Datasource(section: .contactList, title: Datasource.Section.contactList.description(), childs: [
                    Datasource(section: .contactList, title: "Avatars", itemType: .selector,
                               values: AccountMasksManager.shared.masksList(),
                               current: (dict[Datasource.Keys.avatarMasksCurrentAvatarMask.rawValue] as? String) ?? "None",
                               key: .avatarMasksCurrentAvatarMask)
                ])
            ]
        }
        
        datasource.append(Datasource(section: .settings, title: Datasource.Section.settings.description(), childs: [
            Datasource(
                section: .privacy,
                title: Datasource.Section.privacy.description(),
                subtitle: nil,
                icon:"xabber.incognito.square.fill",
                color: UIColor.systemGreen,
                premiumOnly: false,
                viewController: PrivacySettingsViewController.self,
                childs: []
              ),
            Datasource(section: .interface, title: "Interface", icon: "custom.paintpalette.square.fill", color: UIColor.systemGreen, viewController: SimpleTableViewController.self, childs: interfaceChilds),
            Datasource(section: .settings, title: "Notifications", icon: "custom.bell.square.fill", color: UIColor.systemGreen, viewController: SimpleTableViewController.self, childs: [
                        Datasource(section: .chat, title: "Notifications Sound", childs: [
                            Datasource(section: .chat, title: "Incoming massages", itemType: .selector,
                                                           values: MusicBox.shared.fileURLs.lazy.compactMap({$0.absoluteString}).sorted(),
                                                           current: (dict[Datasource.Keys.chatChooseMessageSound.rawValue] as? String) ?? "None",
                                                           key: .chatChooseMessageSound),
                            Datasource(section: .chat, title: "Subscription requests", itemType: .selector,
                                                           values: MusicBox.shared.fileURLs.lazy.compactMap({$0.absoluteString}).sorted(),
                                                           current: (dict[Datasource.Keys.chatChooseSubscriptionSound.rawValue] as? String) ?? "None",
                                                           key: .chatChooseSubscriptionSound)
                        ]),
                        Datasource(section: .inAppNotifications, title: Datasource.Section.inAppNotifications.description(), childs: [
                            Datasource(section: .inAppNotifications,
                                       title: "In-app sounds",
                                       itemType: .toggle,
                                       toggle: dict[Datasource.Keys.notificationInAppSound.rawValue] as? Bool ?? true,
                                       key: .notificationInAppSound),
                            Datasource(section: .inAppNotifications,
                                       title: "On chats screen message preview",
                                       itemType: .toggle,
                                       toggle: dict[Datasource.Keys.notificationInAppAlertLastChats.rawValue] as? Bool ?? false,
                                       key: .notificationInAppAlertLastChats)
                    ])
                ]),
            Datasource(section: .settings, title: "Debug", icon:"custom.ant.square.fill", color: UIColor.systemGreen, key: .developer),
            Datasource(section: .settings, title: "Language", icon:"xabber.translate.square.fill", color: UIColor.systemPurple, key: .languages)
            ]))
        if CommonConfigManager.shared.config.use_yubikey {
            datasource.append(Datasource(section: .security, title: Datasource.Section.security.description(), subtitle: Datasource.Section.security.secondaryDescription(), childs: [
                Datasource(section: .security, title: "Passcode lock *", icon:"custom.hand.raised.square.fill", color: UIColor.systemOrange, premiumOnly: true, viewController: SimpleTableViewController.self, childs: [
                        Datasource(section: .security, subtitle: "If you forget your passcode, you'll need to reinstall the app.\n\nIf you premium subscription expire, passcode will be reset.", childs: [
                            Datasource(section: .security, title: "Turn passcode Off", key: .turnPasscodeOff),
                            Datasource(section: .security, title: "Change Passcode", viewController: PasscodeViewController.self),
                            Datasource(section: .security, title: "Biometrics", key: .turnBiometricsOnOff)]),
                        Datasource(section: .security, childs: [
                            Datasource(section: .autolock, title: "Auto-Lock", key: .passcodeTimer),
                            Datasource(section: .autolock, title: "Attempts", key: .passcodeAttempts),
                            Datasource(section: .autolock, title: "Displayed attempts", key: .displayedAttempts),
                            Datasource(section: .autolock, title: "Show attempts left", itemType: .toggle, toggle: (dict[Datasource.Keys.showAttempts.rawValue] as? Bool) ?? false, key: .showAttempts)
                        ])
                    ], key: .passcode),
                    Datasource(section: .security, title: "Yubikey signature", icon: "custom.key.square.fill", color: UIColor.systemOrange, viewController: YubikeySetupViewController.self, key: .yubikey),
                ]))
        } else {
            datasource.append(Datasource(section: .security, title: Datasource.Section.security.description(), subtitle: Datasource.Section.security.secondaryDescription(), childs: [
                Datasource(section: .security, title: "Passcode lock *", icon:"custom.hand.raised.square.fill", color: UIColor.systemOrange, premiumOnly: true, viewController: SimpleTableViewController.self, childs: [
                        Datasource(section: .security, subtitle: "If you forget your passcode, you'll need to reinstall the app.\n\nIf you premium subscription expire, passcode will be reset.", childs: [
                            Datasource(section: .security, title: "Turn passcode Off", key: .turnPasscodeOff),
                            Datasource(section: .security, title: "Change Passcode", viewController: PasscodeViewController.self),
                            Datasource(section: .security, title: "Biometrics", key: .turnBiometricsOnOff)]),
                        Datasource(section: .security, childs: [
                            Datasource(section: .autolock, title: "Auto-Lock", key: .passcodeTimer),
                            Datasource(section: .autolock, title: "Attempts", key: .passcodeAttempts),
                            Datasource(section: .autolock, title: "Displayed attempts", key: .displayedAttempts),
                            Datasource(section: .autolock, title: "Show attempts left", itemType: .toggle, toggle: (dict[Datasource.Keys.showAttempts.rawValue] as? Bool) ?? false, key: .showAttempts)
                        ])
                    ], key: .passcode)
                ]))
        }
    }
    
    internal func configure() {
        self.navigationItem.backButtonTitle = "Settings".localizeString(id: "settings", arguments: [])
        view.addSubview(tableView)
        
        do {
            let realm = try WRealm.safe()
            self.accounts = realm
                .objects(AccountStorageItem.self)
                .sorted(byKeyPath: "order", ascending: true)
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
        }
        if let accounts = self.accounts, accounts.count == 1 {
            let item = accounts.first!
            self.nickname = item.username
            self.jid = item.jid
            XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                session.devices?.requestList(stream)
            } fail: {
                AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                    user.devices.requestList(stream)
                })
            }
        }
        
        load()
        tableView.delegate = self
        tableView.dataSource = self
        editButton = UIBarButtonItem(title: "Edit", style: .plain, /*barButtonSystemItem: .edit,*/ target: self, action: #selector(self.onEdit))
        doneEditButton = UIBarButtonItem(title: "Done", style: .plain, /*barButtonSystemItem: .done,*/ target: self, action: #selector(self.onDoneEditing))
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    @objc
    func onAcceptButtonPressed() {
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            DispatchQueue.main.async {
                _ = user.akeManager.acceptVerificationRequest(jid: self.jid, sid: self.activeVerificationSession!.sid)
                
                NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showCodeOutputViewNotification,
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
        NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showCodeOutputViewNotification,
                                        object: self,
                                        userInfo: [
                                            "owner": self.owner,
                                            "sid": activeVerificationSession!.sid
                                        ])
    }
    
    @objc
    func onEnterCodePressed() {
        NotificationCenter.default.post(
            name: AuthenticatedKeyExchangeManager.showCodeInputViewNotification,
            object: self,
            userInfo: ["owner": self.jid, "sid": activeVerificationSession!.sid]
        )
        
//        let vc = AuthenticationCodeInputViewController()
//        vc.jid = self.jid
//        vc.owner = self.jid
//        vc.sid = activeVerificationSession!.sid
//        vc.isVerificationWithUsersDevice = true
//        
//        self.navigationController?.present(vc, animated: true)
    }
    
    @objc
    func onCloseVerificationButtonPressed() {
        guard let jid = XMPPJID(string: self.owner),
              let sid = activeVerificationSession?.sid else {
            DDLogDebug("SettingsViewController: \(#function).")
            return
        }
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
            
            if instance?.state == VerificationSessionStorageItem.VerififcationState.receivedRequest {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.akeManager.rejectRequestToVerify(jid: self.owner, sid: sid)
                })
//                akeManager.rejectRequestToVerify(jid: self.owner, sid: sid)
                
                return
            } else if instance?.state != VerificationSessionStorageItem.VerififcationState.failed && instance?.state != VerificationSessionStorageItem.VerififcationState.trusted && instance?.state != VerificationSessionStorageItem.VerififcationState.rejected {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.akeManager.sendErrorMessage(fullJID: jid, sid: sid, reason: "Сontact canceled verification session")
                })
//                akeManager.sendErrorMessage(fullJID: jid, sid: sid, reason: "Сontact canceled verification session")
                
            }
            try realm.write {
                realm.delete(instance!)
            }
            
            return
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }
    
    func headerViewConfig() {
        tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
        tableView.delegate = self
        tableView.dataSource = self
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        headerView.updateSubviews()
        tableView.tableHeaderView = headerView
        self.headerView.delegate = self
    }
    
    override func reloadDatasource() {
        headerView.setMask()
        for row in (0..<(self.accounts?.count ?? 1)) {
            let cell = tableView.cellForRow(at: IndexPath.init(row: row, section: 0)) as? AccountCell
            cell?.setMask()
        }
        tableView.reloadData()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        
        configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = ""
        
        NotifyManager.shared.setLastChats(displayed: false)
        headerViewConfig()
        getQuotaFromRealm()
        getQuota()
        subscribe()
        
        if self.shouldShowTabBar {
            self.tabBarController?.tabBar.isHidden = false
            self.tabBarController?.tabBar.layoutIfNeeded()
        }
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
//        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
//            session.blocked?.requestBlocklist(stream)
//            session.vcardManager?.requestItem(stream, jid: self.jid)
//        } fail: {
//            AccountManager.shared.find(for: self.jid)?.action({ (user, stream) in
//                user.blocked.requestBlocklist(stream)
//                user.vcards.requestItem(stream, jid: self.jid)
//            })
//        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
        self.navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    private func getQuotaFromRealm() {
        do {
            let realm = try Realm()
            guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
                                               forPrimaryKey: self.jid) else { return }
            self.quota = quotaItem.quota
            self.used = quotaItem.total
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func getQuota() {
        func callback() {
            do {
                let realm = try WRealm.safe()
                guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
                                                   forPrimaryKey: self.jid) else { return }
                self.quota = quotaItem.quota
                self.used = quotaItem.total
                self.tableView.reloadData()
            } catch {
                DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
            }
        }
        if !CommonConfigManager.shared.config.supports_multiaccounts {
            AccountManager.shared.users.first?.action({ user, stream in
                user.cloudStorage.getStats()
            })
        } else {
            AccountManager.shared.activeUsers.value.forEach {
                AccountManager.shared.find(for: $0)?.action({ user, stream in
                    user.cloudStorage.getStats()
                })
            }
        }
    }
}
