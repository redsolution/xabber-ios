//
//  VoiceGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 24.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RxSwift
import RxCocoa
import RxRelay
import DeepDiff
import Kingfisher

//class GalleryPlaceholderView: UIView {
//    let image: UIImageView = {
//        let image = UIImageView()
//
//        return image
//    }()
//
//    override init(frame: CGRect) {
//        super.init(frame: frame)
//        self.addSubview(self.image)
//        self.image.fillSuperviewWithOffset(top: 32, bottom: 32, left: 32, right: 32)
//        self.image.tintColor = MDCPalette.grey.tint300
//    }
//
//    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//}
//
//extension GalleryPlaceholderView: Placeholder {
//
//}

class VoiceGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    
    static let cellSize: CGSize = CGSize(square: 128)
    
    class GalleryPhotoItemCell: UICollectionViewCell {
        public static let cellName: String = "GalleryPhotoItemCell"
        private let label = {
            let label = UILabel()
            
            return label
        }()
        
        private let imageView: UIImageView = {
            let view = UIImageView()
            
            view.contentMode = .scaleAspectFill
            
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        required init?(coder: NSCoder) {
            fatalError()
        }

        private func setup() {
            self.contentView.addSubview(self.imageView)
            self.imageView.fillSuperview()
            self.contentView.layer.cornerRadius = 4
            self.contentView.layer.masksToBounds = true
            self.contentView.layer.borderWidth = 1
            self.contentView.layer.borderColor = MDCPalette.grey.tint300.cgColor
        }

        func configure(url: URL, title: String, subtitle: String) {
            let placeholderView = GalleryPlaceholderView(frame: CGRect(square: 64))
            placeholderView.image.image = imageLiteral("custom.photo.badge.clock")
//            self.imageView.addSubview(placeholderView)
//            placeholderView.fillSuperview()
            self.imageView.kf.setImage(
                with: url,
                placeholder: placeholderView,
                options: [
                    .alsoPrefetchToMemory,
                    .waitForCache,
                    .backgroundDecode,
                    .transition(.fade(0.1))
                ]) { result in
                    switch result {
                        case .success(_):
                            break
                        case .failure(_):
//                            self.imageView.kf.
                            let placeholderView = GalleryPlaceholderView(frame: CGRect(square: 64))
                            placeholderView.image.image = imageLiteral("custom.photo.trianglebadge.exclamationmark")
                            self.imageView.addSubview(placeholderView)
                            placeholderView.fillSuperview()
                            self.imageView.layoutIfNeeded()
//                            self.imageView.image = imageLiteral("custom.photo.trianglebadge.exclamationmark")?.withTintColor(MDCPalette.grey.tint300)
                    }
                }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            label.text = nil
            self.imageView.subviews.forEach { $0.removeFromSuperview() }
        }
    }
    
    
    class FlowLayout: UICollectionViewFlowLayout {
        override init() {
            super.init()
            minimumInteritemSpacing = 8
            minimumLineSpacing = 8
            sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            // Do not set itemSize here; it will be computed dynamically
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func calculateItemWidth() -> CGFloat {
            guard let collectionView = collectionView else { return 100 } // Fallback width
            
            let totalHorizontalInsets = sectionInset.left + sectionInset.right +
                                       collectionView.contentInset.left + collectionView.contentInset.right
            
            return collectionView.bounds.width - totalHorizontalInsets
        }
        
        override func prepare() {
            super.prepare()
            itemSize = CGSize(width: calculateItemWidth(), height: 64) // Adjust height as needed
        }
        
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            guard let collectionView = collectionView else { return false }
            
            let oldWidth = collectionView.bounds.width
            if newBounds.width != oldWidth {
                itemSize = CGSize(width: calculateItemWidth(for: newBounds), height: 64)
                return true
            }
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        
        private func calculateItemWidth(for bounds: CGRect) -> CGFloat {
            let totalHorizontalInsets = sectionInset.left + sectionInset.right
            // Note: contentInset may not change with bounds, but use current for safety
            return bounds.width - totalHorizontalInsets - (collectionView?.contentInset.horizontal ?? 0)
        }
    }
    
    public var collectionView: UICollectionView = {
        let layout = FlowLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        
        view.register(GalleryPhotoItemCell.self, forCellWithReuseIdentifier: GalleryPhotoItemCell.cellName)
        
        return view
    }()
    
    override func apply(_ newDatasource: [BaseMediaGalleryForChatViewController.Datasource]) {
        let changes = compareDatasource(newDatasource)
        if self.datasource.isEmpty || newDatasource.isEmpty {
            self.datasource = newDatasource
            self.collectionView.reloadData()
        } else {
            self.collectionView.reload(changes: changes) {
                self.datasource = newDatasource
            }
        }
    }
    
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.collectionView)
        self.collectionView.fillSuperview()
    }
    
    
    override func loadDatasource() {
        self.datasource = []
    }
    
    override func configure() {
        super.configure()
        self.title = "Files"
        self.kind = .voice
        self.collectionView.prefetchDataSource = self
        self.collectionView.dataSource = self
        self.collectionView.delegate = self
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GalleryPhotoItemCell.cellName, for: indexPath) as? GalleryPhotoItemCell else {
            fatalError()
        }
        let item  = self.datasource[indexPath.row]
        
        cell.configure(url: item.url, title: item.title, subtitle: item.subtitle)
        
        return cell
    }
    
    override func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        indexPaths
            .compactMap({ self.datasource[$0.row].url })
            .forEach {
                ImageDownloader
                    .default
                    .downloadImage(
                        with: $0,
                        options: [
                            .alsoPrefetchToMemory,
                            .waitForCache,
                            .backgroundDecode
                        ]
                    )
            }
        super.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }
}
