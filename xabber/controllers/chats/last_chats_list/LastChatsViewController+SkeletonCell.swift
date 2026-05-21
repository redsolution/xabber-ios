//
//  LastChatsViewController+SkeletonCell.swift
//  xabber
//
//  Created by Игорь Болдин on 18.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class SkeletonView: UIView {
    
    var startLocations : [NSNumber] = [-1.0,-0.5, 0.0]
    var endLocations : [NSNumber] = [1.0,1.5, 2.0]
    
    var gradientBackgroundColor : CGColor = UIColor(white: 0.85, alpha: 0.35).cgColor
    var gradientMovingColor : CGColor = UIColor(white: 0.7, alpha: 0.35).cgColor
    
    var movingAnimationDuration : CFTimeInterval = 0.8
    var delayBetweenAnimationLoops : CFTimeInterval = 1.0
    
    
    var gradientLayer: CAGradientLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = bounds
    }

    private func installGradientLayerIfNeeded() {
        if let gradientLayer {
            gradientLayer.frame = bounds
            if gradientLayer.superlayer !== layer {
                layer.addSublayer(gradientLayer)
            }
            return
        }

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = self.bounds
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.8)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        gradientLayer.colors = [
            gradientBackgroundColor,
            gradientMovingColor,
            gradientBackgroundColor
        ]
        gradientLayer.locations = self.startLocations
        self.layer.addSublayer(gradientLayer)
        
        self.gradientLayer = gradientLayer
    }

    func startAnimating(){
        installGradientLayerIfNeeded()

        guard let gradientLayer else { return }

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = self.startLocations
        animation.toValue = self.endLocations
        animation.duration = self.movingAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
        
        
        let animationGroup = CAAnimationGroup()
        animationGroup.duration = self.movingAnimationDuration + self.delayBetweenAnimationLoops
        animationGroup.animations = [animation]
        animationGroup.repeatCount = .infinity
        gradientLayer.add(animationGroup, forKey: animation.keyPath)
    }
    
    func stopAnimating() {
        gradientLayer?.removeAllAnimations()
        gradientLayer?.removeFromSuperlayer()
        gradientLayer = nil
    }
    
}

extension UIView {
    
    /// Apply given views as masks
    ///
    /// - Parameter views: Views to apply as mask.
    /// ## Note: The view calling this function must have all the views in the given array as subviews.
    func setMaskingViews(_ views:[UIView]){

        let mutablePath = CGMutablePath()

        //Append path for each subview
        views.forEach { (view) in
            guard self.subviews.contains(view) else{
                fatalError("View:\(view) is not a subView of \(self). Therefore, it cannot be a masking view.")
            }
            //Check if ellipse
            if view.layer.cornerRadius == view.frame.size.height / 2, view.layer.masksToBounds{
                //Ellipse
                mutablePath.addEllipse(in: view.frame)
            }else{
                //Rect
                mutablePath.addRect(view.frame)
            }
        }
        
        //Create layer
        let maskLayer = CAShapeLayer()
        maskLayer.path = mutablePath
        
        //Apply layer as a mask
        self.layer.mask = maskLayer
    }
}

extension LastChatsViewController {
    class SkeletonCell: UITableViewCell {
        static let cellName = "SkeletonCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill
            
            return stack
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 56))
            
            view.backgroundColor = .clear
            view.translatesAutoresizingMaskIntoConstraints = false
            
            return view
        }()
        
        let avatarView: SkeletonView = {
            let view = SkeletonView(frame: CGRect(square: 64))
            view.translatesAutoresizingMaskIntoConstraints = false
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
//            view.contentMode = .scaleAspectFill
            
//            view.backgroundColor = MDCPalette.grey.tint200
            
            return view
        }()
        
        let usernameView: SkeletonView = {
            let view = SkeletonView()
            
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = MDCPalette.grey.tint50
            view.layer.cornerRadius = 6
            view.layer.masksToBounds = true
            
            return view
        }()
        
        let messageView: SkeletonView = {
            let view = SkeletonView()
            
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = MDCPalette.grey.tint50
            view.layer.cornerRadius = 6
            view.layer.masksToBounds = true
            
            
            return view
        }()
        
        
        
        func setup() {
            self.backgroundColor = ContinuousSplitBackgroundExperiment.isActive ? .clear : .systemBackground
            self.contentView.backgroundColor = .clear
            self.contentView.clipsToBounds = true
            self.contentView.addSubview(self.userImageView)
            self.userImageView.addSubview(self.avatarView)
            self.contentView.addSubview(usernameView)
            self.contentView.addSubview(messageView)
            self.avatarView.layer.backgroundColor = AccountColorManager.shared.randomPalette().tint200.cgColor
            self.separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
            self.activateConstraints()
        }

        private func activateConstraints() {
            let usernameTrailingConstraint = usernameView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
            usernameTrailingConstraint.priority = .defaultHigh
            let messageTrailingConstraint = messageView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
            messageTrailingConstraint.priority = .defaultHigh

            NSLayoutConstraint.activate([
                userImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                userImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                userImageView.widthAnchor.constraint(equalToConstant: 64),
                userImageView.heightAnchor.constraint(equalToConstant: 64),

                avatarView.leadingAnchor.constraint(equalTo: userImageView.leadingAnchor),
                avatarView.trailingAnchor.constraint(equalTo: userImageView.trailingAnchor),
                avatarView.topAnchor.constraint(equalTo: userImageView.topAnchor),
                avatarView.bottomAnchor.constraint(equalTo: userImageView.bottomAnchor),

                usernameView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 96),
                usernameTrailingConstraint,
                usernameView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                usernameView.heightAnchor.constraint(equalToConstant: 18),
                usernameView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),

                messageView.leadingAnchor.constraint(equalTo: usernameView.leadingAnchor),
                messageTrailingConstraint,
                messageView.topAnchor.constraint(equalTo: usernameView.bottomAnchor, constant: 10),
                messageView.heightAnchor.constraint(equalToConstant: 32),
                messageView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
                messageView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10)
            ])
        }
        
        var isAnimationsStart = false
        
        func animate() {
            
            if isAnimationsStart { return }
            self.isAnimationsStart = true
            self.avatarView.startAnimating()
            self.usernameView.startAnimating()
            self.messageView.startAnimating()
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.avatarView.stopAnimating()
            self.usernameView.stopAnimating()
            self.messageView.stopAnimating()
            self.isAnimationsStart = false
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setup()
        }
        
        
    }
}
