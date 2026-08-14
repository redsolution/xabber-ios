//
//  GroupchatJoinViewController.swift
//  xabber_test_xmpp
//
//  Created by Игорь Болдин on 13/12/2019.
//  Copyright © 2019 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RxSwift
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
    
    internal var isIncognitoGroup: Bool = false
    internal var isPeerToPeer: Bool = false
    
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
                if value.isNotEmpty, let url = URL(string: value) {
                    self.avatarView.kf.setImage(
                        with: ImageResource(downloadURL: url, cacheKey: value)
                    )
                }
            })
            .disposed(by: bag)
        
        joinButton
            .rx
            .tap
            .subscribe(onNext: { (_) in
                self.onJoin()
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

    internal func onJoin() {
        guard let account = AccountManager.shared.find(for: owner) else {
            presentLifecycleError(GroupchatServiceError.notPrepared)
            return
        }
        inJoinMode.accept(true)
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                try await CanonicalGroupMembershipLifecycle.join(
                    account: account,
                    groupJID: self.jid
                )
                account.removeCanonicalGroupInvite(self.jid)
                self.inJoinMode.accept(false)
                self.onJoinSucceeded()
            } catch {
                self.inJoinMode.accept(false)
                self.presentLifecycleError(error)
            }
        }
    }
    
    internal func onDecline() {
        guard let account = AccountManager.shared.find(for: owner) else {
            presentLifecycleError(GroupchatServiceError.notPrepared)
            return
        }
        inJoinMode.accept(true)
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                try await account.groupchatService.declineInvite(groupJID: self.jid)
                account.removeCanonicalGroupInvite(self.jid)
                self.inJoinMode.accept(false)
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.inJoinMode.accept(false)
                self.presentLifecycleError(error)
            }
        }
    }
    
    internal func onBlock() {
        guard let account = AccountManager.shared.find(for: owner) else {
            presentLifecycleError(GroupchatServiceError.notPrepared)
            return
        }
        inJoinMode.accept(true)
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let invite = try GroupRepository(
                    realm: WRealm.safe()
                ).incomingInvite(owner: self.owner, groupJID: self.jid)
                try await account.groupchatService.declineInvite(groupJID: self.jid)
                account.removeCanonicalGroupInvite(self.jid)
                if let inviterJID = invite?.inviter?.jid {
                    account.action { user, stream in
                        user.blocked.blockContact(stream, jid: inviterJID)
                    }
                }
                self.inJoinMode.accept(false)
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.inJoinMode.accept(false)
                self.presentLifecycleError(error)
            }
        }
    }

    private func onJoinSucceeded() {
        let vc = ChatViewController()
        vc.jid = jid
        vc.owner = owner
        if isPeerToPeer {
            vc.entity = .privateChat
        } else if isIncognitoGroup {
            vc.entity = .incognitoChat
        } else {
            vc.entity = .groupchat
        }
        vc.conversationType = .group
        var controllers = navigationController?.viewControllers ?? []
        if let index = controllers.firstIndex(of: self) {
            controllers.remove(at: index)
        }
        controllers.append(vc)
        navigationController?.setViewControllers(controllers, animated: true)
    }

    private func presentLifecycleError(_ error: Error) {
        ErrorMessagePresenter().present(
            in: self,
            message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
            animated: true,
            completion: nil
        )
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
            let invite = try GroupRepository(
                realm: WRealm.safe()
            ).incomingInvite(owner: owner, groupJID: jid)
            let preview = invite?.preview
            self.isIncognitoGroup = preview?.privacy == .incognito
            self.isPeerToPeer = preview?.parentJID != nil
            self.username.accept(
                preview?.info?.name
                    ?? preview?.localpart
                    ?? GroupStorageKey.bareJID(jid)
            )
            self.avatarKey.accept(preview?.info?.avatar?.url ?? "")
            self.blockButton.isHidden = invite?.inviter?.jid == nil
        } catch {
            DDLogDebug("GroupchatJoinViewController: \(#function). \(error.localizedDescription)")
        }
        
        if self.isIncognitoGroup {
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
