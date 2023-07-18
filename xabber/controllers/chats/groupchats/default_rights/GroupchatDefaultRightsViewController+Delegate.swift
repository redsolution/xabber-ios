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

protocol GroupchatDefaultRightsDelegate {
    func onChangeState(_ itemId: String, sender: UISwitch?)
}

extension GroupchatDefaultRightsViewController: GroupchatDefaultRightsDelegate {
    func onChangeState(_ itemId: String, sender: UISwitch?) {
        func updateDatasource(value: String?) {
            DispatchQueue.main.async {
                if let row = self.datasource.firstIndex(where: { $0.itemId == itemId }) {
                    print(row)
                    self.datasource[row].value = value
                    self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
                }
            }
        }
        if let item = form.first(where: { ($0["var"] as? String) == itemId }),
            let value = sender?.isOn {
            if value {
                if let items = item["values"] as? [[String: String]] {
                    var values: [[PresenterPickerViewController.Datasource]] = [items
                        .filter { $0["value"] != "0" }
                        .compactMap {
                            return PresenterPickerViewController.Datasource(item["value"] as? String == $0["value"],
                                                                            title: $0["label"] ?? "",
                                                                            value: $0["value"] ?? "")}]
//                        .sorted(by: { $0[0].value < $1[0].value })
                    if let foreverItem = items.first(where:  { $0["value"] == "0"}) {
                        print(foreverItem)
                        values[0].insert(PresenterPickerViewController.Datasource(item["value"] as? String == foreverItem["value"],
                                                                                  title: foreverItem["label"] ?? "",
                                                                                  value: foreverItem["value"] ?? ""),
                                          at: 0)
                    }
                    PickerViewPresenter().present(in: self,
                                                  title: nil,//item.title,
                                                  message: nil,//"Select expiration",
                                                  setText: "Enable".localizeString(id: "use_external_dialog_enable_button", arguments: []),
                                                  cancelText: "Cancel".localizeString(id: "cancel", arguments: []),
                                                  defaultText: nil,
                                                  defaultValue: "0",
                                                  values: values,
                                                  animated: true,
                                                  onCancel: {
                                                      sender?.setOn(false, animated: true)
                                                  }) { (value, label, component) in
                                                    if let index =  self.modifiedForm.value.firstIndex(where: { ($0["var"] as? String) == itemId }) {
                                                        var values = self.modifiedForm.value
                                                        values.remove(at: index)
                                                        self.modifiedForm.accept(values)
                                                    }
                                                    if let value = value {
                                                        var values = self.modifiedForm.value
                                                        values.append(["var": item["var"] ?? "",
                                                                                        "type": item["type"] ?? "",
                                                                                        "value": value])
                                                        self.modifiedForm.accept(values)
                                                    }
                                                    updateDatasource(value: label)
                                                    
                    }
                }
            } else {
                if let index =  modifiedForm.value.firstIndex(where: { ($0["var"] as? String) == itemId }) {
                    var values = modifiedForm.value
                    values.remove(at: index)
                    modifiedForm.accept(values)
                } else {
                    var values = modifiedForm.value
                    values.append(["var": item["var"] ?? "",
                                               "type": item["type"] ?? "",
                                               "value": ""])
                    modifiedForm.accept(values)
                }
                updateDatasource(value: nil)
            }
        }
    }
}
