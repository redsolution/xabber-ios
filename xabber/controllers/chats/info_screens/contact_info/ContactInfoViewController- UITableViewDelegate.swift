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
import XMPPFramework

extension ContactInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if datasource[indexPath.section].childs[indexPath.row].key == "circles" {
            return tableView.estimatedRowHeight
        }
        switch datasource[indexPath.section].childs[indexPath.row].kind {
        case .session: return tableView.estimatedRowHeight
        default: return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = datasource[indexPath.section].childs[indexPath.row]
        if let key = item.key {
            switch key {
            case "jid_field":
                let shareVC = UIActivityViewController(activityItems: [jid],
                                                       applicationActivities: [])
                
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if let popoverController = shareVC.popoverPresentationController {
                        popoverController.sourceView = self.view
                        popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                        popoverController.permittedArrowDirections = []
                    }
                }
                self.present(shareVC, animated: true, completion: nil)
            case "open_chat_button":
                openChat()
            case "notify_chat_button":
                onChangeNotifications()
            case "block_chat_button":
                onBlock()
            case "delete_chat_button":
                onDelete()
            case "qr_code":
                onQRCode()
            case "circles":
                editCircles()
            case "fingerprints":
                showFingerprints()
            case "start_encrypted_chat":
                onStartEncryptedChat()
            default: break
            }
        }
    }
}
