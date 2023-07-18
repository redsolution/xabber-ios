//
//  AccountEditViewController+VcardEditedItemCell.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 06/06/2019.
//  Copyright © 2019 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

extension AccountEditViewController {
    class VcardEditedItem: UITableViewCell {
        static let cellName = "VCardItemCell"
        
        internal var key: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var titleLabel: UILabel = {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200, height: 24)))
            label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
            label.textColor = MDCPalette.grey.tint900
            return label
        }()
        
        var valueLabel: UILabel = {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200, height: 24)))
            label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.footnote)
            label.textColor = MDCPalette.grey.tint500
            return label
        }()
        
        private func activateConstraints() {
            
        }
        
        func configure(_ key: String, for title: String, value: String, editable: Bool) {
            self.key = key
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(valueLabel)
            backgroundColor = .white
            titleLabel.text = title
            valueLabel.text = value
            if editable {
                accessoryType = .disclosureIndicator
            } else {
                selectionStyle = .none
            }
            activateConstraints()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}

