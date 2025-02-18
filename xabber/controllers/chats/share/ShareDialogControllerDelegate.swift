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
            
            self.dismiss(animated: true) {
                self.delegate?
                    .open(
                        owner: item.owner,
                        jid: item.jid,
                        conversationType: item.conversationType,
                        forwarded: self.forwardIds
                    )
            }
        }
    }
}
