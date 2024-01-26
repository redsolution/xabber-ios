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
import RxSwift
import RxRealm
import RxCocoa

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
    
    var isDeletingFilesEnabled: Bool = false
    var imagesUsed: String = "0 KiB"
    var videosUsed: String = "0 KiB"
    var filesUsed: String = "0 KiB"
    var audioUsed: String = "0 KiB"
    var avatarUsed: String = "0 KiB"
    var usedQuota: Int = 0
    var quota: Int = 0
    
    var bag: DisposeBag = DisposeBag()
    
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
        
//        getTypeSizesFromRealm()
        
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
            Datasource(.text, title: "Avatars".localizeString(id: "avatars", arguments: []),subtitle: avatarUsed,  key: "avatars")
        ]))
        
        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.button, title: "Free up space".localizeString(id: "account_delete_files", arguments: []),
                       key: "delete_files")
        ]))
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    func subscribe() {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(AccountQuotaStorageItem.self).filter("jid == %@", self.jid)
            if let item = collection.first {
                self.imagesUsed = item.imagesUsed 
                self.videosUsed = item.videosUsed
                self.filesUsed = item.filesUsed
                self.audioUsed = item.voicesUsed
                self.avatarUsed = item.avatarUsed
                self.usedQuota = item.totalBytes
                self.quota = item.quotaBytes
            }
            Observable.collection(from: collection).debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance).subscribe { results in
                if let item = results.first {
                    self.imagesUsed = item.imagesUsed
                    self.videosUsed = item.videosUsed
                    self.filesUsed = item.filesUsed
                    self.audioUsed = item.voicesUsed
                    self.avatarUsed = item.avatarUsed
                    self.usedQuota = item.totalBytes
                    self.quota = item.quotaBytes
                }
                self.datasource[1].children.forEach {
                    switch $0.key {
                    case "images":
                        $0.subtitle = self.imagesUsed
                    case "videos":
                        $0.subtitle = self.videosUsed
                    case "files":
                        $0.subtitle = self.filesUsed
                    case "voice":
                        $0.subtitle = self.audioUsed
                    default:
                        break
                    }
                }
                self.datasource[2].children[0].subtitle = self.avatarUsed
                self.tableView.reloadData()
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

        } catch {
            DDLogDebug("CloudStorageViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.navigationController?.navigationBar.prefersLargeTitles = false
        subscribe()
        AccountManager.shared.find(for: self.jid)?.action({ user, _ in
            user.cloudStorage.getStats()
        })
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        tableView.reloadData()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
}
