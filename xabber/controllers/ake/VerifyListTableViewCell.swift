//
//  VerifyListTableViewCell.swift
//  xabber
//
//  Created by Admin on 13.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents

class VerifyListTableViewCell: UITableViewCell {
    static let cellName = "VerifyListTableViewCell"
    
    let usernameStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .trailing
        stack.spacing = 8
        
        return stack
    }()
    
    let infoStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 72, right: 4)
        
        return stack
    }()
    
    let topStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .fill
        stack.alignment = .center
        
        return stack
    }()
    
    let bottomStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 8)

        return stack
    }()
    
    let labelsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        
        return stack
    }()
    
    let usernameLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)

        label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let messageLabel: UILabel = {
        let label = UILabel()
        
        label.lineBreakMode = .byWordWrapping
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)
        
        return label
    }()
    
    let dateLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
        label.font = UIFont.systemFont(ofSize: 14)
        label.textAlignment = .right
        
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
        return label
    }()
    
    public final func configure(_ jid: String,
                                owner: String,
                                username: String,
                                message: String,
                                date: Date?) {

        self.imageView?.image = UIImage(systemName: "person.badge.shield.checkmark")
        
        usernameLabel.text = username
        
        messageLabel.numberOfLines = 2
        
        if let date = date {
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
            dateLabel.text = dateFormatter.string(from: date)
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        usernameLabel.textColor = UIColor(red:0.13, green:0.13, blue:0.13, alpha:1)
        usernameLabel.text = nil
        usernameLabel.attributedText = nil
        messageLabel.attributedText = nil
        messageLabel.text = nil
        dateLabel.text = nil
        dateLabel.attributedText = nil
        
        self.contentView.backgroundColor = .systemBackground
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        backgroundColor = .systemBackground
        
//        accountIndicator.frame = CGRect(x: 0.5, y: 1, width: 2, height: 74)
//        userImageView.frame = CGRect(x: 10, y: 10, width: 56, height: 56)
//        addSubview(accountIndicator)
//        addSubview(userImageView)
        
        infoStack.addArrangedSubview(topStack)
        infoStack.addArrangedSubview(bottomStack)
        
        topStack.addArrangedSubview(usernameLabel)
//        topStack.addArrangedSubview(muteIndicator)
        topStack.addArrangedSubview(UIStackView())
//        topStack.addArrangedSubview(deliveryIndicator)
        topStack.addArrangedSubview(dateLabel)
        
        labelsStack.addArrangedSubview(messageLabel)
        bottomStack.addArrangedSubview(labelsStack)
        
        self.selectionStyle = .none
        separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
//        activateConstraints()
        layoutIfNeeded()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
