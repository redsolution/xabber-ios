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
import TOInsetGroupedTableView

class AccountSelectViewController: BaseViewController {
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(AccountCell.self, forCellReuseIdentifier: AccountCell.cellName)
        
        return view
    }()
    
    var delegate: AccountSelectDelegate? = nil
    
    var datasource: [String] = []
    internal var selectedAccount: String = ""
    
    
    internal func updateDatasource() {
        datasource = AccountManager.shared.users.map { return $0.jid }
    }
    
    internal func configure(_ delegate: AccountSelectDelegate, current account: String) {
        title = "Select account".localizeString(id: "choose_account", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        selectedAccount = account
        self.delegate = delegate
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updateDatasource()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
