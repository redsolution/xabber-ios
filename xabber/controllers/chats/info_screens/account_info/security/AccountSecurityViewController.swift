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
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import TOInsetGroupedTableView

// TODO: fix it or drop it
class AccountSecurityViewController: BaseViewController {
    class Datasource {
        enum Kind {
            case password
        }
        
        var kind: Kind
        var title: String
        var value: String
        var editable: Bool
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, value: String = "", editable: Bool, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.editable = editable
            self.childs = childs
        }
    }
    
//    internal var jid: String = ""
    
    internal var datasource: [Datasource] = []
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var bag: DisposeBag = DisposeBag()
    
    internal var password: String = ""
    internal var initialPassword: String = ""
    
    internal var doneButtonActive: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(EditValue.self, forCellReuseIdentifier: EditValue.cellName)
        
        return view
    }()
    
    internal let doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []), style: .done, target: nil, action: nil)
        button.isEnabled = false
        return button
    }()
    
    func load() {
        do {
            let realm = try WRealm.safe()
            account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) ?? AccountStorageItem()
//            password = AccountManager.shared.find(for: jid)?.password ?? ""
            initialPassword = password
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func update() {
//        datasource = [Datasource(.password,
//                                 title: "password",
//                                 editable: false,
//                                 childs: [Datasource(.password,
//                                                     title: "Password",
//                                                     value: AccountManager.shared.find(for: jid)?.password ?? "",
//                                                     editable: false)])
//        ]
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        doneButton.rx.tap.bind {
            self.save()
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
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String) {
        self.jid =  jid
        title = "Password and security".localizeString(id: "account_password_security", arguments: [])
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
        activateConstraints()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
