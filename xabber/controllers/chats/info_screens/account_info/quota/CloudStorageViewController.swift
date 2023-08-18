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

import UIKit
import TOInsetGroupedTableView
import CocoaLumberjack
import RealmSwift

class CloudStorageViewController: BaseViewController {
    class Datasource {
        enum Kind {
            case text
            case button
        }
        
        var kind: Kind
        var viewController: UIViewController.Type?
        var title: String
        var subtitle: String?
        var key: String?
        
        var children: [Datasource]
        
        init(_ kind: Kind, viewController: UIViewController.Type? = nil, title: String, subtitle: String? = nil, key: String? = nil, children: [Datasource] = []) {
            self.kind = kind
            self.viewController = viewController
            self.title = title
            self.subtitle = subtitle
            self.key = key
            
            self.children = children
        }
    }
    var imagesUsed: String = ""
    var videosUsed: String = ""
    var filesUsed: String = ""
    var audioUsed: String = ""
    
    var datasource: [Datasource] = []
    
    let tableView: UITableView = {
        let tableView = InsetGroupedTableView()
        tableView.register(QuotaInfoCell.self, forCellReuseIdentifier: QuotaInfoCell.cellName)
        
        return tableView
    }()
    
    var isCellTapped: Bool = false
    
    func configure(jid: String) {
        self.jid = jid
        title = "Cloud Storage".localizeString(id: "account_cloud_storage", arguments: [])
        
        getTypeSizesFromRealm()
        
        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.text, title: "Media Gallery".localizeString(id: "account_media_gallery", arguments: []),
                       key: "quota_info")
        ]))
        
        datasource.append(Datasource(.text, title: "".localizeString(id: "images", arguments: []), children: [
            Datasource(.text, title: "Images", subtitle: imagesUsed, key: "images"),
            Datasource(.text, title: "Videos".localizeString(id: "videos", arguments: []),
                       subtitle: videosUsed, key: "videos"),
            Datasource(.text, title: "Files".localizeString(id: "files", arguments: []),
                       subtitle: filesUsed, key: "files"),
            Datasource(.text, title: "Voice".localizeString(id: "voice", arguments: []),
                       subtitle: audioUsed, key: "audio")
        ]))
        
        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.button, title: "Free up space...".localizeString(id: "account_delete_files", arguments: []),
                       key: "delete_files")
        ]))
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    func getTypeSizesFromRealm(callback: (()-> Void)? = nil) {
        do {
            let realm = try WRealm.safe()
            let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: jid)
            
            self.imagesUsed = quotaItem?.imagesUsed ?? "0 KiB"
            self.videosUsed = quotaItem?.videosUsed ?? "0 KiB"
            self.filesUsed = quotaItem?.filesUsed ?? "0 KiB"
            self.audioUsed = quotaItem?.voicesUsed ?? "0 KiB"
            
            callback?()
        } catch {
            DDLogDebug("CloudStorageViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func showVCBeforeDeletingFiles(days: Int, preparedDate: String, freedSpace: String) {
        let alert = UIAlertController(title: "Delete files?".localizeString(id: "account_delete_files_confirmation", arguments: []),
                                      message: "Deleting files older than \(days) days will free up \(freedSpace)"
            .localizeString(id: "account_freeing_space_after_deletion_message", arguments: ["\(days)", "\(freedSpace)"]),
                                      preferredStyle: .alert)
        
        let deleteAction = UIAlertAction(title: "Delete".localizeString(id: "account_delete_files_button", arguments: []),
                                         style: .destructive) { _ in
            if let quotaCell = self.tableView.cellForRow(at: IndexPath.init(row: 0, section: 0)) as? QuotaInfoCell,
               let account = AccountManager.shared.find(for: self.jid),
               let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol {
                uploader.deleteMediaForSelectedPeriod(earlierThanDate: preparedDate) {
                    quotaCell.reloadData() {
                        self.getTypeSizesFromRealm() {
                            self.datasource[1].children.forEach({
                                switch $0.title {
                                case "Images".localizeString(id: "images", arguments: []): $0.subtitle = self.imagesUsed
                                case "Videos".localizeString(id: "videos", arguments: []): $0.subtitle = self.videosUsed
                                case "Files".localizeString(id: "files", arguments: []): $0.subtitle = self.filesUsed
                                case "Voice".localizeString(id: "voice", arguments: []): $0.subtitle = self.audioUsed
                                default: break
                                }
                            })
                            self.tableView.reloadSections([0, 1], with: .fade)
                        }
                    }
                }
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel)
        alert.addAction(deleteAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true)
    }
    
    func showVCBeforeDeletingFiles(percent: Int, freedSpace: String) {
        let alert = UIAlertController(title: "Delete files?".localizeString(id: "account_delete_files_confirmation", arguments: []),
                                      message: "Deleting files that make up \(percent) percent of the total memory will free up \(freedSpace)."
            .localizeString(id: "account_freeing_space_after_deletion_message_by_percent", arguments: ["\(percent)", "\(freedSpace)"]),
                                      preferredStyle: .alert)
        
        let deleteAction = UIAlertAction(title: "Delete".localizeString(id: "account_delete_files_button", arguments: []),
                                         style: .destructive) { _ in
            if let quotaCell = self.tableView.cellForRow(at: IndexPath.init(row: 0, section: 0)) as? QuotaInfoCell,
               let account = AccountManager.shared.find(for: self.jid),
               let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol {
                uploader.deleteMediaForSelectedPercent(percent: percent) {
                    quotaCell.reloadData() {
                        self.getTypeSizesFromRealm() {
                            self.datasource[1].children.forEach({
                                switch $0.title {
                                case "Images".localizeString(id: "images", arguments: []): $0.subtitle = self.imagesUsed
                                case "Videos".localizeString(id: "videos", arguments: []): $0.subtitle = self.videosUsed
                                case "Files".localizeString(id: "files", arguments: []): $0.subtitle = self.filesUsed
                                case "Voice".localizeString(id: "voice", arguments: []): $0.subtitle = self.audioUsed
                                default: break
                                }
                            })
                            self.tableView.reloadSections([0, 1], with: .fade)
                        }
                    }
                }
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel)
        alert.addAction(deleteAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
    }
}
