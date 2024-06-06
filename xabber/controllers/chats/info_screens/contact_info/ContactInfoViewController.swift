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
        
    
    public var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    
    var headerHeightMax: CGFloat = 156
    
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
    
    internal var datasource: [Datasource] = []
    
    internal var isBlocked: Bool = false
    internal var isMuted: Bool = false
    
    internal var isDeleted: Bool = false
    
    internal var nickname: String = ""
    
    internal var circles: [String] = []
    
    internal let leftDevicesNavBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem()
        
        return button
    }()
    
    internal func subscribe() {
        datasource = []
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
                        
            circles = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?.groups.toArray() ?? []
            circles = Array(Set(circles)).sorted()
            
            if let item = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.nickname = item.displayName
                self.headerView.configure(
                    avatarUrl: item.avatarUrl,
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                    title: self.nickname,
                    subtitle: self.jid,
                    thirdLine: nil
                )
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
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                    title: self.jid,
                    subtitle: self.jid,
                    thirdLine: nil
                )
            }
            
            Observable
                .collection(from: realm
                    .objects(RosterStorageItem.self)
                    .filter("owner == %@ AND jid == %@", owner, jid))
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.nickname = item.displayName
                        self.headerView.configure(
                            avatarUrl: item.avatarUrl,
                            owner: self.owner,
                            jid: self.jid,
                            titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                            title: self.nickname,
                            subtitle: self.jid,
                            thirdLine: nil
                        )
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
                            owner: self.owner,
                            jid: self.jid,
                            titleColor: .label,//AccountColorManager.shared.primaryColor(for: self.owner),
                            title: self.jid,
                            subtitle: self.jid,
                            thirdLine: nil
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
                        self.leftDevicesNavBarButton.image = indicator
                        self.leftDevicesNavBarButton.tintColor = color
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
                    if self.datasource.isNotEmpty {
                        let section = self.datasource.count - 1
                        guard let row = self.datasource[section]
                            .childs
                            .firstIndex(where: { $0.key == "block_chat_button" }) else { return }
                        let indexPath = IndexPath(row: row, section: section)
                        if let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                            visibleIndexPaths.contains(indexPath) {
                            self.tableView.reloadRows(at: [indexPath], with: .none)
                        }
                    }
                })
                .disposed(by: bag)
            
            Observable.collection(from: realm.objects(LastChatsStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid))
                .debounce(.milliseconds(80), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
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
                            let (text, secondaryText, buttonTitle, buttonKey) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(
                                verificationState: verificationInstance.state
                            )
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
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
        navigationItem.setRightBarButtonItems([editButton, showQRCodeButton], animated: false)
        view.addSubview(tableView)
        
        
        tableView.delegate = self
        tableView.dataSource = self
        
        tableView.tableHeaderView = headerView
        headerView.delegate = self
        
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
        leftDevicesNavBarButton.target = self
        leftDevicesNavBarButton.action = #selector(onLEftDevicesNavBarButtonTouchUp)
        self.navigationItem.setLeftBarButton(leftDevicesNavBarButton, animated: true)
    }
    
    @objc
    func onLEftDevicesNavBarButtonTouchUp(_ sender: UIBarButtonItem) {
        showFingerprints()
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
//        navigationController?.isNavigationBarHidden = true
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        footerView.getReferences()
        tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        navigationController?.navigationBar.shadowImage = UIImage()
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
