//
//  FilesGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import UIKit

struct MediaGalleryFileListLayoutPolicy: Equatable {
    let sectionInset: UIEdgeInsets
    let rowHeight: CGFloat

    init(
        sectionInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        rowHeight: CGFloat = 64
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

final class MediaGalleryFileListFlowLayout: UICollectionViewFlowLayout {
    let policy: MediaGalleryFileListLayoutPolicy

    init(policy: MediaGalleryFileListLayoutPolicy = MediaGalleryFileListLayoutPolicy()) {
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

struct MediaGalleryFileRowState: Equatable {
    let filename: String
    let formattedSize: String
    let iconSystemName: String
    let canOpen: Bool
    let canShare: Bool
    let canJumpToMessage: Bool
    let accessibilityIdentifier: String
    let accessibilityLabel: String
}

enum MediaGalleryFileRowStatePolicy {
    static func state(
        for item: BaseMediaGalleryForChatViewController.Datasource
    ) -> MediaGalleryFileRowState {
        let filename = normalized(item.filename)
            ?? normalized(item.url?.lastPathComponent)
            ?? "File"
        let mimeType = normalized(item.mediaType)
            ?? item.url.map { MimeType(url: $0).value }
        let iconSystemName: String
        switch MimeIcon(mimeType ?? "").value {
        case .image:
            iconSystemName = "photo"
        case .video:
            iconSystemName = "film"
        case .audio:
            iconSystemName = "waveform"
        case .document, .pdf, .table, .presentation, .archive, .file, .avatar:
            iconSystemName = "doc"
        }
        let canJumpToMessage = MediaGalleryMessageNavigationRequestBuilder.request(for: item) != nil

        return MediaGalleryFileRowState(
            filename: filename,
            formattedSize: item.formattedByteSize,
            iconSystemName: iconSystemName,
            canOpen: item.url != nil,
            canShare: item.url != nil,
            canJumpToMessage: canJumpToMessage,
            accessibilityIdentifier: "mediaGallery.file.row.\(item.primary)",
            accessibilityLabel: [filename, item.formattedByteSize]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum MediaGalleryFileAction: Equatable {
    case open(URL)
    case share(URL)
    case goToMessage
}

enum MediaGalleryFileActionPolicy {
    static func availableActions(
        for item: BaseMediaGalleryForChatViewController.Datasource
    ) -> [MediaGalleryFileAction] {
        var actions: [MediaGalleryFileAction] = []
        if let url = item.url {
            actions.append(.open(url))
            actions.append(.share(url))
        }
        if MediaGalleryMessageNavigationRequestBuilder.request(for: item) != nil {
            actions.append(.goToMessage)
        }
        return actions
    }

    static func primaryAction(
        for item: BaseMediaGalleryForChatViewController.Datasource
    ) -> MediaGalleryFileAction? {
        guard let url = item.url else { return nil }
        return .open(url)
    }
}

enum MediaGalleryFileMenuIdentifier {
    static let open = UIAction.Identifier("mediaGallery.file.open")
    static let share = UIAction.Identifier("mediaGallery.file.share")
    static let goToMessage = UIAction.Identifier("mediaGallery.file.goToMessage")
    static let report = MediaGalleryContextMenuIdentifier.report
}

@MainActor
protocol MediaGalleryFileActionRouting: AnyObject {
    func open(_ url: URL, from presenter: UIViewController)
    func share(_ url: URL, from presenter: UIViewController, sourceView: UIView?)
}

@MainActor
final class DefaultMediaGalleryFileActionRouter: MediaGalleryFileActionRouting {
    static let shared = DefaultMediaGalleryFileActionRouter()

    private init() {}

    func open(_ url: URL, from presenter: UIViewController) {
        guard UIApplication.shared.canOpenURL(url) else { return }
        YesNoPresenter().present(
            in: presenter,
            title: "Open this file".localizeString(id: "open_file_message", arguments: []),
            message: url.lastPathComponent,
            yesText: "Open".localizeString(id: "open", arguments: []),
            noText: "Cancel".localizeString(id: "cancel", arguments: []),
            animated: true
        ) { confirmed in
            guard confirmed else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func share(_ url: URL, from presenter: UIViewController, sourceView: UIView?) {
        let activityController = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        if let popover = activityController.popoverPresentationController {
            let sourceView = sourceView ?? presenter.view
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(
                x: sourceView?.bounds.midX ?? 0,
                y: sourceView?.bounds.midY ?? 0,
                width: 1,
                height: 1
            )
        }
        presenter.present(activityController, animated: true)
    }
}

final class FilesGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    final class GalleryItemCell: UICollectionViewListCell {
        static let cellName = "MediaGalleryFileRowCell"

        private(set) var rowState: MediaGalleryFileRowState?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
            directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 4,
                leading: 8,
                bottom: 4,
                trailing: 8
            )
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(with state: MediaGalleryFileRowState) {
            rowState = state
            var content = defaultContentConfiguration()
            content.text = state.filename
            content.secondaryText = state.formattedSize
            content.image = UIImage(systemName: state.iconSystemName)
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption1)
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.imageToTextPadding = 12
            contentConfiguration = content
            accessibilityIdentifier = state.accessibilityIdentifier
            accessibilityLabel = state.accessibilityLabel
            accessibilityHint = state.canOpen
                ? "Double tap to open. More actions are available."
                : "More actions are available."
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            rowState = nil
            contentConfiguration = nil
            accessibilityIdentifier = nil
            accessibilityLabel = nil
            accessibilityHint = nil
        }
    }

    let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "No files"
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "mediaGallery.file.emptyState"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    var fileActionRouter: MediaGalleryFileActionRouting = DefaultMediaGalleryFileActionRouter.shared

    let collectionView: UICollectionView = {
        let view = UICollectionView(
            frame: .zero,
            collectionViewLayout: MediaGalleryFileListFlowLayout()
        )
        view.register(
            GalleryItemCell.self,
            forCellWithReuseIdentifier: GalleryItemCell.cellName
        )
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "mediaGallery.file.list"
        return view
    }()

    override func apply(_ newDatasource: [Datasource]) {
        let changes = compareDatasource(newDatasource)
        if datasource.isEmpty || newDatasource.isEmpty {
            datasource = newDatasource
            collectionView.reloadData()
            updateEmptyState()
            return
        }

        collectionView.reload(changes: changes) { [weak self] in
            self?.datasource = newDatasource
            self?.updateEmptyState()
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
        title = "Files"
        kind = .file
        collectionView.prefetchDataSource = self
        collectionView.dataSource = self
        collectionView.delegate = self
        updateEmptyState()
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GalleryItemCell.cellName,
            for: indexPath
        ) as? GalleryItemCell else {
            fatalError("Unable to dequeue media gallery file row")
        }
        guard datasource.indices.contains(indexPath.row) else {
            cell.prepareForReuse()
            return cell
        }
        cell.configure(with: MediaGalleryFileRowStatePolicy.state(for: datasource[indexPath.row]))
        return cell
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard datasource.indices.contains(indexPath.row),
              let action = MediaGalleryFileActionPolicy.primaryAction(
                for: datasource[indexPath.row]
              ) else {
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        performFileAction(
            action,
            for: datasource[indexPath.row],
            sourceView: collectionView.cellForItem(at: indexPath)
        )
    }

    func performFileAction(
        _ action: MediaGalleryFileAction,
        for item: Datasource,
        sourceView: UIView?
    ) {
        switch action {
        case .open(let url):
            fileActionRouter.open(url, from: self)
        case .share(let url):
            fileActionRouter.share(url, from: self, sourceView: sourceView)
        case .goToMessage:
            openContainingMessage(for: item)
        }
    }

    @available(iOS 13.0, *)
    override func contextMenuActions(for item: Datasource) -> [UIMenuElement] {
        let fileActions = MediaGalleryFileActionPolicy.availableActions(for: item).map { action in
            switch action {
            case .open:
                return UIAction(
                    title: "Open".localizeString(id: "open", arguments: []),
                    image: UIImage(systemName: "arrow.up.forward.app"),
                    identifier: MediaGalleryFileMenuIdentifier.open
                ) { [weak self] _ in
                    self?.performFileAction(action, for: item, sourceView: self?.view)
                }
            case .share:
                return UIAction(
                    title: "Share".localizeString(id: "share", arguments: []),
                    image: UIImage(systemName: "square.and.arrow.up"),
                    identifier: MediaGalleryFileMenuIdentifier.share
                ) { [weak self] _ in
                    self?.performFileAction(action, for: item, sourceView: self?.view)
                }
            case .goToMessage:
                return UIAction(
                    title: "Go to message".localizeString(id: "go_to_message", arguments: []),
                    image: UIImage(systemName: "bubble.left.and.text.bubble.right"),
                    identifier: MediaGalleryFileMenuIdentifier.goToMessage
                ) { [weak self] _ in
                    self?.performFileAction(action, for: item, sourceView: self?.view)
                }
            }
        }
        return fileActions + super.contextMenuActions(for: item)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        super.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !datasource.isEmpty
        collectionView.isHidden = datasource.isEmpty
    }
}
