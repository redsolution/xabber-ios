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

    private enum SectionID: Equatable {
        case recentlyUsed
        case pack(URL)
    }

    private enum StickerSection: Equatable {
        case recentlyUsed([ChatStickerEntry])
        case pack(ChatStickerPack)

        var id: SectionID {
            switch self {
            case .recentlyUsed: .recentlyUsed
            case .pack(let pack): .pack(pack.manifestURL)
            }
        }

        var title: String {
            switch self {
            case .recentlyUsed: L10n.text("chat__stickers__recently_used", fallback: "Recently Used")
            case .pack(let pack): pack.displayName
            }
        }

        var entries: [ChatStickerEntry] {
            switch self {
            case .recentlyUsed(let entries): entries
            case .pack(let pack): pack.stickers
            }
        }
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
    private var sections: [StickerSection] = []
    private var selectedSection: SectionID?
    private var isJumpingToSection = false
    private var isReloadingSections = false
    private var showingStarterPacks = false
    private var installTasks: [URL: Task<Void, Never>] = [:]
    private var installStates: [URL: StarterInstallState] = [:]

    private let panelSurface = UIVisualEffectView()
    private let controlsView = UIView()
    private var controlsConstraints: [NSLayoutConstraint] = []
    private var keyboardHostBottomInset: CGFloat?
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
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityIdentifier = "chat.stickers.panel"

        panelSurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelSurface)
        NSLayoutConstraint.activate([
            panelSurface.topAnchor.constraint(equalTo: view.topAnchor),
            panelSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panelSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updatePanelSurface(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        attachControlsView()

        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        collection.alwaysBounceVertical = true
        collection.automaticallyAdjustsScrollIndicatorInsets = false
        collection.accessibilityIdentifier = "chat.stickers.picker"
        collection.register(ChatStickerSectionHeader.self,
                            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                            withReuseIdentifier: ChatStickerSectionHeader.identifier)
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
        let safeArea = controlsView.safeAreaLayoutGuide
        for child in [toolbar, collection, starterScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            controlsView.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            collection.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            collection.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor),
            starterScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            starterScroll.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(catalogueChanged(_:)),
                                               name: ChatStickerCatalogue.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(catalogueChanged(_:)),
                                               name: ChatStickerCatalogue.recentlyUsedChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceTransparencyDidChange),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                                               object: nil)
        reloadCatalogue()
        updateScrollBottomInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateScrollBottomInsets()
    }

    func setKeyboardHostBottomInset(_ inset: CGFloat?) {
        guard keyboardHostBottomInset != inset else { return }
        let hostChanged = (keyboardHostBottomInset == nil) != (inset == nil)
        keyboardHostBottomInset = inset
        guard isViewLoaded else { return }
        if hostChanged {
            attachControlsView()
        }
        updateScrollBottomInsets()
    }

    private func attachControlsView() {
        let hostedByKeyboard = keyboardHostBottomInset != nil
        panelSurface.isHidden = hostedByKeyboard
        let host = hostedByKeyboard ? view! : panelSurface.contentView
        NSLayoutConstraint.deactivate(controlsConstraints)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controlsView)
        controlsConstraints = [
            controlsView.topAnchor.constraint(equalTo: host.topAnchor),
            controlsView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ]
        NSLayoutConstraint.activate(controlsConstraints)
    }

    private func updateScrollBottomInsets() {
        let bottom = max(view.safeAreaInsets.bottom, keyboardHostBottomInset ?? 0)
        for scrollView in [collection, starterScroll] {
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    @objc private func reduceTransparencyDidChange() {
        updatePanelSurface(reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
    }

    func updatePanelSurface(reduceTransparency: Bool) {
        NativeGlassBarStyle.applySurface(
            to: panelSurface,
            role: .sheet,
            cornerStyle: .fixed(32),
            interactive: false,
            prefersNativeGlass: !reduceTransparency,
            nativeGlassStyle: .regular
        )
        if reduceTransparency {
            panelSurface.backgroundColor = .secondarySystemBackground
            panelSurface.contentView.backgroundColor = .secondarySystemBackground
        }
    }

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
        starterScroll.automaticallyAdjustsScrollIndicatorInsets = false
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
        let installed = catalogue.installed(for: owner)
        let recent = catalogue.recentStickers(for: owner)
        var updatedSections: [StickerSection] = recent.isEmpty ? [] : [.recentlyUsed(recent)]
        updatedSections.append(contentsOf: installed.map(StickerSection.pack))
        if sections != updatedSections {
            let previousSelection = selectedSection
            let previousIndex = sections.firstIndex { $0.id == previousSelection } ?? 0
            let headerY = previousSelection.flatMap { gridHeaderY(for: $0) }
            let offsetInSection = headerY.map { collection.contentOffset.y - $0 } ?? 0
            let wasEmpty = sections.isEmpty
            packs = installed
            sections = updatedSections
            if !sections.contains(where: { $0.id == previousSelection }) {
                selectedSection = sections.isEmpty ? nil : sections[min(previousIndex, sections.count - 1)].id
            }
            if wasEmpty { showingStarterPacks = sections.isEmpty }

            isJumpingToSection = false
            isReloadingSections = true
            packStrip.reloadData()
            collection.reloadData()
            collection.layoutIfNeeded()
            if let selectedSection, let headerY = gridHeaderY(for: selectedSection) {
                let offset = selectedSection == previousSelection ? offsetInSection : 0
                let y = clampedGridOffsetY(headerY + offset)
                collection.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            }
            isReloadingSections = false
        }
        updateVisibleContent()
    }

    private func updateVisibleContent() {
        let installedURLs = Set(packs.map(\.manifestURL))
        let hasAvailableStarterPack = ChatStickerStarterPack.all.contains { !installedURLs.contains($0.manifestURL) }
        showingStarterPacks = sections.isEmpty || (showingStarterPacks && hasAvailableStarterPack)
        for pack in ChatStickerStarterPack.all {
            guard let row = starterRows[pack.manifestURL] else { continue }
            let isInstalled = installedURLs.contains(pack.manifestURL)
            row.view.isHidden = isInstalled
            if showingStarterPacks, !isInstalled, loadedStarterPreviews.insert(pack.manifestURL).inserted {
                row.thumbnail.loadPackPreview(pack.previewURL, owner: owner, size: 44)
            }
            updateStarterButton(pack)
        }

        addButton.isHidden = sections.isEmpty || !hasAvailableStarterPack
        addButton.isSelected = showingStarterPacks
        addButton.accessibilityTraits = showingStarterPacks ? [.button, .selected] : [.button]
        starterScroll.isHidden = !showingStarterPacks
        collection.isHidden = showingStarterPacks

        updateRibbonSelection()
    }

    private func updateRibbonSelection() {
        for indexPath in packStrip.indexPathsForVisibleItems where sections.indices.contains(indexPath.item) {
            let cell = packStrip.cellForItem(at: indexPath) as? ChatStickerPickerCell
            cell?.setPackSelected(!showingStarterPacks && sections[indexPath.item].id == selectedSection)
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

    private func jumpToSection(_ id: SectionID) {
        guard sections.contains(where: { $0.id == id }) else { return }
        showingStarterPacks = false
        selectedSection = id
        updateVisibleContent()
        collection.layoutIfNeeded()
        guard let headerY = gridHeaderY(for: id) else { return }
        let y = clampedGridOffsetY(headerY - collection.adjustedContentInset.top)
        let animated = view.window != nil && abs(collection.contentOffset.y - y) > 0.5
        isJumpingToSection = true
        collection.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        if !animated { isJumpingToSection = false }
        revealSelectedRibbonItem()
    }

    private func gridHeaderY(for id: SectionID) -> CGFloat? {
        guard collection.bounds.width > 0,
              let index = sections.firstIndex(where: { $0.id == id }) else { return nil }
        let path = IndexPath(item: 0, section: index)
        return layout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: path)?
            .frame.minY
    }

    private func clampedGridOffsetY(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, -collection.adjustedContentInset.top), maximumGridOffsetY)
    }

    private var maximumGridOffsetY: CGFloat {
        max(-collection.adjustedContentInset.top,
            collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
    }

    private func revealSelectedRibbonItem() {
        guard view.window != nil, packStrip.bounds.width > 0,
              let index = sections.firstIndex(where: { $0.id == selectedSection }),
              index < packStrip.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: index, section: 0)
        guard !packStrip.indexPathsForVisibleItems.contains(path) else { return }
        packStrip.scrollToItem(at: path, at: .centeredHorizontally, animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collection, !showingStarterPacks, !isJumpingToSection, !isReloadingSections,
              !sections.isEmpty else { return }
        let top = collection.contentOffset.y + collection.adjustedContentInset.top
        let height = max(0, collection.bounds.height - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom)
        let viewport = CGRect(x: 0, y: top, width: collection.bounds.width, height: height)
        let maximum = maximumGridOffsetY
        let currentIndex: Int?
        if maximum > 0.5, collection.contentOffset.y >= maximum - 0.5 {
            currentIndex = sections.indices.last
        } else {
            currentIndex = layout.layoutAttributesForElements(in: viewport)?.map(\.indexPath.section).min()
        }
        guard let currentIndex, sections.indices.contains(currentIndex),
              sections[currentIndex].id != selectedSection else { return }
        selectedSection = sections[currentIndex].id
        updateRibbonSelection()
        revealSelectedRibbonItem()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === collection { isJumpingToSection = false }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === collection { isJumpingToSection = false }
    }

    private func installStarterPack(_ pack: ChatStickerStarterPack) {
        let url = pack.manifestURL
        guard installTasks[url] == nil, !packs.contains(where: { $0.manifestURL == url }) else { return }
        installStates[url] = .installing
        updateStarterButton(pack)
        let imageProfile = ChatStickerImageProfile(view: view)
        installTasks[url] = Task { [weak self, catalogue, owner] in
            do {
                let installed = try await catalogue.install(url, owner: owner, imageProfile: imageProfile)
                guard let self, !Task.isCancelled else { return }
                self.installTasks[url] = nil
                self.installStates[url] = nil
                self.reloadCatalogue()
                self.jumpToSection(.pack(installed.manifestURL))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTasks[url] = nil
                self.installStates[url] = .failed
                self.updateStarterButton(pack)
            }
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === packStrip ? 1 : sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === packStrip ? sections.count : sections[section].entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatStickerPickerCell.identifier, for: indexPath) as! ChatStickerPickerCell
        let imageProfile = ChatStickerImageProfile(view: view)
        if collectionView === packStrip {
            let section = sections[indexPath.item]
            let id = section.id
            let selected = !showingStarterPacks && id == selectedSection
            let activate: () -> Void = { [weak self] in self?.jumpToSection(id) }
            switch section {
            case .recentlyUsed:
                cell.configureRecents(title: section.title, selected: selected, activate: activate)
            case .pack(let pack):
                cell.configurePack(pack, owner: owner, imageProfile: imageProfile, selected: selected, activate: activate)
            }
            return cell
        }

        let sticker = sections[indexPath.section].entries[indexPath.item]
        cell.configure(sticker: sticker, owner: owner, imageProfile: imageProfile, send: { [weak self, weak cell] in
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
            guard sections.indices.contains(indexPath.item) else { return }
            jumpToSection(sections[indexPath.item].id)
        } else if let sticker = sticker(at: indexPath) {
            let cell = collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell
            choose(sticker, from: cell, schedules: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: ChatStickerSectionHeader.identifier, for: indexPath
        ) as! ChatStickerSectionHeader
        header.setTitle(sections[indexPath.section].title)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        guard collectionView === collection else { return .zero }
        let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection)
        return CGSize(width: collectionView.bounds.width, height: ceil(font.lineHeight) + 12)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if collectionView === packStrip { return CGSize(width: 44, height: 42) }
        let available = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let spacing = layout.minimumInteritemSpacing
        let columns = max(3, Int((available + spacing) / (104 + spacing)))
        let size = max(1, floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        return CGSize(width: size, height: size)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard collectionView === collection, let sticker = sticker(at: indexPath), canSchedule() else { return nil }
        let cell = collectionView.cellForItem(at: indexPath) as? ChatStickerPickerCell
        let action = UIAction(title: L10n.text("schedule_message_action", fallback: "Schedule Message"),
                              image: UIImage(systemName: "calendar.badge.clock")) { [weak self, weak cell] _ in
            self?.choose(sticker, from: cell, schedules: true)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [action])
        }
    }

    private func sticker(at indexPath: IndexPath) -> ChatStickerEntry? {
        guard sections.indices.contains(indexPath.section) else { return nil }
        let entries = sections[indexPath.section].entries
        return entries.indices.contains(indexPath.item) ? entries[indexPath.item] : nil
    }

    private func choose(_ entry: ChatStickerEntry, from cell: ChatStickerPickerCell?, schedules: Bool) {
        guard !showingStarterPacks, sections.contains(where: { $0.entries.contains(entry) }),
              !schedules || canSchedule() else { return }
        let thumbnail = cell?.thumbnail.inlineThumbnail(for: entry)
        let handler = schedules ? onSchedule : onSend
        handler(entry.descriptor(thumbnail: thumbnail))
    }
}

private final class ChatStickerSectionHeader: UICollectionReusableView {
    static let identifier = "ChatStickerSectionHeader"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits.insert(.header)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        label.text = title
    }
}

private final class ChatStickerPickerCell: UICollectionViewCell {
    static let identifier = "ChatStickerPickerCell"
    let thumbnail = ChatStickerThumbnailView()
    private let clock = UIImageView(image: UIImage(
        systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    ))
    private var activate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)
        clock.isHidden = true
        clock.tintColor = .label
        clock.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clock)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            thumbnail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            clock.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            clock.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.reset()
        clock.isHidden = true
        activate = nil
        accessibilityCustomActions = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }

    func configure(
        sticker: ChatStickerEntry, owner: String, imageProfile: ChatStickerImageProfile,
        send: @escaping () -> Void, schedule: (() -> Void)?
    ) {
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
        thumbnail.load(sticker, owner: owner, size: ChatStickerImageProfile.gridSize, profile: imageProfile)
    }

    func configurePack(
        _ pack: ChatStickerPack, owner: String, imageProfile: ChatStickerImageProfile,
        selected: Bool, activate: @escaping () -> Void
    ) {
        self.activate = activate
        accessibilityIdentifier = "chat.stickers.pack"
        accessibilityLabel = pack.displayName
        accessibilityHint = nil
        accessibilityCustomActions = nil
        setPackSelected(selected)
        let first = pack.stickers.first
        thumbnail.loadPackPreview(
            pack.coverURL ?? first?.imageURL, owner: owner, size: ChatStickerImageProfile.packCoverSize,
            placeholderText: first?.emojis.first ?? "🖼️", profile: imageProfile
        )
    }

    func configureRecents(title: String, selected: Bool, activate: @escaping () -> Void) {
        self.activate = activate
        accessibilityIdentifier = "chat.stickers.recently_used"
        accessibilityLabel = title
        accessibilityHint = nil
        accessibilityCustomActions = nil
        setPackSelected(selected)
        thumbnail.reset()
        clock.isHidden = false
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

    func load(_ sticker: ChatStickerEntry, owner: String, size: CGFloat, profile: ChatStickerImageProfile? = nil) {
        reset()
        entry = sticker
        placeholder.text = sticker.emojis.first ?? "🖼️"
        requestImage(sticker.imageURL, owner: owner, size: size, profile: profile)
    }

    func loadPackPreview(
        _ url: URL?, owner: String, size: CGFloat, placeholderText: String = "🖼️",
        profile: ChatStickerImageProfile? = nil
    ) {
        reset()
        placeholder.text = placeholderText
        if let url { requestImage(url, owner: owner, size: size, profile: profile) }
    }

    private func requestImage(_ url: URL, owner: String, size: CGFloat, profile: ChatStickerImageProfile?) {
        let id = binding
        let request = (profile ?? ChatStickerImageProfile(view: self)).request(url: url, owner: owner, size: size)
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
