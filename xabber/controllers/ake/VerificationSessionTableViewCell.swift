//
//  VerificationSessionTableViewCell.swift
//  xabber
//
//  Created by Admin on 08.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class VerificationSessionTableViewCell: UITableViewCell {
    static let cellName = "VerificationSessionTableViewCell"
    
    let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        
        return stack
    }()
    
    let labelsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        label.textColor = MDCPalette.grey.tint800
        label.font = UIFont.systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let closeButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 44))
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.imageEdgeInsets = UIEdgeInsets(top: 11, right: 11)
        button.tintColor = .lightGray
        button.contentHorizontalAlignment = .right
        button.contentVerticalAlignment = .top
        
        return button
    }()
    
    let blueButton: UIButton = {
        let button = UIButton()
        button.setTitle("Verify", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.configuration = UIButton.Configuration.filled()
        button.configuration!.baseBackgroundColor = .systemBlue
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
        return button
    }()
    
    let customImageView: UIImageView = {
        let imageView = UIImageView(frame: CGRect(square: 40))
        let image = UIImage(systemName: "exclamationmark.triangle.fill")?.upscale(dimension: 40).withTintColor(.systemOrange)
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        return imageView
    }()
    
    internal func configure(title: String, subtitle: String?) {
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 11, bottom: 11, left: 11, right: 11)
        
        titleLabel.text = title
        
        if subtitle != nil {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 3
            let attributedText = NSMutableAttributedString(string: subtitle!, attributes: [NSAttributedString.Key.paragraphStyle: paragraphStyle])
            subtitleLabel.attributedText = attributedText
        }
        
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)
        
        stack.addArrangedSubview(customImageView)
        stack.addArrangedSubview(labelsStack)
        stack.addArrangedSubview(closeButton)
        
        activateConstraints()
        
        self.selectionStyle = .none
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.rightAnchor.constraint(equalTo: self.contentView.rightAnchor),
        ])
    }
}
