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

protocol ChatToolsButtonDelegate {
    func onScroll()
    func onStop()
}

extension ChatToolsButtonDelegate {
    func onScroll() {
        
    }
    
    func onStop() {
        
    }
}

extension ChatViewController: ChatToolsButtonDelegate {
    
    func onScroll() {
        self.messagesCollectionView.scrollToTop(animated: true)
        self.toolsButtonStateObserver.accept(.hidden)
    }
    
    func onStop() {
        self.stopRecord()
    }
    
    class ToolsButton: UIButton {
        
        enum ToolsState {
            case hidden
            case scrollToBottom
            case unlocked
            case locked
            case pinned
            case deleted
        }
        
        internal var badgeView: UIView = {
            let view = UIView(frame: CGRect(x: 9,
                                            y: -12,
                                            width: 18,
                                            height: 18))
            view.layer.cornerRadius = 9
            
            view.clipsToBounds = true
            view.backgroundColor = MDCPalette.green.tint900
            
            return view
        }()
        
        internal var countLabel: UILabel = {
            let label = UILabel()
            
            label.text = nil
            label.font = UIFont.preferredFont(forTextStyle: .caption2)
            label.textColor = .white
            label.textAlignment = .center
            
            return label
        }()
        
        open var delegate: ChatToolsButtonDelegate? = nil
        
        internal let upIcon: UIImageView = {
            let image = UIImageView(frame: CGRect(x: 6, y: 42, width: 24, height: 24))
            
            image.image = #imageLiteral(resourceName: "chevron-down").withRenderingMode(.alwaysTemplate)
            image.tintColor = MDCPalette.grey.tint600
            image.isHidden = true
            image.transform = CGAffineTransform(scaleX: 1.0, y: -1.0)
            
            return image
        }()
        
        open var currentState: ToolsState = .hidden
        
        internal func setup() {
            backgroundColor = MDCPalette.grey.tint50
            layer.cornerRadius = frame.width / 2
            
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowRadius = 1
            layer.shadowOffset = CGSize(width: 0, height: 0)
            layer.shadowOpacity = 0.21
            
            addTarget(self, action: #selector(onTouchUp), for: .touchUpInside)
            addSubview(upIcon)
            bringSubviewToFront(upIcon)
            addSubview(badgeView)
            bringSubviewToFront(badgeView)
            badgeView.isHidden = true
            countLabel.frame = badgeView.bounds
            badgeView.addSubview(countLabel)
            isUserInteractionEnabled = true
            
//            isMultipleTouchEnabled = true
        }
        
        open func setUnreadBadge(_ count: Int) {
            if count > 0 {
                if badgeView.alpha == 0.0 {
                    UIView.performWithoutAnimation {
                        self.badgeView.alpha = 1.0
                    }
                }
                let badgeString = "\(count)"
                UIView.performWithoutAnimation {
                    self.badgeView.frame = CGRect(x: 12 - (3 * max(1, badgeString.count)),
                                                  y: -12,
                                                  width: 12 + (6 * max(1, badgeString.count)),
                                                  height: 18)
                    self.countLabel.frame = badgeView.bounds
                    self.countLabel.text = badgeString
                }
                
            } else {
                if badgeView.alpha == 1.0 {
                    UIView.performWithoutAnimation {
                        self.badgeView.alpha = 0.0
                    }
                }
            }
        }
        
        open func changeState(_ state: ToolsState) {
            if currentState == state,
                state == .scrollToBottom && currentState != .hidden {
                return
            }
//            if currentState == state { return }
            
            func animate(_ block: @escaping (() -> Void)) {
//                UIView.performWithoutAnimation(block)
                UIView.animate(withDuration: 0.1,
                               delay: 0.0,
                               options: [.showHideTransitionViews, .curveEaseIn],
                               animations: block,
                               completion: nil)
            }
            
            currentState = state
//            self.layer.shadowColor =
            switch state {
            case .hidden:
                animate {
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 0), size: CGSize(square: 36))
                    self.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 42, left: 6, right: 6)
                    self.upIcon.isHidden = true
                    self.badgeView.isHidden = true
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                    self.isHidden = true
                }
                
            case .scrollToBottom:
                animate {
                    self.isHidden = false
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 0), size: CGSize(square: 36))
                    self.setImage(#imageLiteral(resourceName: "chevron-down").withRenderingMode(.alwaysTemplate), for: .normal)
                    self.tintColor = MDCPalette.grey.tint600
                    self.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
                    self.upIcon.isHidden = true
                    self.badgeView.isHidden = false
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                }
            case .unlocked:
                animate {
                    self.isHidden = false
//                    let origin = CGPoint(x: self.frame.origin.x, y: self.frame.origin.y - 18)
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 0), size: CGSize(width: 36, height: 72))
                    self.setImage(#imageLiteral(resourceName: "lock-open").withRenderingMode(.alwaysTemplate), for: .normal)
                    self.tintColor = MDCPalette.grey.tint600
                    self.imageEdgeInsets = UIEdgeInsets(top: 10, bottom: 38, left: 6, right: 6)
                    self.upIcon.isHidden = false
                    self.badgeView.isHidden = true
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                }
            case .pinned:
                animate {
                    self.isHidden = false
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 36), size: CGSize(square: 36))
                    self.setImage(#imageLiteral(resourceName: "stop").withRenderingMode(.alwaysTemplate), for: .normal)
                    self.tintColor = MDCPalette.red.tint600
                    self.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
                    self.upIcon.isHidden = true
                    self.badgeView.isHidden = true
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                }
            case .locked:
                animate {
                    self.isHidden = false
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 36), size: CGSize(square: 36))
                    self.setImage(#imageLiteral(resourceName: "lock").withRenderingMode(.alwaysTemplate), for: .normal)
                    self.tintColor = MDCPalette.grey.tint600
                    self.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
                    self.upIcon.isHidden = true
                    self.badgeView.isHidden = true
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                }
            case .deleted:
                animate {
                    self.isHidden = false
                    self.frame = CGRect(origin: CGPoint(x: 5, y: 36), size: CGSize(square: 36))
                    self.setImage(#imageLiteral(resourceName: "trash").withRenderingMode(.alwaysTemplate), for: .normal)
                    self.tintColor = .systemRed
                    self.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
                    self.upIcon.isHidden = true
                    self.badgeView.isHidden = true
                    let path = CGMutablePath()
                    path.addRoundedRect(in: self.bounds, cornerWidth: self.frame.width / 2, cornerHeight: self.frame.width / 2)
                    self.layer.shadowPath = path
                }
            }
//            let path = CGMutablePath()
//            path.addRoundedRect(in: bounds, cornerWidth: frame.width / 2, cornerHeight: frame.width / 2)
//            UIView.animate(withDuration: 0.1) {
//                self.layer.shadowPath = path
//            }
        }
        
        @objc
        internal func onTouchUp(_ sender: UIButton) {
            print(#function)
            switch currentState {
            case .scrollToBottom: delegate?.onScroll()
            case .pinned: delegate?.onStop()
            default: break
            }
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
    }
}
