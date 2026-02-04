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
        var text: NSAttributedString = NSAttributedString()
        var naturalIndex: Int = 0
        var isPinned: Bool = false
        var hiddenDate: Bool? = nil
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
        
        func updateContent() {
            self.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            self.messageLabel.textInsets = messageLabelInsets
            self.messageLabel.attributedText = self.text
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
        }
        
        func configure(_ text: NSAttributedString) {
            if text != self.text {
                self.text = text
                self.updateContent()
            }
        }
        
        func setupSubviews() {
            addSubview(messageLabel)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func updateCenterIfNotAPinned(_ center: CGPoint) {
            if self.isPinned {
                return
            }
            self.center = center
            self.layoutIfNeeded()
        }
        
        func updateFrameIfNotAPinned(_ frame: CGRect) {
            if self.isPinned {
                return
            }
            self.frame = frame
            self.messageLabel.center.x = self.center.x
            self.layoutSubviews()
//            self.updateContent()
        }
        
        func show() {
            if let hiddenDate = hiddenDate,
               hiddenDate == false {
                return
            }
            self.hiddenDate = false
            UIView.animate(withDuration: 0.6, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.1, options: [.curveEaseIn]) {
                self.alpha = 1.0
            } completion: { _ in
            }
        }
        
        func hide(fast: Bool = false, withoutAnimation: Bool = false) {
            if let hiddenDate = hiddenDate,
               hiddenDate == true {
                return
            }
            self.hiddenDate = true
            if withoutAnimation {
                UIView.performWithoutAnimation {
                    self.alpha = 0.0
                }
            } else {
                UIView.animate(withDuration: fast ? 0.1 : 1.0, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.1, options: [.curveEaseIn]) {
                    self.alpha = 0.0
                } completion: { _ in
                    
                }
            }
        }
    }
}
