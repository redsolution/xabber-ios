//
//  ChatViewController+DateView.swift
//  xabber
//
//  Created by Игорь Болдин on 27.12.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension ChatViewController {
    class FloatDateView: UIView {
        var primary: String = ""
        var naturalIndex: Int = 0
        var isPinned: Bool = false
        let messageLabelInsets = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        let contentView: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        let messageLabel: MessageLabel = {
            let label = MessageLabel()
            
            return label
        }()
        
        func configure(_ text: NSAttributedString) {
            self.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            self.messageLabel.textInsets = messageLabelInsets
            self.messageLabel.attributedText = text
            self.messageLabel.textAlignment = .center
            let constraintBox = CGSize(width: UIScreen.main.bounds.width, height: .greatestFiniteMagnitude)
            let dateRect = text.boundingRect(with: constraintBox, options: [
                .usesLineFragmentOrigin,
                .usesFontLeading
            ], context: nil).integral
            
            let frame = CGRect(
                x: 0,
                y: 4,
                width: dateRect.width + self.messageLabelInsets.horizontal,
                height: dateRect.height + self.messageLabelInsets.vertical
            )
            self.messageLabel.frame = frame
            self.messageLabel.center.x = self.center.x
            self.messageLabel.layer.cornerRadius = frame.height / 2
            self.messageLabel.layer.masksToBounds = true
            self.layoutSubviews()
//            self.messageLabel.sizeToFit()
//            NSLayoutConstraint.activate([
//                messageLabel.widthAnchor.constraint(equalToConstant: dateRect.width),
//                messageLabel.heightAnchor.constraint(equalToConstant: dateRect.height),
//                messageLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
//                messageLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
//            ])
//            messageLabel.frame = dateRect
//            messageLabel.center = contentView.center
        }
        
        func setupSubviews() {
            addSubview(messageLabel)
//            contentView.fillSuperview()
//            contentView.addArrangedSubview(messageLabel)
//            messageLabel.fillSuperview()
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func updateFrameIfNotAPinned(_ frame: CGRect) {
            if self.isPinned {
                return
            }
            self.frame = frame
            self.layoutIfNeeded()
        }
    }
}
