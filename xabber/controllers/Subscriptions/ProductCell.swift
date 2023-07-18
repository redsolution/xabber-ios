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

import UIKit
import StoreKit

class ProductCell: UITableViewCell {
    
    var product: Product?
    
    var buyButtonHandler: ((_ product: Product) -> Void)?
    
    let loadingIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.startAnimating()
        
        return view
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel?.text = ""
        detailTextLabel?.text = ""
        accessoryView = nil
    }
    
    func configure(for product: Product, isPurchased: Bool = false, expirationDate: Date? = nil, willAutoRenew: Bool? = nil) {
      
        textLabel?.text = product.displayName
        selectionStyle = .none

        if isPurchased {
            accessoryType = .checkmark
            accessoryView = nil
            if let expirationDate = expirationDate, let willAutoRenew = willAutoRenew {
                detailTextLabel?.text = (willAutoRenew ? "Renews " : "Expires ") + expirationDate.formatted()
            } else {
                detailTextLabel?.text = product.displayPrice
            }
        } else if AppStore.canMakePayments {
            detailTextLabel?.text = product.displayPrice
            accessoryType = .none
            accessoryView = self.newBuyButton()
        } else {
            detailTextLabel?.text = "Not available"
        }
        detailTextLabel?.textColor = .secondaryLabel
    }
    
    func newBuyButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setTitleColor(tintColor, for: .normal)
        button.setTitle("Buy", for: .normal)
        button.addTarget(self, action: #selector(ProductCell.buyButtonTapped(_:)), for: .touchUpInside)
        button.sizeToFit()
        
        return button
    }
    
    @objc func buyButtonTapped(_ sender: AnyObject) {
        accessoryView = self.loadingIndicator
        buyButtonHandler?(product!)
    }
    
    func cancelLoading() {
        accessoryView = self.newBuyButton()
    }
}

extension Date {
    func formattedDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd, yyyy, HH:MM"
        return dateFormatter.string(from: self)
    }
}
