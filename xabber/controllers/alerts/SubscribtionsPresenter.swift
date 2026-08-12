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

struct SubscribtionsPresenter {
    @discardableResult
    func present(
        animated: Bool,
        owner: String? = nil,
        parent: UIViewController? = nil,
        modalPresentationStyle: UIModalPresentationStyle = .formSheet
    ) -> Bool {
        if ApplicationStateManager.shared.isSubscribtionsShowed {
            return false
        }
        if Self.isPremiumAlreadyPresented() {
            return false
        }
        let account = owner ?? AccountManager.shared.users.first?.jid ?? ""
        guard account.isNotEmpty else {
            return false
        }
        ApplicationStateManager.shared.isSubscribtionsShowed = true
        let vc = PremiumSubscribtionViewController()
        vc.jid = account
        vc.owner = account
        vc.onDismiss = {
            ApplicationStateManager.shared.isSubscribtionsShowed = false
        }
        let didPresent = showModal(
            vc,
            parent: parent,
            modalPresentationStyle: modalPresentationStyle
        )
        if !didPresent {
            ApplicationStateManager.shared.isSubscribtionsShowed = false
        }
        return didPresent
    }

    private static func isPremiumAlreadyPresented() -> Bool {
        guard let top = UIApplication.getTopMostViewController() else {
            return false
        }
        if top is PremiumSubscribtionViewController {
            return true
        }
        if let navigation = top as? UINavigationController,
           navigation.viewControllers.contains(where: { $0 is PremiumSubscribtionViewController }) {
            return true
        }
        if let navigation = top.navigationController,
           navigation.viewControllers.contains(where: { $0 is PremiumSubscribtionViewController }) {
            return true
        }
        return false
    }
}
