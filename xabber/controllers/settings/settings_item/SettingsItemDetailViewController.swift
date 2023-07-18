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
import RxSwift
import CocoaLumberjack
import TOInsetGroupedTableView

class SettingsItemDetailViewController: BaseViewController {
    
    class Datasource {
        
    }
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(SelectorCell.self, forCellReuseIdentifier: SelectorCell.cellName)
        view.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.cellName)
        view.register(SettingsItemSelectorViewController.Cell.self, forCellReuseIdentifier: SettingsItemSelectorViewController.Cell.cellName)
        
        return view
    }()
    
    internal var isDeveloperScreen: Bool = false
    internal var isLanguagesScreen: Bool = false
    
    internal var subtitleData: [NSDictionary]? = nil
    
    internal var datasource: SettingManager.Datasource = SettingManager.Datasource()
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for datasource: SettingManager.Datasource) {
        view.addSubview(tableView)
        tableView.fillSuperview()
        title = datasource.label
        tableView.delegate = self
        tableView.dataSource = self
        self.datasource = datasource.copy() as! SettingManager.Datasource
        if self.datasource.key == "developer" {
            self.isDeveloperScreen = true
            let tapToSend = SettingManager.Datasource(key: "share_log_files",
                                                      label: "Send log files".localizeString(id: "send_all_log_files", arguments: []),
                                                      kind: .selector,
                                                      childs: [],
                                                      values: [],
                                                      value: "")
            self.datasource
                .childs
                .append(SettingManager.Datasource(key: "share",
                                                  label: "Feedback".localizeString(id: "feedback", arguments: []),
                                                  kind: .group,
                                                  childs: [tapToSend],
                                                  values: [],
                                                  value: ""))
        } else if self.datasource.key == SettingManager.KeyScope.languages.rawValue {
            self.isLanguagesScreen = true
            if let path = Bundle.main.path(forResource: "proofreading", ofType: "json") {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                    let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
                    if let result = (jsonResult as? NSArray)?.compactMap({ return $0 as? NSDictionary }) {
                        self.subtitleData = result
                    }
                    
                } catch {
                    DDLogDebug("SettingsItemDetailViewController: \(#function). \(error.localizedDescription)")
                }
            }
        } else if self.datasource.key == "chat" {
        
        }
    }
    
    internal func subscribe() {
        
    }
    
    internal func unsubscribe() {
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
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
