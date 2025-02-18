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

extension ShareDialogController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        
        if item.conversationType == .saved {
            self.dismiss(animated: true) {
                AccountManager.shared.find(for: item.owner)?.action({ user, stream in
                    _ = user.messages.sendSimpleMessage("", to: item.jid, forwarded: self.forwardIds, conversationType: item.conversationType)
                })
            }
        } else {
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
