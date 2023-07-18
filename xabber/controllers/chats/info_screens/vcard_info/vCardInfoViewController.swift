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
import RxSwift
import RxCocoa
import TOInsetGroupedTableView
import Kingfisher
import CocoaLumberjack

class vCardInfoViewController: SimpleBaseViewController {
    
    class Datasource {
        enum Kind {
            case title
            case text
            case resource
            case vcard
            case button
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var key: String?
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, subtitle: String? = nil, key: String? = nil, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            if subtitle?.isEmpty ?? true {
                self.subtitle = nil
            } else {
                self.subtitle = JidManager.shared.prepareJid(jid: subtitle ?? "")
            }
            self.key = key
            self.childs = childs
        }
    }
    
//    public var owner: String = ""
//    public var jid: String = ""
    
    internal var datasource: [Datasource] = []
    internal var resources: Results<ResourceStorageItem>? = nil
    
    internal var avatar: UIImage? = nil
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(VCardCell.self, forCellReuseIdentifier: VCardCell.cellName)
        view.register(TableHeaderWithAvatarCell.self, forCellReuseIdentifier: TableHeaderWithAvatarCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        
        view.tableHeaderView = UIView()
        
        return view
    }()
        
    override func loadDatasource() {
        super.loadDatasource()
        
        do {
            let realm = try WRealm.safe()
            
            resources = realm
                .objects(ResourceStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid)
                .sorted(byKeyPath: "timestamp", ascending: false)
            
            Observable
                .collection(from: realm.objects(vCardStorageItem.self).filter("jid == %@", jid))
                .subscribe(onNext: { (results) in
                    var newDatasource: [Datasource] = [
                    ]
                    if let item = results.first {
//                        self.title = item.generatedNickname
                        newDatasource.append(
                            Datasource(.title, title: "", childs: [
                                Datasource(.title, title: item.generatedNickname, subtitle: self.jid, key: "title")
                            ])
                        )
                        
                        if !(self.resources?.isEmpty ?? true) {
                            newDatasource.append(Datasource(.resource, title: "Connected devices".localizeString(id: "account_connected_devices", arguments: [])))
                        }
                        
//                        newDatasource.append(Datasource(.resource, title: "Connected devices"))
//                        if !self.datasource.contains(where: { $0.kind == .resource }) {
//                            let devices = Datasource(.resource, title: "Connected devices")
//                            newDatasource.append(devices)
//                        }
//                        UIView.performWithoutAnimation {
//                            self.tableView.reloadData()
//                        }
                        
                        let names = Datasource(.vcard, title: "About".localizeString(id: "about", arguments: []), childs: [
                            Datasource(.vcard, title: "First name".localizeString(id: "vcard_given_name", arguments: []), subtitle: item.given),
                            Datasource(.vcard, title: "Middle name".localizeString(id: "vcard_middle_name", arguments: []), subtitle: item.middle),
                            Datasource(.vcard, title: "Surname".localizeString(id: "vcard_family_name", arguments: []), subtitle: item.family),
                            Datasource(.vcard, title: "Full name".localizeString(id: "vcard_full_name", arguments: []), subtitle: item.fn),
                            ].filter { $0.subtitle != nil })

                        if names.childs.isNotEmpty {
                            newDatasource.append(names)
                        }
                        
                        if item.nickname.isNotEmpty {
                            newDatasource.append(Datasource(.vcard, title: "", childs: [
                                Datasource(.vcard, title: "Nickname".localizeString(id: "vcard_nick_name", arguments: []), subtitle: item.nickname),
                            ]))
                        }

                        if item.birthdayString.isNotEmpty {
                            newDatasource.append(Datasource(.vcard, title: "", childs: [
                                Datasource(.vcard, title: "Birthday".localizeString(id: "vcard_birth_date", arguments: []), subtitle: item.birthdayString),
                            ]))
                        }

                        let job = Datasource(.vcard, title: "Job".localizeString(id: "vcard_job", arguments: []), childs: [
                            Datasource(.vcard, title: "Job title".localizeString(id: "vcard_title", arguments: []), subtitle: item.title),
                            Datasource(.vcard, title: "Role".localizeString(id: "vcard_role", arguments: []), subtitle: item.role),
                            Datasource(.vcard, title: "Company".localizeString(id: "vcard_company", arguments: []), subtitle: item.orgname),
                            Datasource(.vcard, title: "Unit".localizeString(id: "vcard_organization_unit", arguments: []), subtitle: item.orgunit),
                        ].filter { $0.subtitle != nil })

                        if job.childs.isNotEmpty {
                            newDatasource.append(job)
                        }

                        if item.url.isNotEmpty {
                            newDatasource.append(Datasource(.vcard, title: "Website".localizeString(id: "vcard_website", arguments: []), childs: [
                                Datasource(.vcard, title: "URL", subtitle: item.url),
                            ]))
                        }

                        if item.descr.isNotEmpty {
                            newDatasource.append(Datasource(.vcard, title: "Description".localizeString(id: "vcard_decsription", arguments: []), childs: [
                                Datasource(.vcard, title: "Bio".localizeString(id: "vcard_bio", arguments: []), subtitle: item.descr),
                            ]))
                        }

                        let phone = Datasource(.vcard, title: "Phone".localizeString(id: "vcard_telephone", arguments: []), childs: [
                            Datasource(.vcard, title: "Work".localizeString(id: "vcard_type_work", arguments: []), subtitle: item.telWorkVoice),
                            Datasource(.vcard, title: "Home".localizeString(id: "vcard_type_home", arguments: []), subtitle: item.telHomeVoice),
                            Datasource(.vcard, title: "Mobile".localizeString(id: "vcard_type_mobile", arguments: []), subtitle: item.telHomeMsg)
                        ].filter { $0.subtitle != nil })

                        if phone.childs.isNotEmpty {
                            newDatasource.append(phone)
                        }

                        let email = Datasource(.vcard, title: "Email".localizeString(id: "vcard_email", arguments: []), childs: [
                            Datasource(.vcard, title: "Work".localizeString(id: "vcard_type_work", arguments: []), subtitle: item.emailWork),
                            Datasource(.vcard, title: "Personal".localizeString(id: "vcard_type_personal", arguments: []), subtitle: item.emailHome)
                        ].filter { $0.subtitle != nil })

                        if email.childs.isNotEmpty {
                            newDatasource.append(email)
                        }

                        let homeAdr = Datasource(.vcard, title: "Home address".localizeString(id: "vcard_home_address", arguments: []), childs: [
                            Datasource(.vcard, title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []), subtitle: item.adrHomePoBox),
                            Datasource(.vcard, title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []), subtitle: item.adrHomeExtadd),
                            Datasource(.vcard, title: "Street".localizeString(id: "vcard_address_street", arguments: []), subtitle: item.adrHomeStreet),
                            Datasource(.vcard, title: "Locality".localizeString(id: "vcard_address_locality", arguments: []), subtitle: item.adrHomeLocality),
                            Datasource(.vcard, title: "Region".localizeString(id: "vcard_address_region", arguments: []), subtitle: item.adrHomeRegion),
                            Datasource(.vcard, title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []), subtitle: item.adrHomePCode),
                            Datasource(.vcard, title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []), subtitle: item.adrHomeCountry),
                        ].filter { $0.subtitle != nil })

                        if homeAdr.childs.isNotEmpty {
                            newDatasource.append(homeAdr)
                        }

                        let workAdr = Datasource(.vcard, title: "Work address".localizeString(id: "vcard_work_address", arguments: []), childs: [
                            Datasource(.vcard, title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []), subtitle: item.adrWorkPoBox),
                            Datasource(.vcard, title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []), subtitle: item.adrWorkExtadd),
                            Datasource(.vcard, title: "Street".localizeString(id: "vcard_address_street", arguments: []), subtitle: item.adrWorkStreet),
                            Datasource(.vcard, title: "Locality".localizeString(id: "vcard_address_locality", arguments: []), subtitle: item.adrWorkLocality),
                            Datasource(.vcard, title: "Region".localizeString(id: "vcard_address_region", arguments: []), subtitle: item.adrWorkRegion),
                            Datasource(.vcard, title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []), subtitle: item.adrWorkPCode),
                            Datasource(.vcard, title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []), subtitle: item.adrWorkCountry),
                        ].filter { $0.subtitle != nil })

                        if workAdr.childs.isNotEmpty {
                            newDatasource.append(workAdr)
                        }
                        
                        self.datasource = newDatasource
                        DispatchQueue.main.async {
                            self.tableView.reloadData()
                        }
                        self.bag = DisposeBag()
                    }
                })
                .disposed(by: bag)
            
            Observable
                .changeset(from: resources!)
                .subscribe(onNext: { (results) in
                    if results.0.isEmpty {
                        if let index = self.datasource.firstIndex(where: { $0.kind == .resource }) {
                            self.datasource.remove(at: index)
                            UIView.performWithoutAnimation {
                                if #available(iOS 11.0, *) {
                                    self.tableView.performBatchUpdates({
                                        self.tableView.deleteSections(IndexSet([index]), with: .none)
                                    }, completion: nil)
                                } else {
                                    self.tableView.beginUpdates()
                                    self.tableView.deleteSections(IndexSet([index]), with: .none)
                                    self.tableView.endUpdates()
                                }
                            }
                        }
                    } else {
                        var shouldInsertSection: Bool = false
                        let resourceSectionIndex: Int = 1
                        if !self.datasource.contains(where: { $0.kind == .resource }) {
                            self.datasource.insert(Datasource(.resource, title: "Connected devices".localizeString(id: "contact_info_connected_clients_header", arguments: [])), at: resourceSectionIndex)
                            shouldInsertSection = true
                        }
                        guard let changeset = results.1 else {
                            UIView.performWithoutAnimation {
                                self.tableView.reloadData()
                            }
                            return
                        }
                        
                        UIView.performWithoutAnimation {
                            if #available(iOS 11.0, *) {
                                self.tableView.performBatchUpdates({
                                    if shouldInsertSection {
                                        self.tableView.insertSections(IndexSet([resourceSectionIndex]), with: .none)
                                    }
                                    self.tableView
                                        .deleteRows(at: changeset
                                            .deleted
                                            .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                    self.tableView
                                        .insertRows(at: changeset
                                            .inserted
                                            .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                    self.tableView
                                        .reloadRows(at: changeset
                                            .updated
                                            .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                }, completion: nil)
                            } else {
                                self.tableView.beginUpdates()
                                if shouldInsertSection {
                                    self.tableView.insertSections(IndexSet([resourceSectionIndex]), with: .none)
                                }
                                if !self.datasource.contains(where: { $0.kind == .resource }) {
                                    self.datasource.insert(Datasource(.resource, title: "Connected devices".localizeString(id: "contact_info_connected_clients_header", arguments: [])), at: resourceSectionIndex)
                                    self.tableView.insertSections(IndexSet([resourceSectionIndex]), with: .none)
                                }
                                self.tableView
                                    .deleteRows(at: changeset
                                        .deleted
                                        .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                self.tableView
                                    .insertRows(at: changeset
                                        .inserted
                                        .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                self.tableView
                                    .reloadRows(at: changeset
                                        .updated
                                        .compactMap({ return IndexPath(row: $0, section: resourceSectionIndex) }), with: .none)
                                self.tableView.endUpdates()
                            }
                        }
                    }
                }).disposed(by: bag)
                
        } catch {
            
        }
        
    }
    
    override func subscribe() {
        super.subscribe()
//        do {
//            let realm = try WRealm.safe()
//            let avatarItem = realm.object(ofType: AvatarStorageItem.self, forPrimaryKey: [self.jid, self.owner].prp())
//            guard let key = avatarItem?.fileUri else { return }
//            
//            ImageCache.default.retrieveImage(forKey: key, completionHandler: { result in
//                switch result {
//                case .success(let data):
//                    if data.cacheType != .none {
//                        self.avatar = data.image
//                    }
//                    break
//                case .failure(_):
//                    break
//                }
//            })
//        } catch {
//            DDLogDebug("vCardInfoViewController: \(#function). \(error.localizedDescription)")
//        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: -70, bottom: 0, left: 0, right: 0)
    }
    
    override func configure() {
        super.configure()
        self.tableView.dataSource = self
        self.tableView.delegate = self
        
        
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
    }
}

extension vCardInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if datasource[indexPath.section].kind == .resource {
            return 64
        }
        if datasource[indexPath.section].childs[indexPath.row].kind == .title {
            return 196
        }
        return 44
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let title = datasource[section].title
        return title.isEmpty ? nil : title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let subtitle = datasource[section].subtitle
        return (subtitle?.isEmpty ?? true) ? nil : subtitle
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if datasource[indexPath.section].kind == .resource {
            guard let resource = self.resources?[indexPath.row] else { return }
            let vc = ContactInfoResourceController()
            vc.jid = self.jid
            vc.owner = self.owner
            vc.resource = resource.resource
            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
            navigationController?.navigationBar.shadowImage = nil
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}

extension vCardInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if datasource[section].kind == .resource {
            return resources?.count ?? 0
        }
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if datasource[indexPath.section].kind == .resource {
            guard let resource = self.resources?[indexPath.row],
                  let cell = tableView.dequeueReusableCell(withIdentifier: ResourceInfoCell.cellName, for: indexPath) as? ResourceInfoCell else { fatalError() }
            cell.configure(title: resource.displayedStatus,
                           subtitle: resource.resource,
                           status: resource.status,
                           entity: resource.entity)
            return cell
        }
        let item = datasource[indexPath.section].childs[indexPath.row]
        if item.kind == .title {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TableHeaderWithAvatarCell.cellName, for: indexPath) as? TableHeaderWithAvatarCell else {
                fatalError()
            }
            
            cell.configure(avatar: self.avatar, owner: self.owner, jid: self.jid, displayName: item.title)
            cell.setMask()
            
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: VCardCell.cellName, for: indexPath) as? VCardCell else {
            fatalError()
        }
        
        cell.configure(title: item.title, subtitle: item.subtitle)
        
        return cell
    }
    
    
}
