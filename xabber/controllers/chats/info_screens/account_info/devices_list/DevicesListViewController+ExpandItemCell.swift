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

extension DevicesListViewController {
    class ExpandCellItem: BaseTableCell {
        static let cellName: String = "ExpandCellItem"
        
        private let expandIndicator: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 24))
            
            view.image = #imageLiteral(resourceName: "chevron-down").withRenderingMode(.alwaysTemplate)
            if #available(iOS 13.0, *) {
                view.tintColor = .secondaryLabel
            } else {
                view.tintColor = .gray
            }
            
            return view
        }()
        
        private let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 17, weight: .regular)
            
            return label
        }()
        
        private let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            
            return label
        }()
        
        private let descriptionLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .light)
            
            return label
        }()
        
        private let statusLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .light)
            
            return label
        }()
        
        private let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        private let topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            
            return stack
        }()
        
        override func setupSubviews() {
            super.setupSubviews()
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 20, right: 20)
            topStack.addArrangedSubview(titleLabel)
            topStack.addArrangedSubview(statusLabel)
            stack.addArrangedSubview(topStack)
            stack.addArrangedSubview(subtitleLabel)
            stack.addArrangedSubview(descriptionLabel)
        }
        
        public final func configure(title: String, subtitle: String, descr: String, lastActivity: Date?) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            descriptionLabel.text = descr
            if let date = lastActivity {
                let dateFormatter = DateFormatter()
                let today = Date()
                
                if NSCalendar.current.isDateInToday(date) {
                    dateFormatter.dateFormat = "HH:mm"
                } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                    dateFormatter.dateFormat = "HH:mm"
                } else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                    dateFormatter.dateFormat = "E"
                } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                    dateFormatter.dateFormat = "MMM dd"
                } else {
                    dateFormatter.dateFormat = "d MMM yyyy"
                }
                 
                statusLabel.text = dateFormatter.string(from: date)
            } else {
                statusLabel.text = "Online".localizeString(id: "account_state_connected", arguments: [])
            }
        }
    }
}
