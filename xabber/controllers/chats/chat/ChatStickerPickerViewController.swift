import UIKit

final class ChatStickerPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private enum StarterInstallState {
        case installing
        case failed
    }

    private struct StarterRow {
        let view: UIStackView
        let thumbnail: ChatStickerThumbnailView
        let status: UILabel
        let button: UIButton
    }

    private let owner: String
    private let catalogue: ChatStickerCatalogue
    private let canSchedule: () -> Bool
    private let onSend: (ChatStickerDescriptor) -> Void
    private let onSchedule: (ChatStickerDescriptor) -> Void
    private let onKeyboard: () -> Void
    private let onCollapse: () -> Void
    private let onSettings: () -> Void

    private var packs: [ChatStickerPack] = []
    private var selectedPackURL: URL?
    private var showingStarterPacks = false
    private var installTasks: [URL: Task<Void, Never>] = [:]
    private var installStates: [URL: StarterInstallState] = [:]

    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var packStrip = UICollectionView(frame: .zero, collectionViewLayout: makePackStripLayout())
    private let starterScroll = UIScrollView()
    private var starterRows: [URL: StarterRow] = [:]
    private var loadedStarterPreviews: Set<URL> = []
    private lazy var addButton = makePanelButton(
        "plus", label: L10n.text("chat__stickers__add_packs", fallback: "Add sticker packs"),
        identifier: "chat.stickers.add_packs"
    ) { [weak self] in
        guard let self else { return }
        self.showingStarterPacks.toggle()
        self.updateVisibleContent()
    }

    init(
        owner: String,
        catalogue: ChatStickerCatalogue? = nil,
        canSchedule: @escaping () -> Bool,
        onSend: @escaping (ChatStickerDescriptor) -> Void,
        onSchedule: @escaping (ChatStickerDescriptor) -> Void,
        onKeyboard: @escaping () -> Void = {},
        onCollapse: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {}
    ) {
        self.owner = owner
        self.catalogue = catalogue ?? .shared
        self.canSchedule = canSchedule
        self.onSend = onSend
        self.onSchedule = onSchedule
        self.onKeyboard = onKeyboard
        self.onCollapse = onCollapse
        self.onSettings = onSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        installTasks.values.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.accessibilityIdentifier = "chat.stickers.panel"

        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        collection.alwaysBounceVertical = true
        collection.accessibilityIdentifier = "chat.stickers.picker"
        packStrip.showsHorizontalScrollIndicator = false
        packStrip.accessibilityIdentifier = "chat.stickers.packs"
        for grid in [collection, packStrip] {
            grid.backgroundColor = .clear
            grid.contentInsetAdjustmentBehavior = .never
            grid.dataSource = self
            grid.delegate = self
            grid.register(ChatStickerPickerCell.self, forCellWithReuseIdentifier: ChatStickerPickerCell.identifier)
        }

        configureStarterPacks()
        let toolbar = makeToolbar()
        let safeArea = view.safeAreaLayoutGuide
        for child in [toolbar, collection, starterScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            collection.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            collection.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            starterScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            starterScroll.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(catalogueChanged(_:)),
                                               name: ChatStickerCatalogue.changed, object: nil)
        reloadCatalogue()
    }

    private var selectedPack: ChatStickerPack? { packs.first { $0.manifestURL == selectedPackURL } }
    private var stickers: [ChatStickerEntry] { selectedPack?.stickers ?? [] }

    private func makeToolbar() -> UIStackView {
        let settings = makePanelButton(
            "gearshape", label: L10n.text("chat__stickers__packs", fallback: "Sticker packs"),
            identifier: "chat.stickers.settings", action: onSettings
        )
        let keyboard = makePanelButton(
            "keyboard", label: L10n.text("chat__stickers__keyboard", fallback: "Keyboard"),
            identifier: "chat.stickers.keyboard", action: onKeyboard
        )
        let collapse = makePanelButton(
            "chevron.down", label: L10n.text("chat__stickers__collapse", fallback: "Hide sticker panel"),
            identifier: "chat.stickers.collapse", action: onCollapse
        )
        let toolbar = UIStackView(arrangedSubviews: [packStrip, addButton, settings, keyboard, collapse])
        toolbar.alignment = .fill
        return toolbar
    }

    private func makePanelButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        let width = button.widthAnchor.constraint(equalToConstant: 44)
        width.priority = UILayoutPriority(999)
        width.isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makePackStripLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.sectionInset = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 4)
        layout.minimumLineSpacing = 2
        return layout
    }

    private func configureStarterPacks() {
        let title = UILabel()
        title.text = L10n.text("chat__stickers__starter_packs", fallback: "Starter packs")
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true

        let rows = UIStackView(arrangedSubviews: [title])
        rows.axis = .vertical
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        starterScroll.contentInsetAdjustmentBehavior = .never
        starterScroll.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: starterScroll.contentLayoutGuide.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: starterScroll.contentLayoutGuide.trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: starterScroll.contentLayoutGuide.topAnchor, constant: 10),
            rows.bottomAnchor.constraint(equalTo: starterScroll.contentLayoutGuide.bottomAnchor, constant: -12),
            rows.widthAnchor.constraint(equalTo: starterScroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        for pack in ChatStickerStarterPack.all {
            let thumbnail = ChatStickerThumbnailView()
            thumbnail.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let thumbnailHeight = thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor)
            thumbnailHeight.priority = UILayoutPriority(999)
            thumbnailHeight.isActive = true

            let title = UILabel()
            title.text = pack.name
            title.font = .preferredFont(forTextStyle: .body)
            title.adjustsFontForContentSizeCategory = true
            title.numberOfLines = 0
            title.isAccessibilityElement = false
            let status = UILabel()
            status.text = L10n.text("chat__stickers__unavailable", fallback: "Sticker pack unavailable")
            status.font = .preferredFont(forTextStyle: .footnote)
            status.adjustsFontForContentSizeCategory = true
            status.numberOfLines = 0
            status.textColor = .secondaryLabel
            status.isAccessibilityElement = false
            let labels = UIStackView(arrangedSubviews: [title, status])
            labels.axis = .vertical
            labels.spacing = 2

            let button = UIButton(configuration: .tinted())
            button.accessibilityIdentifier = "chat.stickers.install.\(pack.id)"
            button.accessibilityLabel = pack.name
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            let buttonHeight = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            buttonHeight.priority = UILayoutPriority(999)
            buttonHeight.isActive = true
            button.addAction(UIAction { [weak self] _ in self?.installStarterPack(pack) }, for: .touchUpInside)

            let row = UIStackView(arrangedSubviews: [thumbnail, labels, button])
            row.alignment = .center
            row.spacing = 8
            rows.addArrangedSubview(row)
            starterRows[pack.manifestURL] = StarterRow(view: row, thumbnail: thumbnail, status: status, button: button)
        }
    }

    @objc private func catalogueChanged(_ note: Notification) {
        guard note.object as? String == owner else { return }
        reloadCatalogue()
    }

    private func reloadCatalogue() {
        let previousPack = selectedPack
        let previousIndex = packs.firstIndex { $0.manifestURL == selectedPackURL } ?? 0
        let installed = catalogue.installed(for: owner)
        if packs != installed {
            packs = installed
            packStrip.reloadData()
        }
        if selectedPack == nil {
            selectedPackURL = packs.isEmpty ? nil : packs[min(previousIndex, packs.count - 1)].manifestURL
            showingStarterPacks = selectedPackURL == nil
        }

        if previousPack != selectedPack {
            reloadGrid(keepingOffset: previousPack?.manifestURL == selectedPackURL)
        }
        updateVisibleContent()
    }

    private func updateVisibleContent() {
        let installedURLs = Set(packs.map(\.manifestURL))
        let hasAvailableStarterPack = ChatStickerStarterPack.all.contains { !installedURLs.contains($0.manifestURL) }
        showingStarterPacks = selectedPack == nil || (showingStarterPacks && hasAvailableStarterPack)
        for pack in ChatStickerStarterPack.all {
            guard let row = starterRows[pack.manifestURL] else { continue }
            let isInstalled = installedURLs.contains(pack.manifestURL)
            row.view.isHidden = isInstalled
            if showingStarterPacks, !isInstalled, loadedStarterPreviews.insert(pack.manifestURL).inserted {
                row.thumbnail.loadPackPreview(pack.previewURL, owner: owner, size: 44)
            }
            updateStarterButton(pack)
        }

        addButton.isHidden = selectedPack == nil || !hasAvailableStarterPack
        addButton.isSelected = showingStarterPacks
        addButton.accessibilityTraits = showingStarterPacks ? [.button, .selected] : [.button]
        starterScroll.isHidden = !showingStarterPacks
        collection.isHidden = showingStarterPacks

        for indexPath in packStrip.indexPathsForVisibleItems where packs.indices.contains(indexPath.item) {
            let cell = packStrip.cellForItem(at: indexPath) as? ChatStickerPickerCell
            cell?.setPackSelected(!showingStarterPacks && packs[indexPath.item].manifestURL == selectedPackURL)
        }
    }

    private func updateStarterButton(_ pack: ChatStickerStarterPack) {
        guard let row = starterRows[pack.manifestURL] else { return }
        let button = row.button
        var configuration = button.configuration ?? .tinted()
        let state = installStates[pack.manifestURL]
        switch state {
        case .installing:
            configuration.title = L10n.text("chat__stickers__installing", fallback: "Installing…")
        case .failed:
            configuration.title = L10n.text("common__action__retry", fallback: "Retry")
        case nil:
            configuration.title = L10n.text("common__action__add", fallback: "Add")
        }
        configuration.showsActivityIndicator = state == .installing
        button.configuration = configuration
        button.isEnabled = state != .installing
        button.accessibilityValue = configuration.title
        row.status.isHidden = state != .failed
        button.accessibilityHint = state == .failed ? row.status.text : nil
    }

    private func selectPack(_ url: URL) {
        guard packs.contains(where: { $0.manifestURL == url }) else { return }
        let alreadySelected = selectedPackURL == url
        selectedPackURL = url
        showingStarterPacks = false
        if !alreadySelected { reloadGrid(keepingOffset: false) }
        updateVisibleContent()
    }

    private func reloadGrid(keepingOffset: Bool) {
        let previousOffset = collection.contentOffset
        collection.reloadData()
        collection.layoutIfNeeded()
        let maxY = max(0, collection.contentSize.height - collection.bounds.height)
        let offset = keepingOffset ? CGPoint(x: 0, y: min(previousOffset.y, maxY)) : .zero
        collection.setContentOffset(offset, animated: false)
    }

    private func installStarterPack(_ pack: ChatStickerStarterPack) {
        let url = pack.manifestURL
        guard installTasks[url] == nil, !packs.contains(where: { $0.manifestURL == url }) else { return }
        installStates[url] = .installing
        updateStarterButton(pack)
        installTasks[url] = Task { [weak self, catalogue, owner] in
            do {
                let installed = try await catalogue.install(url, owner: owner)
                guard let self, !Task.isCancelled else { return }
                self.installTasks[url] = nil
                self.installStates[url] = nil
                self.reloadCatalogue()
                self.selectPack(installed.manifestURL)
                if self.view.window != nil, let index = self.packs.firstIndex(where: { $0.manifestURL == url }) {
                    self.packStrip.layoutIfNeeded()
                    self.packStrip.scrollToItem(at: IndexPath(item: index, section: 0),
                                                at: .centeredHorizontally, animated: true)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTasks[url] = nil
                self.installStates[url] = .failed
                self.updateStarterButton(pack)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === packStrip ? packs.count : stickers.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatStickerPickerCell.identifier, for: indexPath) as! ChatStickerPickerCell
        if collectionView === packStrip {
            let pack = packs[indexPath.item]
            cell.configurePack(pack, owner: owner, selected: !showingStarterPacks && pack.manifestURL == selectedPackURL) { [weak self] in
                self?.selectPack(pack.manifestURL)
            }
            return cell
        }

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
        collectionView.deselectItem(at: indexPath, animated: false)
        if collectionView === packStrip {
            guard packs.indices.contains(indexPath.item) else { return }
            selectPack(packs[indexPath.item].manifestURL)
        } else if stickers.indices.contains(indexPath.item) {
            let cell = collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell
            choose(stickers[indexPath.item], from: cell, schedules: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if collectionView === packStrip { return CGSize(width: 44, height: 42) }
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
        guard collectionView === collection, stickers.indices.contains(indexPath.item), canSchedule() else { return nil }
        let sticker = stickers[indexPath.item]
        let cell = collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell
        let action = UIAction(title: L10n.text("schedule_message_action", fallback: "Schedule Message"),
                              image: UIImage(systemName: "calendar.badge.clock")) { [weak self, weak cell] _ in
            self?.choose(sticker, from: cell, schedules: true)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [action])
        }
    }

    private func choose(_ entry: ChatStickerEntry, from cell: ChatStickerPickerCell?, schedules: Bool) {
        guard !showingStarterPacks, stickers.contains(entry), !schedules || canSchedule() else { return }
        let thumbnail = cell?.thumbnail.inlineThumbnail(for: entry)
        let handler = schedules ? onSchedule : onSend
        handler(entry.descriptor(thumbnail: thumbnail))
    }
}

private final class ChatStickerPickerCell: UICollectionViewCell {
    static let identifier = "ChatStickerPickerCell"
    let thumbnail = ChatStickerThumbnailView()
    private var activate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
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
        activate = nil
        accessibilityCustomActions = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }

    func configure(sticker: ChatStickerEntry, owner: String, send: @escaping () -> Void, schedule: (() -> Void)?) {
        activate = send
        setPackSelected(false)
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
        accessibilityCustomActions = actions
        thumbnail.load(sticker, owner: owner, size: 72)
    }

    func configurePack(_ pack: ChatStickerPack, owner: String, selected: Bool, activate: @escaping () -> Void) {
        self.activate = activate
        accessibilityIdentifier = "chat.stickers.pack"
        accessibilityLabel = pack.displayName
        accessibilityHint = nil
        accessibilityCustomActions = nil
        setPackSelected(selected)
        let first = pack.stickers.first
        thumbnail.loadPackPreview(pack.coverURL ?? first?.imageURL, owner: owner, size: 36,
                                  placeholderText: first?.emojis.first ?? "🖼️")
    }

    func setPackSelected(_ selected: Bool) {
        contentView.backgroundColor = selected ? tintColor.withAlphaComponent(0.14) : .clear
        accessibilityTraits = selected ? [.button, .selected] : [.button]
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
    private let thumbnails: ChatThumbnailServing
    private let imageView = UIImageView()
    private let placeholder = UILabel()
    private var subscription: ChatThumbnailSubscription?
    private var entry: ChatStickerEntry?
    private var binding = UUID()

    init(thumbnails: ChatThumbnailServing = ChatMediaThumbnailPipeline.shared) {
        self.thumbnails = thumbnails
        super.init(frame: .zero)
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
        placeholder.text = sticker.emojis.first ?? "🖼️"
        requestImage(sticker.imageURL, owner: owner, size: size)
    }

    func loadPackPreview(_ url: URL?, owner: String, size: CGFloat, placeholderText: String = "🖼️") {
        reset()
        placeholder.text = placeholderText
        if let url { requestImage(url, owner: owner, size: size) }
    }

    private func requestImage(_ url: URL, owner: String, size: CGFloat) {
        let id = binding
        let request = ChatThumbnailRequest(
            url: url, displaySize: ChatCollectionPrefetchSize(width: Double(size), height: Double(size)),
            scale: Double(window?.screen.scale ?? UIScreen.main.scale),
            traitStyle: ChatThumbnailTraitStyle(traitCollection.userInterfaceStyle), owner: owner,
            isSticker: true
        )
        let consumer = ChatThumbnailConsumer(
            identity: ChatCollectionPrefetchIdentity(kind: .sticker, messagePrimary: owner,
                                                     referencePrimary: url.absoluteString),
            role: .visible(id)
        )
        subscription = thumbnails.acquire(request, consumer: consumer) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.binding == id, case .success(let thumbnail) = result else { return }
                self.imageView.image = thumbnail.image
                self.placeholder.isHidden = true
            }
        }
    }
}
