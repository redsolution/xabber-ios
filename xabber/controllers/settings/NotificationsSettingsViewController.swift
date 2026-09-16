import UIKit

protocol NotificationsSettingsStoring: AnyObject {
    func bool(for key: String, default defaultValue: Bool) -> Bool
    func setBool(_ value: Bool, for key: String)
    func string(for key: String) -> String?
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

    func string(for key: String) -> String? {
        SettingManager.shared.getString(for: key)
    }
}

final class NotificationsSettingsViewController: BaseViewController {
    private enum Section: Int, CaseIterable {
        case types
        case sounds
        case inApp
        case system

        var title: String? {
            switch self {
            case .types: return "Notification Types"
            case .sounds: return "Sounds"
            case .inApp: return "In-App Notifications"
            case .system: return "System Notifications"
            }
        }

        var footer: String? {
            switch self {
            case .types:
                return "Turn alerts on or off independently for each notification type."
            case .sounds:
                return "Choose a sound for incoming messages and subscription requests."
            case .inApp:
                return "Show banners and play sounds while Xabber is open."
            case .system:
                return "Lock Screen previews, permissions, badges and notification delivery are controlled in iOS Settings."
            }
        }
    }

    private enum Row {
        case messages
        case invites
        case subscriptionRequests
        case messageSound
        case subscriptionRequestSound
        case inAppSounds
        case bannersOnChats
        case systemSettings
    }

    private let store: NotificationsSettingsStoring
    internal let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(store: NotificationsSettingsStoring) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        store = SettingManagerNotificationsSettingsStore()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        store = SettingManagerNotificationsSettingsStore()
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
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
            NotificationsSettingsDisclosureCell.self,
            forCellReuseIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier
        )
        tableView.register(
            NotificationsSettingsToggleCell.self,
            forCellReuseIdentifier: NotificationsSettingsToggleCell.reuseIdentifier
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
        case .sounds:
            return [.messageSound, .subscriptionRequestSound]
        case .inApp:
            return [.inAppSounds, .bannersOnChats]
        case .system:
            return [.systemSettings]
        }
    }

    private func soundTitle(for key: SettingsViewController.Datasource.Keys) -> String {
        guard let filename = store.string(for: key.rawValue), filename.isNotEmpty else {
            return "Default"
        }
        return filename
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func showSoundSelector(
        title: String,
        key: SettingsViewController.Datasource.Keys
    ) {
        let datasource = SettingsViewController.Datasource(
            section: .chat,
            title: title,
            itemType: .selector,
            values: MusicBox.shared.fileURLs.lazy.map(\.absoluteString).sorted(),
            current: store.string(for: key.rawValue) ?? "",
            key: key
        )
        let controller = SelectorViewController()
        controller.configure(for: datasource)
        controller.title = title
        navigationController?.pushViewController(controller, animated: true)
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
                title: "Messages",
                icon: "custom.bubble.square.fill",
                iconColor: .systemBlue,
                preference: .messages,
                accessibilityIdentifier: "notifications.messages"
            )
        case .invites:
            return makeNotificationTypeCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "Invites",
                icon: "xabber.invite.square.fill",
                iconColor: .systemOrange,
                preference: .invites,
                accessibilityIdentifier: "notifications.invites"
            )
        case .subscriptionRequests:
            return makeNotificationTypeCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "Subscription Requests",
                icon: "xabber.person.plus.square.fill",
                iconColor: .systemGreen,
                preference: .subscriptionRequests,
                accessibilityIdentifier: "notifications.subscriptionRequests"
            )
        case .messageSound:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsDisclosureCell
            cell.configure(
                title: "Message Sound",
                subtitle: soundTitle(for: .chatChooseMessageSound),
                icon: nil,
                iconColor: .systemBlue,
                accessibilityIdentifier: "notifications.messageSound"
            )
            return cell
        case .subscriptionRequestSound:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsDisclosureCell
            cell.configure(
                title: "Subscription Request Sound",
                subtitle: soundTitle(for: .chatChooseSubscriptionSound),
                icon: nil,
                iconColor: .systemGreen,
                accessibilityIdentifier: "notifications.subscriptionRequestSound"
            )
            return cell
        case .inAppSounds:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "In-App Sounds",
                key: SettingsViewController.Datasource.Keys.notificationInAppSound.rawValue,
                defaultValue: true,
                accessibilityIdentifier: "notifications.inAppSounds"
            )
        case .bannersOnChats:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "Show Banners in Chats",
                key: SettingsViewController.Datasource.Keys.notificationInAppAlertLastChats.rawValue,
                defaultValue: false,
                accessibilityIdentifier: "notifications.bannersOnChats"
            )
        case .systemSettings:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsDisclosureCell
            cell.configure(
                title: "Open iOS Notification Settings",
                subtitle: nil,
                icon: "gearshape.fill",
                iconColor: .systemGray,
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

    private func makeNotificationTypeCell(
        tableView: UITableView,
        indexPath: IndexPath,
        title: String,
        icon: String,
        iconColor: UIColor,
        preference: NotificationAlertPreference,
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
        case .messageSound:
            showSoundSelector(title: "Messages", key: .chatChooseMessageSound)
        case .subscriptionRequestSound:
            showSoundSelector(title: "Subscription Requests", key: .chatChooseSubscriptionSound)
        case .systemSettings:
            openSystemNotificationSettings()
        case .messages, .invites, .subscriptionRequests, .inAppSounds, .bannersOnChats:
            break
        }
    }
}

private final class NotificationsSettingsDisclosureCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsDisclosureCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let labelsStack = UIStackView()
    private let contentStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit

        labelsStack.axis = .vertical
        labelsStack.alignment = .fill
        labelsStack.spacing = 2
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 14
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(labelsStack)
        contentStack.addArrangedSubview(chevron)
        contentView.addSubview(contentStack)

        let minimumHeight: CGFloat
        if #available(iOS 26.0, *) {
            minimumHeight = 52
        } else {
            minimumHeight = 44
        }
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
            iconView.widthAnchor.constraint(equalToConstant: SettingsMenuIconMetrics.dimension),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        subtitle: String?,
        icon: String?,
        iconColor: UIColor,
        accessibilityIdentifier: String
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        iconView.image = icon.flatMap {
            imageLiteral($0, dimension: SettingsMenuIconMetrics.dimension)
        }
        iconView.tintColor = iconColor
        iconView.isHidden = icon == nil
        iconView.accessibilityIdentifier = icon.map { _ in
            accessibilityIdentifier + ".icon"
        }
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }
}

private final class NotificationsSettingsIconToggleCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsIconToggleCell"

    private let toggle = UISwitch()
    private var onValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textLabel?.font = .preferredFont(forTextStyle: .body)
        textLabel?.adjustsFontForContentSizeCategory = true
        imageView?.contentMode = .scaleAspectFit
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
            dimension: SettingsMenuIconMetrics.dimension
        )
        imageView?.tintColor = iconColor
        imageView?.accessibilityIdentifier = accessibilityIdentifier + ".icon"
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
