//
//  FilesGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.12.2025.
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

class FilesGalleryForChatViewController: BaseMediaGalleryForChatViewController {
    
    static let cellSize: CGSize = CGSize(square: 128)
    
    class GalleryItemCell: UICollectionViewCell {
        public static let cellName: String = "GalleryItemCell"
        
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 4)
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            
            button.backgroundColor = MDCPalette.blue.tint500
            button.tintColor = UIColor.white
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 0, right: 0)
            
            return stack
        }()
        
        let filenameLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = UIColor.label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            
            return label
        }()
        
        let sizeLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()
        
                
        var palette: MDCPalette = .amber
        
        internal func setup() {
            self.contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(iconButton)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(filenameLabel)
            contentStack.addArrangedSubview(sizeLabel)
            NSLayoutConstraint.activate([
                iconButton.widthAnchor.constraint(equalToConstant: 36),
                iconButton.heightAnchor.constraint(equalToConstant: 36),
                filenameLabel.heightAnchor.constraint(equalToConstant: 20),
                sizeLabel.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
        
        public func configure(owner: String,  url: URL, filename: String, size: String) {
            self.palette = AccountColorManager.shared.palette(for: owner)
            iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            let mimeType = url.absoluteString
            switch MimeIconTypes(rawValue: mimeType) {
                case .image:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .audio:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .video:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .document:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .pdf:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .table:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .presentation:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .archive:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .file:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .none:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                default:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
            self.iconButton.backgroundColor = palette.tint500
            self.filenameLabel.text = filename
            self.sizeLabel.text = size
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.filenameLabel.text = nil
            self.sizeLabel.text = nil
            self.iconButton.setImage(nil, for: .normal)
            
            
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
        
        view.register(GalleryItemCell.self, forCellWithReuseIdentifier: GalleryItemCell.cellName)
        
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
        self.kind = .file
        self.collectionView.prefetchDataSource = self
        self.collectionView.dataSource = self
        self.collectionView.delegate = self
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GalleryItemCell.cellName, for: indexPath) as? GalleryItemCell else {
            fatalError()
        }
        let item  = self.datasource[indexPath.row]
        
        cell.configure(owner: self.owner, url: item.url, filename: item.title, size: item.subtitle)
        
        return cell
    }
    
    override func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        super.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }
}
