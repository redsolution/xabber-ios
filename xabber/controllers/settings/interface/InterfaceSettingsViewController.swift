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
        case mode
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
        case .mode: return .mode
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
        case .mode: return profile.interfaceStyle.displayName
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
        case .mode: return "Appearance Mode"
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
        case .mode: return "interface.settings.mode"
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
        case .mode:
            pushEditor(AppearanceModeViewController(document: document))
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
                traits: traits
            )
            control.addAction(UIAction { [weak self] _ in self?.onThemeTap?(theme) }, for: .touchUpInside)
            themesStack.addArrangedSubview(control)
        }
    }
}

private final class AppearanceThemeMiniControl: UIControl {
    private let gradient = AppearanceGradientView()
    private let incoming = UIView()
    private let outgoing = UIView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        gradient.translatesAutoresizingMaskIntoConstraints = false
        incoming.translatesAutoresizingMaskIntoConstraints = false
        outgoing.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        incoming.layer.cornerRadius = 9
        outgoing.layer.cornerRadius = 9
        gradient.isUserInteractionEnabled = false
        incoming.isUserInteractionEnabled = false
        outgoing.isUserInteractionEnabled = false
        nameLabel.isUserInteractionEnabled = false
        nameLabel.font = .preferredFont(forTextStyle: .caption2)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        addSubview(gradient)
        addSubview(incoming)
        addSubview(outgoing)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 86),
            gradient.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradient.trailingAnchor.constraint(equalTo: trailingAnchor),
            gradient.topAnchor.constraint(equalTo: topAnchor),
            gradient.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    func configure(theme: AppearanceTheme, selected: Bool, accent: UIColor, traits: UITraitCollection) {
        let palette = theme.palette(for: traits.userInterfaceStyle)
        gradient.colors = palette.backgroundStops.map(\.uiColor)
        incoming.backgroundColor = palette.incomingBubble.uiColor
        outgoing.backgroundColor = palette.outgoingBubble.uiColor
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
    private let backgroundView = AppearanceGradientView()
    private let wallpaperImageView = UIImageView()
    private let contentStack = UIStackView()
    private var currentDocument: AppearanceSettingsDocument?

    var showsChatList = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperImageView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperImageView.contentMode = .scaleAspectFill
        wallpaperImageView.alpha = 0.18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 8
        addSubview(backgroundView)
        addSubview(wallpaperImageView)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            wallpaperImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            wallpaperImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            wallpaperImageView.topAnchor.constraint(equalTo: topAnchor),
            wallpaperImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        animated: Bool = true
    ) {
        currentDocument = document
        let changes = {
            let snapshot = AppearanceResolver.resolve(document: document, traitStyle: traits.userInterfaceStyle)
            self.backgroundView.colors = snapshot.palette.backgroundStops.map(\.uiColor)
            self.configureWallpaper(document.profile.wallpaper)
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

    private func configureWallpaper(_ wallpaper: AppearanceWallpaper) {
        wallpaperImageView.layer.filters = nil
        wallpaperImageView.transform = .identity
        wallpaperImageView.alpha = 0.18
        wallpaperImageView.tintColor = nil
        switch wallpaper {
        case .none:
            wallpaperImageView.image = nil
        case .gradient(let stops, let pattern, let intensity):
            if !stops.isEmpty {
                backgroundView.colors = stops.map(\.uiColor)
            }
            wallpaperImageView.image = pattern.flatMap { UIImage(named: $0.lowercased()) }
            wallpaperImageView.alpha = CGFloat(intensity) / 100
        case .builtIn(let name):
            wallpaperImageView.image = UIImage(named: name)
        case .cloud(let reference, let blurred, let motion):
            wallpaperImageView.image = AppearanceWallpaperCache().image(for: reference)
            wallpaperImageView.alpha = 1
            wallpaperImageView.layer.filters = blurred ? [CIFilter(name: "CIGaussianBlur") as Any] : nil
            wallpaperImageView.transform = motion && !UIAccessibility.isReduceMotionEnabled
                ? CGAffineTransform(scaleX: 1.08, y: 1.08)
                : .identity
        }
    }

    private func configureContent(snapshot: ResolvedAppearanceSnapshot) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if showsChatList {
            for index in 0..<4 {
                contentStack.addArrangedSubview(makeChatRow(index: index, snapshot: snapshot))
            }
        } else {
            let incoming = makeBubble(
                "Good morning! 👋",
                fill: snapshot.palette.incomingBubble.uiColor,
                text: snapshot.palette.incomingText.uiColor,
                radius: snapshot.profile.bubbleRadius,
                outgoing: false,
                font: AppearanceTypography.font(textStyle: .body, appearanceSize: snapshot.profile.textSize)
            )
            let outgoing = makeBubble(
                "It’s morning in Tokyo 😎  23:20 ✓✓",
                fill: snapshot.palette.outgoingBubble.uiColor,
                text: snapshot.palette.outgoingText.uiColor,
                radius: snapshot.profile.bubbleRadius,
                outgoing: true,
                font: AppearanceTypography.font(textStyle: .body, appearanceSize: snapshot.profile.textSize)
            )
            contentStack.addArrangedSubview(incoming)
            contentStack.addArrangedSubview(outgoing)
        }
    }

    private func makeBubble(
        _ text: String,
        fill: UIColor,
        text textColor: UIColor,
        radius: Int,
        outgoing: Bool,
        font: UIFont
    ) -> UIView {
        let container = UIView()
        let bubble = AppearanceInsetLabel()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.text = text
        bubble.font = font
        bubble.adjustsFontForContentSizeCategory = true
        bubble.textColor = textColor
        bubble.backgroundColor = fill
        bubble.numberOfLines = 2
        bubble.layer.cornerRadius = CGFloat(radius)
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        container.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: container.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.88),
            bubble.leadingAnchor.constraint(
                equalTo: outgoing ? container.leadingAnchor : container.leadingAnchor,
                constant: outgoing ? 58 : 0
            ),
            bubble.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: outgoing ? 0 : -58
            ),
            bubble.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        bubble.textInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return container
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

private final class AppearanceInsetLabel: UILabel {
    var textInsets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
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

private final class AppearanceModeViewController: AppearanceDraftViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(document: AppearanceSettingsDocument) {
        super.init(document: document, title: "Appearance Mode")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AppearanceInterfaceStyle.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let value = AppearanceInterfaceStyle.allCases[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = value.displayName
        cell.accessoryType = draft.profile.interfaceStyle == value ? .checkmark : .none
        cell.accessibilityIdentifier = "interface.mode.\(value.rawValue)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        draft.profile.interfaceStyle = AppearanceInterfaceStyle.allCases[indexPath.row]
        tableView.reloadData()
        updatePreview()
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
        updatePreview()
    }

    @objc private func sliderChanged() {
        let index = min(max(Int(slider.value.rounded()), 0), AppearanceTextSize.fixedCases.count - 1)
        slider.setValue(Float(index), animated: false)
        if !systemSwitch.isOn {
            draft.profile.textSize = AppearanceTextSize.fixedCases[index]
            updatePreview()
        }
        refreshControls()
    }

    private func refreshControls() {
        slider.isEnabled = !systemSwitch.isOn
        sizeLabel.text = systemSwitch.isOn ? "System" : AppearanceTextSize.fixedCases[Int(slider.value.rounded())].displayName
    }
}

private final class AppearanceBubbleViewController: AppearanceDraftViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collectionView: UICollectionView
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
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(document: document, title: "Message Bubbles")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppearanceOptionCell.self, forCellWithReuseIdentifier: AppearanceOptionCell.reuseIdentifier)
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
        let stack = UIStackView(arrangedSubviews: [preview, collectionView, radiusRow])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            preview.heightAnchor.constraint(equalToConstant: 250),
            collectionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        radiusChanged()
        updatePreview()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(entitlementChanged),
            name: .premiumEntitlementDidChange,
            object: nil
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        policy.visibleBubbleStyles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let value = policy.visibleBubbleStyles[indexPath.item]
        let locked = !policy.canSelect(value, currentlyApplied: document.profile.bubbleStyle)
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AppearanceOptionCell.reuseIdentifier, for: indexPath) as! AppearanceOptionCell
        cell.configureBubble(
            title: value.displayName,
            style: value,
            selected: value == draft.profile.bubbleStyle,
            locked: locked,
            accent: AppearanceResolver.resolve(document: document, traitStyle: traitCollection.userInterfaceStyle).accent.uiColor
        )
        cell.accessibilityIdentifier = "interface.bubble.\(value.rawValue)"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let value = policy.visibleBubbleStyles[indexPath.item]
        guard policy.canSelect(value, currentlyApplied: document.profile.bubbleStyle) else {
            SubscribtionsPresenter().present(animated: true, parent: self)
            return
        }
        draft.profile.bubbleStyle = value
        collectionView.reloadData()
        updatePreview()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: floor((collectionView.bounds.width - 12) / 2), height: 72)
    }

    @objc private func radiusChanged() {
        let value = min(max(Int(radiusSlider.value.rounded()), 0), 16)
        radiusSlider.setValue(Float(value), animated: false)
        radiusLabel.text = "Radius \(value)"
        draft.profile.bubbleRadius = value
        updatePreview()
    }

    @objc private func entitlementChanged() {
        collectionView.reloadData()
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

    func configureBubble(
        title: String,
        style: AppearanceBubbleStyle,
        selected: Bool,
        locked: Bool,
        accent: UIColor
    ) {
        configure(
            title: title,
            symbol: "message.fill",
            selected: selected,
            locked: locked,
            accent: accent
        )
        symbolView.image = AppearanceBubbleGlyph.image(for: style)
    }
}

private enum AppearanceBubbleGlyph {
    static func image(for style: AppearanceBubbleStyle) -> UIImage {
        let size = CGSize(width: 34, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(2)
            let body = UIBezierPath(
                roundedRect: CGRect(x: 2, y: 2, width: 27, height: 21),
                cornerRadius: style == .wedge ? 3 : 8
            )
            if style == .transparent {
                body.stroke()
            } else {
                body.fill()
            }
            switch style {
            case .noTail:
                break
            case .smooth, .bubble, .wedge:
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 23, y: 20))
                tail.addLine(to: CGPoint(x: 33, y: 26))
                tail.addLine(to: CGPoint(x: 28, y: style == .wedge ? 12 : 21))
                tail.close()
                style == .transparent ? tail.stroke() : tail.fill()
            case .bubbles:
                UIBezierPath(ovalIn: CGRect(x: 27, y: 20, width: 6, height: 6)).fill()
                UIBezierPath(ovalIn: CGRect(x: 24, y: 17, width: 4, height: 4)).fill()
            case .curvy:
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 24, y: 18))
                tail.addCurve(
                    to: CGPoint(x: 33, y: 25),
                    controlPoint1: CGPoint(x: 26, y: 24),
                    controlPoint2: CGPoint(x: 29, y: 25)
                )
                tail.addCurve(
                    to: CGPoint(x: 28, y: 15),
                    controlPoint1: CGPoint(x: 29, y: 22),
                    controlPoint2: CGPoint(x: 28, y: 18)
                )
                tail.close()
                tail.fill()
            case .stripes:
                for offset in stride(from: 0, through: 8, by: 4) {
                    let stripe = UIBezierPath(
                        roundedRect: CGRect(x: 25 + CGFloat(offset), y: 17 + CGFloat(offset) * 0.7, width: 2, height: 8),
                        cornerRadius: 1
                    )
                    stripe.fill()
                }
            case .transparent:
                let tail = UIBezierPath()
                tail.move(to: CGPoint(x: 25, y: 20))
                tail.addLine(to: CGPoint(x: 32, y: 25))
                tail.stroke()
            }
        }.withRenderingMode(.alwaysTemplate)
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

final class AppearanceThemePreviewViewController: BaseViewController {
    private var document: AppearanceSettingsDocument
    private let theme: AppearanceTheme
    private let preview = AppearancePreviewView()
    private let modeControl = UISegmentedControl(items: ["Chat", "Chats"])

    init(document: AppearanceSettingsDocument, theme: AppearanceTheme) {
        self.document = document
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = theme.name
        view.backgroundColor = .systemGroupedBackground
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.accessibilityIdentifier = "interface.themePreview.mode"
        preview.translatesAutoresizingMaskIntoConstraints = false
        let applyButton = UIButton(type: .system)
        applyButton.configuration = .filled()
        applyButton.configuration?.title = "Apply"
        applyButton.configuration?.cornerStyle = .capsule
        applyButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        applyButton.addTarget(self, action: #selector(applyTheme), for: .touchUpInside)
        applyButton.accessibilityIdentifier = "interface.themePreview.apply"
        let stack = UIStackView(arrangedSubviews: [modeControl, preview, applyButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            preview.heightAnchor.constraint(equalToConstant: 430),
            applyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
        refreshPreview()
    }

    @objc private func modeChanged() {
        preview.showsChatList = modeControl.selectedSegmentIndex == 1
        refreshPreview()
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

private final class AppearanceWallpaperViewController: AppearanceDraftViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, PHPickerViewControllerDelegate {
    private let collectionView: UICollectionView
    private let activity = UIActivityIndicatorView(style: .medium)
    private let blurSwitch = UISwitch()
    private let motionSwitch = UISwitch()
    private let uploader: AppearanceCloudWallpaperClient
    private var pendingUploadAsset: AppearanceProcessedWallpaperAsset?
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
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppearanceWallpaperCell.self, forCellWithReuseIdentifier: AppearanceWallpaperCell.reuseIdentifier)
        let colorButton = makeAction(title: "Set a Color", symbol: "paintpalette.fill", selector: #selector(setColor))
        let photoButton = makeAction(title: "Choose from Photos", symbol: "photo.on.rectangle", selector: #selector(choosePhoto))
        activity.hidesWhenStopped = true
        let actions = UIStackView(arrangedSubviews: [colorButton, photoButton, activity])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.alignment = .center
        let blurLabel = UILabel()
        blurLabel.text = "Blurred"
        let motionLabel = UILabel()
        motionLabel.text = "Motion"
        blurSwitch.addTarget(self, action: #selector(effectChanged), for: .valueChanged)
        motionSwitch.addTarget(self, action: #selector(effectChanged), for: .valueChanged)
        blurSwitch.accessibilityIdentifier = "interface.wallpaper.blurred"
        motionSwitch.accessibilityIdentifier = "interface.wallpaper.motion"
        let effects = UIStackView(arrangedSubviews: [blurLabel, blurSwitch, UIView(), motionLabel, motionSwitch])
        effects.axis = .horizontal
        effects.spacing = 10
        effects.alignment = .center
        let stack = UIStackView(arrangedSubviews: [preview, actions, effects, collectionView])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            preview.heightAnchor.constraint(equalToConstant: 250),
            collectionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
        updatePreview()
        refreshEffects()
    }

    private func makeAction(title: String, symbol: String, selector: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = .bordered()
        button.configuration?.title = title
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.imagePadding = 6
        button.addTarget(self, action: selector, for: .touchUpInside)
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
        cell.configure(name: name, selected: selected, accent: view.tintColor)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let name = builtIns[indexPath.item]
        draft.profile.wallpaper = name == "None" ? .none : .builtIn(name: name)
        collectionView.reloadData()
        refreshEffects()
        updatePreview()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = floor((collectionView.bounds.width - 20) / 3)
        return CGSize(width: width, height: width * 1.25)
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
                self.refreshEffects()
                self.updatePreview()
            case .failure(let error):
                self.uploadFailed(error)
            }
        }
    }

    private func selectCloudOwner() -> AppearanceCloudOwnerCandidate? {
        let candidates = AccountManager.shared.users.map { account -> AppearanceCloudOwnerCandidate in
            let configuration = AccountGalleryConfiguration(owner: account.jid)
            let ready: Bool
            if case .ready = account.cloudStorage.availabilityRelay.value { ready = true } else { ready = false }
            return AppearanceCloudOwnerCandidate(
                owner: account.jid,
                galleryIdentity: configuration.currentGalleryIdentity,
                isEnabled: AccountManager.shared.activeUsers.value.contains(account.jid),
                isPremium: SubscribtionsManager.shared.hasActiveSubsription(for: account.jid),
                isReady: ready
            )
        }
        return AppearanceCloudOwnerSelector.select(from: candidates)
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

    @objc private func effectChanged() {
        guard case .cloud(let reference, _, _) = draft.profile.wallpaper else { return }
        let motion = motionSwitch.isOn && !UIAccessibility.isReduceMotionEnabled
        draft.profile.wallpaper = .cloud(
            reference: reference,
            blurred: blurSwitch.isOn,
            motion: motion
        )
        updatePreview()
    }

    private func refreshEffects() {
        if case .cloud(_, let blurred, let motion) = draft.profile.wallpaper {
            blurSwitch.isEnabled = true
            blurSwitch.isOn = blurred
            motionSwitch.isEnabled = !UIAccessibility.isReduceMotionEnabled
            motionSwitch.isOn = motion && !UIAccessibility.isReduceMotionEnabled
        } else {
            blurSwitch.isEnabled = false
            blurSwitch.isOn = false
            motionSwitch.isEnabled = false
            motionSwitch.isOn = false
        }
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
        refreshEffects()
        updatePreview()
        collectionView.reloadData()
    }
}

private final class AppearanceWallpaperCell: UICollectionViewCell {
    static let reuseIdentifier = "AppearanceWallpaperCell"
    private let imageView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .secondarySystemGroupedBackground
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        contentView.addSubview(imageView)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, selected: Bool, accent: UIColor) {
        imageView.image = name == "None" ? nil : UIImage(named: name)
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
