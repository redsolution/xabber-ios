//
//  infoScreenButton.swift
//  xabber
//
//  Created by Игорь Болдин on 18.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

/// A compact action button used in the info screen header.
/// Displays a SF Symbol icon above a text label, with a rounded pill background.
class InfoHeaderButton: UIButton {

    // MARK: - Subviews

    internal let icon: UIImageView = {
        let view = UIImageView()
        view.tintColor = .tintColor
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    internal let title: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    public final func setupSubviews() {
        // Background: system material adapts to dark/light mode
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.masksToBounds = true

        contentStack.addArrangedSubview(icon)
        addSubview(contentStack)

        // Icon size
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Stack pinned to center of button with padding
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])

        addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    // MARK: - Configuration

    func configure(icon iconName: String, title titleText: String, forceStrong: Bool = false) {
        if iconName == "ellipsis" {
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            icon.image = UIImage(systemName: "ellipsis", withConfiguration: config)
        } else {
            icon.image = imageLiteral(iconName, dimension: 24, forceStrong: forceStrong)
        }
        title.text = titleText.lowercased()
    }

    // MARK: - Highlight state

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.1) {
                self.alpha = self.isHighlighted ? 0.6 : 1.0
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.4
        }
    }
}
