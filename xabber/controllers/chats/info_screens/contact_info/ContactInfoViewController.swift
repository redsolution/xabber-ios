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
            case session
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var image: UIImage? = nil
        var key: String?
        var color: UIColor?
        var verificationSid: String?
        var verificationJid: String?
        
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, subtitle: String? = nil, image: UIImage? = nil, color: UIColor? = nil,  key: String? = nil, childs: [Datasource] = [], verificationSid: String? = nil, verificationJid: String? = nil) {
            self.kind = kind
            self.title = title
            if subtitle?.isEmpty ?? true {
                self.subtitle = nil
            } else {
                self.subtitle = subtitle
            }
            self.key = key
            self.childs = childs
            self.image = image
            self.color = color
            self.verificationSid = verificationSid
            self.verificationJid = verificationJid
        }
    }
    
//    open var owner: String = ""
//    open var jid: String = ""
    
//    var headerHeightMax: CGFloat = 246//256
//    var headerHeightMin: CGFloat = 150//156
    
    var headerHeightMax: CGFloat = 324//296//264
//    var headerHeightMin: CGFloat = 180//150
    
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
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "TextCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(VCardCell.self, forCellReuseIdentifier: VCardCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        view.register(EditCirclesCell.self, forCellReuseIdentifier: EditCirclesCell.cellName)
        view.register(SettingsViewController.DeviceCell.self, forCellReuseIdentifier: SettingsViewController.DeviceCell.cellName)
        
        
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
                        self.headerView.configure(
                            avatarUrl: item.avatarMaxUrl ?? item.avatarMinUrl ?? item.oldschoolAvatarKey,
                            jid: self.jid,
                            owner: self.owner,
                            userId: nil,
                            title: self.nickname,
                            subtitle: self.jid,
                            thirdLine: nil,
                            titleColor: AccountColorManager.shared.primaryColor(for: self.owner)
                        )
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
                        self.headerView.configure(
                            avatarUrl: nil,
                            jid: self.jid,
                            owner: self.owner,
                            userId: nil,
                            title: self.nickname,
                            subtitle: self.jid,
                            thirdLine: nil,
                            titleColor: AccountColorManager.shared.primaryColor(for: self.owner)
                        )
                    }
                }).disposed(by: bag)
                        
            Observable
                .collection(from: realm.objects(vCardStorageItem.self).filter("jid == %@", jid))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
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
                        }
                    }
                    do {
                        let realm = try WRealm.safe()
                        
                        let verificationInstance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
                        if let verificationInstance = verificationInstance {
                            let (text, secondaryText, buttonTitle, buttonKey) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(verificationState: verificationInstance.state)
                            let verificationDatasource = Datasource(.text, title: "Active verification session", key: "verification-session", childs: [
                                Datasource(.session, title: text, subtitle: secondaryText, verificationSid: verificationInstance.sid, verificationJid: self.jid)
                            ])
                            
                            if buttonKey != nil {
                                verificationDatasource.childs.append(Datasource(.button, title: buttonTitle!, key: buttonKey, verificationSid: verificationInstance.sid, verificationJid: self.jid))
                                if buttonKey == "accept_verification" {
                                    verificationDatasource.childs.append(Datasource(.button, title: "Reject", key: "reject_verification", verificationSid: verificationInstance.sid, verificationJid: self.jid))
                                }
                            }
                            newDatasource.append(verificationDatasource)
                        }
                        
                        let collectionJid = realm
                            .objects(SignalDeviceStorageItem.self)
                            .filter("jid == %@ AND owner == %@", self.jid, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                        
                        
                        var indicator: UIImage? = nil
                        var color: UIColor? = nil
                        
                        if collectionJid.toArray().filter({ $0.state == .fingerprintChanged }).count > 0 {
                            color = .systemRed
                            indicator = UIImage(systemName: "exclamationmark.triangle.fill")
                        } else if collectionJid.toArray().filter({ $0.state != .trusted }).count > 0 {
                            color = .systemOrange
                            indicator = UIImage(systemName: "exclamationmark.triangle.fill")
                        } else if collectionJid.count == 0 {
                            color = .secondaryLabel
                            indicator = UIImage(systemName: "lock.fill")
                        } else if collectionJid.toArray().filter({ $0.isTrustedByCertificate }).count > 0 {
                            color = .systemGreen
                            indicator = UIImage(systemName: "lock.circle.fill")
                        } else {
                            color = .systemGreen
                            indicator = UIImage(systemName: "lock.fill")
                        }
                        newDatasource.append(Datasource(.text, title: "Encryption", key: "encryption", childs: [
                            Datasource(.button, title: "Identity verification".localizeString(id: "contact_fingerprints", arguments: []), subtitle: "\(collectionJid.count)", image: indicator, color: color, key: "fingerprints"),
                            Datasource(.button, title: "Encrypted chat", subtitle: "", image: indicator, color: color, key: "start_encrypted_chat")
                        ]))
                    } catch {
                        DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
                    }
                    self.datasource = newDatasource
                    self.tableView.reloadData()
                })
                .disposed(by: bag)
            
            
            Observable.collection(from: realm.objects(BlockStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.isBlocked = !results.isEmpty
                    if results.isEmpty {
//                        DispatchQueue.main.async {
                            self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                                                   title: "Block".localizeString(id: "contact_bar_block", arguments: []),
                                                                   style: .danger)
//                        }
                    } else {
//                        DispatchQueue.main.async {
                            self.headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                                                   title: "Unblock".localizeString(id: "contact_bar_unblock", arguments: []),
                                                                   style: .active)
//                        }
                    }
//                    DispatchQueue.main.async {
                        if self.datasource.isNotEmpty {
                            let section = self.datasource.count - 1
                            guard let row = self.datasource[section]
                                .childs
                                .firstIndex(where: { $0.key == "block_chat_button" }) else { return }
                            let indexPath = IndexPath(row: row, section: section)
//                            UIView.performWithoutAnimation {
                                if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                                    visibleIndexPaths.contains(indexPath) {
                                    self.tableView.reloadRows(at: [indexPath], with: .none)
                                }
//                            }
                        }
//                    }
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
//                        DispatchQueue.main.async {
                            self.headerView.thirdButton.configure(#imageLiteral(resourceName: "bell"),
                                          title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                     style: .active)
//                        }
                    }
//                    DispatchQueue.main.async {
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
//                    }
                }).disposed(by: bag)
            
            Observable
                .collection(from: realm
                    .objects(VerificationSessionStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, jid))
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if self.datasource.isEmpty {
                        return
                    }
                    guard let item = results.first else {
                        let section = self.datasource.firstIndex(where: { $0.key == "verification-session" })
                        if let section = section {
                            self.datasource.remove(at: section)
                            self.tableView.reloadData()
                        }
                        
                        return
                    }
                    
                    do {
                        let section = self.datasource.firstIndex(where: { $0.key == "verification-session" })
                        if let section = section {
                            let (text, secondaryText, buttonTitle, buttonKey) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(verificationState: item.state)
                            let verificationDatasource = Datasource(.text, title: "Active verification session", key: "verification-session", childs: [
                                Datasource(.session, title: text, subtitle: secondaryText, verificationSid: item.sid, verificationJid: self.jid)
                            ])
                            
                            if buttonKey != nil {
                                verificationDatasource.childs.append(Datasource(.button, title: buttonTitle!, key: buttonKey, verificationSid: item.sid, verificationJid: self.jid))
                                if buttonKey == "accept_verification" {
                                    verificationDatasource.childs.append(Datasource(.button, title: "Reject", key: "reject_verification", verificationSid: item.sid, verificationJid: self.jid))
                                }
                            }
                            self.datasource[section] = verificationDatasource
                            self.tableView.reloadData()
                            
                            return
                        }
                        
                        let realm = try WRealm.safe()
                        
                        let verificationInstance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
                        if let verificationInstance = verificationInstance {
                            let (text, secondaryText, buttonTitle, buttonKey) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(verificationState: verificationInstance.state)
                            let verificationDatasource = Datasource(.text, title: "Active verification session", key: "verification-session", childs: [
                                Datasource(.session, title: text, subtitle: secondaryText, verificationSid: verificationInstance.sid, verificationJid: self.jid)
                            ])
                            
                            if buttonKey != nil {
                                verificationDatasource.childs.append(Datasource(.button, title: buttonTitle!, key: buttonKey, verificationSid: verificationInstance.sid, verificationJid: self.jid))
                                if buttonKey == "accept_verification" {
                                    verificationDatasource.childs.append(Datasource(.button, title: "Reject", key: "reject_verification", verificationSid: verificationInstance.sid, verificationJid: self.jid))
                                }
                            }
                            self.datasource.insert(verificationDatasource, at: self.datasource.firstIndex(where: { $0.key == "encryption" })!)
                            self.tableView.reloadData()
                            
                            return
                        }
                        
                    } catch {
                        fatalError()
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
        navigationItem.setRightBarButtonItems([editButton, showQRCodeButton], animated: false)
        view.addSubview(tableView)
        if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            tableView.fillSuperviewWithOffset(top: -56, bottom: 0, left: 0, right: 0)
            headerView.frame = CGRect(
                width: view.frame.width,
                height: headerHeightMax
            )
        } else {
            tableView.fillSuperviewWithOffset(top: -56, bottom: 0, left: 0, right: 0)
            headerView.frame = CGRect(
                width: view.frame.width,
                height: headerHeightMax
            )
        }
        
        tableView.delegate = self
        tableView.dataSource = self
        
        tableView.tableHeaderView = headerView
        headerView.delegate = self
        
        headerView.firstButton.configure(#imageLiteral(resourceName: "chat"),
                                         title: "Chat".localizeString(id: "chat_viewer", arguments: []),
                                         style: .active)
        headerView.secondButton.configure(UIImage(systemName: "lock.circle")!,
                                          title: "Secret chat",
                                          style: .active)
        headerView.secondButton.isHidden = true
        headerView.thirdButton.configure(#imageLiteral(resourceName: "bell"),
                                         title: "Notifications".localizeString(id: "contact_bar_notifications", arguments: []),
                                         style: .active)
        headerView.fourthButton.configure(#imageLiteral(resourceName: "cancel"),
                                          title: "Block".localizeString(id: "contact_bar_block", arguments: []),
                                          style: .danger)
        
        footerView.conversationType = self.conversationType
        footerView.jid = self.jid
        footerView.owner = self.owner
        
        footerView.frame = CGRect(x: 0, y: 0,
                                  width: view.frame.width,
                                  height: view.frame.height)
        footerView.mediaButtonsDelegate = self
        footerView.infoVCDelegate = self
        tableView.tableFooterView = footerView
        
        editButton.target = self
        editButton.action = #selector(onEditContact)
        showQRCodeButton.target = self
        showQRCodeButton.action = #selector(showQRCode)
        
        title = " "
        footerView.imagesButton.isSelected = true
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.vcards.requestItem(stream, jid: self.jid)
        })
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
