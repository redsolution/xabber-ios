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

import UIKit
import MaterialComponents.MDCPalettes

class NavBarController: UINavigationController, UINavigationControllerDelegate {

    internal let topToolbar: UIToolbar = {
        let bar = UIToolbar()
        
        bar.isTranslucent = false
        bar.isHidden = true
        
        return bar
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.delegate = self
        
        self.view.addSubview(self.topToolbar)
        self.topToolbar.frame = CGRect(
            origin: CGPoint(
                x: 0,
                y: self.navigationBar.frame.height
            ),
            size: CGSize(
                width: self.navigationBar.frame.width,
                height: 0
            )
        )
        
        self.cancelButton.frame = CGRect(
            origin: CGPoint(
                x: self.navigationBar.frame.width - 44,
                y: 0//self.navigationBar.frame.height
            ),
            size: CGSize(
                width: 36,
                height: 36
            )
        )
        
        self.indicatorIcon.frame = CGRect(
            origin: CGPoint(
                x: 12,
                y: 0//self.navigationBar.frame.height
            ),
            size: CGSize(
                width: 36,
                height: 36
            )
        )
        self.topToolbar.addSubview(self.additionalPanelStack)
        self.additionalPanelStack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 56, right: 56)
        self.topToolbar.addSubview(self.cancelButton)
        self.topToolbar.addSubview(self.indicatorIcon)
    }
    
    internal let additionalPanelStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        
        return stack
    }()
    
    internal let indicatorIcon: UIButton = {
        let button = UIButton()
        
        return button
    }()
    
    internal let cancelButton: UIButton = {
        let button = UIButton()
        
        button.setImage(UIImage(systemName: "xmark")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .tintColor
        
        return button
    }()
    
    
    func clearAdditionalPanel() {
        self.additionalPanelStack.removeAllArrangedSubviews()
    }
    
    func configureAdditionalPanel(_ block: ((NavBarController, UIStackView) -> Void)) {
        self.clearAdditionalPanel()
        block(self, self.additionalPanelStack)
    }
    
    func configureAdditionalPanel(subviews: [UIView]) {
        subviews.forEach { self.additionalPanelStack.addArrangedSubview($0) }
    }
    
    var panelShowd: Bool = false
    
    func showAdditionalPanel(animated: Bool) {
        func transaction(animated: Bool, block: @escaping (() -> Void)) {
            self.panelShowd = true
            if animated {
                UIView.animate(
                    withDuration: 0.33,
                    delay: 0.0,
                    usingSpringWithDamping: 0.6,
                    initialSpringVelocity: 0.1,
                    animations: block
                )
            } else {
                block()
            }
        }
        self.topToolbar.isHidden = false
        transaction(animated: animated) {
            
            self.topToolbar.frame = CGRect(
                origin: CGPoint(
                    x: 0,
                    y: (self.navigationController?.navigationBar.frame.origin.y ?? 0) + self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: self.navigationBar.frame.width,
                    height: 44
                )
            )
//            self.navigationBar.frame = CGRect(
//                origin: CGPoint(
//                    x: 0,
//                    y: 0
//                ),
//                size: CGSize(
//                    width: self.navigationBar.frame.width,
//                    height: self.navigationBar.frame.height + 44
//                )
//            )
            self.cancelButton.frame = CGRect(
                origin: CGPoint(
                    x: self.navigationBar.frame.width - 44,
                    y: 4
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
            self.indicatorIcon.frame = CGRect(
                origin: CGPoint(
                    x: 12,
                    y: 4
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
        }
    }
    
    func hideAdditionalPanel(animated: Bool) {
        func transaction(animated: Bool, block: @escaping (() -> Void)) {
            self.panelShowd = false
            if animated {
                UIView.animate(
                    withDuration: 0.16,
                    delay: 0.0,
                    usingSpringWithDamping: 0.2,
                    initialSpringVelocity: 0.5,
                    animations: block
                )
            } else {
                block()
            }
        }
        transaction(animated: animated) {
            self.cancelButton.frame = CGRect(
                origin: CGPoint(
                    x: self.navigationBar.frame.width - 44,
                    y: 0//self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
            self.indicatorIcon.frame = CGRect(
                origin: CGPoint(
                    x: 12,
                    y: 0//self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
            self.topToolbar.frame = CGRect(
                origin: CGPoint(
                    x: 0,
                    y: self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: self.navigationBar.frame.width,
                    height: 0
                )
            )
        }
        self.topToolbar.isHidden = true
    }
    
    var isFirstLayout: Bool = true
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isFirstLayout {
            self.topToolbar.frame = CGRect(
                origin: CGPoint(
                    x: 0,
                    y: self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: self.navigationBar.frame.width,
                    height: 0
                )
            )
            self.cancelButton.frame = CGRect(
                origin: CGPoint(
                    x: self.navigationBar.frame.width - 44,
                    y: 0//self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
            self.indicatorIcon.frame = CGRect(
                origin: CGPoint(
                    x: 12,
                    y: 0//self.navigationBar.frame.height
                ),
                size: CGSize(
                    width: 36,
                    height: 36
                )
            )
            isFirstLayout = false
        }
    }
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        if self.panelShowd {
            self.hideAdditionalPanel(animated: false)
        }
    }
}


//class XabberToolbar: UIToolbar {
//    
//}
//
//extension ChatViewController: UIBarPositioningDelegate {
//    func position(for bar: UIBarPositioning) -> UIBarPosition {
//        print(bar.description)
//        return .topAttached
//    }
//}
