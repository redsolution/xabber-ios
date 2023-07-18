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
    class UserBarButton: UIView {

        static let initialAvatarSize: CGSize = CGSize(square: 32)

        internal var jid: String = ""
        internal var owner: String = ""

        internal var bag: DisposeBag = DisposeBag()

        internal var allowBarAnimation: Bool = false
        
        internal var avatar: UIImageView = {
            let image = UIImageView(frame: CGRect(origin: CGPoint(x: 5, y: 5),
                                                  size: UserBarButton.initialAvatarSize))
            image.contentMode = .scaleAspectFill

            let mask = AccountMasksManager.shared.load()
            if mask != "square" {
                image.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask32pt))
            } else {
                image.mask = nil
            }
            image.layer.masksToBounds = true
            
            return image
        }()

        internal let status: RoundedStatusView = {
            let view = RoundedStatusView()

            view.frame = CGRect(origin: CGPoint(x: 26, y: 26), size: CGSize(square: 12))

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
                avatar.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask32pt))
            } else {
                avatar.mask = nil
            }
        }
        
        public final func hideProgressBar() {
            UIView.animate(withDuration: 0.66, delay: 0, options: .curveLinear, animations: {
                self.gradientView.alpha = 0
            })
        }
        
        private final func rotateBar() {
            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
                self.gradientView.alpha = 1
            }) { result in
                if self.allowBarAnimation {
                    self.rotateBar()
                }
            }
        }
        
        public final func stopAnimation() {
            self.allowBarAnimation = false
            
            UIView.animate(withDuration: 0.66, delay: 0, options: .curveLinear, animations: {
                self.gradientView.alpha = 0
            }) { result in
                self.stopGradientAnimation()
            }
        }
        
        public final func startAnimation() {
            self.allowBarAnimation = true
            gradientView.alpha = 0
            startGradientAnimation()
            
            UIView.animate(withDuration: 0.33, delay: 0, options: [], animations: {
                self.gradientView.alpha = 1
            })
        }
        
        private func startGradientAnimation() {
            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
                self.gradientView.transform = self.gradientView.transform.rotated(by: .pi)
            }) { result in
                if self.allowBarAnimation {
                    self.startGradientAnimation()
                }
            }
        }
        
        private func stopGradientAnimation() {
            self.allowBarAnimation = false
            UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
                self.gradientView.transform = self.gradientView.transform.rotated(by: .pi)
            }) { _ in
                self.gradientView.layer.removeAllAnimations()
            }
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
                        DefaultAvatarManager.shared.getAvatar(jid: self.jid, owner: self.owner, size: 32) { image in
                            self.avatar.image = image
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
                self.status.frame = CGRect(origin: CGPoint(x: 25, y: 25), size: CGSize(square: 14))
                break
            default:
                self.status.frame = CGRect(origin: CGPoint(x: 27, y: 27), size: CGSize(square: 10))
                break
            }
            self.status.setStatus(status: status, entity: entity)
            self.status.border(1)
        }

        private final func setupSubviews() {
            addSubview(gradientMask)
            gradientMask.addSubview(gradientView)
            addSubview(avatar)
            addSubview(status)
            
            gradient.frame = gradientView.bounds
            gradientView.layer.addSublayer(gradient)
            
            guard let currentMask = AccountMasksManager.shared.load() else { return }
            gradientMask.mask = UIImageView(image: #imageLiteral(resourceName: String(currentMask + "_outline_32pt")))
        }
        
        public final func configure(owner: String, jid: String) {
            self.owner = owner
            self.jid = jid
            subscribe()
            let palette = AccountColorManager.shared.palette(for: owner)
            self.gradientView.alpha = 0
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupSubviews()
        }

        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            unsubscribe()
        }
    }
}
