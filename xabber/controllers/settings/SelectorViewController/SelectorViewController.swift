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

import UIKit
import TOInsetGroupedTableView

class SelectorViewController: UIViewController {

    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "defaultCellReuseID")
        return view
    }()
    
    var datasource: SettingsViewController.Datasource?
    
    open func configure(for datasource: SettingsViewController.Datasource) {
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        self.datasource = datasource
        tableView.reloadData()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

extension SelectorViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource?.values.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let datasource = self.datasource else {
            return UITableViewCell()
        }
        let item = datasource.values[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "defaultCellReuseID", for: indexPath)
        cell.selectionStyle = .none
        
        switch datasource.key {
        case .chatChooseMessageSound, .chatChooseSubscriptionSound:
            if let fileName = URL(string: item)?.pathComponents.last,
               let selectedFileName = URL(string: datasource.current)?.pathComponents.last {
                cell.textLabel?.text = fileName
                cell.accessoryType = (fileName == selectedFileName) ? .checkmark : .none
                return cell
            }
        default:
            break
        }

        cell.textLabel?.text = item.split(separator: "_").joined(separator: " ").capitalized
        cell.accessoryType = (item == datasource.current) ? .checkmark : .none
        
        return cell
    }
    
}

extension SelectorViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let datasource = self.datasource else { return }
        let item = datasource.values[indexPath.row]
        datasource.current = item
        
        if let key = datasource.key {
            
            switch key {
            case .chatChooseMessageSound, .chatChooseSubscriptionSound:
                MusicBox.shared.playSound(path: item)
                if let fileName = URL(string: item)?.pathComponents.last {
                    SettingManager.shared.saveItem(key: key.rawValue, string: fileName)
                }
            case .avatarMasksCurrentAvatarMask:
                AccountMasksManager.shared.save(mask: item)
                NotificationCenter.default.post(name: .newMaskSelected, object: self, userInfo: [:])
            default:
                SettingManager.shared.saveItem(key: key.rawValue, string: item)
            }
        }
        tableView.reloadData()
    }
}
