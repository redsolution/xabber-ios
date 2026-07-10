//
//  VideoGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import AVFoundation
import AVKit
import DeepDiff
import Kingfisher
import MaterialComponents.MDCPalettes
import UIKit

protocol MediaGalleryVideoPreviewCacheLoading: AnyObject {
    func retrieveImage(forKey key: String, completion: @escaping (UIImage?) -> Void)
}

final class KingfisherMediaGalleryVideoPreviewCacheLoader: MediaGalleryVideoPreviewCacheLoading {
    static let shared = KingfisherMediaGalleryVideoPreviewCacheLoader()

    func retrieveImage(forKey key: String, completion: @escaping (UIImage?) -> Void) {
        ImageCache.default.retrieveImage(forKey: key) { result in
            switch result {
            case .success(let value):
                completion(value.image)
            case .failure:
                completion(nil)
            }
        }
    }
}

class VideoGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    class GalleryItemCell: UICollectionViewCell {
        static let cellName = "GalleryItemCell"

        let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()
        let placeholderImageView: UIImageView = {
            let view = UIImageView(image: UIImage(systemName: "video.fill"))
            view.contentMode = .scaleAspectFit
            view.tintColor = .secondaryLabel
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()
        let playIconContainer: UIView = {
            let view = UIView()
            view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 1
            view.layer.cornerRadius = 22
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()
        let playIconView: UIImageView = {
            let view = UIImageView(image: UIImage(systemName: "play.fill"))
            view.contentMode = .scaleAspectFit
            view.tintColor = .white
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()
        let durationLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.58)
            label.textAlignment = .center
            label.layer.cornerRadius = 7
            label.layer.masksToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        private let sensitiveOverlay = SensitiveMediaOverlayView()
        private let imageLoader: MediaGalleryImageLoading
        private let previewCacheLoader: MediaGalleryVideoPreviewCacheLoading
        private var representedPrimary: String?

        override init(frame: CGRect) {
            imageLoader = KingfisherMediaGalleryImageLoader.shared
            previewCacheLoader = KingfisherMediaGalleryVideoPreviewCacheLoader.shared
            super.init(frame: frame)
            setup()
        }

        init(
            frame: CGRect,
            imageLoader: MediaGalleryImageLoading,
            previewCacheLoader: MediaGalleryVideoPreviewCacheLoading
        ) {
            self.imageLoader = imageLoader
            self.previewCacheLoader = previewCacheLoader
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            contentView.backgroundColor = .secondarySystemBackground
            contentView.layer.cornerRadius = 4
            contentView.layer.masksToBounds = true
            contentView.layer.borderWidth = 1
            contentView.layer.borderColor = MDCPalette.grey.tint300.cgColor

            contentView.addSubview(imageView)
            contentView.addSubview(placeholderImageView)
            contentView.addSubview(playIconContainer)
            playIconContainer.addSubview(playIconView)
            contentView.addSubview(durationLabel)
            contentView.addSubview(sensitiveOverlay)
            sensitiveOverlay.fillSuperview()
            sensitiveOverlay.isUserInteractionEnabled = false

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

                placeholderImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                placeholderImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                placeholderImageView.widthAnchor.constraint(equalToConstant: 32),
                placeholderImageView.heightAnchor.constraint(equalToConstant: 32),

                playIconContainer.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                playIconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                playIconContainer.widthAnchor.constraint(equalToConstant: 44),
                playIconContainer.heightAnchor.constraint(equalToConstant: 44),

                playIconView.centerXAnchor.constraint(equalTo: playIconContainer.centerXAnchor),
                playIconView.centerYAnchor.constraint(equalTo: playIconContainer.centerYAnchor),
                playIconView.widthAnchor.constraint(equalToConstant: 20),
                playIconView.heightAnchor.constraint(equalToConstant: 20),

                durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
                durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
                durationLabel.heightAnchor.constraint(equalToConstant: 18),
                durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)
            ])
        }

        func configure(
            state: MediaGalleryVideoCellState,
            embeddedThumbnail: UIImage?
        ) {
            imageLoader.cancelLoad(in: imageView)
            representedPrimary = state.primary
            imageView.image = nil
            placeholderImageView.isHidden = false
            playIconContainer.isHidden = !state.showsPlayIcon
            durationLabel.text = state.durationText
            durationLabel.isHidden = state.durationText == nil
            sensitiveOverlay.isHidden = !state.showsSensitiveOverlay

            switch state.previewSource {
            case .request(let request):
                imageLoader.load(
                    request: request,
                    into: imageView,
                    placeholder: nil
                ) { [weak self] outcome in
                    guard let self,
                          self.representedPrimary == state.primary else {
                        return
                    }
                    if outcome == .success {
                        self.placeholderImageView.isHidden = true
                    } else if let embeddedThumbnail {
                        self.imageView.image = embeddedThumbnail
                        self.placeholderImageView.isHidden = true
                    }
                }
            case .cacheKey(let key):
                previewCacheLoader.retrieveImage(forKey: key) { [weak self] image in
                    guard let self,
                          self.representedPrimary == state.primary else {
                        return
                    }
                    if let image {
                        self.imageView.image = image
                        self.placeholderImageView.isHidden = true
                    } else if let embeddedThumbnail {
                        self.imageView.image = embeddedThumbnail
                        self.placeholderImageView.isHidden = true
                    }
                }
            case .embeddedThumbnail:
                imageView.image = embeddedThumbnail
                placeholderImageView.isHidden = embeddedThumbnail != nil
            case .placeholder:
                break
            }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            imageLoader.cancelLoad(in: imageView)
            representedPrimary = nil
            imageView.image = nil
            placeholderImageView.isHidden = false
            playIconContainer.isHidden = false
            durationLabel.text = nil
            durationLabel.isHidden = true
            sensitiveOverlay.isHidden = true
        }
    }

    let collectionView: UICollectionView = {
        let layout = MediaGalleryThreeColumnFlowLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.register(GalleryItemCell.self, forCellWithReuseIdentifier: GalleryItemCell.cellName)
        return view
    }()

    private var imagePrefetchCoordinator: MediaGalleryImagePrefetchCoordinator?

    override func apply(_ newDatasource: [BaseMediaGalleryForChatViewController.Datasource]) {
        let changes = compareDatasource(newDatasource)
        if datasource.isEmpty || newDatasource.isEmpty {
            datasource = newDatasource
            collectionView.reloadData()
        } else {
            collectionView.reload(changes: changes) {
                self.datasource = newDatasource
            }
        }
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(collectionView)
        collectionView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Videos"
        kind = .video
        collectionView.prefetchDataSource = self
        collectionView.dataSource = self
        collectionView.delegate = self
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        imagePrefetchCoordinator?.cancelAll()
    }

    deinit {
        imagePrefetchCoordinator?.cancelAll()
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GalleryItemCell.cellName,
            for: indexPath
        ) as? GalleryItemCell else {
            fatalError()
        }
        guard datasource.indices.contains(indexPath.item) else {
            cell.prepareForReuse()
            return cell
        }

        let item = datasource[indexPath.item]
        let state = MediaGalleryVideoCellStatePolicy.state(
            for: item,
            displaySize: currentGridItemSize,
            scale: currentScreenScale
        )
        cell.configure(state: state, embeddedThumbnail: item.thumb)
        return cell
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        prefetchCoordinator.prefetchItems(at: indexPaths)
        super.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        imagePrefetchCoordinator?.cancelPrefetchingForItems(at: indexPaths)
        super.collectionView(collectionView, cancelPrefetchingForItemsAt: indexPaths)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard datasource.indices.contains(indexPath.item) else { return }
        let item = datasource[indexPath.item]

        switch MediaGalleryVideoSelectionPolicy.action(for: item) {
        case .none:
            return
        case .confirmSensitive(let url):
            let viewController = SensitiveContentFirstPaneViewController()
            viewController.isFirstStep = true
            viewController.urls = [url]
            viewController.url = url
            viewController.delegate = self
            viewController.messagePrimary = item.messagePrimary
            viewController.referencePrimary = item.primary
            viewController.isVideo = true
            showModal(viewController, parent: self)
        case .play(let url):
            playVideo(at: url)
        }
    }

    private var currentGridItemSize: CGSize {
        guard let layout = collectionView.collectionViewLayout as? MediaGalleryThreeColumnFlowLayout else {
            return CGSize(width: 1, height: 1)
        }
        return layout.policy.squareItemSize(
            containerWidth: collectionView.bounds.width,
            contentInset: collectionView.adjustedContentInset
        )
    }

    private var currentScreenScale: CGFloat {
        view.window?.screen.scale ?? UIScreen.main.scale
    }

    private var prefetchCoordinator: MediaGalleryImagePrefetchCoordinator {
        if let imagePrefetchCoordinator {
            return imagePrefetchCoordinator
        }
        let coordinator = MediaGalleryImagePrefetchCoordinator(
            itemProvider: { [weak self] indexPath in
                guard let self,
                      self.datasource.indices.contains(indexPath.item) else {
                    return nil
                }
                return self.datasource[indexPath.item]
            },
            displaySizeProvider: { [weak self] in
                self?.currentGridItemSize ?? CGSize(width: 1, height: 1)
            },
            scaleProvider: { [weak self] in
                self?.currentScreenScale ?? UIScreen.main.scale
            }
        )
        imagePrefetchCoordinator = coordinator
        return coordinator
    }

    private func playVideo(at url: URL) {
        let player = AVPlayer(url: url)
        let controller = AVPlayerViewController()
        controller.player = player
        present(controller, animated: true) {
            player.play()
        }
    }
}

extension VideoGalleryForChatViewController: SensitiveContentFirstPaneViewControllerDelegate {
    func onViewSensitiveMedia(
        messagePrimary: String,
        referencePrimary: String,
        urls: [URL],
        url: URL,
        isVideo: Bool
    ) {
        if referencePrimary.isNotEmpty {
            revealedSensitiveMediaPrimaries.insert(referencePrimary)
            collectionView.reloadData()
        }
        playVideo(at: url)
    }
}
