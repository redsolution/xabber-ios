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
import SwiftUI
import CocoaLumberjack
import MaterialComponents.MDCPalettes

enum SettingsMenuIconMetrics {
    static let dimension: CGFloat = 24

    static var leadingInset: CGFloat {
        if #available(iOS 26.0, *) {
            return 14
        }
        return 16
    }
}

struct SettingsCloudStorageQuotaDisplayState: Equatable {
    static let basicIconName = "custom.cloud.square.fill"
    static let premiumIconName = "custom.cloud.square.fill.badge.checkmark"

    let detailText: String
    let iconName: String

    static func resolve(
        hasCachedQuota: Bool,
        quotaBytes: Int,
        isRefreshing: Bool,
        lastRefreshFailed: Bool,
        isAvailable: Bool,
        galleryType: AccountGalleryType? = nil
    ) -> SettingsCloudStorageQuotaDisplayState {
        let iconName = galleryType == .premium ? premiumIconName : basicIconName

        func state(_ detailText: String) -> SettingsCloudStorageQuotaDisplayState {
            SettingsCloudStorageQuotaDisplayState(
                detailText: detailText,
                iconName: iconName
            )
        }

        if hasCachedQuota {
            return state(maximumQuotaText(quotaBytes: quotaBytes))
        }

        if lastRefreshFailed || !isAvailable {
            return state("Unavailable")
        }

        if isRefreshing {
            return state("Updating...")
        }

        return state("Updating...")
    }

    private static func maximumQuotaText(quotaBytes: Int) -> String {
        guard quotaBytes >= 0 else {
            return "Unlimited"
        }
        guard quotaBytes > 0 else {
            return "0 MB"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .decimal
        return formatter
            .string(fromByteCount: Int64(quotaBytes))
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "ГБ", with: "GB")
            .replacingOccurrences(of: "МБ", with: "MB")
    }
}

enum SettingsNavigationBarLeadingAction: Equatable {
    case dismissModal
    case none
}

enum SettingsNavigationBarRightAction: Equatable {
    case edit
    case done
    case qrCode
}

enum SettingsNavigationBarPolicy {
    static func leadingAction(exitAction: NavigationExitAction) -> SettingsNavigationBarLeadingAction {
        exitAction == .dismissModal ? .dismissModal : .none
    }

    static func rightActions(
        multiAccounts: Bool,
        isEditing: Bool,
        lockedAccountColor _: String
    ) -> [SettingsNavigationBarRightAction] {
        if multiAccounts {
            return [isEditing ? .done : .edit]
        }
        return [.qrCode]
    }

    static func barButtonStyle(
        for action: SettingsNavigationBarRightAction
    ) -> UIBarButtonItem.Style {
        switch action {
        case .edit, .qrCode:
            return .plain
        case .done:
            return .done
        }
    }
}

enum SettingsAccountProfileMenuFactory {
    static func makeSections(
        accountColorLocked: Bool
    ) -> [SettingsViewController.Datasource] {
        var primaryRows = [
            SettingsViewController.Datasource(
                section: .profile,
                title: "Status".localizeString(id: "groupchat_status", arguments: []),
                icon: "bolt.square.fill",
                color: .systemBlue,
                key: .accountStatus
            ),
            SettingsViewController.Datasource(
                section: .profile,
                title: "Profile",
                icon: "custom.person.square.fill",
                color: .systemBlue,
                key: .accountVcard
            ),
            SettingsViewController.Datasource(
                section: .profile,
                title: "Password".localizeString(id: "account_password", arguments: []),
                icon: "custom.key.square.fill",
                color: .systemCyan,
                viewController: ChangePasswordTableViewController.self,
                key: .accountPassword
            )
        ]

        if !accountColorLocked {
            primaryRows.append(
                SettingsViewController.Datasource(
                    section: .profile,
                    title: "Account color",
                    icon: "custom.paintpalette.square.fill",
                    color: .systemIndigo,
                    key: .accountColor
                )
            )
        }

        return [
            SettingsViewController.Datasource(
                section: .profile,
                childs: primaryRows
            ),
            SettingsViewController.Datasource(
                section: .blockList,
                childs: [
                    SettingsViewController.Datasource(
                        section: .blockList,
                        title: "Block list".localizeString(id: "block_list", arguments: []),
                        icon: "custom.nosign.square.fill",
                        color: .systemTeal,
                        key: .accountBlockedContacts
                    )
                ]
            ),
            SettingsViewController.Datasource(
                section: .circles,
                childs: [
                    SettingsViewController.Datasource(
                        section: .circles,
                        title: "Circles".localizeString(
                            id: "settings_account__section_header_circles",
                            arguments: []
                        ),
                        icon: "custom.person.2.square.fill",
                        color: .systemGreen,
                        viewController: AccountCirclesViewController.self,
                        key: .accountCircles
                    )
                ]
            ),
            SettingsViewController.Datasource(
                section: .delete,
                subtitle: SettingsViewController.Datasource.Section.delete.secondaryDescription(),
                childs: [
                    SettingsViewController.Datasource(
                        section: .delete,
                        title: SettingsViewController.Datasource.Section.delete.description(),
                        key: .accountDelete
                    )
                ]
            )
        ]
    }
}

enum SettingsModalPresentationPolicy {
    static func presenter(for settingsController: UIViewController) -> UIViewController {
        settingsController.navigationController ?? settingsController
    }
}

final class SafetyReportingViewController: SimpleBaseViewController {
    private let textView: UITextView = {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.accessibilityIdentifier = "settings.safety_reporting"
        return textView
    }()

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(textView)
        textView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Safety and Reporting".localizeString(id: "settings_safety_reporting_title", arguments: [])
        let support = ModerationReportConfiguration.supportEmail
        textView.text = "To report objectionable content, abusive users, or safety concerns, use the Report action in chats, profiles, or room screens. You can also contact us at %@."
            .localizeString(id: "settings_safety_reporting_body", arguments: [support])
    }
}

class SettingsViewController: BaseViewController {

    class Datasource {
        enum Keys: String {
            case xabberAccount = "xabberAccount"
            case premium = "premium"
            case accountStatus = "account_status"
            case accountVcard = "account_vcard"
            case accountPassword = "account_password"
            case accountColor = "account_color"
            case accountBlockedContacts = "account_blocked_contacts"
            case accountCircles = "account_circles"
            case accountDelete = "account_delete"
            case accountSessions = "account_sessions"
            case accountQuota = "account_quota"
            case accountEncryption = "account_encryption"
            case subscriptions = "subscriptions"
            case manageStorage = "manage_storage"
            case chatChooseBackgroundColor = "chat_chooseBackgroundColor"
            case chatChooseBackground = "chat_chooseBackground"
            case chatChooseMessageSound = "chat_choose_message_sound"
            case chatChooseSubscriptionSound = "chat_choose_subscription_sound"
            case developer = "developer"
            case languages = "languages"
            case turnPasscodeOff = "turn_passcode_off"
            case changePasscode = "change_passcode"
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
            case avatarChatPosition = "avatar_chat_vertical_position"
            case messageCornerStyle = "message_corner_style"
            case messageCornerRadius = "message_corner_radius"
            case eula = "eula"
            case safetyReporting = "safety_reporting"
            case afterburnTimer = "afterburn_timer"
            case afterburnEnabled = "burn_messages_enabled"
//            case privacy
        }

        enum Section: Int {
            case xAccount = 0
            case premium
            case premiumFeatures
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
            case blockList
            case circles
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
                case .premium:
                    return ""
                case .premiumFeatures:
                    return "Premium Features"
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
                    return ""
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
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 62, right: 8)
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

    class SettingsValueCell: UITableViewCell {
        static let cellName: String = "SettingsViewControllerValueCell"

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            detailTextLabel?.textColor = .secondaryLabel
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            textLabel?.textColor = .label
            detailTextLabel?.text = nil
            detailTextLabel?.textColor = .secondaryLabel
            accessoryType = .none
            imageView?.image = nil
        }
    }

    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)

        view.register(AccountCell.self, forCellReuseIdentifier: AccountCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "AddAccountCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsItem")
        view.register(DeviceCell.self, forCellReuseIdentifier: DeviceCell.cellName)
        view.register(SettingsItemDetailViewController.SelectorCell.self, forCellReuseIdentifier: SettingsItemDetailViewController.SelectorCell.cellName)

        view.register(SettingsValueCell.self, forCellReuseIdentifier: SettingsValueCell.cellName)
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

    var activeVerificationSessionSid: String? = nil

    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        view.bottomPadding = 16

        return view
    }()

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
    var cloudStorageQuotaDisplayState: SettingsCloudStorageQuotaDisplayState = SettingsCloudStorageQuotaDisplayState
        .resolve(
            hasCachedQuota: false,
            quotaBytes: 0,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: true
        )
    private var cloudStorageHasCachedQuota: Bool = false
    private var cloudStorageQuotaBytes: Int = 0
    private var isCloudStorageQuotaRefreshing: Bool = false
    private var cloudStorageQuotaRefreshFailed: Bool = false
    private var cloudStorageQuotaAvailable: Bool = true

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
            updateCloudStorageQuota(
                from: realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: self.jid),
                reloadRow: false
            )
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

            Observable
                .collection(from: realm.objects(AccountQuotaStorageItem.self).filter("jid == %@", self.jid))
                .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { results in
                    self.updateCloudStorageQuota(from: results.first, reloadRow: true)
                }).disposed(by: bag)
        } catch {
            DDLogDebug("SettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }


    internal func unsubscribe() {
        bag = DisposeBag()
    }

    private func updateCloudStorageQuota(from item: AccountQuotaStorageItem?, reloadRow: Bool) {
        if let item = item,
           AccountGalleryConfiguration(owner: jid).cachedQuotaMatchesCurrentGallery() {
            cloudStorageHasCachedQuota = true
            cloudStorageQuotaBytes = item.quotaBytes
            used = item.total
            quota = item.quotaBytes < 0 ? "Unlimited" : item.quota
        } else {
            cloudStorageHasCachedQuota = false
            cloudStorageQuotaBytes = 0
            used = ""
            quota = ""
        }
        updateCloudStorageQuotaDetailText()
        if reloadRow {
            reloadCloudStorageRow()
        }
    }

    private func updateCloudStorageQuotaDetailText() {
        cloudStorageQuotaDisplayState = SettingsCloudStorageQuotaDisplayState
            .resolve(
                hasCachedQuota: cloudStorageHasCachedQuota,
                quotaBytes: cloudStorageQuotaBytes,
                isRefreshing: isCloudStorageQuotaRefreshing,
                lastRefreshFailed: cloudStorageQuotaRefreshFailed,
                isAvailable: cloudStorageQuotaAvailable,
                galleryType: AccountGalleryConfiguration(owner: jid).currentGalleryType
            )
    }

    private func refreshCloudStorageQuotaForCurrentAccount() {
        guard jid.isNotEmpty else { return }
        guard AccountManager.shared.find(for: jid) != nil else {
            isCloudStorageQuotaRefreshing = false
            cloudStorageQuotaRefreshFailed = true
            cloudStorageQuotaAvailable = false
            updateCloudStorageQuotaDetailText()
            reloadCloudStorageRow()
            return
        }

        isCloudStorageQuotaRefreshing = true
        cloudStorageQuotaRefreshFailed = false
        cloudStorageQuotaAvailable = true
        updateCloudStorageQuotaDetailText()
        reloadCloudStorageRow()

        CloudStorageQuotaRefreshCoordinator.shared.refresh(owner: jid, reason: .screenOpen) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCloudStorageQuotaRefreshing = false
                self.cloudStorageQuotaRefreshFailed = result == .failure || result == .unauthorized
                self.cloudStorageQuotaAvailable = result != .unavailable
                self.updateCloudStorageQuotaDetailText()
                self.reloadCloudStorageRow()
            }
        }
    }

    private func reloadCloudStorageRow() {
        guard let indexPath = cloudStorageIndexPath() else {
            tableView.reloadData()
            return
        }

        if tableView.indexPathsForVisibleRows?.contains(indexPath) == true {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }

    private func cloudStorageIndexPath() -> IndexPath? {
        for (section, datasource) in datasource.enumerated() {
            if let row = datasource.childs.firstIndex(where: { $0.key == .manageStorage }) {
                return IndexPath(row: row, section: section)
            }
        }
        return nil
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == self.jid else { return }
        do {
            let realm = try WRealm.safe()
            updateCloudStorageQuota(
                from: realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: self.jid),
                reloadRow: true
            )
        } catch {
            updateCloudStorageQuota(from: nil, reloadRow: true)
        }
    }

    func navigationBarButtonsConfigure(multiAccounts: Bool) {
//        barButtonItemAddAccount = (CommonConfigManager.shared.config.supports_multiaccounts && !multiAccounts) ?
//        UIBarButtonItem(image: imageLiteral( "contact-add")?.withRenderingMode(.alwaysTemplate),
//                        style: .plain,
//                        target: self,
//                        action: #selector(addAccount)) : nil
//        if (CommonConfigManager.shared.config.supports_multiaccounts && !multiAccounts) {
////            navigationItem.leftItemsSupplementBackButton = true
////            navigationItem.setLeftBarButton(barButtonItemAddAccount, animated: true)
////            navigationItem.setLeftBarButtonItems([barButtonItemAddAccount].compactMap { $0 } , animated: false)
//        }
//
//
        let buttons = SettingsNavigationBarPolicy
            .rightActions(
                multiAccounts: multiAccounts,
                isEditing: tableView.isEditing,
                lockedAccountColor: CommonConfigManager.shared.config.locked_account_color
            )
            .map { makeSettingsRightBarButton(for: $0) }

        if buttons.count == 1 {
            navigationItem.setRightBarButton(buttons.first, animated: false)
        } else {
            navigationItem.setRightBarButtonItems(buttons, animated: false)
        }
    }

    private func makeSettingsRightBarButton(for action: SettingsNavigationBarRightAction) -> UIBarButtonItem {
        switch action {
        case .edit:
            ensureSettingsEditButtons()
            return editButton!
        case .done:
            ensureSettingsEditButtons()
            return doneEditButton!
        case .qrCode:
            return UIBarButtonItem(
                image: imageLiteral( "qrcode"),
                style: SettingsNavigationBarPolicy.barButtonStyle(for: action),
                target: self,
                action: #selector(self.onQRCode)
            )
        }
    }

    private func ensureSettingsEditButtons() {
        if editButton == nil {
            editButton = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(onEdit))
        }
        if doneEditButton == nil {
            doneEditButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(onDoneEditing))
        }
    }

    private func configureSettingsLeadingNavigationItem(animated: Bool) {
        let exitAction = NavigationExitPolicy.action(
            for: NavigationExitPolicyContext(destination: self, route: .currentNavigationPush)
        )
        switch SettingsNavigationBarPolicy.leadingAction(exitAction: exitAction) {
        case .dismissModal:
            let button = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(dismissScreen)
            )
            button.accessibilityIdentifier = "settings_dismiss_button"
            navigationItem.setLeftBarButton(button, animated: animated)
        case .none:
            navigationItem.setLeftBarButton(nil, animated: animated)
        }
    }

    var multiAccounts: Bool = false

    internal func load() {
        datasource = []
        activeVerificationSessionSid = nil
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup())
            else { fatalError() }
        let dict = userDefaults.dictionaryRepresentation()

        guard let accounts = self.accounts,
              let item = accounts.first else { return }
        self.nickname = item.username
        self.jid = item.jid

        if accounts.count > 1 {
            multiAccounts = true
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
//            headerViewConfig(multiAccounts: false)

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
                    if CommonConfigManager.shared.config.support_xabber_account {
                        self.headerView.setupXabberAccountButton()
                    }
                }

                if let sessionInstance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.owner).first {
                    self.activeVerificationSessionSid = sessionInstance.sid
                    let (text, secondaryText) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(withOwnDevice: true, verificationState: sessionInstance.state)
                    let verificationDatasource = Datasource(section: .session, childs: [Datasource(section: .session, title: text, subtitle: secondaryText)])

                    datasource.append(verificationDatasource)
                }
            } catch {
                DDLogDebug("SettingsViewController:\(#function). \(error.localizedDescription)")
            }

            let profileSections = SettingsAccountProfileMenuFactory.makeSections(
                accountColorLocked: CommonConfigManager.shared.config.locked_account_color.isNotEmpty
            )
            if CommonConfigManager.shared.config.should_block_application_when_subscribtion_end {
                datasource.append(Datasource(section: .accountSettings, childs: [
                    Datasource(section: .accountSettings, title: "Profile, status, password", icon: "custom.person.square.fill", color: UIColor.systemBlue, viewController: SimpleTableViewController.self, childs: profileSections),
                    Datasource(section: .accountSettings, title: "Devices", icon: "custom.desktopcomputer.square.fill", color: UIColor.systemBlue, key: .accountSessions),
//                    Datasource(section: .accountSettings, title: "Subscriptions", icon: "xabber.lightbulb.square.fill", color: UIColor.systemBlue, key: .subscriptions)
                ]))
            } else {
                datasource.append(Datasource(section: .accountSettings, childs: [
                    Datasource(section: .accountSettings, title: "Profile, status, password", icon: "custom.person.square.fill", color: UIColor.systemBlue, viewController: SimpleTableViewController.self, childs: profileSections),
                    Datasource(section: .accountSettings, title: "Devices", icon: "custom.desktopcomputer.square.fill", color: UIColor.systemBlue, key: .accountSessions),
//                    Datasource(section: .accountSettings, title: "Subscriptions", icon: "xabber.lightbulb.square.fill", color: UIColor.systemBlue, key: .subscriptions)
                ]))
            }

            if AccountManager.shared.find(for: self.jid)?.cloudStorage.isAvailable() ?? false {
                let item = Datasource(
                    section: .accountSettings,
                    title: "Cloud storage",
                    icon: SettingsCloudStorageQuotaDisplayState.basicIconName,
                    color: UIColor.systemBlue,
                    key: .manageStorage
                )
                let sectionToInsert = datasource.firstIndex(where: { $0.section == .accountSettings })
                datasource[sectionToInsert!].childs.insert(item, at: 1)
            }
        }

        datasource.append(Datasource(section: .settings, title: Datasource.Section.settings.description(), childs: [
            Datasource(
                section: .privacy,
                title: Datasource.Section.privacy.description(),
                subtitle: nil,
                icon:"xabber.incognito.fill.square.fill",
                color: UIColor.systemGreen,
                premiumOnly: false,
                viewController: PrivacySettingsViewController.self,
                childs: []
              ),
            Datasource(section: .interface, title: "Interface", icon: "custom.paintpalette.square.fill", color: UIColor.systemGreen, viewController: InterfaceSettingsViewController.self),
            Datasource(
                section: .settings,
                title: "Notifications",
                icon: "custom.bell.square.fill",
                color: UIColor.systemGreen,
                viewController: NotificationsSettingsViewController.self
            ),
            Datasource(section: .settings, title: "Debug", icon:"custom.ant.square.fill", color: UIColor.systemGreen, key: .developer),
            
            Datasource(section: .settings, title: "Language", icon:"xabber.translate.square.fill", color: UIColor.systemPurple, key: .languages)
            ]))

        var premiumFeatures: [Datasource] = []
        if CommonConfigManager.shared.config.support_xabber_account || CommonConfigManager.shared.config.support_subscribtions {
            premiumFeatures.append(
                Datasource(section: .accountSettings, title: "Premium", icon: "star.square.fill", color: MDCPalette.deepPurple.tint500, key: .premium)
            )
        }
        if PasscodeLockPolicy.shouldShowSettingsEntry {
            premiumFeatures.append(
                Datasource(section: .premiumFeatures, title: "Passcode Lock", icon:"custom.hand.raised.square.fill", color: UIColor.systemOrange, premiumOnly: true, viewController: SimpleTableViewController.self, childs: [
                    Datasource(section: .security, subtitle: "Protect the app with a passcode. If you forget it, you will need to reinstall the app.", childs: [
                        Datasource(section: .security, title: "Change Passcode", key: .changePasscode),
                        Datasource(section: .security, title: "Biometrics", key: .turnBiometricsOnOff),
                        Datasource(section: .security, title: "Turn Passcode Off", key: .turnPasscodeOff)
                    ]),
                    Datasource(section: .autolock, childs: [
                        Datasource(section: .autolock, title: "Auto-Lock", key: .passcodeTimer),
                        Datasource(section: .autolock, title: "Attempts", key: .passcodeAttempts),
                        Datasource(section: .autolock, title: "Show attempts left", itemType: .toggle, toggle: (dict[Datasource.Keys.showAttempts.rawValue] as? Bool) ?? false, key: .showAttempts)
                    ])
                ], key: .passcode)
            )
        }
        if premiumFeatures.isNotEmpty {
            datasource.append(Datasource(section: .premiumFeatures, title: Datasource.Section.premiumFeatures.description(), childs: premiumFeatures))
        }
        if CommonConfigManager.shared.config.use_yubikey {
            datasource.append(Datasource(section: .security, title: Datasource.Section.security.description(), subtitle: Datasource.Section.security.secondaryDescription(), childs: [
                    Datasource(section: .security, title: "Yubikey signature", icon: "custom.key.square.fill", color: UIColor.systemOrange, viewController: YubikeySetupViewController.self, key: .yubikey),
                ]))
        }
        datasource.append(Datasource(section: .premiumFeatures, title: "", childs: [
            Datasource(
                section: .settings,
                title: "End User License Agreement".localizeString(id: "eula_settings_title", arguments: []),
                icon:"custom.text.document.square.fill",
                color: UIColor.systemGreen,
                key: .eula
            ),
            Datasource(
                section: .settings,
                title: "Safety and Reporting".localizeString(id: "settings_safety_reporting_title", arguments: []),
                icon:"exclamationmark.bubble.fill",
                color: UIColor.systemRed,
                key: .safetyReporting
            )
        ]))
        
    }

    internal func configure() {
//        self.navigationItem.backButtonTitle = "Settings".localizeString(id: "settings", arguments: [])
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

//        editButton = UIBarButtonItem(title: "Edit", style: .plain, /*barButtonSystemItem: .edit,*/ target: self, action: #selector(self.onEdit))
//        doneEditButton = UIBarButtonItem(title: "Done", style: .plain, /*barButtonSystemItem: .done,*/ target: self, action: #selector(self.onDoneEditing))
//        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
//        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cloudStorageGalleryDidChange(_:)),
                                               name: .cloudStorageGalleryDidChange,
                                               object: nil)
        AccountManager.shared.find(for: self.jid)?.action { user, stream in
            if CredentialsManager.getXabberAccountUUID(for: self.jid) == nil {
                XabberAccountManager.shared.registerAccount(stream, callback: nil)
            }
        }

    }

    @objc
    func onAcceptButtonPressed() {
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            DispatchQueue.main.async {
                _ = user.akeManager.acceptVerificationRequest(jid: self.jid, sid: self.activeVerificationSessionSid ?? "")

                NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showCodeOutputViewNotification,
                                                object: self,
                                                userInfo: [
                                                    "owner": self.owner,
                                                    "sid": self.activeVerificationSessionSid ?? ""
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
                                            "sid": activeVerificationSessionSid ?? ""
                                        ])
    }

    @objc
    func onEnterCodePressed() {
        NotificationCenter.default.post(
            name: AuthenticatedKeyExchangeManager.showCodeInputViewNotification,
            object: self,
            userInfo: ["owner": self.jid, "sid": activeVerificationSessionSid ?? ""]
        )
    }

    @objc
    func onCloseVerificationButtonPressed() {
        guard let jid = XMPPJID(string: self.owner),
              let sid = activeVerificationSessionSid else {
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

            activeVerificationSessionSid = nil

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
        if self.multiAccounts {
            return
        }
        headerView.showButtons = false

        self.headerView.delegate = self
        headerView.applyHeaderLayout(to: tableView, width: view.bounds.width)
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
        title = nil

        NotifyManager.shared.setLastChats(displayed: false)
        headerViewConfig()
        subscribe()
        refreshCloudStorageQuotaForCurrentAccount()
        configureSettingsLeadingNavigationItem(animated: false)

        if self.shouldShowTabBar {
            self.tabBarController?.tabBar.isHidden = false
            self.tabBarController?.tabBar.layoutIfNeeded()
        }
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }

}
