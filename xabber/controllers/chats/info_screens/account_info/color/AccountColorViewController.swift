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
import MaterialComponents.MDCPalettes

class AccountColorViewController: BaseViewController {
    
    class Datasource {
        var key: String
        var title: String
        var active: Bool
        
        init(_ key: String, title: String, active: Bool) {
            self.key = key
            self.title = title
            self.active = active
        }
    }
    
//    internal var jid: String = ""
    internal var isModal: Bool = false
    
    internal var activeColor: String = ""
    
    internal var datasource: [Datasource] = []
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .plain)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(InfoCell.self, forCellReuseIdentifier: InfoCell.cellName)
        
        return view
    }()
    
    func load() {
        activeColor = AccountColorManager.shared.colorItem(for: jid).key
    }
    
    internal func update() {
        datasource = AccountColorManager.colors.map({ (item) -> Datasource in
            return Datasource(item.key, title: item.title, active: item.key == activeColor)
        })
    }
    
    internal func subscribe() {
        
    }
    
    internal func unsubscribe() {
        
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String) {
        self.jid =  jid
        title = "Choose color".localizeString(id: "account_choose_color", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        if isModal {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
            navigationItem.setLeftBarButton(cancelButton, animated: true)
        }
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
    
    @objc
    internal func cancel() {
        self.dismiss(animated: true, completion: nil)
    }
}
