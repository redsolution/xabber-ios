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
import Punycode

extension ChatViewController: MessageLabelDelegate {
    
    func didSelectAddress(_ addressComponents: [String : String]) {
        
    }
    
    func didSelectDate(_ date: Date) {
        if let url = URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:]) { (_) in }
        }
    }
    
    func didSelectPhoneNumber(_ phoneNumber: String) {
        if let url = URL(string: "tel://\(phoneNumber)"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:]) { (_) in }
        }
    }
    
    func didSelectURL(_ url: URL) {
        if UIApplication.shared.canOpenURL(url) {
            let decodedUrl: String = url.absoluteString
            YesNoPresenter().present(
                in: self,
                title: "Open this link?",
                message: decodedUrl,
                yesText: "Open",
                noText: "Cancel",
                animated: true
            ) { (value) in
                if value {
                    UIApplication.shared.open(url, options: [:]) { (_) in }
                }
            }
        }
    }
}
