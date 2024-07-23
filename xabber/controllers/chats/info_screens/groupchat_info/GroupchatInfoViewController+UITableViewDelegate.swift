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

extension GroupchatInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if datasource[indexPath.section].kind == .contact {
            return 64
        }
        if datasource[indexPath.section].childs[indexPath.row].key == "gc_circles" {
            return tableView.estimatedRowHeight
        }
        switch datasource[indexPath.section].childs[indexPath.row].kind {
        case .info:
            if ProcessInfo().operatingSystemVersion.majorVersion == 10 {
                return 44
            } else {
                return tableView.estimatedRowHeight
            }
        default: return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if datasource[indexPath.section].kind == .contact {
            guard let item = contacts?[indexPath.row] else { return }
            let vc = GroupchatContactInfoViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.userId = item.userId
            shouldResetNavbar = false
            
            navigationController?.pushViewController(vc, animated: true)
        } else {
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
                case "gc_settings":
                    showSettings()
                case "gc_default_restrictions":
                    showDefaultRestrictions()
                case "gc_invitations":
                    showInvitations()
                case "gc_blocked":
                    showBlocked()
                case "gc_set_status":
                    if self.canChangeStatus {
                        setStatus()
                    }
                case "gc_circles":
                    editCircles()
                case "gc_qr_code":
                    showQRCode()
                case "gc_clear_history":
                    clearHistory()
                case "gc_export_history":
                    exportHistory()
                case "gc_search":
                    openSearch()
                case "invite":
                    onInvite()
                case "leave":
                    onLeave()
                    
                case "images":
                    let vc = ChatFilesViewController()
                    vc.owner = self.owner
                    vc.jid = self.jid
                    vc.selectedType = .images
                    navigationController?.pushViewController(vc, animated: true)
                    
                case "videos":
                    let vc = ChatFilesViewController()
                    vc.owner = self.owner
                    vc.jid = self.jid
                    vc.selectedType = .videos
                    navigationController?.pushViewController(vc, animated: true)
                    
                case "voice":
                    let vc = ChatFilesViewController()
                    vc.owner = self.owner
                    vc.jid = self.jid
                    vc.selectedType = .voice
                    navigationController?.pushViewController(vc, animated: true)
                    
                case "files":
                    let vc = ChatFilesViewController()
                    vc.owner = self.owner
                    vc.jid = self.jid
                    vc.selectedType = .files
                    navigationController?.pushViewController(vc, animated: true)
                default: break
                }
            }
        }
    }
}
