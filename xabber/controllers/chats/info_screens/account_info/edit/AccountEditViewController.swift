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
import Kingfisher
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import TOInsetGroupedTableView

class AccountEditViewController: BaseViewController {
    
    class Datasource {
        enum Kind {
            case profile
            case vcard
        }
        
        var kind: Kind
        var title: String
        var key: String
        var value: String
        var givenName: String = ""
        var middleName: String = ""
        var family: String = ""
        var fullname: String = ""
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, key: String, value: String, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.childs = childs
            self.key = key
        }
    }
    
//    internal var jid: String = ""
    
    internal var datasource: [Datasource] = []
    
    internal var vcardStructure: [Datasource] = []
    internal var originalStructure: [Datasource] = []
    internal var avatarChanged: Bool = false
    internal var nickname: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var vcard: vCardStorageItem = vCardStorageItem()
    
    internal var avatarImage: UIImage? = nil
    
    internal var doneButtonActive: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var tableViewBottomInset: CGFloat = 8 {
        didSet {
            tableView.contentInset.bottom = tableViewBottomInset
            tableView.scrollIndicatorInsets.bottom = tableViewBottomInset
        }
    }
    
    internal var automaticallyAddedBottomInset: CGFloat {
        if #available(iOS 11.0, *) {
            return tableView.adjustedContentInset.bottom - tableView.contentInset.bottom
        } else {
            return 0
        }
    }
    
    internal var additionalBottomInset: CGFloat = 8 {
        didSet {
            let delta = additionalBottomInset - oldValue
            tableViewBottomInset += delta
        }
    }
    
    internal var initialBottomInset: CGFloat {
        if #available(iOS 11, *) {
            return 0
        } else {
            return 8
        }
    }  
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(VcardEditedItem.self, forCellReuseIdentifier: VcardEditedItem.cellName)
        view.register(ProfileCell.self, forCellReuseIdentifier: ProfileCell.cellName)
        
        view.keyboardDismissMode = .interactive
        
        return view
    }()
    
    internal let doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        return button
    }()
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            self.vcard = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) ?? vCardStorageItem()
            DefaultAvatarManager.shared.getAvatar(jid: jid, owner: jid, size: 128) { image in
                self.avatarImage = image
            }
//            ImageCache.default.retrieveImage(forKey: self.jid, options: nil, callbackQueue: .mainAsync) { (results) in
//                self.avatarImage = try! results.get().image
//            }
        } catch {
            DDLogDebug(["cant load vcard item", jid, #function].joined(separator: ". "))
        }
    }
    
    internal func update() {
        let profile = Datasource(.profile, title: "", key: "", value: "")
        
        datasource = [Datasource(.profile, title: "About".localizeString(id: "about", arguments: []),
                                 key: "", value: "", childs: [profile])]
        VCardManager.getVcardStructure(self.vcard, jid: self.jid).forEach {
            
            self.vcardStructure.append(contentsOf: $0.childs.map({ return Datasource(.vcard, title: $0.title, key: $0.key, value: $0.value) }))
            self.originalStructure.append(contentsOf: $0.childs.map({ return Datasource(.vcard, title: $0.title, key: $0.key, value: $0.value) }))
            self.datasource.append(Datasource(.vcard, title: $0.title, key: $0.key, value: $0.value, childs: $0.childs.compactMap({
                if !["ci_given_name", "ci_full_name", "ci_family_name", "ci_middle_name"].contains($0.key) {
                    if $0.key == "ci_nickname" && self.nickname.isEmpty {
                        self.nickname = $0.value
                    }
                    return Datasource(.vcard, title: $0.title, key: $0.key, value: $0.value)
                } else {
                    return nil
                }
            })))
        }

        
        vcardStructure.forEach {
            switch $0.key {
            case "ci_given_name": profile.givenName = $0.value
            case "ci_middle_name": profile.middleName = $0.value
            case "ci_family_name": profile.family = $0.value
            case "ci_full_name": profile.fullname = $0.value
            default: break
            }
        }
    }
    
    internal func subscribe() {
        addObservers()
        bag = DisposeBag()
        
        doneButton.rx.tap.bind {
            self.onSave()
        }.disposed(by: bag)
        
        doneButtonActive.asObservable().subscribe(onNext: { (value) in
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.33, animations: {
                    self.doneButton.isEnabled = value
                })
            }
        }).disposed(by: bag)
    }
    
    internal func unsubscribe() {
        removeObservers()
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String) {
        self.jid = jid
        title = "Edit profile".localizeString(id: "account_edit_profile", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        navigationItem.setRightBarButton(doneButton, animated: true)
        hideKeyboardWhenTappedAround()
        load()
        update()
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
        subscribe()
        activateConstraints()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tableView.reloadData()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
