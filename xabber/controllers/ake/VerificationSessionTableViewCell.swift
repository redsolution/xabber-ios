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
    private var didSetupSubviews = false
    private var didActivateStaticConstraints = false
    private var blueButtonLeadingConstraint: NSLayoutConstraint?
    
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
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        label.textColor = MDCPalette.grey.tint800
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let closeButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 44))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(imageLiteral("xmark"), for: .normal)
        button.imageEdgeInsets = UIEdgeInsets(top: 11, right: 11)
        button.tintColor = .lightGray
        button.contentHorizontalAlignment = .right
        button.contentVerticalAlignment = .top
        button.accessibilityIdentifier = "verification_session_close_button"
        button.accessibilityLabel = "Close verification"
        button.accessibilityHint = "Dismisses this verification request."
        
        return button
    }()
    
    let blueButton: UIButton = {
        let button = UIButton()
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .systemBlue
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        button.setTitle("Verify", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.accessibilityIdentifier = "verification_session_verify_button"
        button.accessibilityLabel = "Verify"
        button.accessibilityHint = "Starts or continues device verification."
        
        return button
    }()
    
    let customImageView: UIImageView = {
        let imageView = UIImageView(frame: CGRect(square: 40))
        let image = imageLiteral("exclamationmark.triangle.fill")?.upscale(dimension: 40).withTintColor(.systemOrange)
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        return imageView
    }()
    
    internal func configure(title: String, subtitle: String?) {
        setupIfNeeded()
        
        titleLabel.text = title
        
        subtitleLabel.attributedText = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        if let subtitle, subtitle.isNotEmpty {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 3
            let attributedText = NSMutableAttributedString(string: subtitle, attributes: [NSAttributedString.Key.paragraphStyle: paragraphStyle])
            subtitleLabel.attributedText = attributedText
        }
        hideVerificationButton()
        setCloseButtonVisible(true)
        self.selectionStyle = .none
    }

    func showVerificationButton(title: String, accessibilityLabel: String? = nil, accessibilityHint: String? = nil) {
        setupIfNeeded()
        setBlueButtonTitle(title)

        if !labelsStack.arrangedSubviews.contains(blueButton) {
            labelsStack.addArrangedSubview(blueButton)
        }
        blueButton.isHidden = false

        if blueButtonLeadingConstraint == nil {
            blueButtonLeadingConstraint = blueButton.leftAnchor.constraint(equalTo: labelsStack.leftAnchor)
        }
        blueButtonLeadingConstraint?.isActive = true
        blueButton.accessibilityLabel = accessibilityLabel ?? title
        blueButton.accessibilityHint = accessibilityHint ?? "Starts or continues device verification."
    }

    func setCloseButtonVisible(_ isVisible: Bool) {
        setupIfNeeded()
        if !stack.arrangedSubviews.contains(closeButton) {
            stack.addArrangedSubview(closeButton)
        }
        closeButton.isHidden = !isVisible
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        blueButton.removeTarget(nil, action: nil, for: .allEvents)
        closeButton.removeTarget(nil, action: nil, for: .allEvents)
        hideVerificationButton()
        setCloseButtonVisible(true)
        titleLabel.text = nil
        subtitleLabel.attributedText = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        selectionStyle = .none
    }

    private func setupIfNeeded() {
        guard !didSetupSubviews else {
            return
        }
        didSetupSubviews = true

        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 11, bottom: 11, left: 11, right: 11)

        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)

        stack.addArrangedSubview(customImageView)
        stack.addArrangedSubview(labelsStack)
        stack.addArrangedSubview(closeButton)

        activateConstraints()
    }

    private func setBlueButtonTitle(_ title: String) {
        blueButton.setTitle(title, for: .normal)
        blueButton.configuration?.title = title
        blueButton.titleLabel?.adjustsFontForContentSizeCategory = true
        blueButton.titleLabel?.numberOfLines = 0
        blueButton.titleLabel?.lineBreakMode = .byWordWrapping
    }

    private func hideVerificationButton() {
        if labelsStack.arrangedSubviews.contains(blueButton) {
            labelsStack.removeArrangedSubview(blueButton)
        }
        blueButton.removeFromSuperview()
        blueButtonLeadingConstraint?.isActive = false
        blueButton.isHidden = true
    }
    
    func activateConstraints() {
        guard !didActivateStaticConstraints else {
            return
        }
        didActivateStaticConstraints = true

        NSLayoutConstraint.activate([
            blueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.rightAnchor.constraint(equalTo: self.contentView.rightAnchor),
        ])
    }
}
