//
//  InterfaceSettingsViewController.swift
//  xabber
//
//  Created by Codex on 04.09.2026.
//

import PhotosUI
import UIKit

final class InterfaceSettingsViewController: BaseViewController {
    private enum Section: Int, CaseIterable {
        case preview
        case theme
        case mode
        case layout
    }

    private enum Row: Hashable {
        case themes
        case wallpaper
        case accent
        case textSize
        case bubbles
        case avatars
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var appearanceCoordinator = AppearanceCoordinator.shared
    private var document = AppearanceCoordinator.shared.document

    convenience init(appearanceCoordinator: AppearanceCoordinator) {
        self.init()
        self.appearanceCoordinator = appearanceCoordinator
        document = appearanceCoordinator.document
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Interface"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.backButtonDisplayMode = .minimal
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AppearanceOverviewCell.self, forCellReuseIdentifier: AppearanceOverviewCell.reuseIdentifier)
        tableView.register(AppearanceModeSelectionCell.self, forCellReuseIdentifier: AppearanceModeSelectionCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AppearanceValueCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityIdentifier = "interface.settings.table"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: .appearanceDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(entitlementChanged),
            name: .premiumEntitlementDidChange,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        document = appearanceCoordinator.document
        tableView.reloadData()
    }

    @objc private func appearanceChanged() {
        document = appearanceCoordinator.document
        tableView.reloadData()
    }

    @objc private func entitlementChanged() {
        tableView.reloadData()
    }

    private var themeRows: [Row] {
        var rows: [Row] = [.themes]
        if CommonConfigManager.shared.config.locked_background.isEmpty {
            rows.append(.wallpaper)
        }
        rows.append(.accent)
        return rows
    }

    private func row(at indexPath: IndexPath) -> Row? {
        guard let section = Section(rawValue: indexPath.section) else { return nil }
        switch section {
        case .preview: return nil
        case .theme: return themeRows[indexPath.row]
        case .mode: return nil
        case .layout: return [.textSize, .bubbles, .avatars][indexPath.row]
        }
    }

    private func value(for row: Row) -> String? {
        let profile = document.profile
        switch row {
        case .themes:
            return AppearanceThemeCatalog.theme(id: profile.themeID, customThemes: document.customThemes).name
        case .wallpaper:
            switch profile.wallpaper {
            case .none: return "None"
            case .builtIn(let name): return name
            case .gradient: return "Custom Gradient"
            case .cloud: return "Photo"
            }
        case .accent: return nil
        case .textSize: return profile.textSize.displayName
        case .bubbles: return profile.bubbleStyle.displayName
        case .avatars: return "\(profile.avatarMask.displayName), \(profile.avatarPosition.displayName)"
        }
    }

    private func title(for row: Row) -> String {
        switch row {
        case .themes: return "Chat Themes"
        case .wallpaper: return "Chat Wallpaper"
        case .accent: return "Application Color"
        case .textSize: return "Text Size"
        case .bubbles: return "Message Bubbles"
        case .avatars: return "Avatars"
        }
    }

    private func accessibilityID(for row: Row) -> String {
        switch row {
        case .themes: return "interface.settings.chatThemes"
        case .wallpaper: return "interface.settings.wallpaper"
        case .accent: return "interface.settings.applicationColor"
        case .textSize: return "interface.settings.textSize"
        case .bubbles: return "interface.settings.bubbles"
        case .avatars: return "interface.settings.avatars"
        }
    }

    private func pushEditor(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    private func applyOverviewTheme(_ theme: AppearanceTheme) {
        var updated = appearanceCoordinator.document
        guard updated.profile.themeID != theme.id else {
            document = updated
            tableView.reloadData()
            return
        }
        updated.profile.apply(
            theme: theme,
            preserveWallpaper: CommonConfigManager.shared.config.locked_background.isNotEmpty
        )
        do {
            _ = try appearanceCoordinator.commit(updated)
            document = appearanceCoordinator.document
            tableView.reloadData()
        } catch {
            let alert = UIAlertController(
                title: "Couldn’t apply theme",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func applyInterfaceStyle(_ style: AppearanceInterfaceStyle) {
        var updated = appearanceCoordinator.document
        guard updated.profile.interfaceStyle != style else {
            document = updated
            tableView.reloadSections(IndexSet(integer: Section.mode.rawValue), with: .none)
            return
        }
        updated.profile.interfaceStyle = style
        do {
            _ = try appearanceCoordinator.commit(updated)
            document = appearanceCoordinator.document
        } catch {
            let alert = UIAlertController(
                title: "Couldn’t apply appearance",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

extension InterfaceSettingsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .preview: return 1
        case .theme: return themeRows.count
        case .mode: return 1
        case .layout: return 3
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .theme: return "Color Theme"
        case .mode: return "Appearance"
        case .layout: return "Chat Appearance"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if Section(rawValue: indexPath.section) == .preview {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: AppearanceOverviewCell.reuseIdentifier,
                for: indexPath
            ) as? AppearanceOverviewCell else { return UITableViewCell() }
            cell.configure(document: document, traits: traitCollection)
            cell.onThemeTap = { [weak self] theme in
                self?.applyOverviewTheme(theme)
            }
            return cell
        }
        if Section(rawValue: indexPath.section) == .mode {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: AppearanceModeSelectionCell.reuseIdentifier,
                for: indexPath
            ) as? AppearanceModeSelectionCell else { return UITableViewCell() }
            let snapshot = AppearanceResolver.resolve(
                document: document,
                traitStyle: traitCollection.userInterfaceStyle
            )
            cell.configure(
                selectedStyle: document.profile.interfaceStyle,
                accent: snapshot.accent.uiColor,
                traitStyle: traitCollection.userInterfaceStyle
            )
            cell.onSelection = { [weak self] style in
                self?.applyInterfaceStyle(style)
            }
            return cell
        }
        guard let row = row(at: indexPath) else { return UITableViewCell() }
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var configuration = cell.defaultContentConfiguration()
        configuration.text = title(for: row)
        configuration.secondaryText = value(for: row)
        configuration.textProperties.adjustsFontForContentSizeCategory = true
        configuration.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = accessibilityID(for: row)
        if row == .accent {
            let snapshot = AppearanceResolver.resolve(document: document, traitStyle: traitCollection.userInterfaceStyle)
            cell.accessoryView = AppearanceColorIndicator(color: snapshot.accent.uiColor)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = row(at: indexPath) else { return }
        switch row {
        case .themes:
            navigationController?.pushViewController(
                AppearanceThemesViewController(document: document),
                animated: true
            )
        case .wallpaper:
            pushEditor(AppearanceWallpaperViewController(document: document))
        case .accent:
            pushEditor(AppearanceAccentViewController(document: document))
        case .textSize:
            pushEditor(AppearanceTextSizeViewController(document: document))
        case .bubbles:
            pushEditor(AppearanceBubbleViewController(document: document))
        case .avatars:
            pushEditor(AppearanceAvatarViewController(document: document))
        }
    }
}

private final class AppearanceColorIndicator: UIView {
    init(color: UIColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
        backgroundColor = color
        layer.cornerRadius = 13
        layer.borderWidth = 2
        layer.borderColor = UIColor.systemBackground.cgColor
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class AppearanceModeSelectionCell: UITableViewCell {
    static let reuseIdentifier = "AppearanceModeSelectionCell"

    var onSelection: ((AppearanceInterfaceStyle) -> Void)?

    private let optionsStack = UIStackView()
    private var controls: [AppearanceInterfaceStyle: AppearanceModeOptionControl] = [:]

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = false
        accessibilityIdentifier = "interface.settings.appearance"
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 18,
            leading: 16,
            bottom: 16,
            trailing: 16
        )
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        optionsStack.axis = .horizontal
        optionsStack.alignment = .top
        optionsStack.distribution = .fillEqually
        optionsStack.spacing = 12
        contentView.addSubview(optionsStack)
        NSLayoutConstraint.activate([
            optionsStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            optionsStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            optionsStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            optionsStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])

        for style in AppearanceInterfaceStyle.allCases {
            let control = AppearanceModeOptionControl()
            control.addAction(UIAction { [weak self] _ in
                self?.onSelection?(style)
            }, for: .touchUpInside)
            controls[style] = control
            optionsStack.addArrangedSubview(control)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        selectedStyle: AppearanceInterfaceStyle,
        accent: UIColor,
        traitStyle: UIUserInterfaceStyle
    ) {
        for style in AppearanceInterfaceStyle.allCases {
            controls[style]?.configure(
                style: style,
                selected: style == selectedStyle,
                accent: accent,
                traitStyle: traitStyle
            )
        }
    }
}

private final class AppearanceModeOptionControl: UIControl {
    private let contentStack = UIStackView()
    private let preview = AppearanceModePreviewCard()
    private let titleLabel = UILabel()
    private let selectionIndicator = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.spacing = 8
        contentStack.isUserInteractionEnabled = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.minimumScaleFactor = 0.78
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.isAccessibilityElement = false
        selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
        selectionIndicator.contentMode = .scaleAspectFit
        selectionIndicator.isAccessibilityElement = false
        preview.isAccessibilityElement = false
        contentStack.addArrangedSubview(preview)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(selectionIndicator)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            preview.widthAnchor.constraint(equalTo: contentStack.widthAnchor, multiplier: 0.76),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 1.55),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor),
            selectionIndicator.widthAnchor.constraint(equalToConstant: 30),
            selectionIndicator.heightAnchor.constraint(equalTo: selectionIndicator.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        style: AppearanceInterfaceStyle,
        selected: Bool,
        accent: UIColor,
        traitStyle: UIUserInterfaceStyle
    ) {
        preview.configure(style: style, traitStyle: traitStyle)
        titleLabel.text = style.displayName
        selectionIndicator.image = UIImage(
            systemName: selected ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        )
        selectionIndicator.tintColor = selected ? accent : .tertiaryLabel
        accessibilityIdentifier = "interface.mode.\(style.rawValue)"
        accessibilityLabel = "\(style.displayName) appearance"
        accessibilityValue = selected ? "Selected" : nil
        accessibilityHint = "Applies this appearance to the app"
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
}

private final class AppearanceModePreviewCard: UIView {
    private let gradientLayer = CAGradientLayer()
    private let notificationsStack = UIStackView()
    private let firstNotification = UIView()
    private let secondNotification = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        clipsToBounds = true
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradientLayer, at: 0)

        notificationsStack.translatesAutoresizingMaskIntoConstraints = false
        notificationsStack.axis = .vertical
        notificationsStack.spacing = 6
        notificationsStack.isAccessibilityElement = false
        [firstNotification, secondNotification].forEach { notification in
            notification.translatesAutoresizingMaskIntoConstraints = false
            notification.layer.cornerRadius = 8
            notification.layer.cornerCurve = .continuous
            notification.isAccessibilityElement = false
            notification.heightAnchor.constraint(equalToConstant: 20).isActive = true
            notificationsStack.addArrangedSubview(notification)
        }
        addSubview(notificationsStack)
        NSLayoutConstraint.activate([
            notificationsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            notificationsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            notificationsStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(style: AppearanceInterfaceStyle, traitStyle: UIUserInterfaceStyle) {
        let effectiveStyle: UIUserInterfaceStyle
        switch style {
        case .system:
            effectiveStyle = traitStyle == .dark ? .dark : .light
        case .light:
            effectiveStyle = .light
        case .dark:
            effectiveStyle = .dark
        }
        let palette: [UIColor]
        switch effectiveStyle {
        case .dark:
            palette = [
                UIColor(red: 0.04, green: 0.12, blue: 0.30, alpha: 1),
                UIColor(red: 0.04, green: 0.43, blue: 0.61, alpha: 1),
                UIColor(red: 0.01, green: 0.10, blue: 0.22, alpha: 1)
            ]
        default:
            palette = [
                UIColor(red: 0.69, green: 0.95, blue: 0.96, alpha: 1),
                UIColor(red: 0.12, green: 0.65, blue: 0.73, alpha: 1),
                UIColor(red: 0.06, green: 0.30, blue: 0.70, alpha: 1)
            ]
        }
        gradientLayer.colors = palette.map { $0.cgColor }
        let notificationColor = UIColor.white.withAlphaComponent(effectiveStyle == .dark ? 0.18 : 0.52)
        firstNotification.backgroundColor = notificationColor
        secondNotification.backgroundColor = notificationColor
        accessibilityIdentifier = "interface.mode.preview.\(style.rawValue)"
        firstNotification.accessibilityIdentifier = "interface.mode.preview.\(style.rawValue).message.0"
        secondNotification.accessibilityIdentifier = "interface.mode.preview.\(style.rawValue).message.1"
    }
}

private final class AppearanceOverviewCell: UITableViewCell {
    static let reuseIdentifier = "AppearanceOverviewCell"

    var onThemeTap: ((AppearanceTheme) -> Void)?
    private let preview = AppearancePreviewView()
    private let scrollView = UIScrollView()
    private let themesStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        preview.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        themesStack.translatesAutoresizingMaskIntoConstraints = false
        themesStack.axis = .horizontal
        themesStack.spacing = 12
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.addSubview(themesStack)
        contentView.addSubview(preview)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            preview.heightAnchor.constraint(equalToConstant: 210),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            scrollView.heightAnchor.constraint(equalToConstant: 105),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            themesStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            themesStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            themesStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            themesStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            themesStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        accessibilityIdentifier = "interface.settings.preview"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(document: AppearanceSettingsDocument, traits: UITraitCollection) {
        preview.configure(document: document, traits: traits, animated: false)
        themesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let themes = AppearanceThemeCatalog.builtInThemes + document.customThemes
        let snapshot = AppearanceResolver.resolve(document: document, traitStyle: traits.userInterfaceStyle)
        for theme in themes {
            let control = AppearanceThemeMiniControl()
            control.configure(
                theme: theme,
                selected: theme.id == document.profile.themeID,
                accent: snapshot.accent.uiColor,
                traits: traits,
                document: document
            )
            control.addAction(UIAction { [weak self] _ in self?.onThemeTap?(theme) }, for: .touchUpInside)
            themesStack.addArrangedSubview(control)
        }
    }
}

private final class AppearanceThemeMiniControl: UIControl {
    private let background = ChatBackgroundBackdropView()
    private let incoming = UIView()
    private let outgoing = UIView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        incoming.translatesAutoresizingMaskIntoConstraints = false
        outgoing.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        incoming.layer.cornerRadius = 9
        incoming.layer.cornerCurve = .continuous
        incoming.clipsToBounds = true
        outgoing.layer.cornerRadius = 9
        outgoing.layer.cornerCurve = .continuous
        outgoing.clipsToBounds = true
        background.isUserInteractionEnabled = false
        incoming.isUserInteractionEnabled = false
        outgoing.isUserInteractionEnabled = false
        nameLabel.isUserInteractionEnabled = false
        nameLabel.font = .preferredFont(forTextStyle: .caption2)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        addSubview(background)
        addSubview(incoming)
        addSubview(outgoing)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 86),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            incoming.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            incoming.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            incoming.widthAnchor.constraint(equalToConstant: 52),
            incoming.heightAnchor.constraint(equalToConstant: 18),
            outgoing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outgoing.topAnchor.constraint(equalTo: incoming.bottomAnchor, constant: 8),
            outgoing.widthAnchor.constraint(equalToConstant: 52),
            outgoing.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        theme: AppearanceTheme,
        selected: Bool,
        accent: UIColor,
        traits: UITraitCollection,
        document: AppearanceSettingsDocument
    ) {
        var themeDocument = document
        themeDocument.profile.apply(
            theme: theme,
            preserveWallpaper: CommonConfigManager.shared.config.locked_background.isNotEmpty
        )
        let snapshot = AppearanceResolver.resolve(
            document: themeDocument,
            traitStyle: traits.userInterfaceStyle
        )
        background.configure(document: themeDocument)
        background.accessibilityIdentifier = "interface.theme.wallpaper.\(theme.id)"
        incoming.backgroundColor = snapshot.palette.incomingBubble.uiColor
        incoming.accessibilityIdentifier = "interface.theme.bubble.incoming.\(theme.id)"
        outgoing.backgroundColor = snapshot.palette.outgoingBubble.uiColor
        outgoing.accessibilityIdentifier = "interface.theme.bubble.outgoing.\(theme.id)"
        nameLabel.text = theme.name
        layer.borderWidth = selected ? 3 : 0
        layer.borderColor = accent.cgColor
        accessibilityLabel = theme.name
        accessibilityValue = selected ? "Selected" : nil
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityIdentifier = "interface.theme.mini.\(theme.id)"
    }
}

final class AppearancePreviewView: UIView {
    private let backgroundView = ChatBackgroundBackdropView()
    private let contentStack = UIStackView()
    private var currentDocument: AppearanceSettingsDocument?
    private var chatMessageHosts: [AppearanceChatMessagePreviewHostView] = []

    var showsChatList = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 8
        addSubview(backgroundView)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "interface.preview"
        accessibilityLabel = "Appearance preview"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        document: AppearanceSettingsDocument,
        traits: UITraitCollection,
        animated: Bool = true,
        updatingTypographyInPlace: Bool = false
    ) {
        currentDocument = document
        let snapshot = AppearanceResolver.resolve(document: document, traitStyle: traits.userInterfaceStyle)
        if updatingTypographyInPlace,
           !showsChatList,
           chatMessageHosts.isNotEmpty {
            chatMessageHosts.forEach { $0.updateTypography(snapshot: snapshot) }
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let changes = {
            self.backgroundView.configure(document: document)
            self.configureContent(snapshot: snapshot)
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.32, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: changes)
        } else {
            changes()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection),
              let currentDocument else { return }
        configure(document: currentDocument, traits: traitCollection, animated: true)
    }

    private func configureContent(snapshot: ResolvedAppearanceSnapshot) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chatMessageHosts.removeAll(keepingCapacity: true)
        if showsChatList {
            for index in 0..<4 {
                contentStack.addArrangedSubview(makeChatRow(index: index, snapshot: snapshot))
            }
        } else {
            let incoming = AppearanceChatMessagePreviewHostView()
            incoming.configure(text: "Good morning! 👋", outgoing: false, snapshot: snapshot)
            let outgoing = AppearanceChatMessagePreviewHostView()
            outgoing.configure(text: "It’s morning in Tokyo 😎", outgoing: true, snapshot: snapshot)
            contentStack.addArrangedSubview(incoming)
            contentStack.addArrangedSubview(outgoing)
            chatMessageHosts = [incoming, outgoing]
        }
    }

    private func makeChatRow(index: Int, snapshot: ResolvedAppearanceSnapshot) -> UIView {
        let row = UIView()
        row.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.86)
        row.layer.cornerRadius = 14
        let avatar = UIView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.backgroundColor = snapshot.accent.uiColor.withAlphaComponent(0.8)
        avatar.layer.cornerRadius = 18
        if snapshot.profile.avatarMask != .square,
           let maskImage = UIImage(named: snapshot.profile.avatarMask.rawValue + "_32pt") {
            let maskView = UIImageView(image: maskImage)
            maskView.frame = CGRect(origin: .zero, size: CGSize(width: 36, height: 36))
            avatar.mask = maskView
        } else {
            avatar.mask = nil
        }
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = AppearanceTypography.font(
            textStyle: .body,
            appearanceSize: snapshot.profile.textSize,
            weight: .semibold
        )
        title.text = ["Alicia", "Roberto", "Public Chat", "Veronica"][index]
        title.textColor = .label
        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = AppearanceTypography.font(textStyle: .caption1, appearanceSize: snapshot.profile.textSize)
        subtitle.text = "Preview message"
        subtitle.textColor = .secondaryLabel
        row.addSubview(avatar)
        row.addSubview(title)
        row.addSubview(subtitle)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor),
            subtitle.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -5)
        ])
        return row
    }
}

private extension AppearanceBubbleStyle {
    var messageTailIdentifier: String {
        switch self {
        case .noTail:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.noTail.rawValue
        case .smooth:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.smooth.rawValue
        case .bubble:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubble.rawValue
        case .bubbles:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.bubbles.rawValue
        case .curvy:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.curvy.rawValue
        case .stripes:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.stripes.rawValue
        case .transparent:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.transparent.rawValue
        case .wedge:
            return MessageStyleConfig.MessageBubbleContainer.CodingKeys.wedge.rawValue
        }
    }
}

private func appearanceMessageRadius(
    style: AppearanceBubbleStyle,
    value: Int
) -> MessageStyleConfig.MessageRadius.Radius {
    let bubbles = CommonConfigManager.shared.messageStyleConfig.messageBubbles
    let index = String(value)
    switch style {
    case .noTail: return bubbles.noTail.message.bubble.getRadiusFor(index: index)
    case .smooth: return bubbles.smooth.message.bubble.getRadiusFor(index: index)
    case .bubble: return bubbles.bubble.message.bubble.getRadiusFor(index: index)
    case .bubbles: return bubbles.bubbles.message.bubble.getRadiusFor(index: index)
    case .curvy: return bubbles.curvy.message.bubble.getRadiusFor(index: index)
    case .stripes: return bubbles.stripes.message.bubble.getRadiusFor(index: index)
    case .transparent: return bubbles.transparent.message.bubble.getRadiusFor(index: index)
    case .wedge: return bubbles.wedge.message.bubble.getRadiusFor(index: index)
    }
}

private struct AppearancePreviewMessage: MessageType {
    let primary: String
    let jid = "preview@example.invalid"
    let owner = "preview-owner@example.invalid"
    let sender: Sender
    let messageId: String
    let sentDate = Date(timeIntervalSince1970: 1_700_000_000)
    let editDate: Date? = nil
    let kind: MessageKind
    let withAuthor = false
    let withAvatar = false
    let error = false
    let errorType = ""
    let canPinMessage = false
    let canEditMessage = false
    let canDeleteMessage = false
    let forwards: [MessageAttachment]
    let isOutgoing: Bool
    let isEdited = false
    let groupchatAuthorNickname = ""
    let groupchatAuthorBadge = ""
    let groupchatAuthorId = ""
    let isHasAttachedMessages: Bool
    let afterburnInterval: Double = 0
    let tailed = true
    let images: [ImageAttachment] = []
    let videos: [VideoAttachment] = []
    let locations: [LocationAttachment] = []
    let contacts: [ContactAttachment] = []
    let files: [FileAttachment] = []
    let audios: [AudioAttachment]
    let messageWarningText: String? = nil
    let timeMarkerText: NSAttributedString
    let indicator: IndicatorType
    let avatarUrl: String? = nil
    let attributedAuthor: NSAttributedString? = nil

    init(
        text: String,
        outgoing: Bool,
        snapshot: ResolvedAppearanceSnapshot,
        identifier: String? = nil,
        forwards: [MessageAttachment] = [],
        audios: [AudioAttachment] = []
    ) {
        primary = "appearance-preview-\(identifier ?? (outgoing ? "outgoing" : "incoming"))"
        sender = Sender(id: outgoing ? "me" : "contact", displayName: outgoing ? "Me" : "Contact")
        messageId = primary
        isOutgoing = outgoing
        self.forwards = forwards
        self.audios = audios
        isHasAttachedMessages = forwards.isNotEmpty || audios.isNotEmpty
        indicator = outgoing ? .read : .none
        let textColor = outgoing
            ? snapshot.palette.outgoingText.uiColor
            : snapshot.palette.incomingText.uiColor
        kind = .attributedText(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: AppearanceTypography.font(
                        textStyle: .body,
                        appearanceSize: snapshot.profile.textSize
                    ),
                    .foregroundColor: textColor
                ]
            )
        )
        timeMarkerText = NSAttributedString(
            string: "23:20",
            attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }
}

/// Hosts the production text-message cell and production layout calculator,
/// so the settings preview cannot drift from real chat bubble geometry.
private final class AppearanceChatMessagePreviewHostView: UIView {
    private struct Configuration {
        let text: String
        let outgoing: Bool
        let identifier: String?
        let forwards: [MessageAttachment]
        let audios: [AudioAttachment]
    }

    private let messageCell = TextMessageCell(frame: .zero)
    private var message: AppearancePreviewMessage?
    private var snapshot: ResolvedAppearanceSnapshot?
    private var measuredHeightConstraint: NSLayoutConstraint!
    private var configuration: Configuration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isUserInteractionEnabled = false
        addSubview(messageCell)
        measuredHeightConstraint = heightAnchor.constraint(equalToConstant: 1)
        measuredHeightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        text: String,
        outgoing: Bool,
        snapshot: ResolvedAppearanceSnapshot,
        identifier: String? = nil,
        forwards: [MessageAttachment] = [],
        audios: [AudioAttachment] = []
    ) {
        configuration = Configuration(
            text: text,
            outgoing: outgoing,
            identifier: identifier,
            forwards: forwards,
            audios: audios
        )
        applyConfiguration(snapshot: snapshot)
    }

    func updateTypography(snapshot: ResolvedAppearanceSnapshot) {
        guard configuration != nil else { return }
        applyConfiguration(snapshot: snapshot)
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func applyConfiguration(snapshot: ResolvedAppearanceSnapshot) {
        guard let configuration else { return }
        let message = AppearancePreviewMessage(
            text: configuration.text,
            outgoing: configuration.outgoing,
            snapshot: snapshot,
            identifier: configuration.identifier,
            forwards: configuration.forwards,
            audios: configuration.audios
        )
        self.message = message
        self.snapshot = snapshot
        if let identifier = configuration.identifier {
            messageCell.accessibilityIdentifier = "interface.themePreview.chat.message.\(identifier)"
        } else {
            messageCell.accessibilityIdentifier = configuration.outgoing
                ? "interface.preview.message.outgoing"
                : "interface.preview.message.incoming"
        }
        messageCell.messageContainerView.appearancePaletteOverride = snapshot.palette
        messageCell.configureForAppearancePreview(with: message)
        if bounds.width > 0 {
            updateLayoutWidth(bounds.width)
        }
    }

    func updateLayoutWidth(_ width: CGFloat) {
        guard width > 0, let layout = measuredLayout(for: width) else { return }
        if abs(measuredHeightConstraint.constant - layout.cellSize.height) > 0.5 {
            measuredHeightConstraint.constant = layout.cellSize.height
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0,
              let layout = measuredLayout(for: bounds.width),
              let snapshot else { return }
        updateLayoutWidth(bounds.width)
        messageCell.frame = CGRect(origin: .zero, size: layout.cellSize)
        messageCell.contentView.frame = messageCell.bounds
        let attributes = MessagesCollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        layout.apply(to: attributes)
        attributes.frame = CGRect(origin: .zero, size: layout.cellSize)
        messageCell.messageContainerView.appearancePaletteOverride = snapshot.palette
        messageCell.apply(attributes)
        messageCell.setNeedsLayout()
        messageCell.layoutIfNeeded()
    }

    private func measuredLayout(for width: CGFloat) -> ChatMessageLayout? {
        guard let message, let snapshot else { return nil }
        let interfaceStyle: UIUserInterfaceStyle
        switch snapshot.profile.interfaceStyle {
        case .system: interfaceStyle = traitCollection.userInterfaceStyle
        case .light: interfaceStyle = .light
        case .dark: interfaceStyle = .dark
        }
        let context = ChatMessageLayoutContext(
            width: width,
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            localeIdentifier: Locale.current.identifier,
            interfaceStyleRawValue: interfaceStyle.rawValue,
            messageStyle: snapshot.profile.bubbleStyle.messageTailIdentifier,
            cornerRadius: String(snapshot.profile.bubbleRadius),
            avatarMode: snapshot.profile.avatarPosition.rawValue,
            appearanceSignature: snapshot.layoutSignature
        )
        return ChatMessageLayoutCalculator.measure(message, context: context)
    }
}

private final class AppearanceGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var colors: [UIColor] = [.systemBackground, .secondarySystemBackground] {
        didSet { update() }
    }

    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        gradient.colors = colors.map(\.cgColor)
        gradient.locations = colors.enumerated().map { NSNumber(value: Double($0.offset) / Double(max(colors.count - 1, 1))) }
    }
}

class AppearanceDraftViewController: BaseViewController {
    var document: AppearanceSettingsDocument
    var draft: AppearanceDraft
    let preview = AppearancePreviewView()

    init(document: AppearanceSettingsDocument, title: String) {
        self.document = document
        draft = AppearanceDraft(profile: document.profile)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(setTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "interface.editor.set"
        refreshSetButton()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            draft.reset()
        }
    }

    func updatePreview() {
        var updated = document
        updated.profile = draft.profile
        preview.configure(document: updated, traits: traitCollection)
        refreshSetButton()
    }

    func refreshSetButton() {
        navigationItem.rightBarButtonItem?.isEnabled = draft.isDirty
    }

    @objc func setTapped() {
        commitAndPop()
    }

    func commitAndPop() {
        document.profile = draft.profile
        do {
            _ = try AppearanceCoordinator.shared.commit(document)
            draft.accept()
            navigationController?.popViewController(animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t apply appearance", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class AppearanceAccentViewController: AppearanceDraftViewController, UIColorPickerViewControllerDelegate {
    private let stack = UIStackView()
    private let swatches = UIStackView()

    init(document: AppearanceSettingsDocument) {
        super.init(document: document, title: "Application Color")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        swatches.axis = .horizontal
        swatches.distribution = .fillEqually
        swatches.spacing = 10
        preview.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(preview)
        stack.addArrangedSubview(swatches)
        let colors = ["#1687F8", "#35B85A", "#F28A18", "#D94B54", "#9656DD", "#19A7A0", "#D04D91"]
        for value in colors {
            guard let color = AppearanceColor(hex: value) else { continue }
            let button = UIButton(type: .system)
            button.backgroundColor = color.uiColor
            button.layer.cornerRadius = 22
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.accessibilityLabel = "Accent color"
            button.addAction(UIAction { [weak self] _ in
                self?.draft.profile.accentOverride = color
                self?.updatePreview()
            }, for: .touchUpInside)
            swatches.addArrangedSubview(button)
        }
        let custom = UIButton(type: .system)
        custom.configuration = .filled()
        custom.configuration?.title = "Choose Custom Color"
        custom.configuration?.image = UIImage(systemName: "paintpalette.fill")
        custom.configuration?.imagePadding = 8
        custom.addTarget(self, action: #selector(showColorPicker), for: .touchUpInside)
        custom.accessibilityIdentifier = "interface.accent.custom"
        stack.addArrangedSubview(custom)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            preview.heightAnchor.constraint(equalToConstant: 290)
        ])
        updatePreview()
    }

    @objc private func showColorPicker() {
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.supportsAlpha = false
        picker.selectedColor = draft.profile.accentOverride?.uiColor
            ?? AppearanceResolver.resolve(document: document, traitStyle: traitCollection.userInterfaceStyle).accent.uiColor
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        draft.profile.accentOverride = AppearanceColor(uiColor: viewController.selectedColor)
        updatePreview()
    }
}

private final class AppearanceTextSizeViewController: AppearanceDraftViewController {
    private let systemSwitch = UISwitch()
    private let slider = UISlider()
    private let sizeLabel = UILabel()

    init(document: AppearanceSettingsDocument) {
        super.init(document: document, title: "Text Size")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.translatesAutoresizingMaskIntoConstraints = false
        let switchLabel = UILabel()
        switchLabel.text = "Use System Text Size"
        switchLabel.font = .preferredFont(forTextStyle: .body)
        switchLabel.adjustsFontForContentSizeCategory = true
        systemSwitch.isOn = draft.profile.textSize == .system
        systemSwitch.addTarget(self, action: #selector(systemChanged), for: .valueChanged)
        systemSwitch.accessibilityIdentifier = "interface.textSize.system"
        let switchRow = UIStackView(arrangedSubviews: [switchLabel, systemSwitch])
        switchRow.axis = .horizontal
        switchRow.alignment = .center
        sizeLabel.textAlignment = .center
        sizeLabel.textColor = .secondaryLabel
        slider.minimumValue = 0
        slider.maximumValue = Float(AppearanceTextSize.fixedCases.count - 1)
        slider.isContinuous = true
        if let index = AppearanceTextSize.fixedCases.firstIndex(of: draft.profile.textSize) {
            slider.value = Float(index)
        } else {
            slider.value = 3
        }
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.accessibilityIdentifier = "interface.textSize.slider"
        let small = UILabel()
        small.text = "A"
        small.font = .systemFont(ofSize: 14)
        let large = UILabel()
        large.text = "A"
        large.font = .systemFont(ofSize: 28)
        let sliderRow = UIStackView(arrangedSubviews: [small, slider, large])
        sliderRow.axis = .horizontal
        sliderRow.spacing = 12
        sliderRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [preview, switchRow, sizeLabel, sliderRow])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            preview.heightAnchor.constraint(equalToConstant: 330)
        ])
        refreshControls()
        updatePreview()
    }

    @objc private func systemChanged() {
        draft.profile.textSize = systemSwitch.isOn ? .system : AppearanceTextSize.fixedCases[Int(slider.value.rounded())]
        refreshControls()
        updateTypographyPreview()
    }

    @objc private func sliderChanged() {
        let index = min(max(Int(slider.value.rounded()), 0), AppearanceTextSize.fixedCases.count - 1)
        slider.setValue(Float(index), animated: false)
        let selectedSize = AppearanceTextSize.fixedCases[index]
        if !systemSwitch.isOn, draft.profile.textSize != selectedSize {
            draft.profile.textSize = selectedSize
            updateTypographyPreview()
        }
        refreshControls()
    }

    private func updateTypographyPreview() {
        var updated = document
        updated.profile = draft.profile
        preview.configure(
            document: updated,
            traits: traitCollection,
            animated: false,
            updatingTypographyInPlace: true
        )
        refreshSetButton()
    }

    private func refreshControls() {
        slider.isEnabled = !systemSwitch.isOn
        sizeLabel.text = systemSwitch.isOn ? "System" : AppearanceTextSize.fixedCases[Int(slider.value.rounded())].displayName
    }
}

private final class AppearanceBubbleViewController: AppearanceDraftViewController {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let gallery = AppearanceBubbleStyleGalleryView()
    private let radiusSlider = UISlider()
    private let radiusLabel = UILabel()
    private var policy: AppearancePremiumPolicy {
        let provider = LiveAppearanceEntitlementProvider()
        return AppearancePremiumPolicy(
            isEntitled: provider.hasActiveAppearanceEntitlement,
            subscriptionsEnabled: provider.areSubscriptionsEnabled
        )
    }

    init(document: AppearanceSettingsDocument) {
        super.init(document: document, title: "Message Bubbles")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 18
        gallery.translatesAutoresizingMaskIntoConstraints = false
        gallery.onStyleSelected = { [weak self] style in
            self?.select(style)
        }
        radiusSlider.minimumValue = 0
        radiusSlider.maximumValue = 16
        radiusSlider.value = Float(draft.profile.bubbleRadius)
        radiusSlider.addTarget(self, action: #selector(radiusChanged), for: .valueChanged)
        radiusSlider.accessibilityIdentifier = "interface.bubbles.radius"
        radiusLabel.font = .preferredFont(forTextStyle: .body)
        radiusLabel.adjustsFontForContentSizeCategory = true
        let radiusRow = UIStackView(arrangedSubviews: [radiusLabel, radiusSlider])
        radiusRow.axis = .horizontal
        radiusRow.spacing = 12
        radiusRow.alignment = .center
        radiusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        contentStack.addArrangedSubview(gallery)
        contentStack.addArrangedSubview(radiusRow)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        radiusChanged()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(entitlementChanged),
            name: .premiumEntitlementDidChange,
            object: nil
        )
    }

    private func select(_ value: AppearanceBubbleStyle) {
        guard policy.canSelect(value, currentlyApplied: document.profile.bubbleStyle) else {
            SubscribtionsPresenter().present(animated: true, parent: self)
            return
        }
        draft.profile.bubbleStyle = value
        updateGallery()
        refreshSetButton()
    }

    @objc private func radiusChanged() {
        let value = min(max(Int(radiusSlider.value.rounded()), 0), 16)
        radiusSlider.setValue(Float(value), animated: false)
        radiusLabel.text = "Radius \(value)"
        draft.profile.bubbleRadius = value
        updateGallery()
        refreshSetButton()
    }

    @objc private func entitlementChanged() {
        updateGallery()
    }

    private func updateGallery() {
        var updated = document
        updated.profile = draft.profile
        let lockedStyles = Set(policy.visibleBubbleStyles.filter {
            !policy.canSelect($0, currentlyApplied: document.profile.bubbleStyle)
        })
        gallery.configure(
            document: updated,
            traits: traitCollection,
            styles: policy.visibleBubbleStyles,
            selectedStyle: draft.profile.bubbleStyle,
            lockedStyles: lockedStyles
        )
    }
}

/// A single, wallpaper-backed choice surface for every message bubble shape.
/// It uses the same message host as the rest of Interface Appearance, while
/// keeping the selection control adjacent to the message it changes.
final class AppearanceBubbleStyleGalleryView: UIView {
    var onStyleSelected: ((AppearanceBubbleStyle) -> Void)?

    private let backgroundView = ChatBackgroundBackdropView()
    private let rowsStack = UIStackView()
    private var rows: [AppearanceBubbleStyle: AppearanceBubbleStyleRow] = [:]
    private var orderedStyles: [AppearanceBubbleStyle] = []
    private var minimumHeight: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: minimumHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.accessibilityIdentifier = "interface.bubbles.background"
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        rowsStack.spacing = 6
        addSubview(backgroundView)
        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        accessibilityIdentifier = "interface.bubbles.gallery"
        accessibilityLabel = "Message bubble styles"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        document: AppearanceSettingsDocument,
        traits: UITraitCollection,
        styles: [AppearanceBubbleStyle],
        selectedStyle: AppearanceBubbleStyle,
        lockedStyles: Set<AppearanceBubbleStyle>
    ) {
        backgroundView.configure(document: document)
        rebuildRowsIfNeeded(for: styles)
        for (index, style) in styles.enumerated() {
            guard let row = rows[style] else { continue }
            var styleDocument = document
            styleDocument.profile.bubbleStyle = style
            let snapshot = AppearanceResolver.resolve(document: styleDocument, traitStyle: traits.userInterfaceStyle)
            row.configure(
                style: style,
                text: Self.sampleText(for: style),
                outgoing: index.isMultiple(of: 2),
                snapshot: snapshot,
                selected: style == selectedStyle,
                locked: lockedStyles.contains(style),
                accent: snapshot.accent.uiColor
            )
        }
    }

    private func rebuildRowsIfNeeded(for styles: [AppearanceBubbleStyle]) {
        guard orderedStyles != styles else { return }
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll(keepingCapacity: true)
        orderedStyles = styles
        for style in styles {
            let row = AppearanceBubbleStyleRow()
            row.onSelect = { [weak self] style in
                self?.onStyleSelected?(style)
            }
            rows[style] = row
            rowsStack.addArrangedSubview(row)
        }
        minimumHeight = CGFloat(styles.count) * 64
            + CGFloat(max(styles.count - 1, 0)) * rowsStack.spacing
            + 24
        invalidateIntrinsicContentSize()
    }

    private static func sampleText(for style: AppearanceBubbleStyle) -> String {
        switch style {
        case .noTail: return "No tail, just a message"
        case .smooth: return "A smooth reply"
        case .bubble: return "A friendly bubble"
        case .bubbles: return "Small bubbles follow"
        case .curvy: return "A gently curving hello"
        case .stripes: return "A message with stripes"
        case .transparent: return "See through this one"
        case .wedge: return "A sharper reply"
        }
    }
}

private final class AppearanceBubbleStyleRow: UIControl {
    var onSelect: ((AppearanceBubbleStyle) -> Void)?

    private let selectionIndicator = AppearanceBubbleSelectionIndicatorView()
    private let messageHost = AppearanceChatMessagePreviewHostView()
    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private var style: AppearanceBubbleStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
        messageHost.translatesAutoresizingMaskIntoConstraints = false
        messageHost.isUserInteractionEnabled = false
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.tintColor = .systemYellow
        lockView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(selectionIndicator)
        addSubview(messageHost)
        addSubview(lockView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            selectionIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            selectionIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionIndicator.widthAnchor.constraint(equalToConstant: 26),
            selectionIndicator.heightAnchor.constraint(equalTo: selectionIndicator.widthAnchor),
            messageHost.leadingAnchor.constraint(equalTo: selectionIndicator.trailingAnchor, constant: 8),
            messageHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            messageHost.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            messageHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            lockView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lockView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            lockView.widthAnchor.constraint(equalToConstant: 16),
            lockView.heightAnchor.constraint(equalToConstant: 16)
        ])
        addAction(UIAction { [weak self] _ in
            guard let self, let style = self.style else { return }
            self.onSelect?(style)
        }, for: .touchUpInside)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        messageHost.updateLayoutWidth(messageHost.bounds.width)
    }

    func configure(
        style: AppearanceBubbleStyle,
        text: String,
        outgoing: Bool,
        snapshot: ResolvedAppearanceSnapshot,
        selected: Bool,
        locked: Bool,
        accent: UIColor
    ) {
        self.style = style
        messageHost.configure(text: text, outgoing: outgoing, snapshot: snapshot)
        messageHost.accessibilityIdentifier = "interface.bubble.message.\(style.rawValue)"
        selectionIndicator.configure(selected: selected, accent: accent)
        selectionIndicator.accessibilityIdentifier = "interface.bubble.\(style.rawValue).selection"
        lockView.isHidden = !locked
        accessibilityIdentifier = "interface.bubble.\(style.rawValue)"
        accessibilityLabel = style.displayName
        accessibilityValue = locked ? "Premium" : (selected ? "Selected" : nil)
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
}

private final class AppearanceBubbleSelectionIndicatorView: UIView {
    private let checkmarkView = UIImageView(image: UIImage(systemName: "checkmark"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkView.tintColor = .white
        checkmarkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        addSubview(checkmarkView)
        NSLayoutConstraint.activate([
            checkmarkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Bubble style selection"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        layer.cornerCurve = .continuous
    }

    func configure(selected: Bool, accent: UIColor) {
        backgroundColor = selected ? accent : UIColor.systemBackground.withAlphaComponent(0.86)
        layer.borderWidth = selected ? 0 : 2
        layer.borderColor = selected ? nil : UIColor.tertiaryLabel.cgColor
        checkmarkView.isHidden = !selected
        accessibilityValue = selected ? "Selected" : "Not selected"
    }
}

private final class AppearanceAvatarViewController: AppearanceDraftViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collectionView: UICollectionView
    private let positionControl = UISegmentedControl(items: ["Top", "Bottom"])
    private var policy: AppearancePremiumPolicy {
        let provider = LiveAppearanceEntitlementProvider()
        return AppearancePremiumPolicy(
            isEntitled: provider.hasActiveAppearanceEntitlement,
            subscriptionsEnabled: provider.areSubscriptionsEnabled
        )
    }

    init(document: AppearanceSettingsDocument) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(document: document, title: "Avatars")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.showsChatList = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppearanceOptionCell.self, forCellWithReuseIdentifier: AppearanceOptionCell.reuseIdentifier)
        positionControl.selectedSegmentIndex = draft.profile.avatarPosition == .top ? 0 : 1
        positionControl.addTarget(self, action: #selector(positionChanged), for: .valueChanged)
        positionControl.accessibilityIdentifier = "interface.avatars.position"
        let positionLabel = UILabel()
        positionLabel.text = "Group message position"
        positionLabel.font = .preferredFont(forTextStyle: .body)
        positionLabel.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [preview, collectionView, positionLabel, positionControl])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            preview.heightAnchor.constraint(equalToConstant: 250),
            collectionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        updatePreview()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(entitlementChanged),
            name: .premiumEntitlementDidChange,
            object: nil
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        policy.visibleAvatarMasks.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let value = policy.visibleAvatarMasks[indexPath.item]
        let locked = !policy.canSelect(value, currentlyApplied: document.profile.avatarMask)
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AppearanceOptionCell.reuseIdentifier, for: indexPath) as! AppearanceOptionCell
        cell.configure(
            title: value.displayName,
            symbol: value.systemSymbolName,
            selected: value == draft.profile.avatarMask,
            locked: locked,
            accent: AppearanceResolver.resolve(document: document, traitStyle: traitCollection.userInterfaceStyle).accent.uiColor
        )
        cell.accessibilityIdentifier = "interface.avatar.\(value.rawValue)"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let value = policy.visibleAvatarMasks[indexPath.item]
        guard policy.canSelect(value, currentlyApplied: document.profile.avatarMask) else {
            SubscribtionsPresenter().present(animated: true, parent: self)
            return
        }
        draft.profile.avatarMask = value
        collectionView.reloadData()
        updatePreview()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: floor((collectionView.bounds.width - 12) / 2), height: 72)
    }

    @objc private func positionChanged() {
        draft.profile.avatarPosition = positionControl.selectedSegmentIndex == 0 ? .top : .bottom
        updatePreview()
    }

    @objc private func entitlementChanged() {
        collectionView.reloadData()
    }
}

private final class AppearanceOptionCell: UICollectionViewCell {
    static let reuseIdentifier = "AppearanceOptionCell"
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.tintColor = .systemYellow
        contentView.addSubview(symbolView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(lockView)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            symbolView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 30),
            symbolView.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockView.leadingAnchor, constant: -6),
            lockView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            lockView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            lockView.widthAnchor.constraint(equalToConstant: 16),
            lockView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String, selected: Bool, locked: Bool, accent: UIColor) {
        titleLabel.text = title
        symbolView.image = UIImage(systemName: symbol)
        symbolView.tintColor = selected ? accent : .secondaryLabel
        lockView.isHidden = !locked
        contentView.layer.borderWidth = selected ? 3 : 0
        contentView.layer.borderColor = accent.cgColor
        accessibilityLabel = title
        accessibilityValue = [selected ? "Selected" : nil, locked ? "Premium" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
    }

}

final class AppearanceThemesViewController: BaseViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collectionView: UICollectionView
    private var document: AppearanceSettingsDocument

    init(document: AppearanceSettingsDocument) {
        self.document = document
        let layout = UICollectionViewFlowLayout()
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chat Themes"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(createTheme)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "interface.themes.add"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppearanceThemeCell.self, forCellWithReuseIdentifier: AppearanceThemeCell.reuseIdentifier)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        document = AppearanceCoordinator.shared.document
        collectionView.reloadData()
    }

    private var themes: [AppearanceTheme] { AppearanceThemeCatalog.builtInThemes + document.customThemes }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { themes.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let theme = themes[indexPath.item]
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AppearanceThemeCell.reuseIdentifier, for: indexPath) as! AppearanceThemeCell
        let accent = AppearanceResolver.resolve(document: document, traitStyle: traitCollection.userInterfaceStyle).accent.uiColor
        cell.configure(theme: theme, selected: theme.id == document.profile.themeID, accent: accent, traits: traitCollection)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        navigationController?.pushViewController(
            AppearanceThemePreviewViewController(document: document, theme: themes[indexPath.item]),
            animated: true
        )
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = floor((collectionView.bounds.width - 52) / 3)
        return CGSize(width: width, height: width * 1.35)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let theme = themes[indexPath.item]
        return UIContextMenuConfiguration(identifier: theme.id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            if theme.isBuiltIn {
                return UIMenu(children: [
                    UIAction(title: "Create Editable Copy", image: UIImage(systemName: "plus.square.on.square")) { _ in
                        self.copyForEditing(theme)
                    }
                ])
            }
            return UIMenu(children: [
                UIAction(title: "Edit", image: UIImage(systemName: "paintbrush")) { _ in self.edit(theme) },
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self.rename(theme) },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.delete(theme) }
            ])
        }
    }

    @objc private func createTheme() {
        let alert = UIAlertController(title: "New Theme", message: "Choose a unique name.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Theme name"
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text else { return }
            do {
                let store = AppearanceSettingsStore() ?? AppearanceSettingsStore(defaults: .standard, defaultAccentHex: "#007AFF")
                let theme = try store.createCustomTheme(named: name, basedOn: AppearanceThemeCatalog.theme(id: self.document.profile.themeID, customThemes: self.document.customThemes))
                AppearanceCoordinator.shared.reloadAndApply()
                self.document = AppearanceCoordinator.shared.document
                self.edit(theme)
            } catch {
                self.presentError(error)
            }
        })
        present(alert, animated: true)
    }

    private func copyForEditing(_ source: AppearanceTheme) {
        let alert = UIAlertController(title: "New Theme", message: "Editing a built-in theme creates a copy.", preferredStyle: .alert)
        alert.addTextField { $0.text = "\(source.name) Copy" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text else { return }
            do {
                let store = AppearanceSettingsStore() ?? AppearanceSettingsStore(defaults: .standard, defaultAccentHex: "#007AFF")
                let copy = try store.createCustomTheme(named: name, basedOn: source)
                AppearanceCoordinator.shared.reloadAndApply()
                self.document = AppearanceCoordinator.shared.document
                self.edit(copy)
            } catch {
                self.presentError(error)
            }
        })
        present(alert, animated: true)
    }

    private func edit(_ theme: AppearanceTheme) {
        let editor = AppearanceThemeEditorViewController(document: document, theme: theme)
        navigationController?.pushViewController(editor, animated: true)
    }

    private func rename(_ theme: AppearanceTheme) {
        let alert = UIAlertController(title: "Rename Theme", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = theme.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text else { return }
            do {
                let store = AppearanceSettingsStore() ?? AppearanceSettingsStore(defaults: .standard, defaultAccentHex: "#007AFF")
                _ = try store.renameCustomTheme(id: theme.id, to: name)
                AppearanceCoordinator.shared.reloadAndApply()
                self.document = AppearanceCoordinator.shared.document
                self.collectionView.reloadData()
            } catch { self.presentError(error) }
        })
        present(alert, animated: true)
    }

    private func delete(_ theme: AppearanceTheme) {
        let alert = UIAlertController(title: "Delete “\(theme.name)”?", message: "The cloud photo, if any, will remain in Cloud Storage.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                let store = AppearanceSettingsStore() ?? AppearanceSettingsStore(defaults: .standard, defaultAccentHex: "#007AFF")
                try store.deleteCustomTheme(id: theme.id)
                AppearanceCoordinator.shared.reloadAndApply()
                self.document = AppearanceCoordinator.shared.document
                self.collectionView.reloadData()
            } catch { self.presentError(error) }
        })
        present(alert, animated: true)
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Couldn’t save theme", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class AppearanceThemeCell: UICollectionViewCell {
    static let reuseIdentifier = "AppearanceThemeCell"
    private let gradient = AppearanceGradientView()
    private let incoming = UIView()
    private let outgoing = UIView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        gradient.translatesAutoresizingMaskIntoConstraints = false
        incoming.translatesAutoresizingMaskIntoConstraints = false
        outgoing.translatesAutoresizingMaskIntoConstraints = false
        incoming.layer.cornerRadius = 12
        outgoing.layer.cornerRadius = 12
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        contentView.addSubview(gradient)
        contentView.addSubview(incoming)
        contentView.addSubview(outgoing)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            gradient.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            gradient.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            gradient.topAnchor.constraint(equalTo: contentView.topAnchor),
            gradient.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            incoming.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            incoming.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            incoming.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            incoming.heightAnchor.constraint(equalToConstant: 32),
            outgoing.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            outgoing.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            outgoing.topAnchor.constraint(equalTo: incoming.bottomAnchor, constant: 10),
            outgoing.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(theme: AppearanceTheme, selected: Bool, accent: UIColor, traits: UITraitCollection) {
        let palette = theme.palette(for: traits.userInterfaceStyle)
        gradient.colors = palette.backgroundStops.map(\.uiColor)
        incoming.backgroundColor = palette.incomingBubble.uiColor
        outgoing.backgroundColor = palette.outgoingBubble.uiColor
        nameLabel.text = theme.name
        contentView.layer.borderWidth = selected ? 3 : 0
        contentView.layer.borderColor = accent.cgColor
        accessibilityLabel = theme.name
        accessibilityValue = selected ? "Selected" : nil
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityIdentifier = "interface.theme.\(theme.id)"
    }
}

private final class AppearanceThemeConversationPreviewPage: UIView {
    private let baseTopContentInset: CGFloat = 12
    private let backgroundView = ChatBackgroundBackdropView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var messageHosts: [AppearanceChatMessagePreviewHostView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: baseTopContentInset, left: 0, bottom: 112, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        addSubview(backgroundView)
        addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -16)
        ])
        accessibilityLabel = "Chat preview"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let topInset = safeAreaInsets.top + baseTopContentInset
        if abs(scrollView.contentInset.top - topInset) > 0.5 {
            scrollView.contentInset.top = topInset
            scrollView.verticalScrollIndicatorInsets.top = topInset
        }
        let messageWidth = max(1, bounds.width - 16)
        messageHosts.forEach { $0.updateLayoutWidth(messageWidth) }
    }

    func configure(document: AppearanceSettingsDocument, snapshot: ResolvedAppearanceSnapshot) {
        backgroundView.configure(document: document)
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        messageHosts.removeAll(keepingCapacity: true)
        contentStack.addArrangedSubview(makeDateMarker(snapshot: snapshot))

        addMessage(
            id: "opening",
            text: "For relaxing times, make it Suntory time. 😎",
            outgoing: true,
            snapshot: snapshot
        )
        addMessage(
            id: "answer",
            text: "Turn toward the camera, please.",
            outgoing: false,
            snapshot: snapshot
        )
        addMessage(
            id: "question",
            text: "That’s all?",
            outgoing: true,
            snapshot: snapshot
        )
        addMessage(
            id: "confirmation",
            text: "Yes, look at the camera.",
            outgoing: false,
            snapshot: snapshot
        )

        let reply = MessageAttachment(
            primary: "appearance-preview-reply",
            author: "Bob Harris",
            jid: "bob@example.invalid",
            outgoing: false,
            textMessage: NSAttributedString(string: "Yes, look at the camera."),
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarker: NSAttributedString(string: ""),
            subforwards: []
        )
        addMessage(
            id: "reply",
            text: "Does he want me to turn from the right or the left? 🤔",
            outgoing: true,
            snapshot: snapshot
        )

        let waveform: [Float] = [
            0.20, 0.55, 0.35, 0.78, 0.45, 0.85, 0.32, 0.62,
            0.90, 0.48, 0.72, 0.30, 0.82, 0.58, 0.95, 0.40,
            0.66, 0.28, 0.76, 0.52, 0.88, 0.36, 0.70, 0.44
        ]
        let voice = AudioAttachment(
            primary: "appearance-preview-voice",
            url: nil,
            size: 42_000,
            name: "Voice message.m4a",
            duration: 23,
            downloaded: true,
            pcm: waveform
        )
        addMessage(
            id: "voice",
            text: "",
            outgoing: false,
            snapshot: snapshot,
            audios: [voice]
        )
        addMessage(
            id: "quoted",
            text: "Right side. And, uh, with intensity.",
            outgoing: false,
            snapshot: snapshot,
            forwards: [reply]
        )
        addMessage(
            id: "closing",
            text: "Is that everything? It seemed like he said quite a bit more than that. 😮",
            outgoing: true,
            snapshot: snapshot
        )
    }

    private func addMessage(
        id: String,
        text: String,
        outgoing: Bool,
        snapshot: ResolvedAppearanceSnapshot,
        forwards: [MessageAttachment] = [],
        audios: [AudioAttachment] = []
    ) {
        let host = AppearanceChatMessagePreviewHostView()
        host.configure(
            text: text,
            outgoing: outgoing,
            snapshot: snapshot,
            identifier: id,
            forwards: forwards,
            audios: audios
        )
        messageHosts.append(host)
        contentStack.addArrangedSubview(host)
        if bounds.width > 16 {
            host.updateLayoutWidth(bounds.width - 16)
        }
    }

    private func makeDateMarker(snapshot: ResolvedAppearanceSnapshot) -> UIView {
        let container = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Today"
        label.textColor = .white
        label.font = AppearanceTypography.font(
            textStyle: .caption1,
            appearanceSize: snapshot.profile.textSize,
            weight: .semibold
        )
        label.backgroundColor = snapshot.accent.uiColor.withAlphaComponent(0.78)
        label.layer.cornerRadius = 14
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.textAlignment = .center
        label.accessibilityIdentifier = "interface.themePreview.chat.date"
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 38),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 28),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        return container
    }
}

private final class AppearanceThemeChatsPreviewPage: UIView {
    private let baseTopContentInset: CGFloat = 4
    private struct Fixture {
        let name: String
        let message: String
        let time: String
        let status: ResourceStatus
        let entity: RosterItemEntity
        let conversationType: ClientSynchronizationManager.ConversationType
        let delivery: MessageStorageItem.MessageSendingState?
        let unread: Int
        let isPinned: Bool
        let author: String?
    }

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let fixtures: [Fixture] = [
        Fixture(name: "Alicia Torreaux", message: "Bob says hi. 😊 ❤️ 😱", time: "13:02", status: .offline, entity: .contact, conversationType: .regular, delivery: .read, unread: 0, isPinned: true, author: nil),
        Fixture(name: "Roberto", message: "••• typing", time: "14:01", status: .online, entity: .contact, conversationType: .regular, delivery: nil, unread: 0, isPinned: false, author: nil),
        Fixture(name: "Campus Public Chat", message: "We just reached 2,500 members! WOO!", time: "13:53", status: .online, entity: .groupchat, conversationType: .group, delivery: nil, unread: 0, isPinned: false, author: "Jennie Alpha"),
        Fixture(name: "Veronica", message: "Table for four, 2PM. Be there.", time: "13:50", status: .offline, entity: .contact, conversationType: .regular, delivery: nil, unread: 0, isPinned: false, author: nil),
        Fixture(name: "Animal Videos", message: "Vote now! Moar cat videos in this channel?", time: "13:16", status: .offline, entity: .groupchat, conversationType: .channel, delivery: nil, unread: 0, isPinned: false, author: nil),
        Fixture(name: "Little Sister", message: "Don’t tell mom yet, but I got the job! I’m going to ROME!", time: "12:54", status: .offline, entity: .incognitoChat, conversationType: .omemo, delivery: nil, unread: 1, isPinned: false, author: nil),
        Fixture(name: "Jennie Alpha", message: "🖼️ Check these out", time: "12:53", status: .offline, entity: .contact, conversationType: .regular, delivery: nil, unread: 0, isPinned: false, author: nil)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: baseTopContentInset, left: 0, bottom: 112, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        accessibilityLabel = "Chats preview"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let topInset = safeAreaInsets.top + baseTopContentInset
        if abs(scrollView.contentInset.top - topInset) > 0.5 {
            scrollView.contentInset.top = topInset
            scrollView.verticalScrollIndicatorInsets.top = topInset
        }
    }

    func configure(snapshot: ResolvedAppearanceSnapshot) {
        backgroundColor = snapshot.profile.interfaceStyle == .dark
            ? .black
            : .systemBackground
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, fixture) in fixtures.enumerated() {
            let cell = ChatListTableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.isUserInteractionEnabled = false
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.configure(
                "preview-\(index)@example.invalid",
                owner: "preview-owner@example.invalid",
                username: fixture.name,
                attributedUsername: nil,
                message: fixture.message,
                date: Date(),
                deliveryState: fixture.delivery,
                isMute: false,
                isSynced: true,
                isGroupchat: fixture.entity == .groupchat,
                status: fixture.status,
                entity: fixture.entity,
                conversationType: fixture.conversationType,
                unread: fixture.unread,
                unreadString: fixture.unread > 0 ? String(fixture.unread) : nil,
                indicator: .clear,
                isDraft: false,
                isAttachment: false,
                groupchatNickname: fixture.author,
                isSystem: false,
                isPinned: fixture.isPinned,
                subRequest: false,
                avatarUrl: nil,
                hasErrorInChat: false,
                verAction: false
            )
            cell.dateLabel.text = fixture.time
            cell.accountIndicator.isHidden = true
            cell.accessibilityIdentifier = "interface.themePreview.chats.row.\(index)"
            cell.accessibilityLabel = "\(fixture.name), \(fixture.message), \(fixture.time)"
            contentStack.addArrangedSubview(AppearanceThemeChatListPreviewRow(cell: cell))
            if index < fixtures.count - 1 {
                contentStack.addArrangedSubview(makeSeparator())
            }
        }
    }

    private func makeSeparator() -> UIView {
        let container = UIView()
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 0.5),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 96),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
}

private final class AppearanceThemeChatListPreviewRow: UIView {
    private let cell: ChatListTableViewCell

    init(cell: ChatListTableViewCell) {
        self.cell = cell
        super.init(frame: .zero)
        addSubview(cell)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 84)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cell.frame = bounds
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }
}

private final class AppearanceThemePagedPreviewView: UIView, UIScrollViewDelegate {
    private let pagesScrollView = UIScrollView()
    private let pagesStack = UIStackView()
    private let conversationPage = AppearanceThemeConversationPreviewPage()
    private let chatsPage = AppearanceThemeChatsPreviewPage()
    private let pageControl = UIPageControl()
    private var currentDocument: AppearanceSettingsDocument?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        pagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        pagesScrollView.isPagingEnabled = true
        pagesScrollView.showsHorizontalScrollIndicator = false
        pagesScrollView.bounces = true
        pagesScrollView.contentInsetAdjustmentBehavior = .never
        pagesScrollView.delegate = self
        pagesScrollView.accessibilityIdentifier = "interface.themePreview.pages"
        pagesStack.translatesAutoresizingMaskIntoConstraints = false
        pagesStack.axis = .horizontal
        pagesStack.spacing = 0
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.numberOfPages = 2
        pageControl.currentPage = 0
        pageControl.hidesForSinglePage = true
        pageControl.backgroundStyle = .prominent
        pageControl.accessibilityIdentifier = "interface.themePreview.pageControl"
        pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
        addSubview(pagesScrollView)
        pagesScrollView.addSubview(pagesStack)
        pagesStack.addArrangedSubview(conversationPage)
        pagesStack.addArrangedSubview(chatsPage)
        addSubview(pageControl)
        NSLayoutConstraint.activate([
            pagesScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pagesScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pagesScrollView.topAnchor.constraint(equalTo: topAnchor),
            pagesScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pagesStack.leadingAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.leadingAnchor),
            pagesStack.trailingAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.trailingAnchor),
            pagesStack.topAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.topAnchor),
            pagesStack.bottomAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.bottomAnchor),
            pagesStack.heightAnchor.constraint(equalTo: pagesScrollView.frameLayoutGuide.heightAnchor),
            conversationPage.widthAnchor.constraint(equalTo: pagesScrollView.frameLayoutGuide.widthAnchor),
            chatsPage.widthAnchor.constraint(equalTo: pagesScrollView.frameLayoutGuide.widthAnchor),
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -84)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(document: AppearanceSettingsDocument, traits: UITraitCollection) {
        currentDocument = document
        let snapshot = AppearanceResolver.resolve(
            document: document,
            traitStyle: traits.userInterfaceStyle
        )
        conversationPage.configure(document: document, snapshot: snapshot)
        chatsPage.configure(snapshot: snapshot)
        tintColor = snapshot.accent.uiColor
        pageControl.currentPageIndicatorTintColor = snapshot.accent.uiColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection),
              let currentDocument else { return }
        configure(document: currentDocument, traits: traitCollection)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        pageControl.currentPage = min(
            max(Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()), 0),
            pageControl.numberOfPages - 1
        )
    }

    @objc private func pageChanged() {
        let offset = CGPoint(
            x: CGFloat(pageControl.currentPage) * pagesScrollView.bounds.width,
            y: 0
        )
        pagesScrollView.setContentOffset(offset, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

final class AppearanceThemePreviewViewController: BaseViewController {
    private var document: AppearanceSettingsDocument
    private let theme: AppearanceTheme
    private let preview = AppearanceThemePagedPreviewView()
    private let applyGlass = UIVisualEffectView()
    private let applyButton = UIButton(type: .system)

    init(document: AppearanceSettingsDocument, theme: AppearanceTheme) {
        self.document = document
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = theme.name
        view.backgroundColor = .systemBackground
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationAppearance.shadowColor = .clear
        navigationItem.standardAppearance = navigationAppearance
        navigationItem.scrollEdgeAppearance = navigationAppearance
        navigationItem.compactAppearance = navigationAppearance
        preview.translatesAutoresizingMaskIntoConstraints = false
        applyGlass.translatesAutoresizingMaskIntoConstraints = false
        applyGlass.isUserInteractionEnabled = false
        applyGlass.accessibilityIdentifier = "interface.themePreview.applyGlass"
        XabberGlassStyle.applySurface(
            to: applyGlass,
            role: .sheet,
            cornerStyle: .capsule,
            interactive: true
        )
        applyButton.configuration = makeApplyButtonConfiguration()
        applyButton.tintColor = .label
        applyButton.backgroundColor = .clear
        applyButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        applyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        applyButton.addTarget(self, action: #selector(applyTheme), for: .touchUpInside)
        applyButton.accessibilityIdentifier = "interface.themePreview.apply"
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        view.addSubview(applyGlass)
        view.addSubview(applyButton)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: view.topAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            applyButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            applyButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            applyButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            applyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            applyGlass.leadingAnchor.constraint(equalTo: applyButton.leadingAnchor),
            applyGlass.trailingAnchor.constraint(equalTo: applyButton.trailingAnchor),
            applyGlass.topAnchor.constraint(equalTo: applyButton.topAnchor),
            applyGlass.bottomAnchor.constraint(equalTo: applyButton.bottomAnchor)
        ])
        refreshPreview()
    }

    private func makeApplyButtonConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Apply for All Chats"
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 15,
            leading: 20,
            bottom: 15,
            trailing: 20
        )
        return configuration
    }

    private func refreshPreview() {
        var profile = document.profile
        profile.apply(
            theme: theme,
            preserveWallpaper: CommonConfigManager.shared.config.locked_background.isNotEmpty
        )
        var previewDocument = document
        previewDocument.profile = profile
        preview.configure(document: previewDocument, traits: traitCollection)
    }

    @objc private func applyTheme() {
        document.profile.apply(
            theme: theme,
            preserveWallpaper: CommonConfigManager.shared.config.locked_background.isNotEmpty
        )
        do {
            _ = try AppearanceCoordinator.shared.commit(document)
            navigationController?.popToViewController(
                navigationController?.viewControllers.first(where: { $0 is InterfaceSettingsViewController }) ?? self,
                animated: true
            )
        } catch {
            let alert = UIAlertController(title: "Couldn’t apply theme", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

final class AppearanceThemeEditorViewController: BaseViewController, UIColorPickerViewControllerDelegate {
    private enum EditorTab: String {
        case background = "Background"
        case accent = "Accent"
        case messages = "Messages"
    }

    private var document: AppearanceSettingsDocument
    private var theme: AppearanceTheme
    private let original: AppearanceTheme
    private let preview = AppearancePreviewView()
    private let tabKinds: [EditorTab]
    private let tabs: UISegmentedControl

    init(document: AppearanceSettingsDocument, theme: AppearanceTheme) {
        self.document = document
        self.theme = theme
        original = theme
        tabKinds = CommonConfigManager.shared.config.locked_background.isEmpty
            ? [.background, .accent, .messages]
            : [.accent, .messages]
        tabs = UISegmentedControl(items: tabKinds.map(\.rawValue))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            theme = original
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit \(theme.name)"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(save)
        )
        tabs.selectedSegmentIndex = 0
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        preview.translatesAutoresizingMaskIntoConstraints = false
        let changeButton = UIButton(type: .system)
        changeButton.configuration = .filled()
        changeButton.addTarget(self, action: #selector(changeCurrentValue), for: .touchUpInside)
        changeButton.accessibilityIdentifier = "interface.themeEditor.change"
        changeButton.tag = 100
        let stack = UIStackView(arrangedSubviews: [tabs, preview, changeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            preview.heightAnchor.constraint(equalToConstant: 390)
        ])
        updateButtonTitle()
        refreshPreview()
    }

    @objc private func tabChanged() { updateButtonTitle() }

    private func updateButtonTitle() {
        guard let button = view.viewWithTag(100) as? UIButton else { return }
        switch tabKinds[tabs.selectedSegmentIndex] {
        case .background: button.configuration?.title = "Choose Gradient"
        case .accent: button.configuration?.title = "Choose Accent"
        case .messages: button.configuration?.title = "Choose Message Colors"
        }
    }

    @objc private func changeCurrentValue() {
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.supportsAlpha = false
        let palette = theme.palette(for: traitCollection.userInterfaceStyle)
        switch tabKinds[tabs.selectedSegmentIndex] {
        case .background: picker.selectedColor = palette.backgroundStops.first?.uiColor ?? .systemBackground
        case .accent: picker.selectedColor = palette.accent.uiColor
        case .messages: picker.selectedColor = palette.outgoingBubble.uiColor
        }
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        let color = AppearanceColor(uiColor: viewController.selectedColor)
        switch tabKinds[tabs.selectedSegmentIndex] {
        case .background:
            theme.lightPalette.backgroundStops = [color, theme.lightPalette.backgroundStops.last ?? color]
            theme.darkPalette.backgroundStops = [color.darken(0.58), color.darken(0.32)]
            theme.wallpaper = .gradient(stops: theme.lightPalette.backgroundStops, pattern: nil, intensity: 100)
        case .accent:
            theme.lightPalette.accent = color
            theme.darkPalette.accent = color
            theme.lightPalette.replyAccent = color
            theme.darkPalette.replyAccent = color
        case .messages:
            theme.lightPalette.outgoingBubble = color
            theme.darkPalette.outgoingBubble = color.darken(0.55)
        }
        refreshPreview()
    }

    private func refreshPreview() {
        var profile = document.profile
        profile.apply(
            theme: theme,
            preserveWallpaper: CommonConfigManager.shared.config.locked_background.isNotEmpty
        )
        var updated = document
        updated.profile = profile
        if let index = updated.customThemes.firstIndex(where: { $0.id == theme.id }) {
            updated.customThemes[index] = theme
        }
        preview.configure(document: updated, traits: traitCollection)
        navigationItem.rightBarButtonItem?.isEnabled = theme != original
    }

    @objc private func save() { persist(theme) }

    private func persist(_ value: AppearanceTheme) {
        do {
            let store = AppearanceSettingsStore() ?? AppearanceSettingsStore(defaults: .standard, defaultAccentHex: "#007AFF")
            _ = try store.updateCustomTheme(value)
            AppearanceCoordinator.shared.reloadAndApply()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(title: "Couldn’t save theme", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

final class AppearanceWallpaperViewController: AppearanceDraftViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, PHPickerViewControllerDelegate {
    private let scrollView = UIScrollView()
    private let collectionView: UICollectionView
    private let activity = UIActivityIndicatorView(style: .medium)
    private let uploader: AppearanceCloudWallpaperClient
    private var pendingUploadAsset: AppearanceProcessedWallpaperAsset?
    private var builtInGridHeightConstraint: NSLayoutConstraint?
    private let builtIns = ["None", "Honeycomb", "Aliens", "Summer", "Cats", "Flowers", "Flowers-daisy", "Hearts"]

    init(document: AppearanceSettingsDocument, uploader: AppearanceCloudWallpaperClient = XabberAppearanceCloudWallpaperClient()) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        self.uploader = uploader
        super.init(document: document, title: "Chat Wallpaper")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.isScrollEnabled = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "interface.wallpaper.builtInGrid"
        collectionView.register(AppearanceWallpaperCell.self, forCellWithReuseIdentifier: AppearanceWallpaperCell.reuseIdentifier)
        let colorButton = makeAction(
            title: "Color",
            symbol: "paintpalette.fill",
            accessibilityIdentifier: "interface.wallpaper.setColor",
            selector: #selector(setColor)
        )
        let photoButton = makeAction(
            title: "Gallery",
            symbol: "photo.on.rectangle",
            accessibilityIdentifier: "interface.wallpaper.chooseFromIPhone",
            selector: #selector(choosePhoto)
        )
        activity.hidesWhenStopped = true
        let actions = UIStackView(arrangedSubviews: [colorButton, photoButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.alignment = .center
        actions.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [preview, collectionView, actions, activity])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        let gridHeight = collectionView.heightAnchor.constraint(equalToConstant: 0)
        builtInGridHeightConstraint = gridHeight
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
            preview.heightAnchor.constraint(equalToConstant: 250),
            gridHeight
        ])
        updatePreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBuiltInGridHeightIfNeeded()
    }

    private func makeAction(
        title: String,
        symbol: String,
        accessibilityIdentifier: String,
        selector: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = .bordered()
        button.configuration?.title = title
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.imagePadding = 6
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.accessibilityIdentifier = accessibilityIdentifier
        return button
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { builtIns.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let name = builtIns[indexPath.item]
        let selected: Bool
        if name == "None", case .none = draft.profile.wallpaper { selected = true }
        else if case .builtIn(let current) = draft.profile.wallpaper { selected = current == name }
        else { selected = false }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AppearanceWallpaperCell.reuseIdentifier, for: indexPath) as! AppearanceWallpaperCell
        cell.configure(
            name: name,
            selected: selected,
            accent: view.tintColor,
            document: builtInPreviewDocument(for: name)
        )
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let name = builtIns[indexPath.item]
        draft.profile.wallpaper = name == "None" ? .none : .builtIn(name: name)
        collectionView.reloadData()
        updatePreview()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = wallpaperTileWidth(for: collectionView.bounds.width)
        return CGSize(width: width, height: width * 1.25)
    }

    private func wallpaperTileWidth(for availableWidth: CGFloat) -> CGFloat {
        floor(max(0, availableWidth - 20) / 3)
    }

    private func updateBuiltInGridHeightIfNeeded() {
        let tileWidth = wallpaperTileWidth(for: collectionView.bounds.width)
        guard tileWidth > 0 else { return }
        let rows = ceil(CGFloat(builtIns.count) / 3)
        let height = rows * tileWidth * 1.25 + max(0, rows - 1) * 10
        guard abs((builtInGridHeightConstraint?.constant ?? 0) - height) > 0.5 else { return }
        builtInGridHeightConstraint?.constant = height
        collectionView.collectionViewLayout.invalidateLayout()
    }

    @objc private func setColor() {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func choosePhoto() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        activity.startAnimating()
        navigationItem.rightBarButtonItem?.isEnabled = false
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            guard let self else { return }
            guard error == nil, let image = object as? UIImage else {
                DispatchQueue.main.async { self.uploadFailed(error ?? AppearanceWallpaperProcessingError.invalidImage) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let asset = try AppearanceWallpaperPhotoProcessor.process(image)
                    DispatchQueue.main.async { self.upload(asset) }
                } catch {
                    DispatchQueue.main.async { self.uploadFailed(error) }
                }
            }
        }
    }

    private func upload(_ asset: AppearanceProcessedWallpaperAsset) {
        pendingUploadAsset = asset
        guard let owner = selectCloudOwner() else {
            uploadFailed(AppearanceCloudWallpaperError.galleryUnavailable)
            return
        }
        let request = AppearanceCloudWallpaperUploadRequest(
            owner: owner.owner,
            galleryIdentity: owner.galleryIdentity,
            data: asset.data,
            filename: asset.filename,
            mimeType: asset.mimeType,
            metadata: ["purpose": "chat_wallpaper", "schema": "1", "context": "file"]
        )
        uploader.upload(request: request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reference):
                self.pendingUploadAsset = nil
                self.activity.stopAnimating()
                self.draft.profile.wallpaper = .cloud(reference: reference, blurred: false, motion: false)
                self.collectionView.reloadData()
                self.updatePreview()
            case .failure(let error):
                self.uploadFailed(error)
            }
        }
    }

    private func selectCloudOwner() -> AppearanceCloudOwnerCandidate? {
        let candidates = AccountManager.shared.users.map { account -> AppearanceCloudOwnerCandidate in
            AppearanceCloudOwnerCandidate.fromLoadedEnabledAccount(
                owner: account.jid,
                isPremium: SubscribtionsManager.shared.hasActiveSubsription(for: account.jid),
                requestContext: CloudStorageGalleryRequestContext.resolve(owner: account.jid)
            )
        }
        return AppearanceCloudOwnerSelector.select(from: candidates)
    }

    /// Built-in artwork is transparent. Render it through the same backdrop as
    /// a chat, while retaining a manually selected color/gradient underneath.
    func builtInPreviewDocument(for name: String) -> AppearanceSettingsDocument {
        var tileDocument = document
        tileDocument.profile = draft.profile
        let snapshot = AppearanceResolver.resolve(
            document: tileDocument,
            traitStyle: traitCollection.userInterfaceStyle
        )
        let backgroundStops: [AppearanceColor]
        if case .gradient(let stops, _, _) = draft.profile.wallpaper,
           !stops.isEmpty {
            backgroundStops = stops
        } else {
            backgroundStops = snapshot.palette.backgroundStops
        }
        tileDocument.profile.wallpaper = .gradient(
            stops: backgroundStops,
            pattern: name == "None" ? nil : name.lowercased(),
            intensity: 10
        )
        return tileDocument
    }

    private func uploadFailed(_ error: Error) {
        activity.stopAnimating()
        refreshSetButton()
        let alert = UIAlertController(title: "Couldn’t upload wallpaper", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.pendingUploadAsset = nil
        })
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            guard let self else { return }
            if let asset = self.pendingUploadAsset {
                self.activity.startAnimating()
                self.upload(asset)
            } else {
                self.choosePhoto()
            }
        })
        present(alert, animated: true)
    }

}

extension AppearanceWallpaperViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        let color = AppearanceColor(uiColor: viewController.selectedColor)
        draft.profile.wallpaper = .gradient(
            stops: [color, color.lighten(0.28)],
            pattern: nil,
            intensity: 100
        )
        updatePreview()
        collectionView.reloadData()
    }
}

final class AppearanceWallpaperCell: UICollectionViewCell {
    static let reuseIdentifier = "AppearanceWallpaperCell"
    private let backdrop = ChatBackgroundBackdropView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isUserInteractionEnabled = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.textColor = .white
        nameLabel.shadowColor = UIColor.black.withAlphaComponent(0.6)
        nameLabel.shadowOffset = CGSize(width: 0, height: 1)
        contentView.addSubview(backdrop)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        name: String,
        selected: Bool,
        accent: UIColor,
        document: AppearanceSettingsDocument
    ) {
        backdrop.configure(document: document)
        backdrop.accessibilityIdentifier = "interface.wallpaper.backdrop.\(name)"
        nameLabel.text = name
        contentView.layer.borderWidth = selected ? 3 : 0
        contentView.layer.borderColor = accent.cgColor
        accessibilityLabel = name
        accessibilityValue = selected ? "Selected" : nil
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityIdentifier = "interface.wallpaper.\(name)"
    }
}

private extension AppearanceColor {
    init(uiColor: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            uiColor.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    func darken(_ amount: Double) -> AppearanceColor {
        AppearanceColor(red: red * amount, green: green * amount, blue: blue * amount, alpha: alpha)
    }

    func lighten(_ amount: Double) -> AppearanceColor {
        AppearanceColor(
            red: red + (1 - red) * amount,
            green: green + (1 - green) * amount,
            blue: blue + (1 - blue) * amount,
            alpha: alpha
        )
    }
}

private extension AppearanceAvatarMask {
    var systemSymbolName: String {
        switch self {
        case .circle: return "circle.fill"
        case .rounded: return "app.fill"
        case .square: return "square.fill"
        case .roundedSquare: return "squareshape.fill"
        case .star: return "star.fill"
        case .pentagon: return "pentagon.fill"
        case .octagon: return "octagon.fill"
        }
    }
}
