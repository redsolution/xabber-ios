////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import UIKit
//import RxSwift
//import RealmSwift
//import MaterialComponents.MDCPalettes
//import CocoaLumberjack
//
//
//func getAppTabBar() -> XabberTabBar? {
//    if var topController = UIApplication.shared.keyWindow?.rootViewController {
//        while let presentedViewController = topController.presentedViewController {
//            topController = presentedViewController
//        }
//        if topController.restorationIdentifier != nil {
//            if topController.restorationIdentifier! == "tabBarControllerRID" {
//                return topController as? XabberTabBar
//            }
//        }
//    }
//    return nil
//}
//
//class XabberTabBar: UITabBarController {
//    
//    enum Screens: Int {
//        case chats = 1
////        case calls
//        case contacts
////        case discover
//        case settings
//    }
//    
//    internal var previousSelectedItem: Int = Screens.chats.rawValue
//    
//    internal var chatsDelegate: XabberTabBarDelegate? = nil
//    internal var callsDelegate: XabberTabBarDelegate? = nil
//    internal var contactsDelegate: XabberTabBarDelegate? = nil
//    internal var discoverDelegate: XabberTabBarDelegate? = nil
//    internal var settingsDelegate: XabberTabBarDelegate? = nil
//    
//    
//    public static let chatVCIndex: Int = 0
//    public static let settingsVCIndex: Int = 3
//    
//    open func selectChatsVC() {
//        self.selectedIndex = XabberTabBar.chatVCIndex
//    }
//    
//    open func selectSettingsVC() {
//        self.selectedIndex = XabberTabBar.settingsVCIndex
//    }
//    
//    internal func configureChatViewController(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) -> ChatViewController {
//        XMPPUIActionManager.shared.open(owner: owner)
//        let chatVC = ChatViewController()
//        chatVC.owner = owner
//        chatVC.jid = jid
//        chatVC.conversationType = conversationType
//        return chatVC
//    }
//    
//    internal func configure() {
//        
//        viewControllers?.forEach {
//            guard let nav = $0 as? UINavigationController else {
//                fatalError()
//            }
////            nav.navigationBar.isTranslucent = false
//            switch nav.restorationIdentifier {
//            case "SettingsNavBarViewController":
//                let vc = SettingsViewController()
//                vc.shouldShowTabBar = true
//                nav.viewControllers = [vc]
//            case "LastChatshNavBarViewController":
//                let vc = LastChatsViewController()
//                vc.title = " "
//                self.chatsDelegate = vc
//                if let payload = NotifyManager.shared.openViewControllerPayload,
//                    let owner = payload["owner"],
//                    let jid = payload["jid"],
//                    let action = payload["action"] {
//                    NotifyManager.shared.openViewControllerPayload = nil
//                    switch action {
//                    case "initialChat":
//                        self.selectChatsVC()
//                        let chatVC = configureChatViewController(owner: owner, jid: jid, conversationType: .omemo)
//                        nav.viewControllers = [vc, chatVC]
//                    default:
//                        nav.viewControllers = [vc]
//                    }
//                } else {
//                    nav.viewControllers = [vc]
//                }
//            case "ContactsNavBarViewController":
//                let vc = ContactsViewController()
////                self.callsDelegate = vc
//                nav.viewControllers = [vc]
//            case "LastCallsNavBarViewController":
//                let vc = LastCallsViewController()
//                self.callsDelegate = vc
//                nav.viewControllers = [vc]
//            case "NotificationsNavBarViewController":
//                let vc = NotificationsListViewController()
////                self.discoverDelegate = vc
//                nav.viewControllers = [vc]
//            default: break
//            }
//        }
////        self.tabBar.items?.first?.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
////        self.tabBar.tintColor = AccountColorManager.shared.topColor()
////        self.tabBar.items?.forEach {
////            item in
////            item.
////        }
//    }
//    
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        configure()
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(appDidBecomeActive),
//                                               name: UIApplication.didBecomeActiveNotification,
//                                               object: nil)
//    }
//    
//    override func viewDidAppear(_ animated: Bool) {
//        super.viewDidAppear(animated)
//        self.setUnreadsValue(NotifyManager.shared.unreadMessagesCount)
//        if ApplicationStateManager.shared.isApplicationBlocked() {
//            SubscribtionsPresenter().present(animated: true)
//        }
//    }
//    
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//        self.setUnreadsValue(NotifyManager.shared.unreadMessagesCount)
//    }
//    
//    func hide() {
////        self.tabBar.isHidden = true
//    }
//    
//    func show() {
////        self.tabBar.isHidden = false
//    }
//    
//    @objc
//    internal func appDidBecomeActive() {
//        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { (_) in
//            self.displayChatIfNeeded()
//        }
//        
//        NotifyManager.shared.openViewControllerPayload = nil
//    }
//    
//    public func displayChatIfNeeded() {
//        if let payload = NotifyManager.shared.openViewControllerPayload,
//            let owner = payload["owner"],
//            let jid = payload["jid"],
//            owner != jid,
//            let action = payload["action"] {
//            var isGroupchat: Bool = false
//            do {
//                let realm = try WRealm.safe()
//                isGroupchat = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil
//            } catch {
//                print("XabberTabBar: \(#function). \(error.localizedDescription)")
//            }
//            NotifyManager.shared.openViewControllerPayload = nil
//            switch action {
//            case "foregroundChat":
//                displayChat(owner: owner, jid: jid, conversationType: isGroupchat ? .group : .omemo)
//            default: break
//            }
//        }
//    }
//    
//    public final func displayAddContactVC(jid: String, nickname: String?) {
//        do {
//            let realm = try WRealm.safe()
//            guard let owner = realm.objects(AccountStorageItem.self).filter("enabled == %@", true).sorted(byKeyPath: "order").first?.jid else {
//                return
//            }
//            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
//                self.displayContactInfo(owner: owner, jid: jid, converationType: .omemo)
//            } else {
//                self.selectChatsVC()
//                let vc = AddContactViewController()
//                vc.contactJid = jid
//                if let nickname = nickname,
//                   nickname.isNotEmpty {
//                    vc.contactNickname = nickname
//                }
//                let nav = viewControllers?.first as? UINavigationController
//                nav?.title = " "
//                if let rootVc = nav?.viewControllers.first {
//                    if let lastChatsVC = rootVc as? LastChatsViewController {
//                        vc.delegate = lastChatsVC
//                    }
//                    nav?.setViewControllers([rootVc, vc], animated: true)
//                } else {
//                    nav?.pushViewController(vc, animated: false)
//                }
//            }
//            
//        } catch {
//            DDLogDebug("XabberTabBar: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    func displayChat(owner: String, jid: String, entity: RosterItemEntity? = nil, conversationType: ClientSynchronizationManager.ConversationType) {
//        self.selectChatsVC()
//        let vc = configureChatViewController(owner: owner, jid: jid, conversationType: conversationType)
//        print("entity", entity)
//        if let entity = entity {
//            vc.entity = entity
//        }
//        let nav = viewControllers?.first as? UINavigationController
//        nav?.title = " "
//        if let rootVc = nav?.viewControllers.first {
//            nav?.setViewControllers([rootVc, vc], animated: true)
//        } else {
//            nav?.pushViewController(vc, animated: false)
//        }
//    }
//    
//    func displayContactInfo(owner: String, jid: String, converationType: ClientSynchronizationManager.ConversationType) {
//        self.selectChatsVC()
//        let chatVc = configureChatViewController(owner: owner, jid: jid, conversationType: converationType)
//        if converationType == .group {
//            let infoVc = GroupchatInfoViewController()
//            infoVc.owner = owner
//            infoVc.jid = jid
//            let nav = viewControllers?.first as? UINavigationController
//            nav?.title = " "
//            if let chats = nav?.viewControllers.first {
//                nav?.setViewControllers([chats, chatVc, infoVc], animated: false)
//            }
//        } else {
//            let infoVc = ContactInfoViewController()
//            infoVc.owner = owner
//            infoVc.jid = jid
//            let nav = viewControllers?.first as? UINavigationController
//            nav?.title = " "
//            if let chats = nav?.viewControllers.first {
//                nav?.setViewControllers([chats, chatVc, infoVc], animated: false)
//            }
//        }
//        
//    }
//    
//    public func updateColor() {
//        self.tabBar.tintColor = AccountColorManager.shared.topColor()
//    }
//    
//    override func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
//        
//        self.tabBar.tintColor = AccountColorManager.shared.topColor()
//        
//        func execute(_ delegate: XabberTabBarDelegate?, current tag: Int) {
//            if ((self.viewControllers?[tag] as? UINavigationController)?.viewControllers.count ?? 0) != 1 {
//                return
//            }
//            if item.tag == previousSelectedItem {
//                delegate?.onSelectCurrent(self, item: item)
//            } else {
//                delegate?.onSelect(self, item: item, myTag: tag, tag: item.tag)
//            }
//        }
//        
//        switch item.tag {
//        case Screens.chats.rawValue: execute(chatsDelegate, current: Screens.chats.rawValue)
////        case Screens.calls.rawValue: execute(callsDelegate, current: Screens.calls.rawValue)
//        case Screens.contacts.rawValue: execute(contactsDelegate, current: Screens.contacts.rawValue)
////        case Screens.discover.rawValue: execute(discoverDelegate, current: Screens.discover.rawValue)
////        case Screens.settings.rawValue: execute(settingsDelegate, current: Screens.settings.rawValue)
//        default: break
//        }
//        previousSelectedItem = item.tag
//    }
//    
//    public final func setUnreadsValue(_ value: Int?) {
//        if let value = value,
//            value > 0 {
//            self.tabBar.items?[0].badgeValue = "\(value)"
//        } else {
//            self.tabBar.items?[0].badgeValue = nil
//        }
//    }
//    
//}
