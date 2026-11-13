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
        center.addObserver(self, selector: #selector(discoveryDidChange), name: .privacyProxyDiscoveryDidChange, object: nil)
        center.addObserver(self, selector: #selector(premiumDidChange), name: .premiumEntitlementDidChange, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshAll()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isObserving = false
        NotificationCenter.default.removeObserver(self)
        proxySettings.forEach { $0.stopProbing() }
    }

    @objc private func discoveryDidChange(_ notification: Notification) {
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
        proxySettings.forEach { $0.refresh(forceProbe: true) }
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
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        if row == 0 {
            content.text = L10n.text(
                "settings__proxy__explanation",
                fallback: "Messages often carry media hosted on other sites: link previews, pictures, videos, voice and video messages, attached files. Contacts' avatars are media too. Loading any of it directly tells that site your IP address and roughly when you read the message. A privacy proxy shields your IP address from being exposed: it fetches the media for you, so the site only ever sees the proxy."
            )
        } else {
            content.text = L10n.text("settings__proxy__how_it_works", fallback: "How it works")
            content.secondaryText = L10n.text(
                "settings__proxy__route_explanation",
                fallback: "The site sees only the proxy. The proxy, named by your server, sees your address instead."
            )
        }
        cell.contentConfiguration = content
        return cell
    }
}
