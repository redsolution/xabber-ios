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
import CocoaLumberjack

extension ChatViewController {
    class MessagesPanel: UIView {
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 0, left: 16, right: 16)
            
            return stack
        }()
        
        let middleContent: UIButton = {
            let button = UIButton()
            
//            button.backgroundColor = .red
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return button
        }()
        
        let middleContentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            
            stack.isUserInteractionEnabled = false
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 0, right: 0)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
                        
            return label
        }()
        
        let separatorView: UIView = {
            let view = UIView()
            
            return view
        }()
        
        let closeButton: UIButton = {
            let button = UIButton()
            
            button.tintColor = MDCPalette.grey.tint500
            button.setImage(#imageLiteral(resourceName: "feather_close_24pt").withRenderingMode(.alwaysTemplate), for: .normal)
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 2, left: 6, right: 14)
            
            return button
        }()
        
        internal var onCloseCallback: (() -> Void)? = nil
        internal var onMiddleContentTouchCallback: (() -> Void)? = nil
        
        internal var stackConstraints: [NSLayoutConstraint] = []
        
        internal func setup() {
            addSubview(stack)
            stack.fillSuperviewWithOffset(top: 8, bottom: 0, left: 8, right: 0)
            
            middleContent.addSubview(middleContentStack)
            middleContentStack.fillSuperview()
            middleContentStack.addArrangedSubview(titleLabel)
            middleContentStack.addArrangedSubview(messageLabel)
            
            stack.addArrangedSubview(separatorView)
            stack.addArrangedSubview(middleContent)
            stack.addArrangedSubview(closeButton)
            
            stackConstraints = [
                separatorView.heightAnchor.constraint(equalToConstant: 38),
//                separatorView.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 1),
                separatorView.widthAnchor.constraint(equalToConstant: 2),
                separatorView.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 10),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 32),
                closeButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -20),
                
                middleContent.leftAnchor.constraint(equalTo: separatorView.rightAnchor, constant: 8),
                middleContent.rightAnchor.constraint(equalTo: closeButton.leftAnchor, constant: -8),
            ]
            
            closeButton.addTarget(self, action: #selector(onClose), for: .touchUpInside)
            middleContent.addTarget(self, action: #selector(onMiddleContentTouch), for: .touchUpInside)
                        
//            self.isUserInteractionEnabled = false
            NSLayoutConstraint.activate(stackConstraints)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        open func show() {
//            NSLayoutConstraint.activate(stackConstraints)
        }
        
        open func hide() {
//            NSLayoutConstraint.deactivate(stackConstraints)
        }
        
        open func update(title: String, message: NSAttributedString, color palette: MDCPalette) {
            separatorView.backgroundColor = palette.tint500
            titleLabel.text = title
            messageLabel.attributedText = message
            titleLabel.textColor = palette.tint800
        }
        
        @objc
        internal func onClose(_ sender: UIButton) {
            onCloseCallback?()
        }
        
        @objc
        internal func onMiddleContentTouch(_ sender: UIButton) {
            onMiddleContentTouchCallback?()
        }
    }
    
    internal func onMessagesPanelClose() {
        print("Call empty", #function)
        attachedMessagesIds.accept([])
        editMessageId.accept(nil)
        xabberInputBar.inputTextView.text = ""
    }
    
    internal func onMessagesPanelMiddleContentTouch() {
        if attachedMessagesIds.value.isEmpty {
            DispatchQueue.main.async {
                self.showToast(error: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
        } else {
            if attachedMessagesIds.value.count == 1 {
                if let messageId = attachedMessagesIds.value.first,
                    let index = messagesObserver?.firstIndex(where: { $0.primary == messageId }) {
                    DispatchQueue.main.async {
                        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: true)
                        self.scrollItemIndexPath = IndexPath(row: 0, section: index)
                        (self.messagesCollectionView.cellForItem(at: IndexPath(row: 0, section: index)) as? MessageContentCell)?.hilghlightCell(color: UIColor.blue.withAlphaComponent(0.1), duration: 1.6)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.showShareViewController(self.attachedMessagesIds.value)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.showShareViewController(self.attachedMessagesIds.value)
                }
            }
        }
    }
    
    internal func messagesPanelValidationError(_ error: String) {
        print("Call empty", #function)
        self.showToast(error: error)
        self.attachedMessagesIds.accept([])
    }
}

extension ChatViewController: ShareViewControllerDelegate {
    func open(owner: String, jid: String, forwarded messages: [String]) {
        if jid == self.jid {
            self.attachedMessagesIds.accept(messages)
            self.xabberInputBar.changeRecordToSend()
        } else {
//            self.jid = jid
//            self.viewDidLoad()
//            self.viewWillAppear(true)
//            self.viewDidAppear(true)
            
            
            let vc = ChatViewController()
            vc.jid = jid
            vc.owner = owner
            vc.xabberInputBar.changeRecordToSend()
            var vcs = self.navigationController?.viewControllers ?? []
            if let index = vcs.firstIndex(of: self) {
                vcs.remove(at: index)
            }
            vcs.append(vc)
//            vc.attachedMessagesIds.accept(messages)
//            vc.forwardedIds.accept(Set(messages))
            self.navigationController?.setViewControllers(vcs, animated: true)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
//                self.attachedMessagesIds.accept(messages)
                vc.attachedMessagesIds.accept(messages)
//            }
        }
    }
}
