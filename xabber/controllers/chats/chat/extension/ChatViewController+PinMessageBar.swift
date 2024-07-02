////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import UIKit
//import RealmSwift
//import RxRealm
//import RxSwift
//import RxCocoa
//import MaterialComponents.MDCPalettes
//import CocoaLumberjack
//
//extension ChatViewController {
//    
//    class PinMessageView: UIView {
//        
//        let stack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.alignment = .center
//            stack.spacing = 16
//            stack.distribution = .fill
//            
////            stack.isLayoutMarginsRelativeArrangement = true
////            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 4, left: 8, right: 8)
//            
//            return stack
//        }()
//        
//        let middleStack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .vertical
//            stack.alignment = .leading
//            stack.spacing = 2
//            stack.distribution = .fill
//            
//            stack.isUserInteractionEnabled = true
//            
//            return stack
//        }()
//        
//        let topStack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.distribution = .fill
//            stack.alignment = .center
//            stack.spacing = 8
//            
//            return stack
//        }()
//        
//        let topLabel: UILabel = {
//            let label = UILabel()
//            
//            label.numberOfLines = 1
//            
//            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
//            
//            return label
//        }()
//        
//        let dateLabel: UILabel = {
//            let label = UILabel()
//            
//            label.numberOfLines = 1
////            label.lineBreakMode = .
//            
//            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
//            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
//            
//            return label
//        }()
//        
//        let bottomLabel: UILabel = {
//            let label = UILabel()
//            
//            label.numberOfLines = 1
//            label.lineBreakMode = .byTruncatingTail
//            
//            return label
//        }()
//        
//        let iconView: UIImageView = {
//            let view = UIImageView(frame: CGRect(square: 24))
//            
//            view.image = #imageLiteral(resourceName: "pin").withRenderingMode(.alwaysTemplate)
//            view.tintColor = MDCPalette.grey.tint500
////            view.insets
//            
//            return view
//        }()
//        
//        let unpinButton: UIButton = {
//            let button = UIButton()
//            
//            button.setImage(#imageLiteral(resourceName: "feather_close_24pt").withRenderingMode(.alwaysTemplate), for: .normal)
//            button.frame = CGRect(square: 36)
//            button.tintColor = .gray
//            
//            button.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
//            
//            return button
//        }()
//        
//        internal let bottomLine: UIView = {
//            let view = UIView()
//            
//            view.backgroundColor = UIColor.black.withAlphaComponent(0.21)
//            
//            return view
//        }()
//        
//        internal let gesture: UITapGestureRecognizer = {
//            let gesture = UITapGestureRecognizer()
//            
//            gesture.numberOfTapsRequired = 1
////            gesture.numberOfTouchesRequired = 1
//            gesture.delaysTouchesBegan = true
//            
//            return gesture
//        }()
//        
//        open var onUnpinCallback: (() -> Void)? = nil
//        
//        open var onTapCallback: (() -> Void)? = nil
//        
//        @objc
//        internal func onUnpin() {
//            onUnpinCallback?()
//        }
//        
//        @objc
//        internal func onTap(sender: UIGestureRecognizer?) {
//            onTapCallback?()
//        }
//        
//        internal func activateConstraints() {
//            iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
//            iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true
//            unpinButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
//            unpinButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
//        }
//        
//        override init(frame: CGRect) {
//            super.init(frame: frame)
//            addSubview(stack)
//            stack.fillSuperview()
//            stack.addArrangedSubview(iconView)
//            stack.addArrangedSubview(middleStack)
//            stack.addArrangedSubview(unpinButton)
//            middleStack.addArrangedSubview(topLabel)
//            middleStack.addArrangedSubview(bottomLabel)
//            addSubview(bottomLine)
//            middleStack.addGestureRecognizer(gesture)
//            gesture.addTarget(self, action: #selector(self.onTap(sender:)))
//            
//            unpinButton.addTarget(self, action: #selector(onUnpin), for: .touchUpInside)
//        }
//        
//        required init?(coder: NSCoder) {
//            fatalError()
//        }
//        
//        open func configure(topLabelText: NSAttributedString, bottomLabelText: NSAttributedString, dateLabelText: NSAttributedString) {
//            topLabel.attributedText = topLabelText
//            bottomLabel.attributedText = bottomLabelText
//            dateLabel.attributedText = dateLabelText
//        }
//        
//        open func layoutBottomLine() {
//            bottomLine.frame = CGRect(x: 0, y: frame.maxY - 0.5, width: frame.width, height: 0.5)
//            bringSubviewToFront(bottomLine)
//            setNeedsLayout()
//        }
//    }
//    
//    internal func subscribePinMessageBar() {
//        if !groupchat { return }
//        pinBag = DisposeBag()
//        do {
//            let realm = try WRealm.safe()
//            Observable
//                .collection(from: realm
//                    .objects(GroupChatStorageItem.self)
//                    .filter("owner == %@ AND jid == %@", owner, jid))
//                .subscribe(onNext: { (results) in
//                    if let groupchat = results.first {
//                        if groupchat.pinnedMessage.isEmpty || groupchat.pinnedMessage == "0" {
//                            self.pinnedMessageId.accept(nil)
//                        } else {
//                            if self.pinnedMessageId.value != groupchat.pinnedMessage {
//                                self.pinnedMessageId.accept(groupchat.pinnedMessage)
//                            }
//                        }
//                        if groupchat.canChangeSettings {
//                            if !self.canUnpinMessage.value {
//                                self.canUnpinMessage.accept(true)
//                            }
//                        } else {
//                            if self.canUnpinMessage.value {
//                                self.canUnpinMessage.accept(false)
//                            }
//                        }
//                    }
//                })
//                .disposed(by: pinBag)
//            
//            canUnpinMessage
//                .asObservable()
//                .subscribe(onNext: { (value) in
//                    self.pinMessageView.unpinButton.isHidden = !value
//                })
//                .disposed(by: pinBag)
//            
//            pinnedMessageId
//                .asObservable()
//                .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (value) in
//                    if let stanzaId = value {
//                        if stanzaId != self.currentPinnedMessageId {
//                            self.currentPinnedMessageId = stanzaId
//                            self.willShowPinMessageBar(animated: false)
//                        }
//                    } else {
//                        if self.currentPinnedMessageId != nil {
//                            self.hidePinMessageBar(animated: true)
//                        }
//                    }
//                })
//                .disposed(by: pinBag)
//        } catch {
//            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    internal func willShowPinMessageBar(animated: Bool) {
//        guard let messageId = currentPinnedMessageId else { return }
//        do {
//            let realm = try WRealm.safe()
//            var pinDelayBag = DisposeBag()
//            Observable
//                .collection(from: realm
//                    .objects(MessageStorageItem.self)
//                    .filter("owner == %@ AND opponent == %@ AND archivedId == %@", owner, jid, messageId))
//                .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    if let message = results.first {
//                        pinDelayBag = DisposeBag()
//                        let body = NSAttributedString(string: message.displayedBody(entity: self.entity),
//                                                      attributes: [NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .caption1)])
//                        let author = ContactChatMetadataManager
//                            .shared
//                            .get(message.groupchatAuthorNickname ?? "",
//                                 for: self.owner,
//                                 badge: message.groupchatAuthorBadge ?? "",
//                                 role: message.groupchatMetadata?["role"] as? String ?? "member")
//                            .getAttributedNickname([.font: UIFont.preferredFont(forTextStyle: .caption1)])
//                        
//                        let date = message.date
////                        DispatchQueue.main.async {
//                            if messageId == self.settedPinnedMessageId { return }
//                            self.settedPinnedMessageId = self.currentPinnedMessageId
//                            self.showPinMessageBar(animated: animated, message: body, author: author, date: date)
////                        }
//                    }
//                })
//                .disposed(by: pinDelayBag)
//            
//        } catch {
//            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    internal func showPinMessageBar(animated: Bool, message: NSAttributedString, author: NSAttributedString, date: Date) {
//        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
//            if animated {
//                UIView.animate(withDuration: 0.3,
//                               animations: block,
//                               completion: completion)
//            } else {
//                block()
//                completion?(true)
//            }
//        }
//        
//        if let maxY = self.navigationController?.navigationBar.frame.maxY,
//            let width = self.navigationController?.navigationBar.frame.width {
//            let dateFormatter = DateFormatter()
//            dateFormatter.dateFormat = "EEEE, MMM d, yyyy HH:mm"
//            let dateString = NSAttributedString(string: dateFormatter.string(from: date), attributes: [NSAttributedString.Key.font : UIFont.preferredFont(forTextStyle: .caption1), NSAttributedString.Key.foregroundColor : MDCPalette.grey.tint500])
//            
//            pinMessageView.configure(topLabelText: author, bottomLabelText: message, dateLabelText: dateString)
//            pinMessageView.onUnpinCallback = onUnpinMessage
//            pinMessageView.onTapCallback = onTapPinnedMessage
//            pinMessageBar.frame = CGRect(x: 0, y: 0, width: width, height: 64)
//            
//            messageCollectionViewBottomInset = 116
////            self.currentPinnedMessageId = self.pinnedMessageId.value
//            transition({
////                self.pinMessageView.isHidden = false
//                self.pinMessageBar.frame = CGRect(x: 0, y: maxY, width: width, height: 48)
//                self.pinMessageView.frame = CGRect(x: 0, y: 0, width: width, height: 48)
//                self.pinMessageBar.alpha = 1.0
//                self.pinMessageView.activateConstraints()
//            }) { (result) in
//                self.pinMessageView.layoutBottomLine()
//            }
//        }
//    }
//    
//    
//    internal func hidePinMessageBar(animated: Bool) {
//        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
//            if animated {
//                UIView.animate(withDuration: 0.3,
//                               animations: block,
//                               completion: completion)
//            } else {
//                block()
//                completion?(true)
//            }
//        }
//        messageCollectionViewBottomInset = 72
//        let width = self.pinMessageBar.frame.width
//        transition({
//            self.pinMessageBar.frame = CGRect(x: 0, y: 0, width: width, height: 64)
////            self.pinMessageView.frame = CGRect(x: 0, y: 0, width: width, height: 48)
//            self.pinMessageView.frame = CGRect(x: 0, y: 0, width: width, height: 64)
//            self.pinMessageBar.alpha = 0
////            self.pinMessageView.isHidden = true
//        }) { (result) in
//            self.settedPinnedMessageId = nil
//            self.currentPinnedMessageId = nil
//        }
//        
//    }
//
//    internal func onUnpinMessage() {
//        
//        ActionSheetPresenter().present(
//            in: self,
//            title: nil,
//            message: nil,
//            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
//            values: [ActionSheetPresenter.Item(destructive: true,
//                                               title: "Unpin".localizeString(id: "group_chat__pinned_message__tooltip_unpin", arguments: []),
//                                               value: "unpin")],
//            animated: true
//        ) { (value) in
//            if value == "unpin" {
//                DispatchQueue.main.async {
//                    var origin = self.view.center
//                    let keyboardHeight = 432 / UIScreen.main.scale
//                    if self.view.bounds.height - origin.x < keyboardHeight {
//                        origin.x = self.view.bounds.height - keyboardHeight - 44
//                    }
//                    self.view.makeToastActivity(origin)
//                    XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                        session.groupchat?.unpinMessage(stream, groupchat: self.jid) { (error) in
//                            DispatchQueue.main.async {
//                                self.view.hideToastActivity()
//                                if let error = error {
//                                    var message = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
//                                    switch error {
//                                    case "not-allowed": message = "You don't have permission to unpin messages".localizeString(id: "groupchats_no_unpin_permission", arguments: [])
//                                    default: break
//                                    }
//                                    self.showToast(error: message)
//                                } else {
//                                    self.pinnedMessageId.accept(nil)
//                                }
//                            }
//                        }
//                    }) {
//                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                            user.groupchats.unpinMessage(stream, groupchat: self.jid) { (error) in
//                                DispatchQueue.main.async {
//                                    self.view.hideToastActivity()
//                                    if let error = error {
//                                        var message = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
//                                        switch error {
//                                        case "not-allowed": message = "You don't have permission to unpin messages".localizeString(id: "groupchats_no_unpin_permission", arguments: [])
//                                        default: break
//                                        }
//                                        self.showToast(error: message)
//                                    } else {
//                                        self.pinnedMessageId.accept(nil)
//                                    }
//                                }
//                            }
//                        })
//                    }
//                }
//            }
//        }
//    }
//    
//    internal func onTapPinnedMessage() {
//        if let messageId = currentPinnedMessageId,
//            let index = messagesObserver?.firstIndex(where: { $0.archivedId == messageId }) {
//            DispatchQueue.main.async {
//                self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: true)
//                self.scrollItemIndexPath = IndexPath(row: 0, section: index)
//                (self.messagesCollectionView.cellForItem(at: IndexPath(row: 0, section: index)) as? MessageContentCell)?
//                    .hilghlightCell(color: UIColor.blue.withAlphaComponent(0.1), duration: 1.6)
//            }
//        }
//    }
//}
