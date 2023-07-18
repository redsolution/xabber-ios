//
//  GroupchatJoinViewController.swift
//  xabber_test_xmpp
//
//  Created by Игорь Болдин on 13/12/2019.
//  Copyright © 2019 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import RxRealm
import RxCocoa
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import Kingfisher

class GroupchatJoinViewController: BaseViewController {
    
//    internal var jid: String = ""
//    internal var owner: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var username: BehaviorRelay<String> = BehaviorRelay<String>(value: "")
    internal var avatarKey: BehaviorRelay<String> = BehaviorRelay<String>(value: "")
    
    internal var inJoinMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    static let avatarSize: CGFloat = 160
    
    internal var isPrivateGroup: Bool = false
    
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, bottom: 44, left: 16, right: 16)
        
        return stack
    }()
    
    internal var avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: GroupchatJoinViewController.avatarSize))
        
        view.layer.cornerRadius = avatarSize / 2
//        if #available(iOS 13.0, *) {
//            view.layer.borderColor = UIColor.systemBackground.cgColor
//        } else {
            view.layer.borderColor = UIColor.white.cgColor
//        }
        view.layer.borderWidth = 1
        view.layer.masksToBounds = true
        
        return view
    }()
    
    internal let titleLabel: UILabel = {
        let label = UILabel()
        
//        if #available(iOS 13.0, *) {
//            label.textColor = .label
//        } else {
            label.textColor = .darkText
//        }
        label.font = UIFont.preferredFont(forTextStyle: .title1)
        
        return label
    }()
    
    internal let subtitleLabel: UILabel = {
        let label = UILabel()
        
//        if #available(iOS 13.0, *) {
//            label.textColor = .secondaryLabel
//        } else {
            label.textColor = MDCPalette.grey.tint500//.systemGray
//        }
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.numberOfLines = 0
        
        return label
    }()
    
    internal let buttonsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.alignment = .center
        stack.axis = .vertical
        stack.distribution = .equalCentering
        stack.spacing = 12
        
        
        return stack
    }()
    
    internal let joinButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Join".uppercased(), for: .normal)
        button.setTitleColor(MDCPalette.green.tint500, for: .normal)
        
        return button
    }()
    
    internal let declineButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Decline".uppercased(), for: .normal)
        button.setTitleColor(MDCPalette.red.tint500, for: .normal)
        
        return button
    }()
    
    internal let blockButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Block".uppercased(), for: .normal)
        button.setTitleColor(MDCPalette.red.tint500, for: .normal)
        
        return button
    }()
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try Realm()
            Observable
                .collection(from: realm
                                    .objects(vCardStorageItem.self)
                                    .filter("jid == %@", jid))
                .subscribe(onNext: { (results) in
                    if let instance = results.first {
                        if instance.generatedNickname.isNotEmpty {
                            self.username.accept(instance.generatedNickname)
                        } else if let localpart = self.jid.split(separator: "@").first {
                            self.username.accept("\(localpart)")
                        } else {
                            self.username.accept(self.jid)
                        }
                        self.avatarKey.accept(self.jid)
                    }
                })
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("GroupchatJoinViewController: \(#function). \(error.localizedDescription)")
        }
        
        username
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    self.titleLabel.text = value
                    self.titleLabel.setNeedsLayout()
                }
            })
            .disposed(by: bag)
              
        inJoinMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(nil, animated: true)
                    }
                }
            })
            .disposed(by: bag)
        
        avatarKey
            .asObservable()
            .subscribe(onNext: { (value) in
                if value.isNotEmpty {
                    self.avatarView.kf.setImage(with: ImageResource(downloadURL: URL(string: value)!, cacheKey: value))
                }
            })
            .disposed(by: bag)
        
        joinButton
            .rx
            .tap
            .subscribe(onNext: { (_) in
                self.inJoinMode.accept(false)
                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                    user.groupchats.join(stream, uiConnection: false, groupchat: self.jid, callback: self.onJoinCallback)
                })
            })
            .disposed(by: bag)
        
        declineButton
            .rx
            .tap
            .subscribe(onNext: { (_) in
                self.onDecline()
            })
            .disposed(by: bag)
        
        blockButton
            .rx
            .tap
            .subscribe(onNext: { (_) in
                self.onBlock()
            })
            .disposed(by: bag)
    }
    
    internal func onDecline() {
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.blockInvite(groupchat: self.jid)
        })
        self.navigationController?.popViewController(animated: true)
    }
    
    internal func onBlock() {
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.blockInvite(groupchat: self.jid, withContact: true)
        })
        self.navigationController?.popViewController(animated: true)
    }
    
    internal func onJoinCallback(_ error: String?) {
        inJoinMode.accept(false)
        if let error = error {
            var message: String = ""
            switch error {
            case "error":
                message = "Invite was revoked"
                AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                    user.groupchats.blockInvite(groupchat: self.jid)
                })
            case "fail":
                message = "Connection failed"
            default:
                message = "Internal server error"
            }
            DispatchQueue.main.async {
                ErrorMessagePresenter().present(in: self,
                                                message: message,
                                                animated: true,
                                                completion: nil)
            }
        } else {
            DispatchQueue.main.async {
                let vc = ChatViewController()
                vc.jid = self.jid
                vc.owner = self.owner
                vc.entity = self.isPrivateGroup ? .privateChat : .groupchat
                vc.conversationType = .group
                var vcs = self.navigationController?.viewControllers ?? []
                if let index = vcs.firstIndex(of: self) {
                    vcs.remove(at: index)
                }
                vcs.append(vc)
                self.navigationController?.setViewControllers(vcs, animated: true)
            }
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        [joinButton, declineButton, blockButton].forEach {
            $0.heightAnchor.constraint(equalToConstant: 44).isActive = true
            $0.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        avatarView.widthAnchor.constraint(equalToConstant: GroupchatJoinViewController.avatarSize).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: GroupchatJoinViewController.avatarSize).isActive = true
        buttonsStack.heightAnchor.constraint(lessThanOrEqualToConstant: 56 * 3).isActive = true
//        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9).isActive = true
    }
    
    open func configure(_ jid: String, owner: String) {
        self.jid = jid
        self.owner = owner
        
        
        view.addSubview(stack)
        stack.fillSuperview()
        buttonsStack.addArrangedSubview(joinButton)
        buttonsStack.addArrangedSubview(declineButton)
        buttonsStack.addArrangedSubview(blockButton)
        
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(avatarView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(buttonsStack)
        stack.addArrangedSubview(UIStackView())
        
        do {
            let realm = try Realm()
            self.isPrivateGroup = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND groupchat == %@", owner, jid)
                .first?
                .isAnonymous ?? false
        } catch {
            DDLogDebug("GroupchatJoinViewController: \(#function). \(error.localizedDescription)")
        }
        
        if self.isPrivateGroup {
            subtitleLabel.text = "You are invited to group chat. If you accept, your XMPP Id shall not be visible to group members"
        } else {
            subtitleLabel.text = "You are invited to group chat. If you accept, \(owner) username shall be visible to group members"
        }
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        activateConstraints()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        getAppTabBar()?.hide()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
