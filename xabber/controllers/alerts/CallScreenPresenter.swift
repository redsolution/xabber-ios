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
import XMPPFramework
import UIKit

struct CallScreenPresenter {
    let jid: String
    let owner: String
//    let mediaType: CallManager.CallType
    let hideAppTabBar: Bool
    
    public func asyncGetPresenter() -> UIViewController? {
        let presenter = UIApplication.getTopMostViewController()
//        if presenter == nil {
////            sleep(1)
//            return asyncGetPresenter()
//        }
        return presenter
    }
    
    func present(animated: Bool, completion: (()->Void)?) -> CallScreenViewController? {
        let vc = CallScreenViewController()
        
        vc.owner = owner
        vc.jid = jid
        vc.modalPresentationStyle = .fullScreen
        vc.shouldHideAppTabBar = hideAppTabBar
        let presenter = asyncGetPresenter()
        presenter?.present(vc, animated: true, completion: nil)
                
        return vc
    }
}

