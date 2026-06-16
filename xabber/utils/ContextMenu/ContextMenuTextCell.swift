//
//  ContextMenuTextCell.swift
//
//
//  Created by Umer on 31/05/2023.
//

import UIKit

class ContextMenuTextCell: ContextMenuCell {
    
    lazy var titleLabel: UILabel = {
        let tLabel = UILabel()
        tLabel.translatesAutoresizingMaskIntoConstraints = false
        return tLabel
    }()
    lazy var iconImageView: UIImageView = {
        let imgView = UIImageView()
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.heightAnchor.constraint(equalToConstant: 20).isActive = true
        imgView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return imgView
    }()
    lazy var stackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [titleLabel, iconImageView])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = 8
        return stackView
    }()
    
    override func commonInit() {
        super.commonInit()
        
        contentView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        
        // Configure the view for the selected state
    }
    
    override open func prepareForReuse() {
        super.prepareForReuse()
        
        titleLabel.text = nil
        iconImageView.image = nil
        contentView.alpha = 1
        selectionStyle = .default
        
    }
    
    open override func setup(){
        titleLabel.text = item.title
        let enabled = item.isEnabled
        contentView.alpha = enabled ? 1 : 0.55
        selectionStyle = enabled ? .default : .none

        if let menuConstants = style {
            titleLabel.font = menuConstants.LabelDefaultFont
            if !enabled {
                let disabledColor: UIColor
                if #available(iOS 13.0, *) {
                    disabledColor = .secondaryLabel
                } else {
                    disabledColor = .gray
                }
                self.titleLabel.textColor = disabledColor
                self.iconImageView.tintColor = disabledColor
            } else if item.danger {
                self.titleLabel.textColor = .systemRed
                self.iconImageView.tintColor = .systemRed
            } else {
                self.titleLabel.textColor = menuConstants.LabelDefaultColor
                self.iconImageView.tintColor = menuConstants.LabelDefaultColor
            }
        }
        iconImageView.image = item.image
        iconImageView.isHidden = (item.image == nil)
        
    }
    
}
