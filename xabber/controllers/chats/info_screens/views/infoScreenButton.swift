//
//  infoScreenButton.swift
//  xabber
//
//  Created by Игорь Болдин on 18.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class InfoHeaderButton: UIButton {
    
    private func addBlurSubviews() {
        self.backgroundColor = nil
        let containerEffect = UIBlurEffect(style: .light)
        let containerView = UIVisualEffectView(effect: containerEffect)
        containerView.frame = self.bounds
        self.clipsToBounds = true
        
        containerView.isUserInteractionEnabled = false
        
        self.insertSubview(containerView, belowSubview: self.imageView!)
        
        let vibrancy = UIVibrancyEffect(blurEffect: containerEffect)
        let vibrancyView = UIVisualEffectView(effect: vibrancy)
        vibrancyView.frame = containerView.bounds
        
        vibrancyView.contentView.addSubview(self.icon)
        vibrancyView.contentView.addSubview(self.title)
        
        containerView.contentView.addSubview(vibrancyView)
    }
    
    func setRoundedCorners() {
        self.layer.cornerRadius = self.bounds.width / 2
    }
    
    internal let icon: UIImageView = {
        let view = UIImageView(frame: .zero)
        
        view.tintColor = .tintColor
        
        return view
    }()
    
    internal let title: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 12, weight: .light)
        label.textColor = .tintColor
        label.textAlignment = .center
        
        label.numberOfLines = 1
        
        
        return label
    }()
    
    internal let stack: UIStackView = {
        let stack = UIStackView(frame: CGRect(width: 72, height: 44))
        
        stack.axis = .vertical
//        stack.distribution = .equalCentering
        stack.alignment = .center
        
        return stack
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public final func setupSubviews() {
//        addSubview(stack)
        backgroundColor = .white
        layer.cornerRadius = 8
        layer.masksToBounds = true
//        stack.fillSuperviewWithOffset(top: 4, bottom: 2, left: 4, right: 4)
//        stack.addArrangedSubview(icon)
//        stack.addArrangedSubview(title)
//        activateConstraints()
//        addBlurSubviews()
        
        icon.center = CGPoint(x: self.frame.midX, y: 18)
        addSubview(icon)
//        title.frame = CGRect(
//            origin: CGPoint(x: 0, y: 24),
//            size: CGSize(width: 80, height: 32)
//        )
        addSubview(title)
    }
    
    func configure(icon: String, title: String, forceStrong: Bool = false) {
        self.icon.image = imageLiteral(icon, dimension: 24, forceStrong: forceStrong)
        self.icon.sizeToFit()
        self.icon.center = CGPoint(x: 40, y: 20)
        self.title.text = title.lowercased()
        self.title.sizeToFit()
        self.title.center = CGPoint(x: 40, y: 44)
    }
    
    private final func activateConstraints() {
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
}
