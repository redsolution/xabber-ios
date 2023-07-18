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
import CocoaLumberjack
import TOInsetGroupedTableView

class AccountConnectionViewController: BaseViewController {
    class Datasource {
        enum Kind {
            case resource
        }
        
        var kind: Kind
        var title: String
        var value: String
        var date: Date
        var status: ResourceStatus
        var editable: Bool
        var current: Bool
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, value: String = "", date: Date = Date(), status: ResourceStatus = .offline, current: Bool = false, editable: Bool, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.date = date
            self.current = current
            self.editable = editable
            self.childs = childs
        }
    }
    
//    internal var jid: String = ""
    
    internal var datasource: [Datasource] = []
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var bag: DisposeBag = DisposeBag()
    
    internal var password: String = ""
    internal var resource: String = ""
    internal var initialPassword: String = ""
    internal var initialResource: String = ""
    
    internal var currentToken: String = ""
    internal var tokenSupport: Bool = false
    
    internal var doneButtonActive: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(EditValue.self, forCellReuseIdentifier: EditValue.cellName)
        
        return view
    }()
    
    internal let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                     style: .done, target: nil, action: nil)
        button.isEnabled = true
        return button
    }()
    
    @objc
    func dismissVCByButtonTap() {
        self.dismiss(animated: true, completion: nil)
    }
    
    internal let doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        button.isEnabled = false
        return button
    }()
    
    func load() {
        do {
            let realm = try WRealm.safe()
            account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) ?? AccountStorageItem()
            resource = account.resource?.resource ?? ""
            initialResource = resource
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func update() {
        datasource = [Datasource(.resource,
                                 title: "resource",
                                 editable: false,
                                 childs: [Datasource(.resource,
                                                     title: "Resource".localizeString(id: "account_resource", arguments: []),
                                                     value: account.resource?.resource ?? "",
                                                     editable: false)])
        ]
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
        title = "Conenction settings".localizeString(id: "account_connection_settings", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        cancelButton.target = self
        cancelButton.action = #selector(dismissVCByButtonTap)
        navigationItem.setLeftBarButton(cancelButton, animated: true)
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
