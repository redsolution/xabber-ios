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

extension ShareDialogController: ShareDialogControllerDelegate {
    func onOpen(_ jid: String) {
        if let item = datasource.first(where: { $0.jid == jid }) {
            
            self.dismiss(animated: false) {
                self.delegate?
                    .open(
                        owner: self.owner,
                        jid: item.jid,
                        forwarded: self.forwardIds
                    )
            }
            
//            let vc = ChatViewController()
//            vc.jid = item.jid
//            vc.owner = owner
//            vc.forwardAuthor = forwardedAuthor
//            var vcs = self.navigationController?.viewControllers ?? []
//            if let index = vcs.firstIndex(of: self) {
//                vcs.remove(at: index)
//            }
//            vcs.append(vc)
//            self.navigationController?.setViewControllers(vcs, animated: true)
//            vc.attachedMessagesIds.accept(forwardIds)
//            print(self.presentingViewController?.restorationIdentifier)
//            self.presentingViewController?.navigationController?.pushViewController(vc, animated: true)
//            self.dismiss(animated: true, completion: nil)
//            forwardIds.forEach {vc.forwardedIds.value.insert($0)}
        }
    }
}
