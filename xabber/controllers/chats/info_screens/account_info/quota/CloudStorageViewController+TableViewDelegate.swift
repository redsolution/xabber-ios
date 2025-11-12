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
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        func showConfirmationToDelete(percent: Int) {
            let viewController = FileDeletionConfirmation(percent: percent, owner: self.jid)
            self.navigationController?.pushViewController(viewController, animated: true)
        }
        
        let item = datasource[indexPath.section].children[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        if item.subtitle == "0 КБ" {
            return
        }
        switch item.key {
        case "delete_files":
            if imagesUsed == "0 КБ" && videosUsed == "0 КБ" && audioUsed == "0 КБ" && filesUsed == "0 КБ" {
                return
            }
            let freeQuotaAsPercentage = Int(100 * (quota - usedQuota) / quota)
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Free up 15% of space", value: "15percent", isEnabled: freeQuotaAsPercentage < 15 ? true : false),
                ActionSheetPresenter.Item(destructive: false, title: "Free up 25% of space", value: "25percent", isEnabled: freeQuotaAsPercentage < 25 ? true : false),
                ActionSheetPresenter.Item(destructive: false, title: "Free up 50% of space", value: "50percent", isEnabled: freeQuotaAsPercentage < 50 ? true : false),
                ActionSheetPresenter.Item(destructive: false, title: "Free up 100% of space", value: "100percent", isEnabled: freeQuotaAsPercentage < 100 ? true : false)
            ]
            
            ActionSheetPresenter()
                .present(in: self,
                         title: "Free up space".localizeString(id: "account_delete_files_message", arguments: []),
                         message: "Select how much space you want to free up on your cloud storage:".localizeString(id: "account_which_files_to_delete", arguments: []), // "Choose how many files will be deleted to free up space (as a percentage)"
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
            let viewController = CloudStorageGalleryViewController(selectedType: .image, owner: self.jid)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "videos":
            let viewController = CloudStorageGalleryViewController(selectedType: .video, owner: self.jid)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "audio":
            let viewController = CloudStorageGalleryViewController(selectedType: .audio, owner: self.jid)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "files":
            let viewController = CloudStorageGalleryViewController(selectedType: .file, owner: self.jid)
            navigationController?.pushViewController(viewController, animated: true)
            return
        case "avatars":
            let viewController = CloudStorageGalleryViewController(selectedType: .avatar, owner: self.jid)
            navigationController?.pushViewController(viewController, animated: true)
            break
        default:
            break
        }
    }
}
