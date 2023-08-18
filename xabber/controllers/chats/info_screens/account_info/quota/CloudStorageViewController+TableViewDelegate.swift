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
//            uploader.getFreeSpaceAfterDeletion(earlierThanDate: preparedDate) { freedSpace in
//                if freedSpace == nil {
//                    self.showVCBeforeDeletingFiles(days: days, preparedDate: preparedDate, freedSpace: "0 KiB")
//                } else if freedSpace == "New token" {
//                    getFreedSpace(days: days, preparedDate: preparedDate)
//                } else {
//                    self.showVCBeforeDeletingFiles(days: days, preparedDate: preparedDate, freedSpace: freedSpace!)
//                }
//            }
            uploader.getFilesToDelete(earlierThanDate: preparedDate) { viewControllerDelete in
                if viewControllerDelete == nil {
                    return
                } else {
                    self.navigationController?.pushViewController(viewControllerDelete!, animated: true)
                    return
                }
            }
        }
//        func getFreedSpace(days: Int, preparedDate: String) {
//            guard let account = AccountManager.shared.find(for: jid), let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
//            uploader.getFilesToDelete(earlierThanDate: <#T##String#>, successCallback: <#T##((String?) -> Void)##((String?) -> Void)##(String?) -> Void#>)
//        }
        func getFreedSpace(percent: String) {
            guard let account = AccountManager.shared.find(for: jid), let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
            uploader.getFreeSpaceAfterDeletionBySize(percent: percent) { freedSpace in
                if freedSpace == nil {
                    self.showVCBeforeDeletingFiles(percent: Int(percent)!, freedSpace: "0 KiB")
                } else {
                    self.showVCBeforeDeletingFiles(percent: Int(percent)!, freedSpace: freedSpace!)
                }
            }
        }
        
        let item = datasource[indexPath.section].children[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        switch item.key {
        case "delete_files":
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "15%", value: "15percent"),
                ActionSheetPresenter.Item(destructive: false, title: "25%", value: "25percent"),
                ActionSheetPresenter.Item(destructive: false, title: "50%", value: "50percent"),
                ActionSheetPresenter.Item(destructive: false, title: "All files", value: "100percent"),
                ActionSheetPresenter.Item(destructive: false, title: "6 days", value: "6days")
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
                    case "6days":
                        prepareDate(days: 6) { preparedDate in
                            getFreedSpace(days: 6, preparedDate: preparedDate)
                        }
                        return
                    case "15percent":
                        getFreedSpace(percent: "15")
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
