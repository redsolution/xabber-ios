//
//  VoiceGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 24.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import UIKit

protocol MediaGalleryVoicePlaybackCoordinating: AnyObject {
    @discardableResult
    func addObserver(_ observer: @escaping (VoiceMessageStateChange) -> Void) -> UUID
    func removeObserver(_ token: UUID?)
    func state(for descriptor: VoiceMessageDescriptor) -> VoiceMessagePlaybackState
    func handleTap(_ descriptor: VoiceMessageDescriptor)
    func setVisibleVoiceMessages(_ visibleDescriptors: [VoiceMessageDescriptor])
}

extension VoiceMessagePlaybackCoordinator: MediaGalleryVoicePlaybackCoordinating {}

struct MediaGalleryVoiceListLayoutPolicy: Equatable {
    let sectionInset: UIEdgeInsets
    let rowHeight: CGFloat

    init(
        sectionInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        rowHeight: CGFloat = 80
    ) {
        self.sectionInset = sectionInset
        self.rowHeight = max(44, rowHeight)
    }

    func itemSize(
        containerWidth: CGFloat,
        contentInset: UIEdgeInsets = .zero
    ) -> CGSize {
        let horizontalInset = sectionInset.left
            + sectionInset.right
            + contentInset.left
            + contentInset.right
        return CGSize(
            width: max(0, containerWidth - horizontalInset),
            height: rowHeight
        )
    }
}

final class MediaGalleryVoiceListFlowLayout: UICollectionViewFlowLayout {
    let policy: MediaGalleryVoiceListLayoutPolicy

    init(policy: MediaGalleryVoiceListLayoutPolicy = MediaGalleryVoiceListLayoutPolicy()) {
        self.policy = policy
        super.init()
        sectionInset = policy.sectionInset
        minimumLineSpacing = 1
        minimumInteritemSpacing = 0
        itemSize = CGSize(width: 1, height: policy.rowHeight)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        if let collectionView {
            itemSize = policy.itemSize(
                containerWidth: collectionView.bounds.width,
                contentInset: collectionView.adjustedContentInset
            )
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return true }
        return abs(newBounds.width - collectionView.bounds.width) > .ulpOfOne
    }
}

enum MediaGalleryVoiceDescriptorMapper {
    static func descriptor(
        for item: BaseMediaGalleryForChatViewController.Datasource
    ) -> VoiceMessageDescriptor {
        VoiceMessageDescriptor(
            referencePrimary: item.primary,
            containerMessagePrimary: item.messagePrimary,
            remoteURL: item.url,
            decodedURL: item.decodedURL,
            duration: max(0, item.durationSeconds ?? 0),
            downloaded: item.isDownloaded || item.decodedURL != nil,
            pcm: item.pcm,
            sentDate: item.date,
            archivedId: normalized(item.archiveId)
        )
    }

    private static func normalized(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum MediaGalleryVoiceWaveformPolicy {
    private static let fallbackPattern: [Float] = [
        0.18, 0.32, 0.48, 0.26, 0.62, 0.4,
        0.22, 0.54, 0.36, 0.7, 0.3, 0.44
    ]

    static func levels(for pcm: [Float]) -> [Float] {
        guard !pcm.isEmpty else {
            return (0..<48).map { fallbackPattern[$0 % fallbackPattern.count] }
        }
        return pcm.map { min(max($0, 0.08), 1) }
    }
}

struct MediaGalleryVoiceRowState: Equatable {
    let descriptor: VoiceMessageDescriptor
    let playbackState: VoiceMessagePlaybackState
    let waveformLevels: [Float]
    let waveformProgress: Double
    let controlIconSystemName: String
    let durationText: String
    let metadataText: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let controlAccessibilityLabel: String
}

enum MediaGalleryVoiceRowStatePolicy {
    static func state(
        descriptor: VoiceMessageDescriptor,
        playbackState: VoiceMessagePlaybackState
    ) -> MediaGalleryVoiceRowState {
        let totalDuration = duration(for: playbackState, fallback: descriptor.duration)
        let totalText = MediaGalleryDatasourceMapper.formatDuration(totalDuration)
        let controlIconSystemName: String
        let controlAccessibilityLabel: String
        let durationText: String

        switch playbackState {
        case .notDownloaded:
            controlIconSystemName = "square.and.arrow.down"
            controlAccessibilityLabel = "Download voice message"
            durationText = totalText
        case .queued:
            controlIconSystemName = "clock"
            controlAccessibilityLabel = "Voice message queued for download"
            durationText = "Queued · \(totalText)"
        case .downloading(let progress):
            controlIconSystemName = "xmark"
            controlAccessibilityLabel = "Cancel voice message download"
            durationText = "\(totalText) · \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        case .downloaded:
            controlIconSystemName = "play.fill"
            controlAccessibilityLabel = "Play voice message"
            durationText = totalText
        case .playing(let currentTime, let duration):
            controlIconSystemName = "pause.fill"
            controlAccessibilityLabel = "Pause voice message"
            durationText = "\(MediaGalleryDatasourceMapper.formatDuration(currentTime)) / \(MediaGalleryDatasourceMapper.formatDuration(duration))"
        case .paused(let currentTime, let duration):
            controlIconSystemName = "play.fill"
            controlAccessibilityLabel = "Resume voice message"
            durationText = "\(MediaGalleryDatasourceMapper.formatDuration(currentTime)) / \(MediaGalleryDatasourceMapper.formatDuration(duration))"
        case .failed:
            controlIconSystemName = "arrow.clockwise"
            controlAccessibilityLabel = "Retry voice message download"
            durationText = "Retry · \(totalText)"
        }

        let metadataText = DateFormatter.localizedString(
            from: descriptor.sentDate,
            dateStyle: .short,
            timeStyle: .short
        )
        return MediaGalleryVoiceRowState(
            descriptor: descriptor,
            playbackState: playbackState,
            waveformLevels: MediaGalleryVoiceWaveformPolicy.levels(for: descriptor.pcm),
            waveformProgress: playbackState.playbackProgress,
            controlIconSystemName: controlIconSystemName,
            durationText: durationText,
            metadataText: metadataText,
            accessibilityIdentifier: "mediaGallery.voice.row.\(descriptor.referencePrimary)",
            accessibilityLabel: ["Voice message", metadataText, durationText]
                .filter { !$0.isEmpty }
                .joined(separator: ", "),
            controlAccessibilityLabel: controlAccessibilityLabel
        )
    }

    private static func duration(
        for state: VoiceMessagePlaybackState,
        fallback: TimeInterval
    ) -> TimeInterval {
        switch state {
        case .playing(_, let duration), .paused(_, let duration):
            return max(duration, 0)
        default:
            return max(fallback, 0)
        }
    }
}

enum MediaGalleryVoiceMenuIdentifier {
    static let goToMessage = UIAction.Identifier("mediaGallery.voice.goToMessage")
    static let report = MediaGalleryContextMenuIdentifier.report
}

final class VoiceGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    final class GalleryVoiceItemCell: UICollectionViewCell {
        static let cellName = "MediaGalleryVoiceRowCell"

        let controlButton: UIButton = {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tintColor = .white
            button.backgroundColor = .systemBlue
            button.layer.cornerRadius = 22
            button.layer.cornerCurve = .continuous
            button.accessibilityIdentifier = "mediaGallery.voice.control"
            return button
        }()

        let waveformView: AudioVisualizationView = {
            let view = AudioVisualizationView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.audioVisualizationMode = .read
            view.audioVisualizationType = .both
            view.backgroundColor = .clear
            view.gradientStartColor = .systemBlue
            view.gradientEndColor = .systemBlue
            view.barBackgroundFillColor = UIColor.systemBlue.withAlphaComponent(0.2)
            view.meteringLevelBarWidth = 2
            view.meteringLevelBarCornerRadius = 2
            view.meteringLevelBarInterItem = 1.5
            view.isUserInteractionEnabled = false
            return view
        }()

        let metadataLabel: UILabel = {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.preferredFont(forTextStyle: .caption2)
            label.textColor = .secondaryLabel
            label.adjustsFontForContentSizeCategory = true
            return label
        }()

        let durationLabel: UILabel = {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.textAlignment = .right
            label.adjustsFontForContentSizeCategory = true
            return label
        }()

        private(set) var renderedState: MediaGalleryVoiceRowState?
        private(set) var renderedWaveformLevels: [Float] = []
        private var onPrimaryAction: (() -> Void)?
        private var onJumpToMessage: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            state: MediaGalleryVoiceRowState,
            onPrimaryAction: @escaping () -> Void,
            onJumpToMessage: @escaping () -> Void
        ) {
            self.onPrimaryAction = onPrimaryAction
            self.onJumpToMessage = onJumpToMessage
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(
                    name: "Go to message".localizeString(id: "go_to_message", arguments: []),
                    actionHandler: { [weak self] _ in
                        guard let self else { return false }
                        self.onJumpToMessage?()
                        return true
                    }
                )
            ]
            render(state: state)
        }

        func render(state: MediaGalleryVoiceRowState) {
            renderedState = state
            renderedWaveformLevels = state.waveformLevels
            contentView.layoutIfNeeded()
            waveformView.meteringLevels = state.waveformLevels
            waveformView.currentGradientPercentage = Float(state.waveformProgress)
            waveformView.setNeedsDisplay()
            controlButton.setImage(
                UIImage(systemName: state.controlIconSystemName),
                for: .normal
            )
            controlButton.accessibilityLabel = state.controlAccessibilityLabel
            metadataLabel.text = state.metadataText
            durationLabel.text = state.durationText
            accessibilityIdentifier = state.accessibilityIdentifier
            accessibilityLabel = state.accessibilityLabel
            accessibilityHint = "Double tap to play or download. More actions are available."
        }

        override func accessibilityActivate() -> Bool {
            onPrimaryAction?()
            return onPrimaryAction != nil
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            renderedState = nil
            renderedWaveformLevels = []
            waveformView.pause()
            waveformView.currentGradientPercentage = 0
            onPrimaryAction = nil
            onJumpToMessage = nil
            accessibilityCustomActions = nil
            accessibilityIdentifier = nil
            accessibilityLabel = nil
            accessibilityHint = nil
            metadataLabel.text = nil
            durationLabel.text = nil
            controlButton.setImage(nil, for: .normal)
        }

        @objc
        private func controlButtonTapped() {
            onPrimaryAction?()
        }

        private func setup() {
            contentView.backgroundColor = .secondarySystemBackground
            contentView.layer.cornerRadius = 12
            contentView.layer.cornerCurve = .continuous
            contentView.addSubview(controlButton)
            contentView.addSubview(waveformView)
            contentView.addSubview(metadataLabel)
            contentView.addSubview(durationLabel)
            controlButton.addTarget(
                self,
                action: #selector(controlButtonTapped),
                for: .touchUpInside
            )
            isAccessibilityElement = true
            accessibilityTraits = .button

            NSLayoutConstraint.activate([
                controlButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                controlButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                controlButton.widthAnchor.constraint(equalToConstant: 44),
                controlButton.heightAnchor.constraint(equalToConstant: 44),

                waveformView.leadingAnchor.constraint(equalTo: controlButton.trailingAnchor, constant: 12),
                waveformView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
                waveformView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                waveformView.heightAnchor.constraint(equalToConstant: 30),

                metadataLabel.leadingAnchor.constraint(equalTo: waveformView.leadingAnchor),
                metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -8),
                metadataLabel.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 6),
                durationLabel.trailingAnchor.constraint(equalTo: waveformView.trailingAnchor),
                durationLabel.centerYAnchor.constraint(equalTo: metadataLabel.centerYAnchor)
            ])
        }
    }

    let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "No voice messages"
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "mediaGallery.voice.emptyState"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    var playbackCoordinator: MediaGalleryVoicePlaybackCoordinating = VoiceMessagePlaybackCoordinator.shared
    private(set) var playbackObserverToken: UUID?
    private var visibleDescriptors: [VoiceMessageDescriptor] = []

    let collectionView: UICollectionView = {
        let view = UICollectionView(
            frame: .zero,
            collectionViewLayout: MediaGalleryVoiceListFlowLayout()
        )
        view.register(
            GalleryVoiceItemCell.self,
            forCellWithReuseIdentifier: GalleryVoiceItemCell.cellName
        )
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "mediaGallery.voice.list"
        return view
    }()

    deinit {
        playbackCoordinator.removeObserver(playbackObserverToken)
        playbackCoordinator.setVisibleVoiceMessages([])
    }

    override func apply(_ newDatasource: [Datasource]) {
        let changes = compareDatasource(newDatasource)
        if datasource.isEmpty || newDatasource.isEmpty {
            datasource = newDatasource
            collectionView.reloadData()
            updateEmptyState()
            scheduleVisibleVoiceMessageUpdate()
            return
        }

        collectionView.reload(changes: changes) { [weak self] in
            self?.datasource = newDatasource
            self?.updateEmptyState()
            self?.scheduleVisibleVoiceMessageUpdate()
        }
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 24
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -24
            ),
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func configure() {
        super.configure()
        title = "Voice"
        kind = .voice
        collectionView.prefetchDataSource = self
        collectionView.dataSource = self
        collectionView.delegate = self
        updateEmptyState()
    }

    override func subscribe() {
        super.subscribe()
        beginPlaybackObservation()
        scheduleVisibleVoiceMessageUpdate()
    }

    override func unsubscribe() {
        endPlaybackObservation()
        super.unsubscribe()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateVisibleVoiceMessages(at: collectionView.indexPathsForVisibleItems)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GalleryVoiceItemCell.cellName,
            for: indexPath
        ) as? GalleryVoiceItemCell else {
            fatalError("Unable to dequeue media gallery voice row")
        }
        guard datasource.indices.contains(indexPath.row) else {
            cell.prepareForReuse()
            return cell
        }
        let item = datasource[indexPath.row]
        let descriptor = MediaGalleryVoiceDescriptorMapper.descriptor(for: item)
        let state = MediaGalleryVoiceRowStatePolicy.state(
            descriptor: descriptor,
            playbackState: playbackCoordinator.state(for: descriptor)
        )
        cell.configure(
            state: state,
            onPrimaryAction: { [weak self] in
                self?.handlePrimaryAction(for: item)
            },
            onJumpToMessage: { [weak self] in
                self?.performMessageJump(for: item)
            }
        )
        return cell
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard datasource.indices.contains(indexPath.row) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        handlePrimaryAction(for: datasource[indexPath.row])
    }

    func handlePrimaryAction(for item: Datasource) {
        playbackCoordinator.handleTap(
            MediaGalleryVoiceDescriptorMapper.descriptor(for: item)
        )
    }

    func performMessageJump(for item: Datasource) {
        openContainingMessage(for: item)
    }

    func beginPlaybackObservation() {
        guard playbackObserverToken == nil else { return }
        playbackObserverToken = playbackCoordinator.addObserver { [weak self] change in
            if Thread.isMainThread {
                self?.handlePlaybackStateChange(change)
            } else {
                DispatchQueue.main.async {
                    self?.handlePlaybackStateChange(change)
                }
            }
        }
    }

    func endPlaybackObservation() {
        playbackCoordinator.removeObserver(playbackObserverToken)
        playbackObserverToken = nil
        visibleDescriptors = []
        playbackCoordinator.setVisibleVoiceMessages([])
    }

    func updateVisibleVoiceMessages(at indexPaths: [IndexPath]) {
        var seen = Set<Int>()
        let descriptors = indexPaths
            .filter { $0.section == 0 && datasource.indices.contains($0.row) }
            .sorted { $0.row < $1.row }
            .compactMap { indexPath -> VoiceMessageDescriptor? in
                guard seen.insert(indexPath.row).inserted else { return nil }
                return MediaGalleryVoiceDescriptorMapper.descriptor(
                    for: datasource[indexPath.row]
                )
            }
        guard descriptors != visibleDescriptors else { return }
        visibleDescriptors = descriptors
        playbackCoordinator.setVisibleVoiceMessages(descriptors)
    }

    @available(iOS 13.0, *)
    override func contextMenuActions(for item: Datasource) -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if canOpenContainingMessage(for: item) {
            actions.append(
                UIAction(
                    title: "Go to message".localizeString(id: "go_to_message", arguments: []),
                    image: UIImage(systemName: "bubble.left.and.text.bubble.right"),
                    identifier: MediaGalleryVoiceMenuIdentifier.goToMessage
                ) { [weak self] _ in
                    self?.performMessageJump(for: item)
                }
            )
        }
        return actions + super.contextMenuActions(for: item)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        super.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleVoiceMessages(at: collectionView.indexPathsForVisibleItems)
    }

    private func handlePlaybackStateChange(_ change: VoiceMessageStateChange) {
        guard let row = datasource.firstIndex(where: { $0.primary == change.referencePrimary }),
              let cell = collectionView.cellForItem(
                at: IndexPath(item: row, section: 0)
              ) as? GalleryVoiceItemCell else {
            return
        }
        let descriptor = MediaGalleryVoiceDescriptorMapper.descriptor(for: datasource[row])
        cell.render(
            state: MediaGalleryVoiceRowStatePolicy.state(
                descriptor: descriptor,
                playbackState: change.state
            )
        )
    }

    private func scheduleVisibleVoiceMessageUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateVisibleVoiceMessages(at: self.collectionView.indexPathsForVisibleItems)
        }
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !datasource.isEmpty
        collectionView.isHidden = datasource.isEmpty
    }
}
