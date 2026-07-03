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
import Kingfisher
import MaterialComponents.MDCPalettes
import CocoaLumberjack


extension ChatViewController {
    final class ChatNavbarHeaderView: UIView {
        private let titleButton: UIButton
        private let titleStack: UIStackView
        private let avatarView: UserBarButton
        private var widthConstraint: NSLayoutConstraint?
        private let avatarSize: CGFloat = 42
        private let avatarSpacing: CGFloat = 12

        init(titleButton: UIButton, titleStack: UIStackView, avatarView: UserBarButton) {
            self.titleButton = titleButton
            self.titleStack = titleStack
            self.avatarView = avatarView
            super.init(frame: .zero)
            setupSubviews()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupSubviews() {
            translatesAutoresizingMaskIntoConstraints = false
            backgroundColor = .clear

            titleButton.translatesAutoresizingMaskIntoConstraints = false
            titleButton.backgroundColor = .clear

            titleStack.translatesAutoresizingMaskIntoConstraints = false
            if titleStack.superview !== titleButton {
                titleButton.addSubview(titleStack)
            }

            avatarView.translatesAutoresizingMaskIntoConstraints = false

            addSubview(titleButton)
            addSubview(avatarView)

            titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
            avatarView.setContentCompressionResistancePriority(.required, for: .horizontal)
            avatarView.setContentHuggingPriority(.required, for: .horizontal)

            widthConstraint = widthAnchor.constraint(equalToConstant: 220)
            widthConstraint?.priority = .required
            widthConstraint?.isActive = true

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: avatarSize),

                avatarView.trailingAnchor.constraint(equalTo: trailingAnchor),
                avatarView.topAnchor.constraint(equalTo: topAnchor),
                avatarView.widthAnchor.constraint(equalToConstant: avatarSize),
                avatarView.heightAnchor.constraint(equalToConstant: avatarSize),

                titleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                titleButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleButton.heightAnchor.constraint(equalToConstant: avatarSize),

                titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleButton.leadingAnchor, constant: 8),
                titleStack.trailingAnchor.constraint(lessThanOrEqualTo: titleButton.trailingAnchor, constant: -8),
                titleStack.centerXAnchor.constraint(equalTo: titleButton.centerXAnchor),
                titleStack.topAnchor.constraint(greaterThanOrEqualTo: titleButton.topAnchor),
                titleStack.bottomAnchor.constraint(lessThanOrEqualTo: titleButton.bottomAnchor),
                titleStack.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor)
            ])
        }

        func updateAvailableWidth(_ width: CGFloat) {
            widthConstraint?.constant = max(160, width)
            invalidateIntrinsicContentSize()
            frame.size = CGSize(width: max(160, width), height: avatarSize)
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: widthConstraint?.constant ?? 220, height: avatarSize)
        }
    }

    class UserBarButton: UIView {

        static let initialAvatarSize: CGSize = CGSize(square: 42)

        internal var jid: String = ""
        internal var owner: String = ""

        internal var bag: DisposeBag = DisposeBag()

        internal var allowBarAnimation: Bool = false
        
        internal var avatar: UIImageView = {
            let image = UIImageView(frame: CGRect(origin: CGPoint(x: 0, y: 0),
                                                  size: UserBarButton.initialAvatarSize))
            image.contentMode = .scaleAspectFill

            let mask = AccountMasksManager.shared.load()
            if mask != "square" {
                image.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt)!.upscale(dimension: 42))
            } else {
                image.mask = nil
            }
            image.layer.masksToBounds = true
            
            return image
        }()

        internal let status: RoundedStatusView = {
            let view = RoundedStatusView()

            view.frame = CGRect(origin: CGPoint(x: 30, y: 30), size: CGSize(square: 12))

            return view
        }()
        
        private let gradientView: UIView = {
            let view = UIView(frame: CGRect(origin: CGPoint(x: -7, y: -7),
                                                 size: CGSize(square: 52)))

            return view
        }()
        
        internal var gradient: CAGradientLayer = {
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.colors = [
                UIColor.white.cgColor,
                UIColor.systemOrange.cgColor
            ]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0, y: 0.5)
            
            return gradient
        }()
        
        private let gradientMask: UIImageView = {
            let view = UIImageView(frame: CGRect(origin: CGPoint(x: 2, y: 2),
                                            size: CGSize(square: 52)))
            view.backgroundColor = .clear
            
            return view
        }()
        
        func setMask() {
            if AccountMasksManager.shared.load() != "square" {
                avatar.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt))
            } else {
                avatar.mask = nil
            }
        }
        
        public final func hideProgressBar() {
//            UIView.animate(withDuration: 0.66, delay: 0, options: .curveLinear, animations: {
//                self.gradientView.alpha = 0
//            })
        }
        
        private final func rotateBar() {
//            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
//                self.gradientView.alpha = 1
//            }) { result in
//                if self.allowBarAnimation {
//                    self.rotateBar()
//                }
//            }
        }
        
        public final func stopAnimation() {
//            self.allowBarAnimation = false
//
//            UIView.animate(withDuration: 0.66, delay: 0, options: .curveLinear, animations: {
//                self.gradientView.alpha = 0
//            }) { result in
//                self.stopGradientAnimation()
//            }
        }
        
        public final func startAnimation() {
//            self.allowBarAnimation = true
//            gradientView.alpha = 0
//            startGradientAnimation()
//
//            UIView.animate(withDuration: 0.33, delay: 0, options: [], animations: {
//                self.gradientView.alpha = 1
//            })
        }
        
        private func startGradientAnimation() {
//            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
//                self.gradientView.transform = self.gradientView.transform.rotated(by: .pi)
//            }) { result in
//                if self.allowBarAnimation {
//                    self.startGradientAnimation()
//                }
//            }
        }
        
        private func stopGradientAnimation() {
//            self.allowBarAnimation = false
//            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
//                self.gradientView.transform = self.gradientView.transform.rotated(by: .pi)
//            }) { _ in
//                self.gradientView.layer.removeAllAnimations()
//            }
        }
        
        internal func subscribe() {
            bag = DisposeBag()
            do {
                let realm = try WRealm.safe()
                Observable.collection(from: realm
                    .objects(ResourceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                    .sorted(by: [
                        SortDescriptor(keyPath: "timestamp", ascending: false),
                        SortDescriptor(keyPath: "priority", ascending: false)
                    ]))
                    .subscribe(onNext: { (results) in
                        if let item = results.first {
                            self.updateStatus(status: item.status, entity: item.entity)
                        } else {
                            self.updateStatus(status: .offline, entity: .contact)
                        }
                    })
                    .disposed(by: bag)
                
                Observable
                    .collection(from: realm
                        .objects(RosterStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                    .subscribe(onNext: { (results) in
                        let avatarUrl = results.first?.avatarMinUrl ?? results.first?.avatarMaxUrl ?? results.first?.oldschoolAvatarKey
                        DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: self.jid, owner: self.owner, size: 32) { image in
                            if let image = image {
                                self.avatar.image = image
                            } else {
                                self.avatar.image = UIImageView.getDefaultAvatar(for: self.jid, owner: self.owner, size: 32)
                            }
                        }
                    })
                    .disposed(by: bag)
            } catch {
                DDLogDebug("UserBarButton: \(#function). \(error.localizedDescription)")
            }
            
        }

        internal func unsubscribe() {
            bag = DisposeBag()
        }

        internal func updateStatus(status: ResourceStatus, entity: RosterItemEntity) {
            self.status.border(1)
            switch entity {
            case .groupchat, .incognitoChat, .server, .bot, .privateChat, .issue:
                self.status.frame = CGRect(origin: CGPoint(x: 28, y: 28), size: CGSize(square: 14))
                break
            default:
                self.status.frame = CGRect(origin: CGPoint(x: 30, y: 30), size: CGSize(square: 10))
                break
            }
            self.status.setStatus(status: status, entity: entity)
            self.status.border(1)
        }

        private final func setupSubviews() {
            backgroundColor = .clear
            addSubview(gradientMask)
            gradientMask.addSubview(gradientView)
            addSubview(avatar)
            addSubview(status)
            
            gradient.frame = gradientView.bounds
            gradientView.layer.addSublayer(gradient)
            
            guard let currentMask = AccountMasksManager.shared.load() else { return }
            gradientMask.mask = UIImageView(image: imageLiteral( String(currentMask + "_outline_32pt")))
        }
        
        public final func configure(owner: String, jid: String) {
            self.owner = owner
            self.jid = jid
            subscribe()
            let palette = AccountColorManager.shared.palette(for: owner)
            self.gradientView.alpha = 0
            self.avatar.backgroundColor = MDCPalette.grey.tint50
        }

        override init(frame: CGRect) {
            super.init(frame: CGRect(origin: frame.origin, size: UserBarButton.initialAvatarSize))
            setupSubviews()
        }

        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }

        override var intrinsicContentSize: CGSize {
            UserBarButton.initialAvatarSize
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            UserBarButton.initialAvatarSize
        }

        deinit {
            unsubscribe()
        }
    }
}

enum ChatNavigationAvatarItemFactory {
    static let accessibilityIdentifier = "chat_navigation_avatar_button"
    static let imageSize: CGFloat = 42
    private static let savedIconSize: CGFloat = 16

    static func makeItem(
        image: UIImage?,
        target: AnyObject?,
        action: Selector
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: image?.withRenderingMode(.alwaysOriginal),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityIdentifier = accessibilityIdentifier
        item.accessibilityLabel = "Chat info".localizeString(id: "chat_info", arguments: [])
        return item
    }

    static func avatarImage(from image: UIImage?) -> UIImage? {
        guard let image else {
            return nil
        }
        return renderAvatarImage(
            image: image,
            backgroundColor: nil,
            iconTintColor: nil,
            prefersSquareMask: AccountMasksManager.shared.load() == "square"
        )
    }

    static func savedMessagesImage(
        backgroundColor: UIColor,
        iconTintColor: UIColor
    ) -> UIImage? {
        let icon = imageLiteral(XMPPFavoritesManagerStorageItem.imageName, dimension: savedIconSize)?
            .withTintColor(iconTintColor, renderingMode: .alwaysOriginal)
        return renderAvatarImage(
            image: icon,
            backgroundColor: backgroundColor,
            iconTintColor: iconTintColor,
            prefersSquareMask: AccountMasksManager.shared.load() == "square"
        )
    }

    private static func renderAvatarImage(
        image: UIImage?,
        backgroundColor: UIColor?,
        iconTintColor: UIColor?,
        prefersSquareMask: Bool
    ) -> UIImage? {
        let size = CGSize(width: imageSize, height: imageSize)
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let path = UIBezierPath(
                roundedRect: bounds,
                cornerRadius: prefersSquareMask ? 7 : imageSize / 2
            )
            path.addClip()

            if let backgroundColor {
                backgroundColor.setFill()
                UIRectFill(bounds)
            } else {
                UIColor.clear.setFill()
                UIRectFill(bounds)
            }

            guard let image else {
                return
            }

            let drawRect: CGRect
            if backgroundColor != nil {
                let origin = CGPoint(
                    x: (imageSize - savedIconSize) / 2,
                    y: (imageSize - savedIconSize) / 2
                )
                drawRect = CGRect(origin: origin, size: CGSize(width: savedIconSize, height: savedIconSize))
            } else {
                drawRect = aspectFillRect(for: image.size, in: bounds)
            }

            if let iconTintColor, backgroundColor != nil {
                iconTintColor.setFill()
            }
            image.draw(in: drawRect)
        }
    }

    private static func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return bounds
        }

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - scaledSize.width / 2,
            y: bounds.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }
}

extension ChatViewController {
    internal func invalidateNavigationAvatarItem() {
        navigationAvatarGeneration = UUID()
        navigationAvatarRequestKey = nil
        navigationAvatarBag = DisposeBag()
        navigationAvatarItem = nil
    }

    internal var isTopVisibleChatController: Bool {
        guard isViewLoaded else {
            return false
        }
        guard let navigationController else {
            return false
        }
        return navigationController.topViewController === self
            && navigationController.visibleViewController === self
    }

    internal func currentNavigationAvatarPlaceholderImage() -> UIImage? {
        if conversationType == .saved {
            let palette = AccountColorManager.shared.palette(for: owner)
            return ChatNavigationAvatarItemFactory.savedMessagesImage(
                backgroundColor: palette.tint100,
                iconTintColor: palette.tint900
            )
        }

        let displayName = currentNavigationAvatarDisplayName()
        return ChatNavigationAvatarItemFactory.avatarImage(
            from: UIImageView.getDefaultAvatar(
                for: displayName,
                owner: owner,
                size: ChatNavigationAvatarItemFactory.imageSize
            )
        )
    }

    internal func startNavigationAvatarObservation() {
        guard conversationType != .saved else {
            return
        }

        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm
                    .objects(RosterStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .observe(on: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] _ in
                    guard let self, self.isTopVisibleChatController else {
                        return
                    }
                    self.refreshNavigationAvatarImage()
                })
                .disposed(by: navigationAvatarBag)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    internal func refreshNavigationAvatarImage() {
        guard conversationType != .saved else {
            updateNavigationAvatarImageIfCurrent(currentNavigationAvatarPlaceholderImage())
            return
        }

        let avatarUrl = currentNavigationAvatarURL()
        let displayName = currentNavigationAvatarDisplayName()
        let requestKey = [owner, jid, avatarUrl ?? "", displayName].joined(separator: "|")
        let generation = navigationAvatarGeneration
        navigationAvatarRequestKey = requestKey

        let fallback = currentNavigationAvatarPlaceholderImage()
        updateNavigationAvatarImageIfCurrent(fallback)

        DefaultAvatarManager.shared.getAvatar(
            url: avatarUrl,
            jid: jid,
            owner: owner,
            size: ChatNavigationAvatarItemFactory.imageSize
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard self.navigationAvatarGeneration == generation,
                      self.navigationAvatarRequestKey == requestKey,
                      self.isTopVisibleChatController,
                      !self.inSearchMode.value else {
                    return
                }
                self.updateNavigationAvatarImageIfCurrent(
                    ChatNavigationAvatarItemFactory.avatarImage(from: image) ?? fallback
                )
            }
        }
    }

    private func updateNavigationAvatarImageIfCurrent(_ image: UIImage?) {
        guard !inSearchMode.value else {
            return
        }
        navigationAvatarItem?.image = image?.withRenderingMode(.alwaysOriginal)
    }

    private func currentNavigationAvatarURL() -> String? {
        do {
            let realm = try WRealm.safe()
            let rosterItem = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
            )
            return rosterItem?.avatarMinUrl ?? rosterItem?.avatarMaxUrl ?? rosterItem?.oldschoolAvatarKey
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func currentNavigationAvatarDisplayName() -> String {
        do {
            let realm = try WRealm.safe()
            if conversationType == .group,
               let group = realm.object(
                ofType: GroupChatStorageItem.self,
                forPrimaryKey: GroupChatStorageItem.genPrimary(jid: jid, owner: owner)
               ) {
                return group.name
            }

            if let rosterItem = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
            ) {
                return rosterItem.displayName
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        return jid
    }
}
