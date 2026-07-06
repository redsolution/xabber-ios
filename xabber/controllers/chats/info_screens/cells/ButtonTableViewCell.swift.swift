//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class ButtonTableViewCell: UITableViewCell {
    
    static let cellName = "ButtonTableViewCell"
    
    enum Style {
        case normal
        case danger
        case destructiveSubtle
    }
    
    var stack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 20, right: 16)
        
        return stack
    }()
    
    var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.gray
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isAccessibilityElement = false
        return label
    }()

    private var didSetup = false
    private var minimumHeightConstraint: NSLayoutConstraint?

    var minimumEffectiveHeight: CGFloat {
        return minimumHeightConstraint?.constant ?? 0
    }
    
    func configure(for title: String, style: Style) {
        setupIfNeeded()

        selectionStyle = .default
        backgroundColor = .white
        contentView.backgroundColor = .white
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        titleLabel.text = title
        switch style {
        case .normal:
            titleLabel.font = UIFont.preferredFont(forTextStyle: .body)
            titleLabel.textColor = MDCPalette.blue.tint500
        case .danger:
            titleLabel.font = UIFont.preferredFont(forTextStyle: .body)
            titleLabel.textColor = MDCPalette.red.tint500
        case .destructiveSubtle:
            titleLabel.font = UIFont.preferredFont(forTextStyle: .callout)
            titleLabel.textColor = .systemRed
        }
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityTraits = .button
    }

    private func setupIfNeeded() {
        guard !didSetup else {
            return
        }

        didSetup = true
        contentView.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(titleLabel)

        let heightConstraint = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        minimumHeightConstraint = heightConstraint
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
