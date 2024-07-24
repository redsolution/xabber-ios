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

extension SettingsItemDetailViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.childs.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if datasource.key == "languages" {
            return datasource.childs.first?.values.count ?? 0
        }
        return datasource.childs[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if self.isLanguagesScreen {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SelectorCell.cellName, for: indexPath) as? SelectorCell else {
                return UITableViewCell(frame: .zero)
            }
//            let value = subtitleData?.first(where: {
//
//            })
            let title = datasource.childs.first!.values[indexPath.row]
            let twoLetterCode = TranslationsManager.shared.prepareLanCode(language: title)
            let percentage = (subtitleData?.first(where: {
                if let val = $0["lang"] as? String,
                   val == twoLetterCode {
                    return true
                }
                return false
            })?["percent"] as? String) ?? "0"
            cell.configure(key: title, for: title, value: "\(percentage)%", icon: "xabber.globe.connected.square.fill", color: MDCPalette.green.tint500, isFirstLevelVuew: true)
            return cell
        }
        
        let item = datasource.childs[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .title:
            break
        case .bool:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SwitchCell.cellName, for: indexPath) as? SwitchCell else {
                return UITableViewCell(frame: .zero)
            }
            cell.switchCallback = onBoolItemDidChange
            cell.configure(item.key, for: item.label, active: item.value as! Bool)
            return cell
        case .selector:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SelectorCell.cellName, for: indexPath) as? SelectorCell else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(key: item.key, for: item.label, value: item.value as! String, icon: "xabber.globe.connected.square.fill", color: MDCPalette.green.tint500)
            return cell
        case .group:
            break
        }
        return UITableViewCell(frame: .zero)
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if datasource.key == "languages" {
            return ""
        }
        return datasource.childs[section].label
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if datasource.key == "languages" {
            return ""
        }
        return datasource.childs[section].value as? String
    }
}
