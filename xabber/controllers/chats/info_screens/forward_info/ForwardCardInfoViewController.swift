import UIKit
import Kingfisher

/// A message-scoped presentation snapshot, separate from the live contact or
/// group settings screens. Displaying a card never changes the local roster.
final class ForwardCardInfoViewController: UIViewController {
    private(set) var snapshot: ForwardCardSnapshot
    private(set) var primaryAction: ForwardCardPrimaryAction?
    private let onAction: (ForwardCardAction) -> Void
    private let onOpenGroup: () -> Void

    var refreshTask: Task<Void, Never>?

    let headerView = InfoScreenHeaderView(frame: .zero)
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var primaryActionButton: UIButton?
    private(set) var sourceGroupButton: UIButton?

    private enum Section { case sourceGroup, details, primaryAction }

    private var sections: [Section] {
        var result: [Section] = []
        if sourceGroupButton != nil { result.append(.sourceGroup) }
        if !details.isEmpty { result.append(.details) }
        if primaryActionButton != nil { result.append(.primaryAction) }
        return result
    }

    private struct Detail {
        let title: String
        let value: String
        let accessibilityIdentifier: String
    }

    private var details: [Detail] {
        var result: [Detail] = []
        if let jid = nonempty(snapshot.jid) {
            result.append(Detail(
                title: L10n.text("forward_card__field__xmpp_id", fallback: "XMPP ID"),
                value: jid, accessibilityIdentifier: "forward_card_jid"
            ))
        }
        if let badge = nonempty(snapshot.badge) {
            result.append(Detail(
                title: L10n.text("forward_card__field__badge", fallback: "Badge"),
                value: badge, accessibilityIdentifier: "forward_card_badge"
            ))
        }
        if snapshot.kind == .group, let privacy = snapshot.privacy {
            result.append(Detail(
                title: L10n.text("forward_card__field__privacy", fallback: "Privacy"),
                value: privacyTitle(privacy), accessibilityIdentifier: "forward_card_privacy"
            ))
        }
        return result
    }

    init(snapshot: ForwardCardSnapshot, primaryAction: ForwardCardPrimaryAction?,
         onAction: @escaping (ForwardCardAction) -> Void,
         onOpenGroup: @escaping () -> Void) {
        self.snapshot = snapshot
        self.primaryAction = primaryAction
        self.onAction = onAction
        self.onOpenGroup = onOpenGroup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func makeNavigationController(
        snapshot: ForwardCardSnapshot, primaryAction: ForwardCardPrimaryAction?,
        onAction: @escaping (ForwardCardAction) -> Void,
        onOpenGroup: @escaping () -> Void
    ) -> UINavigationController {
        let controller = ForwardCardInfoViewController(
            snapshot: snapshot, primaryAction: primaryAction,
            onAction: onAction, onOpenGroup: onOpenGroup
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = false
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "forward_card_sheet"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.text("common__action__done", fallback: "Done"),
            style: .done, target: self, action: #selector(closeSheet)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "forward_card_close"
        navigationItem.backButtonDisplayMode = .minimal
        headerView.titleButton.isUserInteractionEnabled = false
        headerView.titleButton.accessibilityTraits = .header
        headerView.imageButton.isUserInteractionEnabled = false
        headerView.imageButton.isAccessibilityElement = false
        renderSnapshot()
        renderPrimaryAction()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func updatePrimaryAction(_ action: ForwardCardPrimaryAction?) {
        primaryAction = action
        guard isViewLoaded else { return }
        renderPrimaryAction()
    }

    /// A late response can hydrate the current target, never redirect its action.
    func updateSnapshot(_ updated: ForwardCardSnapshot) {
        guard updated.owner == snapshot.owner,
              updated.kind == snapshot.kind,
              updated.jid == snapshot.jid else { return }
        snapshot = updated
        guard isViewLoaded else { return }
        renderSnapshot()
        tableView.reloadData()
    }

    @objc func performPrimaryAction() {
        guard let action = primaryAction, action.isEnabled else { return }
        onAction(action.kind)
    }

    @objc func openSourceGroup() {
        guard snapshot.sourceGroup != nil else { return }
        onOpenGroup()
    }

    func dismissSheet(completion: @escaping () -> Void = {}) {
        cancelRefresh()
        let container = navigationController ?? self
        let containment = container.presentationController?.delegate
            as? ModalPresentationContainmentController
        guard container.presentingViewController != nil else {
            containment?.restoreIfNeeded()
            completion()
            return
        }
        container.dismiss(animated: true) {
            containment?.restoreIfNeeded()
            completion()
        }
    }

    @objc private func closeSheet() {
        dismissSheet()
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        resetAvatarLoad(placeholder: headerView.imageButton.image(for: .normal))
    }

    private func resetAvatarLoad(placeholder: UIImage?) {
        headerView.imageButton.kf.cancelImageDownloadTask()
        // A cached-image lookup can complete after cancellation. An empty
        // Kingfisher source also invalidates its previous task identifier.
        headerView.imageButton.kf.setImage(
            with: nil as KF.ImageResource?, for: .normal, placeholder: placeholder
        )
    }

    private func layoutHeader(force: Bool = false) {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        let height = headerView.preferredHeight(for: width)
        guard force || tableView.tableHeaderView !== headerView
            || abs(headerView.frame.width - width) > 0.5
            || abs(headerView.frame.height - height) > 0.5 else { return }
        headerView.applyHeaderLayout(to: tableView, width: width)
    }

    private func renderSnapshot() {
        title = snapshot.kind == .group
            ? L10n.text("forward_card__title__group", fallback: "Group")
            : L10n.text("forward_card__title__contact", fallback: "Contact")
        headerView.titleButton.setTitle(snapshot.name, for: .normal)
        headerView.titleButton.setTitleColor(.label, for: .normal)
        headerView.subtitleLabel.text = nonempty(snapshot.jid)
        headerView.subtitleLabel.isHidden = nonempty(snapshot.jid) == nil
        headerView.thirdLineLabel.text = nonempty(snapshot.badge)
        headerView.thirdLineLabel.isHidden = nonempty(snapshot.badge) == nil
        headerView.setMask()

        let placeholder = UIImageView.getDefaultAvatar(for: snapshot.name, owner: snapshot.owner, size: 112)
        resetAvatarLoad(placeholder: placeholder)
        if let url = snapshot.avatarURL {
            // The URL-specific key keeps this asserted photo out of JID caches.
            let resource = KF.ImageResource(
                downloadURL: url, cacheKey: "forward-card-snapshot:\(url.absoluteString)"
            )
            headerView.imageButton.kf.setImage(
                with: resource, for: .normal, placeholder: placeholder,
                options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 112, height: 112))),
                          .scaleFactor(UIScreen.main.scale)]
            )
        }
        sourceGroupButton = makeSourceGroupButton()
        layoutHeader(force: true)
    }

    private func renderPrimaryAction() {
        primaryActionButton?.removeTarget(self, action: #selector(performPrimaryAction), for: .touchUpInside)
        primaryActionButton?.isEnabled = false
        primaryActionButton = nil
        headerView.configureButtons { [] }
        headerView.showButtons = false
        if let action = primaryAction {
            let button = UIButton(type: .system)
            let presentation = actionPresentation(action.kind)
            var configuration = UIButton.Configuration.plain()
            configuration.title = presentation.title
            configuration.image = imageLiteral(presentation.icon, dimension: 20)
            configuration.imagePadding = 12
            configuration.titleAlignment = .leading
            configuration.titleLineBreakMode = .byWordWrapping
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            configuration.baseForegroundColor = .tintColor
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = font
                return result
            }
            button.configuration = configuration
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            button.isEnabled = action.isEnabled
            button.isAccessibilityElement = true
            button.accessibilityTraits = action.isEnabled ? [.button] : [.button, .notEnabled]
            button.accessibilityLabel = presentation.title
            button.accessibilityIdentifier = "forward_card_primary_\(presentation.identifier)"
            button.addTarget(self, action: #selector(performPrimaryAction), for: .touchUpInside)
            primaryActionButton = button
        }
        layoutHeader(force: true)
        tableView.reloadData()
    }

    private func makeSourceGroupButton() -> UIButton? {
        guard let group = snapshot.sourceGroup else { return nil }
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = group.name
        configuration.subtitle = group.privacy.map(privacyTitle)
        configuration.image = imageLiteral(
            group.privacy == .incognito ? "xabber.incognito.variant" : "person.3.fill"
        )
        configuration.imagePadding = 12
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = .secondarySystemGroupedBackground
        configuration.background.cornerRadius = 14
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.accessibilityIdentifier = "forward_card_source_group"
        button.accessibilityLabel = group.name
        button.accessibilityValue = group.privacy.map(privacyTitle)
        button.accessibilityHint = L10n.text("forward_card__action__open_source_group", fallback: "Open source group")
        button.addTarget(self, action: #selector(openSourceGroup), for: .touchUpInside)
        return button
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func privacyTitle(_ privacy: ForwardContactCard.Privacy) -> String {
        switch privacy {
        case .public: return L10n.text("forward_card__privacy__public", fallback: "Public")
        case .incognito: return L10n.text("forward_card__privacy__incognito", fallback: "Incognito")
        }
    }

    private func actionPresentation(_ action: ForwardCardAction) -> (icon: String, title: String, identifier: String) {
        switch action {
        case .openChat:
            return ("message", L10n.text("contact_bar_chat", fallback: "Chat"), "open_chat")
        case .addContact:
            return ("person.badge.plus", L10n.text("contact_add", fallback: "Add contact"), "add_contact")
        case .openGroup:
            return ("person.3", L10n.text("forward_card__action__open_group", fallback: "Open group"), "open_group")
        case .joinGroup:
            return ("person.3", L10n.text("groupchat_join", fallback: "Join"), "join_group")
        case .requestToJoin:
            return ("person.badge.plus", L10n.text("forward_card__action__request_to_join", fallback: "Request to join"), "request_to_join")
        }
    }
}

extension ForwardCardInfoViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .sourceGroup, .primaryAction: return 1
        case .details: return details.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if sections[section] == .sourceGroup {
            return L10n.text("forward_card__field__source_group", fallback: "Source group")
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .sourceGroup:
            return buttonCell(sourceGroupButton!, backgroundColor: .clear)
        case .primaryAction:
            return buttonCell(primaryActionButton!, backgroundColor: .secondarySystemGroupedBackground)
        case .details: break
        }
        let detail = details[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var configuration = cell.defaultContentConfiguration()
        configuration.text = detail.title
        configuration.secondaryText = detail.value
        configuration.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        configuration.textProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        configuration.secondaryTextProperties.color = .label
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.textProperties.adjustsFontForContentSizeCategory = true
        configuration.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = configuration
        cell.accessibilityIdentifier = detail.accessibilityIdentifier
        cell.selectionStyle = .none
        return cell
    }

    private func buttonCell(_ button: UIButton, backgroundColor: UIColor) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = backgroundColor
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
        ])
        return cell
    }
}
