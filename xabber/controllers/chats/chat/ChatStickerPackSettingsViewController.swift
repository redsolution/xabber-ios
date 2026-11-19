import UIKit

final class ChatStickerPackSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case installed, starterPacks, link
    }

    private let owner: String
    private let catalogue: ChatStickerCatalogue
    private var packs: [ChatStickerPack] = []
    private var operations: [URL: Task<Void, Never>] = [:]
    private var failures: Set<URL> = []
    private var lastLink: URL?

    init(owner: String, catalogue: ChatStickerCatalogue? = nil) {
        self.owner = owner
        self.catalogue = catalogue ?? .shared
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        operations.values.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("chat__stickers__packs", fallback: "Sticker packs")
        tableView.accessibilityIdentifier = "chat.stickers.settings"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "StickerPackSettingsRow")
        NotificationCenter.default.addObserver(self, selector: #selector(catalogueChanged(_:)),
                                               name: ChatStickerCatalogue.changed, object: nil)
        reloadCatalogue()
    }

    @objc private func catalogueChanged(_ note: Notification) {
        guard note.object as? String == owner else { return }
        reloadCatalogue()
    }

    private func reloadCatalogue() {
        packs = catalogue.installed(for: owner)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section.allCases[section] {
        case .installed: return packs.count
        case .starterPacks: return ChatStickerStarterPack.all.count
        case .link: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section.allCases[section] {
        case .installed:
            return packs.isEmpty ? nil : L10n.text("chat__stickers__installed_packs", fallback: "Installed packs")
        case .starterPacks:
            return L10n.text("chat__stickers__starter_packs", fallback: "Starter packs")
        case .link:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "StickerPackSettingsRow", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        var url: URL?
        var available = true
        switch Section.allCases[indexPath.section] {
        case .installed:
            let pack = packs[indexPath.row]
            content.text = pack.displayName
            url = pack.manifestURL
            cell.accessibilityIdentifier = "chat.stickers.settings.installed"
        case .starterPacks:
            let starter = ChatStickerStarterPack.all[indexPath.row]
            content.text = starter.name
            url = starter.manifestURL
            available = !packs.contains { $0.manifestURL == starter.manifestURL }
            content.secondaryText = available ? L10n.text("common__action__add", fallback: "Add")
                                              : L10n.text("chat__stickers__installed", fallback: "Installed")
            cell.accessibilityIdentifier = "chat.stickers.settings.starter.\(starter.id)"
        case .link:
            content.text = L10n.text("chat__stickers__install_link", fallback: "Install by link")
            url = lastLink
            cell.accessibilityIdentifier = "chat.stickers.settings.link"
        }
        if let url, operations[url] != nil {
            content.secondaryText = L10n.text("chat__stickers__installing", fallback: "Installing…")
            available = false
        } else if let url, failures.contains(url), available {
            content.secondaryText = L10n.text("common__action__retry", fallback: "Retry")
        }
        cell.contentConfiguration = content
        cell.selectionStyle = available ? .default : .none
        cell.accessibilityTraits = available ? .button : [.button, .notEnabled]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section.allCases[indexPath.section] {
        case .installed:
            let pack = packs[indexPath.row]
            guard operations[pack.manifestURL] == nil else { return }
            showPackActions(pack, sourceRect: tableView.rectForRow(at: indexPath))
        case .starterPacks:
            let starter = ChatStickerStarterPack.all[indexPath.row]
            guard !packs.contains(where: { $0.manifestURL == starter.manifestURL }) else { return }
            install(starter.manifestURL)
        case .link:
            if let lastLink, operations[lastLink] != nil { return }
            enterManifestURL()
        }
    }

    private func showPackActions(_ pack: ChatStickerPack, sourceRect: CGRect) {
        let actions = UIAlertController(title: pack.displayName, message: nil, preferredStyle: .actionSheet)
        actions.addAction(UIAlertAction(title: L10n.text("chat__stickers__refresh_pack", fallback: "Refresh pack"),
                                        style: .default) { [weak self] _ in
            self?.install(pack.manifestURL)
        })
        actions.addAction(UIAlertAction(title: L10n.text("chat__stickers__remove_pack", fallback: "Remove pack"),
                                        style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try catalogue.remove(pack.manifestURL, owner: owner)
                failures.remove(pack.manifestURL)
                reloadCatalogue()
            } catch {
                ToastPresenter().presentError(message: L10n.text("chat__stickers__unavailable",
                                                                 fallback: "Sticker pack unavailable"))
            }
        })
        actions.addAction(UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel))
        actions.popoverPresentationController?.sourceView = tableView
        actions.popoverPresentationController?.sourceRect = sourceRect
        present(actions, animated: true)
    }

    private func enterManifestURL() {
        let alert = UIAlertController(
            title: L10n.text("chat__stickers__install_link", fallback: "Install by link"),
            message: nil,
            preferredStyle: .alert
        )
        let add = UIAlertAction(title: L10n.text("chat__stickers__install", fallback: "Install"),
                                style: .default) { [weak self, weak alert] _ in
            guard let self, let input = alert?.textFields?.first?.text,
                  let url = ChatStickerPackManifest.manifestURL(input) else { return }
            lastLink = url
            install(url)
        }
        alert.addTextField { [lastLink] field in
            field.placeholder = L10n.text("chat__stickers__manifest_url", fallback: "Sticker pack URL")
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "chat.stickers.manifest_url"
            field.text = lastLink?.absoluteString
            add.isEnabled = lastLink != nil
            field.addAction(UIAction { [weak add, weak field] _ in
                add?.isEnabled = field?.text.flatMap(ChatStickerPackManifest.manifestURL) != nil
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel))
        alert.addAction(add)
        present(alert, animated: true)
    }

    private func install(_ url: URL) {
        guard operations[url] == nil else { return }
        failures.remove(url)
        let imageProfile = ChatStickerImageProfile(view: view)
        operations[url] = Task { [weak self, catalogue, owner] in
            do {
                try await catalogue.install(url, owner: owner, imageProfile: imageProfile)
            } catch {
                guard !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self?.failures.insert(url)
                }
            }
            self?.operations.removeValue(forKey: url)
            self?.reloadCatalogue()
        }
        tableView.reloadData()
    }
}
