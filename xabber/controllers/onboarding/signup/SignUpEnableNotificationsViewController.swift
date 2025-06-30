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

class SignUpEnableNotificationsViewController: SignUpBaseViewController {
        
    override func configure() {
        self.navigationItem.hidesBackButton = true
        
        view.backgroundColor = .systemBackground
        if CommonConfigManager.shared.config.use_large_title {
            navigationItem.largeTitleDisplayMode = .automatic
        } else {
            navigationItem.largeTitleDisplayMode = .never
        }
        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        
        textField.isHidden = true
        button.isHidden = true
        navigationController?.isNavigationBarHidden = false
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Notifications".localizeString(id: "contact_bar_notifications", arguments: [])
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) {
            (granted, error) in
            if granted {
                DispatchQueue.main.async {
                    (UIApplication.shared.delegate as? AppDelegate)?.getNotificationSettings()
//                    let vc = UISplitViewController(style: .tripleColumn)
//                    vc.navigationItem.largeTitleDisplayMode = .always
//                    vc.navigationController?.navigationBar.prefersLargeTitles = true
//                    vc.restorationIdentifier = "MainSplitViewController"
//                    vc.restoresFocusAfterTransition = true
//                    let chatsVc = LastChatsViewController()
//                    let primaryVc = LeftMenuViewController()
//                    let emptyChatVc = EmptyChatViewController()
//                    primaryVc.chatsVc = chatsVc
//                    chatsVc.splitDelegate = emptyChatVc
//                    chatsVc.navigationController?.navigationBar.prefersLargeTitles = true
//                    vc.minimumPrimaryColumnWidth = 320
//                    vc.minimumSupplementaryColumnWidth = 320
//                    vc.displayModeButtonVisibility = .always
//                    vc.preferredDisplayMode = .oneBesideSecondary//.oneBesideSecondary//.allVisible
//                    vc.preferredSplitBehavior = .displace//.tile
//                    vc.primaryBackgroundStyle = .sidebar
//                    
//                    vc.delegate = (UIApplication.shared.delegate as! AppDelegate)
//                    vc.viewControllers = [
//                        primaryVc,
//                        chatsVc,
//                        UINavigationController(rootViewController: emptyChatVc)
//                    ]
//                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = vc
//                    (UIApplication.shared.delegate as! AppDelegate).splitController = vc
                    
                    (UIApplication.shared.delegate as? AppDelegate)?.setupRootViewController()
                }
            } else {
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: " ", message: "You can enable notifications later in settings".localizeString(id: "title_register_enable_notifications", arguments: []), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Continue".localizeString(id: "title_register_continue", arguments: []), style: .cancel, handler: { _ in
                        
                        (UIApplication.shared.delegate as? AppDelegate)?.setupRootViewController()
//                        let vc = UISplitViewController(style: .tripleColumn)
//                        vc.navigationItem.largeTitleDisplayMode = .always
//                        vc.navigationController?.navigationBar.prefersLargeTitles = true
//                        vc.restorationIdentifier = "MainSplitViewController"
//                        vc.restoresFocusAfterTransition = true
//                        let chatsVc = LastChatsViewController()
//                        let primaryVc = LeftMenuViewController()
//                        let emptyChatVc = EmptyChatViewController()
//                        primaryVc.chatsVc = chatsVc
//                        chatsVc.splitDelegate = emptyChatVc
//                        chatsVc.navigationController?.navigationBar.prefersLargeTitles = true
//                        vc.minimumPrimaryColumnWidth = 320
//                        vc.minimumSupplementaryColumnWidth = 320
//                        vc.displayModeButtonVisibility = .always
//                        vc.preferredDisplayMode = .oneBesideSecondary//.oneBesideSecondary//.allVisible
//                        vc.preferredSplitBehavior = .displace//.tile
//                        vc.primaryBackgroundStyle = .sidebar
//                        
//                        vc.delegate = (UIApplication.shared.delegate as! AppDelegate)
//                        vc.viewControllers = [
//                            primaryVc,
//                            chatsVc,
//                            UINavigationController(rootViewController: emptyChatVc)
//                        ]
//                        (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = vc
//                        (UIApplication.shared.delegate as! AppDelegate).splitController = vc
                        
                        
//                            let viewController: UIViewController = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "tabBarControllerRID") as UIViewController
//                            (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = viewController
                    }))
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        if let popoverController = alert.popoverPresentationController {
                            popoverController.sourceView = self.view
                            popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                            popoverController.permittedArrowDirections = []
                        }
                    }
                    self.present(alert, animated:  true, completion: nil)
                }
            }
        }
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Last thing! Enable notifications so you never miss a message!".localizeString(id: "title_registration_last_thing", arguments: [])
    }
}
