import UIKit

final class SecuritySettingsViewController: BaseViewController, UITableViewDataSource {
    let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private let owners: [String]
    private let proxySettings: [PrivacyProxySettings]
    private var isObserving = false

    convenience init(owners: [String]) {
        self.init(owners: owners) { PrivacyProxySettings(owner: $0) }
    }

    init(owners: [String], makeSettings: (String) -> PrivacyProxySettings) {
        self.owners = owners.filter { !$0.isEmpty }
        self.proxySettings = self.owners.map(makeSettings)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SettingsViewController.Datasource.Section.security.description()
        view.backgroundColor = .systemGroupedBackground
        tableView.accessibilityIdentifier = "settings.security.table"
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for settings in proxySettings {
            settings.onChange = { [weak self] _ in self?.tableView.reloadData() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(proxyAvailabilityDidChange), name: .privacyProxyAvailabilityDidChange, object: nil)
        center.addObserver(self, selector: #selector(premiumDidChange), name: .premiumEntitlementDidChange, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshAll()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isObserving = false
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func proxyAvailabilityDidChange(_ notification: Notification) {
        refreshOwner(notification.userInfo?["owner"] as? String)
    }

    @objc private nonisolated func premiumDidChange(_ notification: Notification) {
        let owner = notification.userInfo?["jid"] as? String
        Task { @MainActor [weak self] in
            guard let self, isObserving else { return }
            refreshOwner(owner)
        }
    }

    @objc private func appDidBecomeActive() {
        refreshAll()
    }

    private func refreshOwner(_ owner: String?) {
        guard let owner, let index = owners.firstIndex(of: owner) else { return }
        proxySettings[index].refresh()
    }

    private func refreshAll() {
        proxySettings.forEach { $0.refresh() }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        max(1, proxySettings.count) + 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == max(1, proxySettings.count) ? 2 : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == max(1, proxySettings.count) {
            return L10n.text("settings__proxy__what_it_does", fallback: "What it does")
        }
        let title = L10n.text("settings__proxy__title", fallback: "Privacy proxy")
        return owners.count > 1 ? "\(title) · \(owners[section])" : title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard proxySettings.indices.contains(section) else { return nil }
        let state = proxySettings[section].state
        switch state.availability {
        case .checking:
            return nil
        case .notAdvertised:
            let domain = owners[section].split(separator: "@", maxSplits: 1).last.map(String.init) ?? owners[section]
            return L10n.format(
                "settings__proxy__not_provided",
                fallback: "%@ does not provide a privacy proxy",
                arguments: [domain]
            )
        case .unreachable(let host):
            return L10n.format("settings__proxy__did_not_answer", fallback: "%@ did not answer.", arguments: [host])
        case .reachable(let host):
            let provider = L10n.format("settings__proxy__provider", fallback: "Provided by %@", arguments: [host])
            guard state.requiresPremium else { return provider }
            let premium = L10n.text("settings__proxy__premium_required", fallback: "Premium is required to enable the privacy proxy.")
            return [provider, premium].joined(separator: "\n")
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == max(1, proxySettings.count) {
            return informationCell(at: indexPath.row)
        }

        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        let settings = proxySettings.indices.contains(indexPath.section) ? proxySettings[indexPath.section] : nil
        if let settings, settings.state.showsSwitch {
            let label = L10n.text(
                "settings__proxy__toggle",
                fallback: "Load external media through the privacy proxy"
            )
            content.text = label
            let toggle = UISwitch()
            toggle.accessibilityLabel = label
            toggle.accessibilityIdentifier = "settings.security.proxy.enabled"
            toggle.isOn = settings.state.isEnabled
            toggle.isEnabled = settings.state.canChangeSwitch
            toggle.addAction(UIAction { [weak settings, weak toggle] _ in
                guard let settings, let toggle else { return }
                settings.setEnabled(toggle.isOn)
                toggle.setOn(settings.state.isEnabled, animated: true)
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.isAccessibilityElement = false
        } else {
            content.text = statusText(settings?.state)
            cell.accessibilityIdentifier = "settings.security.proxy.status"
        }
        cell.contentConfiguration = content
        return cell
    }

    private func statusText(_ state: PrivacyProxySettings.State?) -> String {
        switch state?.availability {
        case .checking:
            return L10n.text("settings__proxy__checking", fallback: "Checking…")
        case .notAdvertised, nil:
            return L10n.text("settings__proxy__not_available", fallback: "Not available")
        case .unreachable:
            return L10n.text("settings__proxy__not_responding", fallback: "Not responding")
        case .reachable:
            return L10n.text("settings__proxy__enabled", fallback: "Enabled")
        }
    }

    private func informationCell(at row: Int) -> UITableViewCell {
        if row == 1 { return PrivacyProxyDiagramCell() }

        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.text = L10n.text(
            "settings__proxy__explanation",
            fallback: "Messages often carry media hosted on other sites: link previews, pictures, videos, voice and video messages, attached files. Contacts' avatars are media too. Loading any of it directly tells that site your IP address and roughly when you read the message. A privacy proxy shields your IP address from being exposed: it fetches the media for you, so the site only ever sees the proxy."
        )
        cell.contentConfiguration = content
        return cell
    }
}

private final class PrivacyProxyDiagramCell: UITableViewCell {
    private let routes = UIStackView()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)

        let title = UILabel()
        title.text = L10n.text("settings__proxy__how_it_works", fallback: "How it works")
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.accessibilityTraits.insert(.header)

        routes.axis = .vertical
        routes.spacing = 12
        routes.addArrangedSubview(PrivacyProxyRouteCard(usesProxy: false))
        routes.addArrangedSubview(PrivacyProxyRouteCard(usesProxy: true))

        let stack = UIStackView(arrangedSubviews: [title, routes])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        updateRouteLayout(for: bounds.width)
        super.layoutSubviews()
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        updateRouteLayout(for: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    private func updateRouteLayout(for cellWidth: CGFloat) {
        let margins = contentView.directionalLayoutMargins
        let availableWidth = cellWidth - margins.leading - margins.trailing
        let fitsSideBySide = availableWidth >= 2 * 240 + routes.spacing
            && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let axis: NSLayoutConstraint.Axis = fitsSideBySide ? .horizontal : .vertical
        guard routes.axis != axis else { return }
        routes.axis = axis
        routes.distribution = fitsSideBySide ? .fillEqually : .fill
    }
}

private final class PrivacyProxyRouteCard: UIView {
    private static let proxyOrange = UIColor(red: 1, green: 0.34, blue: 0.13, alpha: 1)
    private static let exposureColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 1)
            : UIColor(red: 0.60, green: 0.34, blue: 0, alpha: 1)
    }

    init(usesProxy: Bool) {
        super.init(frame: .zero)
        let title = usesProxy
            ? L10n.text("settings__proxy__route_proxied", fallback: "With a privacy proxy")
            : L10n.text("settings__proxy__route_direct", fallback: "Without a proxy")
        let caption = usesProxy
            ? L10n.text(
                "settings__proxy__route_explanation",
                fallback: "The site sees only the proxy. The proxy, named by your server, sees your address instead."
            )
            : L10n.text(
                "settings__proxy__direct_explanation",
                fallback: "The site sees your IP address, and when and how often you opened its media."
            )

        let heading = Self.label(title, style: .subheadline, color: .label)
        heading.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        let explanation = Self.label(caption, style: .footnote)
        let flow = UIStackView()
        flow.alignment = .top
        flow.addArrangedSubview(Self.node(
            L10n.text("settings__proxy__node_you", fallback: "You"), symbol: "person.fill"
        ))
        if usesProxy {
            let userAddress = Self.arrow(L10n.text("settings__proxy__arrow_user", fallback: "your IP"))
            let proxyAddress = Self.arrow(L10n.text("settings__proxy__arrow_proxy", fallback: "proxy’s address"))
            flow.addArrangedSubview(userAddress)
            flow.addArrangedSubview(Self.node(
                L10n.text("settings__proxy__node_proxy", fallback: "Proxy"),
                symbol: "lock.shield.fill", background: Self.proxyOrange
            ))
            flow.addArrangedSubview(proxyAddress)
            userAddress.widthAnchor.constraint(equalTo: proxyAddress.widthAnchor).isActive = true
        } else {
            flow.addArrangedSubview(Self.arrow(
                L10n.text("settings__proxy__arrow_direct", fallback: "your IP address"), exposed: true
            ))
        }
        flow.addArrangedSubview(Self.node(
            L10n.text("settings__proxy__node_site", fallback: "Other site"), symbol: "globe"
        ))

        let stack = UIStackView(arrangedSubviews: [heading, flow, explanation])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])

        layer.cornerRadius = 8
        layer.borderWidth = 1
        updateBorderColor()
        isAccessibilityElement = true
        accessibilityIdentifier = usesProxy ? "settings.security.proxy.route.proxied" : "settings.security.proxy.route.direct"
        accessibilityLabel = title
        accessibilityValue = caption
        accessibilityTraits = .staticText
        stack.accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateBorderColor()
        }
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    private static func label(
        _ text: String, style: UIFont.TextStyle, color: UIColor = .secondaryLabel
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private static func node(_ text: String, symbol: String, background: UIColor = .systemGray) -> UIView {
        let dot = UIView()
        dot.backgroundColor = background
        dot.layer.cornerRadius = 20
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        dot.addSubview(icon)

        let caption = diagramLabel(text)
        let node = UIStackView(arrangedSubviews: [dot, caption])
        node.axis = .vertical
        node.alignment = .center
        node.spacing = 4
        let preferredWidth = node.widthAnchor.constraint(equalToConstant: 56)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            node.widthAnchor.constraint(greaterThanOrEqualTo: dot.widthAnchor),
            dot.widthAnchor.constraint(equalToConstant: 40),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),
            icon.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: node.widthAnchor)
        ])
        return node
    }

    private static func arrow(_ text: String, exposed: Bool = false) -> UIView {
        let line = PrivacyProxyRouteArrow(color: exposed ? exposureColor : .systemGray)
        let caption = diagramLabel(text, color: exposed ? exposureColor : .secondaryLabel)
        let arrow = UIStackView(arrangedSubviews: [line, caption])
        arrow.axis = .vertical
        arrow.spacing = 3
        line.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let minimumWidth = arrow.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumWidth.priority = UILayoutPriority(751)
        minimumWidth.isActive = true
        return arrow
    }

    private static func diagramLabel(_ text: String, color: UIColor = .secondaryLabel) -> UILabel {
        let label = label(text, style: .caption2, color: color)
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 11), maximumPointSize: 17
        )
        label.textAlignment = .center
        return label
    }
}

private final class PrivacyProxyRouteArrow: UIView {
    private let color: UIColor

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tail = isRTL ? bounds.width : 0
        let tip = isRTL ? 0 : bounds.width
        let shoulder = tip + (isRTL ? 6 : -6)
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: tail, y: 19))
        arrow.addLine(to: CGPoint(x: shoulder, y: 19))
        arrow.addLine(to: CGPoint(x: shoulder, y: 15))
        arrow.addLine(to: CGPoint(x: tip, y: 20))
        arrow.addLine(to: CGPoint(x: shoulder, y: 25))
        arrow.addLine(to: CGPoint(x: shoulder, y: 21))
        arrow.addLine(to: CGPoint(x: tail, y: 21))
        arrow.close()
        color.setFill()
        arrow.fill()
    }
}
