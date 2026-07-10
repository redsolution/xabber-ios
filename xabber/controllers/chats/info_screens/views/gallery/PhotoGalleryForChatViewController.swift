//
//  MediaGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 12.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import DeepDiff
import Kingfisher

class GalleryPlaceholderView: UIView {
    let image: UIImageView = {
        let image = UIImageView()
        image.contentMode = .center
        return image
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(image)
    }

    func configureWithThumb(_ thumb: UIImage?, placeholderImage: UIImage?) {
        if let thumb = thumb?.blurred(radius: 5, targetSize: 128) {
            image.image = thumb
            image.fillSuperview()
        } else {
            image.image = placeholderImage
            image.tintColor = MDCPalette.grey.tint300
            image.fillSuperviewWithOffset(top: 32, bottom: 32, left: 32, right: 32)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension GalleryPlaceholderView: Placeholder {}

enum MediaGalleryImageLoadOutcome: Equatable {
    case success
    case failure
}

protocol MediaGalleryImageLoading: AnyObject {
    func load(
        request: MediaGalleryImageRequest,
        into imageView: UIImageView,
        placeholder: UIView?,
        completion: @escaping (MediaGalleryImageLoadOutcome) -> Void
    )
    func cancelLoad(in imageView: UIImageView)
}

final class KingfisherMediaGalleryImageLoader: MediaGalleryImageLoading {
    static let shared = KingfisherMediaGalleryImageLoader()

    func load(
        request: MediaGalleryImageRequest,
        into imageView: UIImageView,
        placeholder: UIView?,
        completion: @escaping (MediaGalleryImageLoadOutcome) -> Void
    ) {
        imageView.kf.setImage(
            with: request.resource,
            placeholder: placeholder as? GalleryPlaceholderView,
            options: request.kingfisherOptions + [.transition(.fade(0.1))]
        ) { result in
            switch result {
            case .success:
                completion(.success)
            case .failure:
                completion(.failure)
            }
        }
    }

    func cancelLoad(in imageView: UIImageView) {
        imageView.kf.cancelDownloadTask()
    }
}

class PhotoGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    class GalleryPhotoItemCell: UICollectionViewCell {
        static let cellName = "GalleryPhotoItemCell"

        private let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            return view
        }()
        private let sensitiveOverlay = SensitiveMediaOverlayView()
        private let imageLoader: MediaGalleryImageLoading
        private var representedPrimary: String?
        private(set) var failurePlaceholderPrimary: String?

        override init(frame: CGRect) {
            imageLoader = KingfisherMediaGalleryImageLoader.shared
            super.init(frame: frame)
            setup()
        }

        init(frame: CGRect, imageLoader: MediaGalleryImageLoading) {
            self.imageLoader = imageLoader
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            contentView.addSubview(imageView)
            imageView.fillSuperview()
            contentView.addSubview(sensitiveOverlay)
            sensitiveOverlay.fillSuperview()
            sensitiveOverlay.isUserInteractionEnabled = false
            contentView.layer.cornerRadius = 4
            contentView.layer.masksToBounds = true
            contentView.layer.borderWidth = 1
            contentView.layer.borderColor = MDCPalette.grey.tint300.cgColor
        }

        func configure(
            primary: String,
            request: MediaGalleryImageRequest,
            thumb: UIImage?,
            isSensitive: Bool
        ) {
            imageLoader.cancelLoad(in: imageView)
            representedPrimary = primary
            failurePlaceholderPrimary = nil
            imageView.image = nil
            imageView.subviews.forEach { $0.removeFromSuperview() }
            sensitiveOverlay.isHidden = !isSensitive

            let placeholderView = GalleryPlaceholderView(frame: CGRect(square: 64))
            placeholderView.configureWithThumb(
                thumb,
                placeholderImage: imageLiteral("custom.photo.badge.clock")
            )
            imageLoader.load(
                request: request,
                into: imageView,
                placeholder: placeholderView
            ) { [weak self] outcome in
                guard let self,
                      self.representedPrimary == primary,
                      outcome == .failure else {
                    return
                }
                self.failurePlaceholderPrimary = primary
                self.imageView.subviews.forEach { $0.removeFromSuperview() }
                let failureView = GalleryPlaceholderView(frame: CGRect(square: 64))
                failureView.configureWithThumb(
                    thumb,
                    placeholderImage: imageLiteral("custom.photo.trianglebadge.exclamationmark")
                )
                self.imageView.addSubview(failureView)
                failureView.fillSuperview()
            }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            imageLoader.cancelLoad(in: imageView)
            representedPrimary = nil
            failurePlaceholderPrimary = nil
            imageView.image = nil
            imageView.subviews.forEach { $0.removeFromSuperview() }
            sensitiveOverlay.isHidden = true
        }
    }

    let collectionView: UICollectionView = {
        let layout = MediaGalleryThreeColumnFlowLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.register(
            GalleryPhotoItemCell.self,
            forCellWithReuseIdentifier: GalleryPhotoItemCell.cellName
        )
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
        title = "Images"
        kind = .image
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
            withReuseIdentifier: GalleryPhotoItemCell.cellName,
            for: indexPath
        ) as? GalleryPhotoItemCell else {
            fatalError()
        }
        guard datasource.indices.contains(indexPath.item) else {
            cell.prepareForReuse()
            return cell
        }

        let item = datasource[indexPath.item]
        if let request = MediaGalleryImageRequestPlanner.request(
            for: item,
            displaySize: currentGridItemSize,
            scale: currentScreenScale
        ) {
            cell.configure(
                primary: item.primary,
                request: request,
                thumb: item.thumb,
                isSensitive: item.isSensitive && !item.isSensitiveRevealed
            )
        } else {
            cell.prepareForReuse()
        }
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
        guard datasource.indices.contains(indexPath.item),
              let url = datasource[indexPath.item].url else {
            return
        }
        let item = datasource[indexPath.item]
        if item.isSensitive && !item.isSensitiveRevealed {
            let viewController = SensitiveContentFirstPaneViewController()
            viewController.isFirstStep = true
            viewController.urls = datasource.compactMap(\.url)
            viewController.url = url
            viewController.delegate = self
            viewController.messagePrimary = item.messagePrimary
            viewController.referencePrimary = item.primary
            viewController.isVideo = false
            showModal(viewController, parent: self)
            return
        }

        let urls = datasource.compactMap(\.url)
        let gallery = PhotoGallery(urls: urls, from: url)
        let navigationController = UINavigationController(rootViewController: gallery)
        navigationController.modalPresentationStyle = .fullScreen
        gallery.initialPage = urls.firstIndex(of: url) ?? 0
        present(navigationController, animated: true)
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
}

extension PhotoGalleryForChatViewController: SensitiveContentFirstPaneViewControllerDelegate {
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
        let gallery = PhotoGallery(urls: urls, from: url)
        let navigationController = UINavigationController(rootViewController: gallery)
        navigationController.modalPresentationStyle = .fullScreen
        gallery.initialPage = urls.firstIndex(of: url) ?? 0
        present(navigationController, animated: true)
    }
}
