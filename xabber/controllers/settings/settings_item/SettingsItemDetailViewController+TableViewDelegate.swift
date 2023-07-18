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

extension SettingsItemDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 48
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if self.isLanguagesScreen {
            tableView.deselectRow(at: indexPath, animated: true)
            
            tableView.visibleCells.forEach({
                $0.accessoryType = .none
            })
            
            let cell = tableView.cellForRow(at: indexPath) as? SettingsItemDetailViewController.SelectorCell
            cell?.accessoryType = .checkmark
            
            
            //TranslationsManager.shared.save(language: cell?.titleLabel.text ?? "Default")
            TranslationsManager.shared.save(language: cell?.textLabel?.text ?? "Default")
            
            NotificationCenter
                .default
                .post(
                    name: .newLanguageSelected,
                    object: self,
                    userInfo: [:])
            
            return
        }
        
        let item = self.datasource.childs[indexPath.section].childs[indexPath.row]
        if item.key == "share_log_files" {
            self.shareLogFiles()
            return
        }
        if item.kind == .selector {
            let vc = SettingsItemSelectorViewController()
            vc.configure(datasource: item)
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}
