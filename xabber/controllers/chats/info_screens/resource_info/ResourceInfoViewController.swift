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
import RealmSwift
import RxRealm
import RxSwift
import CocoaLumberjack

class ContactInfoResourceController: UIViewController {
    
    public var owner: String = ""
    public var jid: String = ""
    public var resource: String = ""
    public var isModal: Bool = false
    
    var rosterItem: RosterStorageItem? = nil
    
    var bag: DisposeBag = DisposeBag()
    
    var deviceType: String = ""
    
    var tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(VCardCell.self, forCellReuseIdentifier: VCardCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        
        return view
    }()
    
    
    
    private class Datasource {
        
        enum Kind {
            case status
            case regular
        }
        
        var category: String
        var value: String
        var kind: Kind
        var status: ResourceStatus
        
        init(category: String, value: String, kind: Kind, status: ResourceStatus = .offline) {
            self.category = category
            self.value = value
            self.kind = kind
            self.status = status
        }
    }
    
    private var datasource: [Datasource] = []
    
    private func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            self.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: "\(self.jid)_\(self.owner)")
        } catch {
            DDLogDebug("cant load contact \(self.jid) info")
        }
    }
    
    private func populateDatasource(from resource: ResourceStorageItem) {
        
        func addItem(category: String, value: String) {
            if value.isNotEmpty {
                self.datasource.append(Datasource(category: category,
                                                  value: value,
                                                  kind: .regular))
            }
        }
        
        deviceType = RosterUtils.shared.convertResourceTypeToString(resource.type)
        
        self.datasource = []
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        self.datasource.append(Datasource(category: "Status".localizeString(id: "groupchat_status", arguments: []),
                                          value: RosterUtils.shared.convertStatus(resource.status),
                                          kind: .status,
                                          status: resource.status))
        addItem(category: "Resource".localizeString(id: "account_resource", arguments: []), value: resource.resource)
        addItem(category: "Client".localizeString(id: "contact_viewer_client", arguments: []), value: resource.client)
        addItem(category: "Priority".localizeString(id: "account_priority", arguments: []), value: "\(resource.priority)")
        addItem(category: "Last updated".localizeString(id: "account_last_updated", arguments: []), value: formatter.string(from: resource.timestamp))
    }
    
    private func configureNavbar() {
        self.title = "Resource details".localizeString(id: "account_resource_details", arguments: [])
        if isModal {
            self.navigationItem.setLeftBarButton(UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close)), animated: true)
        }
    }
    
    @objc
    private final func close(_ sender: UIBarButtonItem) {
        self.dismiss(animated: true, completion: nil)
    }
    
    private func configure() {
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
        self.configureNavbar()
        self.loadDatasource()
    }
    
    private func subscribe() {
        self.bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            if let resource = realm.objects(ResourceStorageItem.self).filter("owner == %@ AND jid == %@ AND resource == %@", owner, jid, resource).first {
                Observable.from(object: resource)
                    .asObservable()
                    .subscribe(onNext: { (item) in
                        self.populateDatasource(from: item)
                        self.tableView.reloadData()
                    })
                    .disposed(by: self.bag)
            }
        } catch {
            DDLogDebug("adefsg")
        }
    }
    
    private func unsubscribe() {
        
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
        self.subscribe()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
}

extension ContactInfoResourceController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return deviceType
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return self.jid
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.row]
        switch item.kind {
        case .status:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
                fatalError("Cant dequeue cell for identifier ContactResourceInfoStatusCell")
            }
            
            cell.configure(
                title: self.rosterItem?.getPrimaryResource()?.displayedStatus ?? "Offline"
                    .localizeString(id: "unavailable", arguments: []),
                status: item.status,
                entity: .contact,
                isTemporary: false
            )
            cell.accessoryType = .none
            
//            cell.configure()
//            cell.updateContent(status: item.status, category: "Status")
            return cell
        case .regular:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: VCardCell.cellName, for: indexPath) as? VCardCell else {
                fatalError("Cant dequeue cell for identifier ContactInfoVcardCell")
            }
//            cell.configure()
//            let last: Bool = indexPath.row == self.datasource.countFromZero
//            cell.updateContent(is: last, for: item.category, with: item.value)
            cell.configure(title: item.category, subtitle: item.value)
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
    }
}

extension ContactInfoResourceController: UITableViewDelegate {
    
}
