//
//  ChatBackgroundColorSelectionCell.swift
//  xabber
//
//  Created by Admin on 22.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class ChatBackgroundColorSelectionCell: UITableViewCell {
    class BackgroundColorCollectionViewCell: UICollectionViewCell {
        static let cellName = "BackgroundColorCollectionViewCell"
        
        var color: ChatViewController.BackgroundColor? = nil
        
        let gradientView: UIView = {
            let view = UIView()
            
            return view
        }()
        
        let imageView: UIImageView = {
            let imageView = UIImageView()
            
            return imageView
        }()
        
        public func setup() {
            contentView.layer.cornerRadius = 15
            
            contentView.addSubview(gradientView)
            gradientView.frame = contentView.bounds.insetBy(dx: 5, dy: 5)
            
            gradientView.layer.sublayers = nil
            
            let gradient = getGradientFrom(commonColor: color ?? .purple, frame: gradientView.bounds)
            gradientView.layer.insertSublayer(gradient, at: 0)
            
        }
        
        func getGradientFrom(commonColor color: ChatViewController.BackgroundColor, frame: CGRect) -> CAGradientLayer {
            let gradient = CAGradientLayer()
            gradient.colors = ChatViewController.getColorsForGradient(forColor: color)
            gradient.startPoint = CGPoint.zero
            gradient.endPoint = CGPoint(x: 1, y: 1)
            
            gradient.frame = frame
            gradient.cornerRadius = 10
            
            return gradient
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            
            contentView.layer.borderColor = nil
            contentView.layer.borderWidth = 0
            
            gradientView.removeFromSuperview()
            gradientView.layer.sublayers = nil
            
            isSelected = false
        }
    }
    
    var currentColor: ChatViewController.BackgroundColor? = nil
    var backgroundColors = ChatViewController.BackgroundColor.allCases
    
    let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 5
        
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.showsHorizontalScrollIndicator = false
        
        view.register(BackgroundColorCollectionViewCell.self, forCellWithReuseIdentifier: BackgroundColorCollectionViewCell.cellName)
        
        return view
    }()
    
    func configure() {
        contentView.addSubview(collectionView)
        collectionView.fillSuperviewWithOffset(top: 15, bottom: 15, left: 15, right: 15)
        
        collectionView.dataSource = self
        collectionView.delegate = self
    }
    
}

extension ChatBackgroundColorSelectionCell: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return backgroundColors.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let color = backgroundColors[indexPath.row]
        
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BackgroundColorCollectionViewCell.cellName, for: indexPath) as? BackgroundColorCollectionViewCell else {
            return UICollectionViewCell(frame: .zero)
        }
        
        cell.color = color
        cell.setup()
        
        if currentColor == backgroundColors[indexPath.row] {
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
            
            cell.contentView.layer.borderColor = UIColor.gray.cgColor
            cell.contentView.layer.borderWidth = 1
        }
        
        return cell
    }
    
}

extension ChatBackgroundColorSelectionCell: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView,
                          layout collectionViewLayout: UICollectionViewLayout,
                          sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: 100, height: 120)
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) as? BackgroundColorCollectionViewCell {
            currentColor = backgroundColors[indexPath.item]
            
            cell.contentView.layer.borderColor = UIColor.gray.cgColor
            cell.contentView.layer.borderWidth = 1
            
            SettingManager.shared.saveItem(key: "chat_chooseBackgroundColor", string: currentColor?.rawValue ?? ChatViewController.BackgroundColor.purple.rawValue)
            NotificationCenter.default.post(name: .chatBackgroundChanged, object: self, userInfo: [:])
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) as? BackgroundColorCollectionViewCell {
            cell.contentView.layer.borderColor = nil
            cell.contentView.layer.borderWidth = 0
        }
    }
    
}

extension ChatBackgroundColorSelectionCell: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return 5
    }
}
