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
        func prepareDate(days: Int, callback: @escaping ((String) -> Void )) {
            var dateComponent = DateComponents()
            
            dateComponent.day = -days
            guard let date = Calendar.current.date(byAdding: dateComponent, to: Date()) else { return }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "YYYY-MM-dd"
            let preparedDate = formatter.string(from: date)
            
            callback(preparedDate)
        }
        
        func showFilesToDelete(percent: Int) {
            let viewController = CloudStorageDeleteViewController(percent: percent, owner: self.jid)
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
                        showFilesToDelete(percent: 15)
                    case "25percent":
                        showFilesToDelete(percent: 25)
                    case "50percent":
                        showFilesToDelete(percent: 50)
                    case "100percent":
                        showFilesToDelete(percent: 100)
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
