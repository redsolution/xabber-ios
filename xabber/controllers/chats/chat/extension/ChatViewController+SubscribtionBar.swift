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
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import MaterialComponents.MDCPalettes
import Toast_Swift
import CocoaLumberjack

extension ChatViewController {

    class SubscribtionBarView: UIView {
        
        enum State {
            case notInRoster
            case subscribe
        }
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .bottom
            stack.spacing = 8
//            stack.distribution = .fill
//
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 8, right: 8)
            
            return stack
        }()
        
        let middleStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .leading
            stack.spacing = 4
            stack.distribution = .fill
            
            stack.isUserInteractionEnabled = true
            
            return stack
        }()
                
        let addContactButton: UIButton = {
            let button = UIButton()
            
            button.tintColor = .systemBlue
            button.setTitle("Add contact".localizeString(id: "application_action_no_contacts", arguments: []), for: .normal)
            button.setTitleColor(.systemBlue, for: .normal)
            
            
            return button
        }()
        
        let blockButton: UIButton = {
            let button = UIButton()
            
            button.tintColor = .systemRed
            button.setTitle("Block".localizeString(id: "contact_bar_block", arguments: []), for: .normal)
            button.setTitleColor(.systemRed, for: .normal)
            
            return button
        }()
        
        let subscribeButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(.systemBlue, for: .normal)
            button.setTitle("Incoming subscription request".localizeString(id: "incoming_subscription_request", arguments: []), for: .normal)
            button.contentVerticalAlignment = .bottom
            
            return button
        }()
        
        let cancelButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "feather_close_24pt").withRenderingMode(.alwaysTemplate), for: .normal)
            button.frame = CGRect(square: 36)
            button.tintColor = .gray
            
            button.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
            
            return button
        }()
        
        internal let bottomLine: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.21)
            
            return view
        }()
        
        open var state: State = .notInRoster
        
        open var onCancelCallback: (() -> Void)? = nil
        
        open var onAddContactCallback: (() -> Void)? = nil
        open var onBlockContactCallback: (() -> Void)? = nil
        open var onSubscribeCallback: (() -> Void)? = nil
        
        @objc
        internal func onAddContactButtonPressed() {
            onAddContactCallback?()
        }
        
        @objc
        internal func onBlockButtonPressed() {
            onBlockContactCallback?()
        }
        
        @objc
        private func onSubscribeButtonPressed() {
            onSubscribeCallback?()
        }
        
        @objc
        internal func onCancel() {
            onCancelCallback?()
        }
        
        var subscribtionConstraints: [NSLayoutConstraint] = []
        var notInRosterConstraints: [NSLayoutConstraint] = []
        
        internal func activateConstraints() {
            notInRosterConstraints = [
                blockButton.widthAnchor.constraint(equalTo: addContactButton.widthAnchor, multiplier: 1),
                cancelButton.widthAnchor.constraint(equalToConstant: 36),
                cancelButton.heightAnchor.constraint(equalToConstant: 36)
            ]
            
            subscribtionConstraints = [
//                rightButton.widthAnchor.constraint(equalToConstant: 90),
//                cancelButton.widthAnchor.constraint(equalToConstant: 36),
//                cancelButton.heightAnchor.constraint(equalToConstant: 36)
                self.subscribeButton.widthAnchor.constraint(equalTo: self.stack.widthAnchor),
                self.subscribeButton.heightAnchor.constraint(equalTo: self.stack.heightAnchor)
            ]
        }
        
        open func configure(for state: State) -> CGFloat {
            self.state = state
            switch state {
            case .notInRoster:
                NSLayoutConstraint.activate(notInRosterConstraints)
                NSLayoutConstraint.deactivate(subscribtionConstraints)
//                self.textLabel.isHidden = true
                self.subscribeButton.isHidden = true
                self.blockButton.isHidden = false
                self.addContactButton.isHidden = false
                self.cancelButton.isHidden = false
                return 40
            case .subscribe:
                NSLayoutConstraint.deactivate(notInRosterConstraints)
                NSLayoutConstraint.activate(subscribtionConstraints)
                self.addContactButton.isHidden = true
                self.blockButton.isHidden = true
                self.cancelButton.isHidden = true//false
                self.subscribeButton.isHidden = false
                return 40
            }
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(stack)
            stack.fillSuperviewWithOffset(top: 64, bottom: 0, left: 0, right: 0)
            stack.addArrangedSubview(middleStack)
            stack.addArrangedSubview(cancelButton)
//            middleStack.addArrangedSubview(textLabel)
            middleStack.addArrangedSubview(addContactButton)
            middleStack.addArrangedSubview(blockButton)
            middleStack.addArrangedSubview(subscribeButton)
//            addSubview(bottomLine)
            activateConstraints()
            
            cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
            addContactButton.addTarget(self, action: #selector(onAddContactButtonPressed), for: .touchUpInside)
            blockButton.addTarget(self, action: #selector(onBlockButtonPressed), for: .touchUpInside)
            subscribeButton.addTarget(self, action: #selector(onSubscribeButtonPressed), for: .touchUpInside)
        }
        
        required init?(coder: NSCoder) {
            fatalError()
        }
        
        open func layoutBottomLine() {
            bottomLine.frame = CGRect(x: 0, y: frame.maxY - 0.5, width: frame.width, height: 0.5)
            bringSubviewToFront(bottomLine)
            setNeedsLayout()
        }
    }
    
    internal func showSubscribtionBar(animated: Bool, state: SubscribtionBarView.State) {
        
        let height = subscribtionBarView.configure(for: state)
        
        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
            if animated {
                UIView.animate(withDuration: 0.3,
                               animations: block,
                               completion: completion)
            } else {
                block()
                completion?(true)
            }
        }
        
        if let maxY = self.navigationController?.navigationBar.frame.maxY,
            let width = self.navigationController?.navigationBar.frame.width {
            
            subscribtionBarView.frame = CGRect(x: 0, y: 0, width: width, height: height)
//            additionalBottomInset = 40
            subscribtionBarView.onCancelCallback = onCancelSubscribtionBarButtonPressed
            subscribtionBarView.onAddContactCallback = onAddContactBarButtonPressed
            subscribtionBarView.onBlockContactCallback = onBlockContactBarButtonPressed
            subscribtionBarView.onSubscribeCallback = onSubscribeBarButtonPressed
            
            transition({
                self.subscribtionBar.isHidden = false
                self.subscribtionBarView.isHidden = false
                self.subscribtionBar.frame = CGRect(x: 0, y: 0, width: width, height: maxY + height)
                self.subscribtionBarView.layoutBottomLine()
            }) { (result) in
                self.subscribtionBarView.layoutBottomLine()
            }
        }
    }
    
    
    internal func hideSubscribtionBar(animated: Bool) {
        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
            if animated {
                UIView.animate(withDuration: 0.3,
                               animations: block,
                               completion: completion)
            } else {
                block()
                completion?(true)
            }
        }
        let width = self.subscribtionBar.frame.width
        transition({
            self.subscribtionBar.frame = CGRect(x: 0, y: 0, width: width, height: 64)
            self.subscribtionBarView.isHidden = true
            self.subscribtionBar.isHidden = true
        }) { (result) in
            
        }
        
    }
    
    internal func onSubscribeBarButtonPressed() {
        
        var items: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: false, title: "Allow and subscribe back".localizeString(id: "chat_allow_and_subscribe", arguments: []), value: "subscribe_subscribed"),
            ActionSheetPresenter.Item(destructive: false, title: "Allow".localizeString(id: "chat_allow", arguments: []), value: "subscribed"),
            ActionSheetPresenter.Item(destructive: true, title: "Decline".localizeString(id: "decline", arguments: []), value: "unsubscribe_unsubscsribed")
        ]
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                print(instance.ask)
                print(instance.subscribtion)
                if(instance.subscribtion == .to) {
                    items.removeFirst()
                }
            }
        } catch {
            DDLogDebug("SubscribtionBarView: \(#function). \(error.localizedDescription)")
        }
        
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: items,
            animated: true
        ) { value in
            switch value {
            case "subscribe_subscribed":
                DispatchQueue.main.async {
                    self.hideSubscribtionBar(animated: true)
                }
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.presences.subscribe(stream, jid: self.jid)
                    user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
                })
                
            case "subscribed":
                DispatchQueue.main.async {
                    self.hideSubscribtionBar(animated: true)
                }
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
                })

            case "unsubscribe_unsubscsribed":
                DispatchQueue.main.async {
                    self.hideSubscribtionBar(animated: true)
                }
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.presences.unsubscribe(stream, jid: self.jid)
                    user.presences.unsubscribed(stream, jid: self.jid)
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                            try realm.write {
                                instance.ask = .none
                            }
                        }
                    } catch {
                        DDLogDebug("SubscribtionBarView: \(#function). \(error.localizedDescription)")
                    }
                })
                
            default:
                break
            }
        }
    }
    
    internal func onAddContactBarButtonPressed() {
        hideSubscribtionBar(animated: true)
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            
            user.presences.subscribe(stream, jid: self.jid)
            user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
            user.vcards.requestItem(stream, jid: self.jid)
            user.roster.setContact(stream, jid: self.jid, nickname: nil, groups: [], callback: nil)
        })
    }
    
    internal func onBlockContactBarButtonPressed() {
        hideSubscribtionBar(animated: true)
        XMPPUIActionManager.shared.open(owner: self.owner)
        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
            session.blocked?.blockContact(stream, jid: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.blocked.blockContact(stream, jid: self.jid)
            })
        }
        DispatchQueue.main.async {
            self.showToast(error: "Contact \(self.jid) has been blocked".localizeString(id: "contact_has_been_blocked", arguments: ["\(self.jid)"]))
        }
    }
    
    internal func onCancelSubscribtionBarButtonPressed() {
        hideSubscribtionBar(animated: true)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.presences.unsubscribed(stream, jid: self.jid)
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                    try realm.write {
                        instance.ask = .none
                    }
                }
            } catch {
                DDLogDebug("SubscribtionBarView: \(#function). \(error.localizedDescription)")
            }
        })
    }
}
