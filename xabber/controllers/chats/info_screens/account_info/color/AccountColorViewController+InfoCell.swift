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

extension AccountColorViewController {
    
    class InfoCell: UITableViewCell {
        
        static let cellName = "InfoCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 12
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            label.setContentHuggingPriority(.required, for: .horizontal)
            return label
        }()
        
        let colorIndicatorView: UIView = {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            return view
        }()

        let trailingSpacer = UIView(frame: .zero)

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupView()
        }

        private func setupView() {
            selectionStyle = .blue
            backgroundColor = .systemBackground
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(colorIndicatorView)
            stack.addArrangedSubview(trailingSpacer)
            stack.setCustomSpacing(0, after: colorIndicatorView)
            NSLayoutConstraint.activate([
                colorIndicatorView.widthAnchor.constraint(equalToConstant: 24),
                colorIndicatorView.heightAnchor.constraint(equalToConstant: 24)
            ])
        }

        func configure(for title: String, color: UIColor, active: Bool) {
            titleLabel.text = title
            colorIndicatorView.backgroundColor = color
            accessoryType = active ? .checkmark : .none
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            colorIndicatorView.layer.cornerRadius = colorIndicatorView.bounds.height / 2
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            titleLabel.text = nil
            colorIndicatorView.backgroundColor = .clear
            accessoryType = .none
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
    
}
