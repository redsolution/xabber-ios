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

extension CloudStorageViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if datasource[indexPath.section].children[indexPath.row].key == "quota_info" {
            return 110
        }
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        func showConfirmationToDelete(percent: Int) {
            let viewController = FileDeletionConfirmation(percent: percent, owner: self.jid)
            self.navigationController?.pushViewController(viewController, animated: true)
        }
        
        let item = datasource[indexPath.section].children[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        switch item.key {
        case "delete_files":
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "15%", value: "15percent"),
                ActionSheetPresenter.Item(destructive: false, title: "25%", value: "25percent"),
                ActionSheetPresenter.Item(destructive: false, title: "50%", value: "50percent"),
                ActionSheetPresenter.Item(destructive: false, title: "All files", value: "100percent")
            ]
            
            ActionSheetPresenter()
                .present(in: self,
                         title: "Free up space".localizeString(id: "account_delete_files_message", arguments: []),
                         message: "Choose how many files will be deleted to free up space (as a percentage)".localizeString(id: "account_which_files_to_delete", arguments: []),
                         cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                         values: deleteItems,
                         animated: true
                ) { result in
                    
                    switch result {
                    case "15percent":
                        showConfirmationToDelete(percent: 15)
                    case "25percent":
                        showConfirmationToDelete(percent: 25)
                    case "50percent":
                        showConfirmationToDelete(percent: 50)
                    case "100percent":
                        showConfirmationToDelete(percent: 100)
                    default:
                        break
                    }
                }
            return
        case "images":
            let viewController = CloudStorageGalleryViewController()
            viewController.configure(jid: self.jid, .images)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "videos":
            let viewController = CloudStorageGalleryViewController()
            viewController.configure(jid: self.jid, .videos)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "files":
            let viewController = CloudStorageGalleryViewController()
            viewController.configure(jid: self.jid, .files)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "audio":
            let viewController = CloudStorageGalleryViewController()
            viewController.configure(jid: self.jid, .voice)
            navigationController?.pushViewController(viewController, animated: true)
            return
        default:
            break
        }
    }
}
