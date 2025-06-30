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

class BaseViewController: UIViewController {
        
    
    open var owner: String = ""
    open var jid: String = ""
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabBarController?.tabBar.isHidden = true
        self.tabBarController?.tabBar.layoutIfNeeded()
        self.navigationItem.backButtonDisplayMode = .minimal
        
        
        observer()
//        getAppTabBar()?.hide()
    }
    
    public func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
    }
    
    @objc
    func languageChanged() {
        print("Notification received")
    }
//        
//    override func viewWillLayoutSubviews() {
//        super.viewWillLayoutSubviews()
//        self.shouldChangeFrame()
//    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.shouldChangeFrame()
    }
    
    public func shouldChangeFrame() {
        
    }
    
    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }
    
    deinit {
        removeNotificationObserer()
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.tabBarController?.tabBar.isHidden = true
        self.tabBarController?.tabBar.layoutIfNeeded()
//        getAppTabBar()?.hide()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
//        if isBeingDismissed {
//            if self == (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc {
//                (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = nil
//            }
//        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        getAppTabBar()?.hide()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
                
        
//        self.tabBarController?.tabBar.isHidden = false
//        self.tabBarController?.tabBar.layoutIfNeeded()
    }
    
    @objc
    func reloadDatasource() {
        
    }
    
}

extension BaseViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if self == (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc {
            (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = nil
        }
    }
}


