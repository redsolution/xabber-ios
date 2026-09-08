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
        case messages
        case inApp
        case system

        var title: String? {
            switch self {
            case .messages: return "Message Notifications"
            case .inApp: return "In-App Notifications"
            case .system: return "System Notifications"
            }
        }

        var footer: String? {
            switch self {
            case .messages:
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
        case subscriptionRequests
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
        case .messages:
            return [.messages, .subscriptionRequests]
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
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsDisclosureCell
            cell.configure(
                title: "Messages",
                subtitle: "Sound: \(soundTitle(for: .chatChooseMessageSound))",
                icon: "bubble.left.and.bubble.right.fill",
                iconColor: .systemBlue,
                accessibilityIdentifier: "notifications.messages"
            )
            return cell
        case .subscriptionRequests:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NotificationsSettingsDisclosureCell.reuseIdentifier,
                for: indexPath
            ) as! NotificationsSettingsDisclosureCell
            cell.configure(
                title: "Subscription Requests",
                subtitle: "Sound: \(soundTitle(for: .chatChooseSubscriptionSound))",
                icon: "person.badge.plus.fill",
                iconColor: .systemGreen,
                accessibilityIdentifier: "notifications.subscriptionRequests"
            )
            return cell
        case .inAppSounds:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "In-App Sounds",
                key: .notificationInAppSound,
                defaultValue: true,
                accessibilityIdentifier: "notifications.inAppSounds"
            )
        case .bannersOnChats:
            return makeToggleCell(
                tableView: tableView,
                indexPath: indexPath,
                title: "Show Banners in Chats",
                key: .notificationInAppAlertLastChats,
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
        key: SettingsViewController.Datasource.Keys,
        defaultValue: Bool,
        accessibilityIdentifier: String
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationsSettingsToggleCell.reuseIdentifier,
            for: indexPath
        ) as! NotificationsSettingsToggleCell
        cell.configure(
            title: title,
            isOn: store.bool(for: key.rawValue, default: defaultValue),
            accessibilityIdentifier: accessibilityIdentifier
        ) { [weak self] value in
            self?.store.setBool(value, for: key.rawValue)
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
        case .messages:
            showSoundSelector(title: "Messages", key: .chatChooseMessageSound)
        case .subscriptionRequests:
            showSoundSelector(title: "Subscription Requests", key: .chatChooseSubscriptionSound)
        case .systemSettings:
            openSystemNotificationSettings()
        case .inAppSounds, .bannersOnChats:
            break
        }
    }
}

private final class NotificationsSettingsDisclosureCell: UITableViewCell {
    static let reuseIdentifier = "NotificationsSettingsDisclosureCell"

    private let iconBackground = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.layer.cornerRadius = 11
        iconBackground.layer.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        contentView.addSubview(iconBackground)
        iconBackground.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(chevron)
        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 42),
            iconBackground.heightAnchor.constraint(equalTo: iconBackground.widthAnchor),
            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 23),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -13),
            chevron.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        subtitle: String?,
        icon: String,
        iconColor: UIColor,
        accessibilityIdentifier: String
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        iconBackground.backgroundColor = iconColor
        iconView.image = UIImage(systemName: icon)
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
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
