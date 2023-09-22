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
import RxCocoa
import CocoaLumberjack
import TOInsetGroupedTableView

class ContactInfoViewController: BaseViewController {
    
    class Datasource {
        enum Kind {
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
                self.subtitle = subtitle
            }
            self.key = key
            self.childs = childs
        }
    }
    
//    open var owner: String = ""
//    open var jid: String = ""
    
//    var headerHeightMax: CGFloat = 246//256
//    var headerHeightMin: CGFloat = 150//156
    
    var headerHeightMax: CGFloat = 282//264
    var headerHeightMin: CGFloat = 180//150
    
    public var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
                
        return view
    }()
    
    internal let footerView: InfoScreenFooterView = {
        let view = InfoScreenFooterView(frame: .zero)
        view.isGroupChat = false
        
        return view
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(UITableViewCell.self, forCellReuseIdentifier: "TextCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(VCardCell.self, forCellReuseIdentifier: VCardCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        view.register(EditCirclesCell.self, forCellReuseIdentifier: EditCirclesCell.cellName)
        
        return view
    }()
    
    internal let editButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: #imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate), style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal let showQRCodeButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: #imageLiteral(resourceName: "qrcode").withRenderingMode(.alwaysTemplate), style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var headerConstraintSet: NSLayoutConstraintSet? = nil
    
    internal var datasource: [Datasource] = []
    
    internal var isBlocked: Bool = false
    internal var isMuted: Bool = false
    
    internal var isDeleted: Bool = false
    
    internal var nickname: String = ""
    
    internal var circles: [String] = []
    
    internal func subscribe() {
        datasource = []
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
                        
            circles = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?.groups.toArray() ?? []
            circles = Array(Set(circles)).sorted()
            
            Observable
                .collection(from: realm
                    .objects(RosterStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, jid))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.nickname = item.displayName
                        if item.subscribtion == .undefined {
                            self.isDeleted = true
                        }
                        if item.groups.toArray().sorted() != self.circles.sorted() {
                            self.circles = item.groups.toArray().sorted()
                            if let circleSection = self.datasource.firstIndex(where: { $0.childs.first(where: { $0.key == "circles" }) != nil }),
                               let circleRow = self.datasource[circleSection].childs.firstIndex(where: { $0.key == "circles" }) {
                                self.tableView.reloadRows(at: [IndexPath(row: circleRow, section: circleSection)], with: .none)
                            }
                        }
                    } else {
                        self.nickname = self.jid
                        self.isDeleted = true
                    }
                    
                    
                    self.headerView.configure(
                        jid: self.jid,
                        owner: self.owner,
                        userId: nil,
                        title: self.nickname,
                        subtitle: self.jid,
                        thirdLine: nil,
                        titleColor: AccountColorManager.shared.primaryColor(for: self.owner)
                    )
                }).disposed(by: bag)
                        
            Observable
                .collection(from: realm.objects(vCardStorageItem.self).filter("jid == %@", jid))
                .subscribe(onNext: { (results) in
                    var newDatasource: [Datasource] = []
                    if let item = results.first {
                        
                        var vcardSection: [Datasource] = []
                        
                        if item.given.isNotEmpty {
                            vcardSection.append(Datasource(.vcard, title: "First name".localizeString(id: "vcard_given_name", arguments: []), subtitle: item.given))
                        }
                        if item.family.isNotEmpty {
                            vcardSection.append(Datasource(.vcard, title: "Surname".localizeString(id: "vcard_family_name", arguments: []), subtitle: item.family))
                        }
                        if item.birthdayString.isNotEmpty {
                            vcardSection.append(Datasource(.vcard, title: "Birthday".localizeString(id: "vcard_birth_date", arguments: []), subtitle: item.birthdayString))
                        }
                        
                        if vcardSection.isNotEmpty {
                            newDatasource.append(Datasource(.vcard, title: "About".localizeString(id: "about", arguments: []), subtitle: "View full vCard", key: "about_section", childs: vcardSection))
                        } else {
//                            newDatasource.append(Datasource(.vcard, title: "About", subtitle: "View full vCard", key: "about_section", childs: []))
                        }
                    }
                    
                    newDatasource.append(Datasource(.text, title: "", childs: [
                        Datasource(.button, title: "Circles".localizeString(id: "contact_circle", arguments: []), key: "circles")
                    ]))
                    
                    if self.conversationType == .omemo {
                        do {
                            let realm = try WRealm.safe()
                            let collectionOwner = realm
                                .objects(SignalDeviceStorageItem.self)
                                .filter("jid == %@ AND owner == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue).count
                            let collectionJid = realm
                                .objects(SignalDeviceStorageItem.self)
                                .filter("jid == %@ AND owner == %@ AND state_ != %@", self.jid, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue).count
                            var subtitle = ""
                            if collectionOwner > 0 {
                                subtitle = "⚠️"
                            } else if collectionJid > 0 {
                                subtitle = "⚠️"
                            }
                            newDatasource.append(Datasource(.text, title: "", childs: [
                                Datasource(.button, title: "Identity verification".localizeString(id: "contact_fingerprints", arguments: []), subtitle: subtitle, key: "fingerprints")
                            ]))
                        } catch {
                            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
                        }
                        
                    }
                    
                    self.datasource = newDatasource
                    self.tableView.reloadData()
                })
                .disposed(by: bag)
            
            
            Observable.collection(from: realm.objects(BlockStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.isBlocked = !results.isEmpty
                    if results.isEmpty {
                        DispatchQueue.main.async {
                            self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                                                   title: "Block".localizeString(id: "contact_bar_block", arguments: []),
                                                                   style: .danger)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                                                   title: "Unblock".localizeString(id: "contact_bar_unblock", arguments: []),
                                                                   style: .active)
                        }
                    }
                    DispatchQueue.main.async {
                        if self.datasource.isNotEmpty {
                            let section = self.datasource.count - 1
                            guard let row = self.datasource[section]
                                .childs
                                .firstIndex(where: { $0.key == "block_chat_button" }) else { return }
                            let indexPath = IndexPath(row: row, section: section)
                            UIView.performWithoutAnimation {
                                if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                                    visibleIndexPaths.contains(indexPath) {
                                    self.tableView.reloadRows(at: [indexPath], with: .none)
                                }
                            }
                        }
                    }
                })
                .disposed(by: bag)
            
            Observable.collection(from: realm.objects(LastChatsStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.isMuted = item.isMuted
                        let expiredAt = item.muteExpired
                        DispatchQueue.main.async {
                            if expiredAt > Date().timeIntervalSince1970 {
                                self.headerView.thirdButton.configure(#imageLiteral(resourceName: "bell-sleep"),
                                          title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                    style: .inactive
                                )
                            } else {
                                self.headerView.thirdButton.configure(#imageLiteral(resourceName: "bell-off"),
                                          title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                    style: .active
                                )
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.headerView.thirdButton.configure(#imageLiteral(resourceName: "bell"),
                                          title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                     style: .active)
                        }
                    }
                    DispatchQueue.main.async {
                        if self.datasource.isNotEmpty {
                            let section = self.datasource.count - 1
                            guard let row = self.datasource[section]
                                .childs
                                .firstIndex(where: { $0.key == "notify_chat_button" }) else { return }
                            let indexPath = IndexPath(row: row, section: section)
                            UIView.performWithoutAnimation {
                                if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                                    visibleIndexPaths.contains(indexPath) {
                                    self.tableView.reloadRows(at: [indexPath], with: .none)
                                }
                            }
                        }
                    }
                }).disposed(by: bag)
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    
    internal func configure() {
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
        tableView.delegate = self
        tableView.dataSource = self
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                headerHeightMax += topOffset
                headerHeightMin += topOffset
            }
        }
        headerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: headerHeightMax)
        view.addSubview(headerView)
        
        navigationItem.setRightBarButtonItems([editButton, showQRCodeButton], animated: true)
        tableView.contentInset = UIEdgeInsets(top: headerHeightMax - 88, bottom: -44, left: 0, right: 0) //Was: headerHeightMax - 64
        tableView.setContentOffset(CGPoint(x: 0, y: -headerHeightMax), animated: true)
        tableView.showsVerticalScrollIndicator = false
        headerView.delegate = self
        headerView.firstButton.configure(#imageLiteral(resourceName: "chat"),
                                         title: "Chat".localizeString(id: "chat_viewer", arguments: []),
                                         style: .active)
        headerView.secondButton.configure(#imageLiteral(resourceName: "call"),
                                          title: "Call".localizeString(id: "contact_bar_call", arguments: []),
                                          style: .active,
                                          enabled: false)
        headerView.secondButton.isHidden = true
        headerView.thirdButton.configure(#imageLiteral(resourceName: "bell"),
                                         title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                         style: .active)
        headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                          title: "Block".localizeString(id: "contact_bar_block", arguments: []),
                                          style: .danger)
//        headerView.subtitleLabel.isHidden = true
        
        footerView.conversationType = self.conversationType
        footerView.jid = self.jid
        footerView.owner = self.owner
        
        footerView.frame = CGRect(x: 0, y: 0,
                                  width: view.frame.width,
                                  height: view.frame.height - headerHeightMin)
        footerView.mediaButtonsDelegate = self
        footerView.infoVCDelegate = self
        tableView.tableFooterView = footerView
        
        editButton.target = self
        editButton.action = #selector(onEditContact)
        showQRCodeButton.target = self
        showQRCodeButton.action = #selector(showQRCode)
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//            user.vCardAvatars.fetch(stream, for: self.jid)
            user.vcards.requestItem(stream, jid: self.jid)
        })
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        title = " "
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        
        footerView.imagesButton.isSelected = true
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        headerView.setMask()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        getAppTabBar()?.hide()
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        footerView.getReferences()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        if let title = self.headerView.titleButton.titleLabel?.text {
            self.navigationItem.backButtonTitle = "\(title)'s Info"
        } else {
            self.navigationItem.backButtonTitle = "Info"
        }
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
//        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//        navigationController?.navigationBar.shadowImage = nil
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
