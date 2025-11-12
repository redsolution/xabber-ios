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

class CreateNewGroupEditViewController: BaseViewController {
    
    
    internal var callback: (([String: String]) -> Void)? = nil
    internal var datasource: [[String: String]] = []
    internal var header: String? = nil
    internal var footer: String? = nil
    internal var current: [String: String]? = nil
    internal var custom: String? = nil
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(TextCell.self, forCellReuseIdentifier: TextCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")
        
        return view
    }()
    
    @objc
    internal func done(_ force: Bool = false) {
        if let current = current {
            callback?(current)
            navigationController?.popViewController(animated: true)
        }
    }
    
    open func customFieldCallback(_ sender: UITextField) {
        custom = sender.text
        if let text = sender.text {
            current = ["type": "custom", "Label": "Custom", "value": text]
            tableView.reloadRows(at: (0..<datasource.endIndex - 1).map { return IndexPath(row: $0, section: 0)}, with: .none)
        } else {
            custom = nil
        }
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(_ values: [[String: String]], title: String, header: String?, footer: String?, current: [String: String], callback: @escaping (([String: String]) -> Void)) {
        self.title = title
        self.datasource = values
        self.callback = callback
        self.header = header
        self.footer = footer
        self.current = current
        if current["type"] == "custom" {
            custom = current["value"]
        }
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        if values.first(where: { $0["type"] == "custom" }) != nil {
            navigationItem.setRightBarButton(UIBarButtonItem(title: "Save",
                                                             style: .done,
                                                             target: self,
                                                             action: #selector(done)),
                                             animated: true)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
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

extension CreateNewGroupEditViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return header
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return footer
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        if item["type"] ?? "" == "custom" {
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: TextCell.cellName,
                                     for: indexPath) as? TextCell else {
                fatalError()
            }
            
            cell.configure("Custom server".localizeString(id: "contact_custom_server", arguments: []), value: custom ?? "")
            cell.callback = customFieldCallback
            return cell
        } else {
            let cell = tableView
                .dequeueReusableCell(withIdentifier: "UITableViewCell",
                                     for: indexPath)
            cell.textLabel?.text = item["label"]
            cell.accessoryType = item == current ? .checkmark : .none
            return cell
        }
    }
}

extension CreateNewGroupEditViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        if item["type"] != "custom" {
            current = item
            done()
        }
    }
}

