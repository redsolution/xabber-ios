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

class SubscribtionTopInfoTableViewCell: BaseTableCell {
    
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 16, right: 20)
        
        return stack
    }()
    
    internal let verticalStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 8
        
        return stack
    }()
    
    internal let topLabel: UILabel = {
        let label = UILabel()
        
        return label
    }()
    
    internal let bottomLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        
        return label
    }()
    
    internal let statusLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = .systemRed
        label.textAlignment = .right
        
        return label
    }()
    
    internal let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        
        view.startAnimating()
        view.isHidden = true
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        
        contentView.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(verticalStack)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(activityIndicator)
        verticalStack.addArrangedSubview(topLabel)
        verticalStack.addArrangedSubview(bottomLabel)
    }
    
    
}
