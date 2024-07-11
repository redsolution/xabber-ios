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

class EditCirclesCell: UITableViewCell {
    public static let cellName: String = "EditCirclesCell"
    
    let iconView: UIImageView = {
        let view = UIImageView()
        view.tintColor = .tintColor
        return view
    }()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 17)
        label.numberOfLines = 1
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 14, weight: .light)
        label.numberOfLines = 0
        
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
    
    public final func configure(icon: String?, title: String, circles: [String]) {
        titleLabel.text = title
        if let icon = icon {
//            let image = #imageLiteral(resourceName: icon).upscale(dimension: 24).withRenderingMode(.alwaysTemplate)
//            if  {
//                iconView.image = image
//            } else 
            if let image = UIImage(systemName: icon) {
                iconView.image = image
            } else if let image = UIImage(named: icon) {
                iconView.image = image
            }
        }
        if circles.isEmpty {
            subtitleLabel.text = "No circles".localizeString(id: "contact_circles_empty", arguments: [])
            subtitleLabel.font = subtitleLabel.font.italic()
        } else {
            subtitleLabel.text = circles.joined(separator: ", ")
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .light)
    }
    
    public final func setupSubviews() {
        selectionStyle = .none
        iconView.frame = CGRect(
            origin: CGPoint(x: 18, y: 8),
            size: CGSize(square: 24)
        )
        contentView.addSubview(iconView)
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 10, bottom: 10, left: 56, right: 16)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        accessoryType = .disclosureIndicator
        
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
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
