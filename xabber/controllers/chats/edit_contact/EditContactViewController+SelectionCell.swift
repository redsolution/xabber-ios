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

extension EditContactViewController {
    class SelectionCell: UITableViewCell {
        public static let cellName: String = "SelectionCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
//            stack.distribution = .equalSpacing
//            stack.spacing = 8
            
            return stack
        }()
        
        let selectionMarkView: UIView = {
            let view = UIView(
                frame: CGRect(
                    origin: .zero,
                    size: CGSize(square: 24))
            )
            
            view.layer.cornerRadius = view.frame.width / 2
            view.layer.borderWidth = 2
            view.layer.borderColor = MDCPalette.grey.tint300.cgColor
            if #available(iOS 13.0, *) {
                view.backgroundColor = .systemBackground
            } else {
                view.backgroundColor = .white
            }
            
            return view
        }()
        
        let checkMarkImageView: UIImageView = {
            let view = UIImageView(
                frame: CGRect(
                    origin: CGPoint(x: 2, y: 2),
                    size: CGSize(square: 20))
            )
            
            view.image = imageLiteral( "check")?.withRenderingMode(.alwaysTemplate)
            if #available(iOS 13.0, *) {
                view.tintColor = .systemBackground
            } else {
                view.tintColor = .white
            }
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.font = UIFont.systemFont(ofSize: 17)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            label.textAlignment = .left
            return label
        }()
        
        public final func configure(title: String, isSelected: Bool) {
            titleLabel.text = title
            if isSelected {
                selectionMarkView.backgroundColor = .systemBlue
                checkMarkImageView.isHidden = false
                selectionMarkView.layer.borderColor = UIColor.systemBlue .cgColor
//                if #available(iOS 13.0, *) {
//                    selectionMarkView.layer.borderColor = UIColor.systemBackground.cgColor
//                } else {
//                    selectionMarkView.layer.borderColor = UIColor.white.cgColor
//                }
            } else {
                selectionMarkView.backgroundColor = .white
                checkMarkImageView.isHidden = true
                selectionMarkView.layer.borderColor = MDCPalette.grey.tint300.cgColor
            }
        }
        
        public final func setupSubviews() {
            selectionStyle = .none
            selectionMarkView.addSubview(checkMarkImageView)
//            contentView.addSubview(selectionMarkView)
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 0, bottom: 0, left: 16, right: 16)
            stack.addArrangedSubview(selectionMarkView)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(UIStackView())
            NSLayoutConstraint.activate([
                selectionMarkView.widthAnchor.constraint(equalToConstant: 24),
                selectionMarkView.heightAnchor.constraint(equalToConstant: 24),
                titleLabel.leftAnchor.constraint(equalTo: selectionMarkView.rightAnchor, constant: 12)
            ])
            
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .value1, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
