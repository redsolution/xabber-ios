import UIKit

final class ChatStickerPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private static let catalogueBase = "https://cdn.jsdelivr.net/gh/redsolution/xabber-stickers@adf96ab"

    private let owner: String
    private let catalogue: ChatStickerCatalogue
    private let canSchedule: () -> Bool
    private let onSend: (ChatStickerDescriptor) -> Void
    private let onSchedule: (ChatStickerDescriptor) -> Void
    private var packs: [ChatStickerPack] = []
    private var selectedPackURL: URL?
    private var operation: Task<Void, Never>?
    private var didChooseSticker = false

    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let emptyButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)

    init(
        owner: String,
        catalogue: ChatStickerCatalogue? = nil,
        canSchedule: @escaping () -> Bool,
        onSend: @escaping (ChatStickerDescriptor) -> Void,
        onSchedule: @escaping (ChatStickerDescriptor) -> Void
    ) {
        self.owner = owner
        self.catalogue = catalogue ?? .shared
        self.canSchedule = canSchedule
        self.onSend = onSend
        self.onSchedule = onSchedule
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = L10n.text("chat__stickers__title", fallback: "Stickers")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        let inset: CGFloat = 12
        layout.sectionInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(ChatStickerPickerCell.self, forCellWithReuseIdentifier: ChatStickerPickerCell.identifier)
        collection.accessibilityIdentifier = "chat.stickers.picker"

        emptyButton.setTitle(L10n.text("chat__stickers__add_packs", fallback: "Add sticker packs"), for: .normal)
        emptyButton.showsMenuAsPrimaryAction = true
        emptyButton.accessibilityIdentifier = "chat.stickers.add_packs"
        progress.hidesWhenStopped = true
        [collection, emptyButton, progress].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(catalogueChanged(_:)),
                                               name: ChatStickerCatalogue.changed, object: nil)
        reloadCatalogue()
    }

    private var selectedPack: ChatStickerPack? { packs.first { $0.manifestURL == selectedPackURL } }
    private var stickers: [ChatStickerEntry] { selectedPack?.stickers ?? [] }

    @objc private func close() {
        operation?.cancel()
        dismiss(animated: true)
    }

    @objc private func catalogueChanged(_ note: Notification) {
        guard note.object as? String == owner else { return }
        reloadCatalogue()
    }

    private func reloadCatalogue() {
        packs = catalogue.installed(for: owner)
        if selectedPack == nil { selectedPackURL = packs.first?.manifestURL }
        title = selectedPack?.name ?? L10n.text("chat__stickers__title", fallback: "Stickers")
        emptyButton.isHidden = selectedPack != nil || operation != nil
        let addMenu = managementMenu()
        emptyButton.menu = addMenu

        let addBarButton = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: addMenu)
        addBarButton.accessibilityLabel = L10n.text("chat__stickers__add_packs", fallback: "Add sticker packs")
        addBarButton.isEnabled = operation == nil
        let packMenu = UIMenu(children: packs.map { pack in
            UIAction(title: pack.name, state: pack.manifestURL == selectedPackURL ? .on : .off) { [weak self] _ in
                self?.selectedPackURL = pack.manifestURL
                self?.reloadCatalogue()
            }
        })
        let packButton = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"), menu: packMenu)
        packButton.accessibilityLabel = L10n.text("chat__stickers__packs", fallback: "Sticker packs")
        navigationItem.rightBarButtonItems = packs.isEmpty ? [addBarButton] : [addBarButton, packButton]
        collection.reloadData()
    }

    private func managementMenu() -> UIMenu {
        var actions = [
            catalogueAction(path: "monsters", title: L10n.text("chat__stickers__install_monsters", fallback: "Install Monsters")),
            catalogueAction(path: "owls", title: L10n.text("chat__stickers__install_owls", fallback: "Install Owls")),
            UIAction(title: L10n.text("chat__stickers__install_link", fallback: "Install by link"),
                     image: UIImage(systemName: "link")) { [weak self] _ in self?.enterManifestURL() }
        ]
        if let pack = selectedPack {
            actions.append(UIAction(title: L10n.text("chat__stickers__refresh_pack", fallback: "Refresh pack"),
                                    image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.install(pack.manifestURL)
            })
            actions.append(UIAction(title: L10n.text("chat__stickers__remove_pack", fallback: "Remove pack"),
                                    image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                do { try catalogue.remove(pack.manifestURL, owner: owner) }
                catch { presentFailure() }
            })
        }
        return UIMenu(children: actions)
    }

    private func catalogueAction(path: String, title: String) -> UIAction {
        let url = URL(string: "\(Self.catalogueBase)/\(path)/pack.xml")!
        let attributes: UIMenuElement.Attributes = packs.contains { $0.manifestURL == url } ? .disabled : []
        return UIAction(title: title, image: UIImage(systemName: "plus.circle"), attributes: attributes) { [weak self] _ in
            self?.install(url)
        }
    }

    private func enterManifestURL() {
        let alert = UIAlertController(
            title: L10n.text("chat__stickers__install_link", fallback: "Install by link"),
            message: nil, preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = L10n.text("chat__stickers__manifest_url", fallback: "Sticker pack URL")
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "chat.stickers.manifest_url"
        }
        alert.addAction(UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.text("chat__stickers__install", fallback: "Install"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let input = alert?.textFields?.first?.text, let url = ChatStickerPackManifest.manifestURL(input) else {
                DispatchQueue.main.async { self.presentFailure() }
                return
            }
            self.install(url)
        })
        present(alert, animated: true)
    }

    private func install(_ url: URL) {
        guard operation == nil else { return }
        let owner = owner
        let catalogue = catalogue
        progress.startAnimating()
        operation = Task { [weak self] in
            do {
                let pack = try await catalogue.install(url, owner: owner)
                guard let self, !Task.isCancelled else { return }
                self.selectedPackURL = pack.manifestURL
                self.finishLoad()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finishLoad()
                self.presentFailure()
            }
        }
        reloadCatalogue()
    }

    private func finishLoad() {
        operation = nil
        progress.stopAnimating()
        reloadCatalogue()
    }

    private func presentFailure() {
        let alert = UIAlertController(
            title: L10n.text("chat__stickers__unavailable", fallback: "Sticker pack unavailable"),
            message: nil, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.text("common__action__ok", fallback: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { stickers.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatStickerPickerCell.identifier, for: indexPath) as! ChatStickerPickerCell
        let sticker = stickers[indexPath.item]
        cell.configure(sticker: sticker, owner: owner, send: { [weak self, weak cell] in
            self?.choose(sticker, from: cell, schedules: false)
        }, schedule: canSchedule() ? { [weak self, weak cell] in
            self?.choose(sticker, from: cell, schedules: true)
        } : nil)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ChatStickerPickerCell)?.thumbnail.reset()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard stickers.indices.contains(indexPath.item) else { return }
        choose(stickers[indexPath.item], from: collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell, schedules: false)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns = max(3, Int(collectionView.bounds.width / 84))
        let available = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let size = max(1, floor((available - CGFloat(columns - 1) * layout.minimumInteritemSpacing) / CGFloat(columns)))
        return CGSize(width: size, height: size)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard stickers.indices.contains(indexPath.item),
              let cell = collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell else { return nil }
        let sticker = stickers[indexPath.item]
        var actions: [UIAction] = []
        if canSchedule() {
            actions.append(UIAction(title: L10n.text("schedule_message_action", fallback: "Schedule Message"),
                                    image: UIImage(systemName: "calendar.badge.clock")) { [weak self, weak cell] _ in
                self?.choose(sticker, from: cell, schedules: true)
            })
        }
        if cell.thumbnail.canRevealImage {
            actions.append(UIAction(title: ExternalImageConsent.title, image: UIImage(systemName: "photo")) { [weak cell] _ in
                cell?.thumbnail.reveal(sticker: sticker)
            })
        }
        return actions.isEmpty ? nil : UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: actions) }
    }

    private func choose(_ entry: ChatStickerEntry, from cell: ChatStickerPickerCell?, schedules: Bool) {
        guard !didChooseSticker, stickers.contains(entry), !schedules || canSchedule() else { return }
        let thumbnail = cell?.thumbnail.inlineThumbnail(for: entry)
        let sticker = entry.descriptor(thumbnail: thumbnail)
        let handler = schedules ? onSchedule : onSend
        didChooseSticker = true
        dismiss(animated: true) { handler(sticker) }
    }
}

private final class ChatStickerPickerCell: UICollectionViewCell {
    static let identifier = "ChatStickerPickerCell"
    let thumbnail = ChatStickerThumbnailView()
    private var send: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            thumbnail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.reset()
        send = nil
        accessibilityCustomActions = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let send else { return false }
        send()
        return true
    }

    func configure(sticker: ChatStickerEntry, owner: String, send: @escaping () -> Void, schedule: (() -> Void)?) {
        self.send = send
        accessibilityIdentifier = "chat.stickers.picker.sticker"
        accessibilityLabel = sticker.name
        accessibilityHint = sticker.description.isEmpty ? nil : sticker.description
        var actions: [UIAccessibilityCustomAction] = []
        if let schedule {
            actions.append(UIAccessibilityCustomAction(name: L10n.text("schedule_message_action", fallback: "Schedule Message")) { _ in
                schedule()
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: ExternalImageConsent.title) { [weak self] _ in
            self?.thumbnail.reveal(sticker: sticker) ?? false
        })
        accessibilityCustomActions = actions
        thumbnail.load(sticker, owner: owner, size: 72)
    }
}

final class ChatStickerSuggestionStrip: UIScrollView {
    static let rowHeight: CGFloat = 54

    private let itemsView = UIStackView()
    private var entries: [ChatStickerEntry] = []
    private var owner = ""
    private var emoji: String?
    var onSend: ((ChatStickerDescriptor) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        showsHorizontalScrollIndicator = false
        accessibilityIdentifier = "chat.stickers.suggestions"

        itemsView.axis = .horizontal
        itemsView.spacing = 4
        itemsView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(itemsView)
        NSLayoutConstraint.activate([
            itemsView.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 4),
            itemsView.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -4),
            itemsView.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 3),
            itemsView.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -3),
            itemsView.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ entries: [ChatStickerEntry], owner: String, emoji: String?) {
        guard self.entries != entries || self.owner != owner || self.emoji != emoji else { return }
        self.entries = entries
        self.owner = owner
        self.emoji = emoji
        itemsView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setContentOffset(.zero, animated: false)
        for entry in entries {
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "chat.stickers.suggestion"
            button.accessibilityLabel = entry.name
            button.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let thumbnail = ChatStickerThumbnailView()
            thumbnail.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(thumbnail)
            NSLayoutConstraint.activate([
                thumbnail.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 3),
                thumbnail.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                thumbnail.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
                thumbnail.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3)
            ])
            thumbnail.load(entry, owner: owner, size: 42)
            button.addAction(UIAction { [weak self, weak thumbnail] _ in
                guard let self, self.owner == owner, self.entries.contains(entry) else { return }
                let sticker = entry.descriptor(preferredEmoji: emoji, thumbnail: thumbnail?.inlineThumbnail(for: entry))
                self.onSend?(sticker)
            }, for: .touchUpInside)
            itemsView.addArrangedSubview(button)
        }
    }
}

final class ChatStickerThumbnailView: UIView {
    private let imageView = UIImageView()
    private let placeholder = UILabel()
    private var subscription: ChatThumbnailSubscription?
    private var entry: ChatStickerEntry?
    private var owner = ""
    private var displaySize: CGFloat = 1
    private var binding = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .scaleAspectFit
        placeholder.textAlignment = .center
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        [placeholder, imageView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: trailingAnchor),
                $0.topAnchor.constraint(equalTo: topAnchor),
                $0.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { subscription?.cancel() }

    var canRevealImage: Bool {
        guard let entry, imageView.image == nil else { return false }
        return PrivacyProxyMediaRouter.shared.canRequestDirectImage(entry.imageURL, owner: owner)
    }

    @discardableResult
    func reveal(sticker: ChatStickerEntry) -> Bool {
        guard entry == sticker, canRevealImage else { return false }
        let owner = owner
        let binding = binding
        ExternalImageConsent.present(for: sticker.imageURL, owner: owner, from: self,
                                     shouldGrant: { [weak self] in self?.binding == binding }) { [weak self] in
            guard let self, self.binding == binding else { return }
            self.load(sticker, owner: owner, size: self.displaySize)
        }
        return true
    }

    func inlineThumbnail(for sticker: ChatStickerEntry) -> Data? {
        guard entry == sticker, let image = imageView.image else { return nil }
        return ChatStickerWireCodec.thumbnail(from: image)
    }

    func reset() {
        subscription?.cancel()
        subscription = nil
        entry = nil
        binding = UUID()
        imageView.image = nil
        placeholder.text = nil
        placeholder.isHidden = false
    }

    func load(_ sticker: ChatStickerEntry, owner: String, size: CGFloat) {
        reset()
        entry = sticker
        self.owner = owner
        displaySize = size
        placeholder.text = sticker.emojis.first ?? "🖼️"
        let id = binding
        let request = ChatThumbnailRequest(
            url: sticker.imageURL, displaySize: ChatCollectionPrefetchSize(width: Double(size), height: Double(size)),
            scale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle), owner: owner
        )
        let consumer = ChatThumbnailConsumer(
            identity: ChatCollectionPrefetchIdentity(kind: .sticker, messagePrimary: owner,
                                                     referencePrimary: sticker.imageURL.absoluteString),
            role: .visible(id)
        )
        subscription = ChatMediaThumbnailPipeline.shared.acquire(request, consumer: consumer) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.binding == id, case .success(let thumbnail) = result else { return }
                self.imageView.image = thumbnail.image
                self.placeholder.isHidden = true
            }
        }
    }
}
