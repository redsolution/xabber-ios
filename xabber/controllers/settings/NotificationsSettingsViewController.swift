import UIKit

protocol NotificationsSettingsStoring: AnyObject {
    func bool(for key: String, default defaultValue: Bool) -> Bool
    func setBool(_ value: Bool, for key: String)
}

private final class SettingManagerNotificationsSettingsStore: NotificationsSettingsStoring {
    func bool(for key: String, default defaultValue: Bool) -> Bool {
        guard let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
              defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return SettingManager.shared.get(bool: key)
    }

    func setBool(_ value: Bool, for key: String) {
        SettingManager.shared.saveItem(key: key, bool: value)
    }
}

final class NotificationsSettingsViewController: BaseViewController {
    private enum Section: Int, CaseIterable {
        case types
        case inApp
        case payloadMode
        case system

        var title: String? {
            switch self {
            case .types: return L10n.text("notifications_settings__sounds__title", fallback: "Notification Sounds")
            case .inApp: return L10n.text("notifications_settings__in_app__title", fallback: "In-App Notifications")
            case .payloadMode: return L10n.text("notifications_settings__payload_mode__title", fallback: "Push Content")
            case .system: return nil
            }
        }

        var footer: String? {
            switch self {
            case .types:
                return L10n.text("notifications_settings__sounds__footer", fallback: "Turn sounds on or off independently for each notification type.")
            case .inApp:
                return L10n.format(
                    "notifications_settings__in_app__footer",
                    fallback: "Show banners and play enabled notification sounds while %1$@ is open.",
                    arguments: [CommonConfigManager.shared.config.app_name]
                )
            case .payloadMode:
                return L10n.text("notifications_settings__payload_mode__footer", fallback: "Choose preferred push content. Full can include the message; partial loads it when needed.")
            case .system:
                return L10n.text("notifications_settings__system__footer", fallback: "Lock Screen previews, permissions, badges and notification delivery are controlled in iOS Settings.")
            }
        }
    }

    private enum Row {
        case messages
        case invites
        case subscriptionRequests
        case inAppSounds
        case bannersOnChats
        case fullPayload
        case partialPayload
        case systemSettings
    }

    private let store: NotificationsSettingsStoring
    private let payloadModeProvider: () -> PushPayloadMode
    private let payloadModeSetter: (PushPayloadMode) -> Void
    internal let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(
        store: NotificationsSettingsStoring,
        payloadModeProvider: @escaping () -> PushPayloadMode = { PushPayloadPreferences.current },
        payloadModeSetter: @escaping (PushPayloadMode) -> Void = { PushPayloadPreferences.set($0) }
    ) {
        self.store = store
        self.payloadModeProvider = payloadModeProvider
        self.payloadModeSetter = payloadModeSetter
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        store = SettingManagerNotificationsSettingsStore()
        payloadModeProvider = { PushPayloadPreferences.current }
        payloadModeSetter = { PushPayloadPreferences.set($0) }
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        store = SettingManagerNotificationsSettingsStore()
        payloadModeProvider = { PushPayloadPreferences.current }
        payloadModeSetter = { PushPayloadPreferences.set($0) }
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("notifications__screen__title", fallback: "Notifications")
        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityIdentifier = "notifications.settings.table"
        tableView.register(
            NotificationsSettingsIconToggleCell.self,
            forCellReuseIdentifier: NotificationsSettingsIconToggleCell.reuseIdentifier
        )
        tableView.register(
            NotificationsSettingsActionCell.self,
            forCellReuseIdentifier: NotificationsSettingsActionCell.reuseIdentifier
        )
        tableView.register(
            NotificationsSettingsToggleCell.self,
            forCellReuseIdentifier: NotificationsSettingsToggleCell.reuseIdentifier
        )
        tableView.register(
            NotificationsSettingsChoiceCell.self,
            forCellReuseIdentifier: NotificationsSettingsChoiceCell.reuseIdentifier
        )
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 18
        }
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private func rows(for section: Section) -> [Row] {
        switch section {
        case .types:
            return [.messages, .invites, .subscriptionRequests]
        case .inApp:
            return [.inAppSounds, .bannersOnChats]
        case .payloadMode:
            return [.fullPayload, .partialPayload]
        case .system:
            return [.systemSettings]
        }
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

extension NotificationsSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        return rows(for: section).count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }
        let sectionRows = rows(for: section)
        guard sectionRows.indices.contains(indexPath.row) else { return UITableViewCell() }
        let row = sectionRows[indexPath.row]
        switch row {
        case .messages:
            return makeNotificationTypeCell(
                tableView: tableView,
                indexPath: indexPath,
                title: L10n.text("notification_settings__title__messages", fallback: "Messages"),
                icon: "custom.bubble.square.fill",
                iconColor: .systemBlue,
                preference: .messages,
                accessibilityIdentifier: "notifications.messages"
            )
        case .invites:
            return makeNotificationTypeCell(
                tableView: tableView,
                indexPath: indexPath,
                title: L10n.text("notification_settings__title__invites", fallback: "Invites"),
                icon: "xabber.invite.square.fill",
                iconColor: .systemOrange,
                preference: .invites,
                accessibilityIdentifier: "notifications.invites"
            )
        case .subscriptionRequests:
            return makeNotificationTypeCell(
                tableView: tableView,
                indexPath: indexPath,
                title: L10n.text("notification_settings__title__subscription_requests", fallback: "Subscription Requests"),
                icon: "xabber.person.plus.square.fill",
                iconColor: .systemGreen,
                preference: .subscriptionRequests,
                accessibilityIdentifier: "notifications.subscriptionRequests"
            )
        case .inAppSounds:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: L10n.text("notification_settings__title__in_app_sounds", fallback: "In-App Sounds"),
                key: SettingsViewController.Datasource.Keys.notificationInAppSound.rawValue,
                defaultValue: true,
                accessibilityIdentifier: "notifications.inAppSounds"
            )
        case .bannersOnChats:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: L10n.text("notification_settings__title__show_banners_in_chats", fallback: "Show Banners in Chats"),
                key: SettingsViewController.Datasource.Keys.notificationInAppAlertLastChats.rawValue,
                defaultValue: false,
                accessibilityIdentifier: "notifications.bannersOnChats"
            )
        case .fullPayload:
            return makePayloadModeCell(
                tableView: tableView,
                indexPath: indexPath,
                mode: .full,
                title: L10n.text("notifications_settings__payload_mode__full", fallback: "Full"),
                accessibilityIdentifier: "notifications.payloadMode.full"
            )
        case .partialPayload:
            return makePayloadModeCell(
                tableView: tableView,
                indexPath: indexPath,
                mode: .summary,
                title: L10n.text("notifications_settings__payload_mode__partial", fallback: "Partial"),
                accessibilityIdentifier: "notifications.payloadMode.partial"
            )
        case .systemSettings:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsActionCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsActionCell
            cell.configure(
                title: L10n.text("notification_settings__title__open_ios_notification_settings", fallback: "Open iOS Notification Settings"),
                accessibilityIdentifier: "notifications.systemSettings"
            )
            return cell
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer
    }

    private func makeToggleCell(
        tableView: UITableView,
        indexPath: IndexPath,
        title: String,
        key: String,
        defaultValue: Bool,
        accessibilityIdentifier: String
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationsSettingsToggleCell.reuseIdentifier,
            for: indexPath
        ) as! NotificationsSettingsToggleCell
        cell.configure(
            title: title,
            isOn: store.bool(for: key, default: defaultValue),
            accessibilityIdentifier: accessibilityIdentifier
        ) { [weak self] value in
            self?.store.setBool(value, for: key)
        }
        return cell
    }

    private func makePayloadModeCell(
        tableView: UITableView,
        indexPath: IndexPath,
        mode: PushPayloadMode,
        title: String,
        accessibilityIdentifier: String
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationsSettingsChoiceCell.reuseIdentifier,
            for: indexPath
        ) as! NotificationsSettingsChoiceCell
        cell.configure(
            title: title,
            isSelected: payloadModeProvider() == mode,
            accessibilityIdentifier: accessibilityIdentifier
        )
        return cell
    }

    private func makeNotificationTypeCell(
        tableView: UITableView,
        indexPath: IndexPath,
        title: String,
        icon: String,
        iconColor: UIColor,
        preference: NotificationSoundPreference,
        accessibilityIdentifier: String
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationsSettingsIconToggleCell.reuseIdentifier,
            for: indexPath
        ) as! NotificationsSettingsIconToggleCell
        cell.configure(
            title: title,
            icon: icon,
            iconColor: iconColor,
            isOn: store.bool(for: preference.rawValue, default: true),
            accessibilityIdentifier: accessibilityIdentifier
        ) { [weak self] value in
            self?.store.setBool(value, for: preference.rawValue)
        }
        return cell
    }
}

extension NotificationsSettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }
        let sectionRows = rows(for: section)
        guard sectionRows.indices.contains(indexPath.row) else { return }
        let row = sectionRows[indexPath.row]
        switch row {
        case .systemSettings:
            openSystemNotificationSettings()
        case .fullPayload, .partialPayload:
            let mode: PushPayloadMode = row == .fullPayload ? .full : .summary
            guard payloadModeProvider() != mode else { return }
            payloadModeSetter(mode)
            tableView.reloadSections(IndexSet(integer: Section.payloadMode.rawValue), with: .none)
        case .messages, .invites, .subscriptionRequests, .inAppSounds, .bannersOnChats:
            break
        }
    }
}

private final class NotificationsSettingsChoiceCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsChoiceCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        textLabel?.font = .preferredFont(forTextStyle: .body)
        textLabel?.adjustsFontForContentSizeCategory = true
        textLabel?.numberOfLines = 0
        textLabel?.isAccessibilityElement = false
        isAccessibilityElement = true
        selectionStyle = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, isSelected: Bool, accessibilityIdentifier: String) {
        textLabel?.text = title
        textLabel?.textColor = .label
        accessoryType = isSelected ? .checkmark : .none
        accessoryView = nil
        imageView?.image = nil
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityLabel = title
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
}

private final class NotificationsSettingsActionCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsActionCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        textLabel?.font = .preferredFont(forTextStyle: .body)
        textLabel?.adjustsFontForContentSizeCategory = true
        textLabel?.textAlignment = .left
        accessoryType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        accessibilityIdentifier: String
    ) {
        textLabel?.text = title
        textLabel?.textColor = tintColor
        imageView?.image = nil
        accessoryType = .none
        accessoryView = nil
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityLabel = title
        accessibilityTraits = .button
    }
}

private final class NotificationsSettingsIconToggleCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsIconToggleCell"
    // A custom switch accessory skips the standard disclosure cell's icon
    // expansion. Apply the same effective scale so the visible tile matches
    // SettingsViewController instead of falling back to its intrinsic bounds.
    private static let accessorySymbolScale: CGFloat = 1.275

    private let toggle = UISwitch()
    private var onValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textLabel?.font = .preferredFont(forTextStyle: .body)
        textLabel?.adjustsFontForContentSizeCategory = true
        imageView?.isAccessibilityElement = false
        textLabel?.isAccessibilityElement = false
        isAccessibilityElement = false
        toggle.isAccessibilityElement = true
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        accessoryView = toggle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView?.image = nil
        textLabel?.text = nil
        toggle.isOn = true
        onValueChanged = nil
        accessibilityIdentifier = nil
    }

    func configure(
        title: String,
        icon: String,
        iconColor: UIColor,
        isOn: Bool,
        accessibilityIdentifier: String,
        onValueChanged: @escaping (Bool) -> Void
    ) {
        textLabel?.text = title
        imageView?.image = imageLiteral(
            icon,
            dimension: SettingsMenuIconMetrics.dimension * Self.accessorySymbolScale
        )
        tintColor = iconColor
        imageView?.accessibilityIdentifier = accessibilityIdentifier + ".icon"
        toggle.isOn = isOn
        toggle.accessibilityLabel = L10n.format("notifications_settings__accessibility_label__value_notification_sound", fallback: "%@ Notification Sound", arguments: [String(describing: title)])
        toggle.accessibilityIdentifier = accessibilityIdentifier + ".switch"
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onValueChanged = onValueChanged
    }

    @objc private func valueChanged() {
        onValueChanged?(toggle.isOn)
    }
}

private final class NotificationsSettingsToggleCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsToggleCell"

    private let titleLabel = UILabel()
    private let toggle = UISwitch()
    private var onValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        contentView.addSubview(titleLabel)
        contentView.addSubview(toggle)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            toggle.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        isOn: Bool,
        accessibilityIdentifier: String,
        onValueChanged: @escaping (Bool) -> Void
    ) {
        titleLabel.text = title
        toggle.isOn = isOn
        toggle.accessibilityLabel = title
        toggle.accessibilityIdentifier = accessibilityIdentifier + ".switch"
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onValueChanged = onValueChanged
    }

    @objc private func valueChanged() {
        onValueChanged?(toggle.isOn)
    }
}
