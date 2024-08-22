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
    enum Color: CaseIterable {
        case none
        case purple
        case darkRed
        case lightRed
        case yellowOrange
        case yellowBlue
        case lightGreen
        case greenBlue
        case lightBlue
    }
    
    var currentColor: ChatViewController.BackgroundColor? = nil
    var backgroundColors = ChatViewController.BackgroundColor.allCases
    
    let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.showsHorizontalScrollIndicator = false
        
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "UICollectionViewCell")
        
        return view
    }()
    
    func configure() {
        contentView.addSubview(collectionView)
        collectionView.fillSuperviewWithOffset(top: 15, bottom: 15, left: 15, right: 15)
        
        collectionView.dataSource = self
        collectionView.delegate = self
    }
    
    func getGradientFrom(commonColor color: ChatViewController.BackgroundColor, frame: CGRect) -> CAGradientLayer {
//        var firstColor: CGColor = CGColor(gray: 1, alpha: 1)
//        var secondColor: CGColor = CGColor(gray: 1, alpha: 1)
//        
//        switch color {
//        case .purple:
//            firstColor = CGColor(red: 255/255, green: 122/255, blue: 245/255, alpha: 1.0)
//            secondColor = CGColor(red: 81/255, green: 49/255, blue: 98/255, alpha: 1.0)
//            
//        case .darkRed:
//            firstColor = CGColor(red: 205/255, green: 92/255, blue: 92/255, alpha: 0.5)
//            secondColor = CGColor(red: 220/255, green: 20/255, blue: 60/255, alpha: 1)
//            
//        case .lightRed:
//            firstColor = CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 0.5)
//            secondColor = CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 1)
//            
//        case .yellowOrange:
//            firstColor = CGColor(red: 255/255, green: 215/255, blue: 0, alpha: 1)
//            secondColor = CGColor(red: 255/255, green: 69/255, blue: 0, alpha: 1)
//            
//        case .yellowBlue:
//            firstColor = CGColor(red: 255/255, green: 215/255, blue: 0, alpha: 0.5)
//            secondColor = CGColor(red: 30/255, green: 144/255, blue: 255/255, alpha: 0.5)
//            
//        case .lightGreen:
//            firstColor = CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5)
//            secondColor = CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5)
//            
//        case .greenBlue:
//            firstColor = CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5)
//            secondColor = CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
//            
//        case .lightBlue:
//            firstColor = CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
//            secondColor = CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
//            
//        default:
//            break
//        }
        
        let gradient = CAGradientLayer()
        gradient.colors = ChatViewController.getColorsForGradient(forColor: color)
        gradient.startPoint = CGPoint.zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        
        gradient.frame = frame
        gradient.cornerRadius = 10
        
        return gradient
    }
}

extension ChatBackgroundColorSelectionCell: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return backgroundColors.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let color = backgroundColors[indexPath.row]
        
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "UICollectionViewCell", for: indexPath)
        cell.contentView.layer.sublayers = nil
        
        let gradient = getGradientFrom(commonColor: color, frame: cell.contentView.bounds)
        cell.contentView.layer.insertSublayer(gradient, at: 0)
        
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
        
    }
    
}

extension ChatBackgroundColorSelectionCell: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return 10
    }
}
