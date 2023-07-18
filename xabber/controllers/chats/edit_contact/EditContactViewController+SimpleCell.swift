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

extension EditContactViewController {
    class SubscribtionCell: UITableViewCell {
        
        enum Highlight {
            case high
            case middle
            case low
        }
        
        static let cellName: String = "SubscribtionCell"
        
        private let stack: UIStackView = {
            let stack = UIStackView()
            
            return stack
        }()
        
        private let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .systemBlue
            
            return label
        }()
        
        private let indicator: UIImageView = {
            let view = UIImageView()
            
            view.image = #imageLiteral(resourceName: "information").withRenderingMode(.alwaysTemplate)
            view.tintColor = .systemRed
            
            return view
        }()
        
        public final func configure(title: String, showIndicator: Bool, highlight: Highlight) {
            titleLabel.text = title
            switch highlight {
            case .high:
                titleLabel.alpha = 1.0
            case .middle:
                titleLabel.alpha = 0.75
            case .low:
                titleLabel.alpha = 0.5
            }
            self.indicator.isHidden = !showIndicator
        }
        
        public final func setupSubviews() {
            selectionStyle = .none
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 10, bottom: 10, left: 16, right: 16)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(indicator)
            accessoryType = .disclosureIndicator
            
        }
        
        override func prepareForReuse() {
            titleLabel.textColor = .systemBlue
            titleLabel.alpha = 1.0
            indicator.isHidden = true
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
    }
}
