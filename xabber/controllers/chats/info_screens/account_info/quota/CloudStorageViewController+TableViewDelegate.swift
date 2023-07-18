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
        func getFreedSpace(days: Int, preparedDate: String) {
            guard let account = AccountManager.shared.find(for: jid),
                  let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
            uploader.getFreeSpaceAfterDeletion(earlierThanDate: preparedDate) { freedSpace in
                if freedSpace == nil {
                    self.showVCBeforeDeletingFiles(days: days, preparedDate: preparedDate, freedSpace: "0 KiB")
                } else {
                    self.showVCBeforeDeletingFiles(days: days, preparedDate: preparedDate, freedSpace: freedSpace!)
                }
            }
        }
        
        let item = datasource[indexPath.section].children[indexPath.row]
        if item.key == "delete_files" {
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Older than 15 days".localizeString(id: "delete_files_older_than_15_days", arguments: []), value: "15days"),
                ActionSheetPresenter.Item(destructive: false, title: "Older than 30 days".localizeString(id: "delete_files_older_than_30_days", arguments: []), value: "30days"),
                ActionSheetPresenter.Item(destructive: false, title: "Older than 60 days".localizeString(id: "delete_files_older_than_60_days", arguments: []), value: "60days")
            ]
            
            ActionSheetPresenter()
                .present(in: self,
                         title: "Delete files".localizeString(id: "account_delete_files_message", arguments: []),
                         message: "Choose which files will be deleted".localizeString(id: "account_which_files_to_delete", arguments: []),
                         cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                         values: deleteItems,
                         animated: true
                ) { result in
                    
                    switch result {
                    case "15days":
                        prepareDate(days: 15) { preparedDate in
                            getFreedSpace(days: 15, preparedDate: preparedDate)
                        }
                    case "30days":
                        prepareDate(days: 30) { preparedDate in
                            getFreedSpace(days: 30, preparedDate: preparedDate)
                        }
                    case "60days":
                        prepareDate(days: 60) { preparedDate in
                            getFreedSpace(days: 60, preparedDate: preparedDate)
                        }
                    default:
                        break
                    }
                }
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
