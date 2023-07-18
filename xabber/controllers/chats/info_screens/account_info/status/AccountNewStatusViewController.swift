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
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import TOInsetGroupedTableView

class AccountNewStatusViewController: BaseViewController {
    
    class Datasource {
        
        enum Kind {
            case custom
            case basic
        }
        
        var kind: Kind
        var title: String
        var value: String
        var status: ResourceStatus
        var current: Bool
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, status: ResourceStatus, value: String, current: Bool = false, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.current = current
            self.childs = childs
        }
        
    }
    
    open var isModal: Bool = false
    
//    internal var jid: String = ""
    
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var primaryResource: ResourceStorageItem = ResourceStorageItem()
    internal var datasource: [Datasource] = []
    
    internal var statusMessage: String = ""
    internal var statusMessageCopy: String = ""
    internal var statusState: ResourceStatus = .online
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(BaseStatus.self, forCellReuseIdentifier: BaseStatus.cellName)
        view.register(CustomStatus.self, forCellReuseIdentifier: CustomStatus.cellName)
        
        return view
    }()
    
    internal let doneButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Set".localizeString(id: "set", arguments: []),
                                     style: .done, target: nil, action: nil)
        return button
    }()
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) ?? AccountStorageItem()
            primaryResource = account.resource ?? ResourceStorageItem()
            statusMessage = primaryResource.statusMessage
            statusMessageCopy = statusMessage
            statusState = account.enabled ? primaryResource.status : .offline
        } catch {
            DDLogDebug(["cant load account info", jid, #function].joined(separator: ". "))
        }
    }
    
    internal func update() {
        datasource = [Datasource(.custom,
                                 title: "Set custom status message".localizeString(id: "set_custom_status_message", arguments: []),
                                 status: .online,
                                 value: "",
                                 childs: [Datasource(.custom, title: "Status message".localizeString(id: "status_message", arguments: []), status: statusState, value: statusMessage)]),
                      Datasource(.basic,
                                 title: "Set status".localizeString(id: "status_editor", arguments: []),
                                 status: statusState,
                                 value: "",
                                 childs: [Datasource(.basic, title: "", status: .online, value: "", current: .online == statusState),
                                          Datasource(.basic, title: "", status: .chat, value: "", current: .chat == statusState),
                                          Datasource(.basic, title: "", status: .dnd, value: "", current: .dnd == statusState),
                                          Datasource(.basic, title: "", status: .away, value: "", current: .away == statusState),
                                          Datasource(.basic, title: "", status: .xa, value: "", current: .xa == statusState),
                                          Datasource(.basic, title: "", status: .offline, value: "", current: .offline == statusState)]),
        ]
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        doneButton.rx.tap.bind {
            self.done()
        }.disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String) {
        self.jid = jid
        title = "Set status".localizeString(id: "status_editor", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        navigationItem.setRightBarButton(doneButton, animated: true)
        doneButton.isEnabled = false
        load()
        update()
        if isModal {
            navigationItem.setLeftBarButton(UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissScreen)), animated: true)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
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
    
    @objc
    internal func dismissScreen() {
        self.dismiss(animated: true, completion: nil)
    }
}
