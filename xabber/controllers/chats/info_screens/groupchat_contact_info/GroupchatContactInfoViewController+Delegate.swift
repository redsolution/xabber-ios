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

protocol GroupchatContactInfoPermissionDelegate {
    func onChangePermission(sender: UISwitch?, itemId: String, value: Bool)
}

extension GroupchatContactInfoViewController: GroupchatContactInfoPermissionDelegate {
    internal func changeItem(_ itemId: String, value: String?) {
        var item = form.first(where: { $0["var"] as? String == itemId})
        if item == nil { return }
        item?.updateValue(value ?? "", forKey: "value")
        var changes = changedValues.value
        if let index = changes.firstIndex(where: { $0["var"] as? String == itemId }) {
            changes.remove(at: index)
        } else if value == nil {
            changes.append(item!)
        }
        if value != nil {
            changes.append(item!)
        }
        changedValues.accept(changes)
        formDatasource.enumerated().forEach {
            (offset, datasource) in
            if let index = datasource.firstIndex(where: { $0.itemId == itemId }) {
                datasource[index].value = value
                DispatchQueue.main.async {
                    if #available(iOS 11.0, *) {
                        UIView.performWithoutAnimation {
                            self.tableView.performBatchUpdates({
                                self.tableView.reloadRows(at: [IndexPath(row: index,
                                                                         section: offset + self.datasource.count)],
                                                          with: .none)
                            }, completion: nil)
                        }
                    } else {
                        UIView.performWithoutAnimation {
                            self.tableView.beginUpdates()
                            self.tableView.reloadRows(at: [IndexPath(row: index,
                                                                     section: offset + self.datasource.count)],
                                                      with: .none)
                            self.tableView.endUpdates()
                        }
                    }
                }
            }
        }
    }
    
    func onChangePermission(sender: UISwitch?, itemId: String, value: Bool) {
        
        formDatasource.forEach {
            datasourceItem in
            if let item = datasourceItem.first(where: { $0.itemId == itemId }) {
                if !value {
                    changeItem(itemId, value: nil)
                    return
                }
                if let items = item.payload as? [[String: String]] {
                    var values: [[PresenterPickerViewController.Datasource]] = [items
                        .filter { $0["value"] != "0" }
                        .compactMap {
                            return PresenterPickerViewController.Datasource(false,
                                                                            title: $0["label"] ?? "",
                                                                            value: $0["value"] ?? "")}]
                    if let foreverItem = items.first(where:  { $0["value"] == "0"}) {
                        values[0].insert(PresenterPickerViewController.Datasource(true,
                                                                                  title: foreverItem["label"] ?? "",
                                                                                  value: foreverItem["value"] ?? ""),
                                         at: 0)
                    }
                    
                    PickerViewPresenter().present(
                        in: self,
                        title: item.title,
                        message: nil,
                        setText: "Enable".localizeString(id: "use_external_dialog_enable_button", arguments: []),
                        cancelText: "Cancel".localizeString(id: "cancel", arguments: []),
                        defaultText: nil,
                        defaultValue: nil,
                        values: values,
                        animated: true,
                        onCancel: {
                            DispatchQueue.main.async {
                                sender?.setOn(!value, animated: true)
                            }
                        }) { (value, title, _) in
                            self.changeItem(itemId, value: value ?? "0")
                        }
                }
            }
        }
    }
}
