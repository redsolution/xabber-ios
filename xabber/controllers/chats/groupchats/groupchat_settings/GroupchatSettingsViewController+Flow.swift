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

extension GroupchatSettingsViewController {
    @objc
    internal func dismissController() {
//        self.dismiss(animated: true, completion: nil)
        if isStatus {
            self.dismiss(animated: true, completion: nil)
        } else {
            self.navigationController?.popViewController(animated: true)
        }
    }
    
    @objc
    internal func onEditGroups() {
         let vc = EditContactViewController()
         vc.owner = self.owner
         vc.jid = self.jid
         self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func onFormCallback(_ form: [[String: Any]]?, error: String?) {
        self.inSaveMode.accept(false)
        if let form = form {
            self.form = form
        }
        if let error = error {
            var header: String = "Unsupported data format".localizeString(id: "groupchats_unsupported_data_format", arguments: [])
            if error == "fail" {
                header = "Can`t load form, internal server error".localizeString(id: "groupchats_cant_load_form", arguments: [])
            }
            
            
            DispatchQueue.main.async {
                self.datasource = [Datasource(.listSingle,
                                              itemId: "",
                                              header: header,
                                              footer: "",
                                              placeholder: "",
                                              value: "",
                                              values: [],
                                              options: [],
                                              raw: [:])]
                self.tableView.reloadData()
            }
        } else {
            DispatchQueue.main.async {
                self.updateDatasource()
            }
        }
        
    }
    
    internal func changeItem(_ itemId: String, kind: Datasource.Kind, value: String, append: Bool) {
        var item = form.first(where: { $0["var"] as? String == itemId })
        if item == nil { return }
        switch kind {
        case .textSingle, .textMulti:
            item?.updateValue(value, forKey: "value")
        case .listSingle:
            item?.updateValue(value, forKey: "value")
            datasource.first(where: { $0.itemId == itemId })?.value = value
            DispatchQueue.main.async {
                if let section = self.datasource.firstIndex(where: { $0.itemId == itemId }) {
                    self.tableView.reloadSections(IndexSet([section]), with: .none)
                }
            }
        default: break
        }
        if let index = changedValues.value.firstIndex(where: { $0["var"] as? String == itemId }) {
            var values = changedValues.value
            values.remove(at: index)
            changedValues.accept(values)
        }
        if (item?["value"] as? String) != (form.first(where: { $0["var"] as? String == itemId })?["value"] as? String) {
            var values = changedValues.value
            values.append(item!)
            changedValues.accept(values)
        }
        
    }
    
    internal func updateDatasource() {
        datasource = []
        form.forEach { (item) in
            if self.isStatus {
                if (item["var"] as? String) != "status" {
                    return
                }
            } else {
                if (item["var"] as? String) == "status" {
                    return
                }
            }
            switch item["type"] as! String {
            case "list-single":
                datasource.append(Datasource(.listSingle,
                                             itemId: (item["var"] as? String) ?? "",
                                             header: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             footer: "",
                                             placeholder: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             value: (item["value"] as? String) ?? "",
                                             values: (item["values"] as? [String]) ?? [],
                                             options: (item["options"] as? [[String: String]]) ?? [],
                                             raw: item))
            case "text-multi":
                datasource.append(Datasource(.textMulti,
                                             itemId: (item["var"] as? String) ?? "",
                                             header: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             footer: (item["var"] as? String) == "description" ? "Short description of groupchat. Example, XMPP developers group chat.".localizeString(id: "groupchat_short_description", arguments: []) : "",
                                             placeholder: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             value: (item["value"] as? String) ?? "",
                                             values: (item["values"] as? [String]) ?? [],
                                             options: (item["options"] as? [[String: String]]) ?? [],
                                             raw: item))
            case "text-single":
                datasource.append(Datasource(.textSingle,
                                             itemId: (item["var"] as? String) ?? "",
                                             header: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             footer: "",
                                             placeholder: (item["label"] as? String) ?? (item["var"] as? String) ?? "",
                                             value: (item["value"] as? String) ?? "",
                                             values: (item["values"] as? [String]) ?? [],
                                             options: (item["options"] as? [[String: String]]) ?? [],
                                             raw: item))
            default: break
            }
        }
        if !self.isStatus {
            datasource.append(Datasource(.delete,
                                         itemId: "",
                                         header: "",
                                         footer: "All data will be deleted"
                                            .localizeString(id: "all_data_will_be_deleted", arguments: []),
                                         placeholder: "",
                                         value: "Delete"
                                            .localizeString(id: "delete", arguments: []),
                                         values: [],
                                         options: [],
                                         raw: [:]))
        }
        self.tableView.reloadData()
    }
    
    internal func onDelete() {
        DispatchQueue.main.async {
            DeleteItemPresenter()
                .present(in: self,
                         title: "Delete group"
                            .localizeString(id: "group_remove", arguments: []),
                         message: "All data will be deleted"
                            .localizeString(id: "all_data_will_be_deleted", arguments: []),
                         deleteText: "Delete"
                            .localizeString(id: "delete", arguments: []),
                         cancelText: "Cancel"
                            .localizeString(id: "cancel", arguments: []),
                         animated: true) { (value) in
                         if value {
                             AccountManager
                                 .shared
                                 .find(for: self.owner)?
                                 .action({ (user, stream) in
                                 user.groupchats.delete(stream,
                                                         groupchat: self.jid,
                                                         callback: self.onDeleteCallback)
                             })
                         }
            }
        }
    }
    
    internal func onDeleteCallback(error: String?) {
        DispatchQueue.main.async {
            if let error = error {
                var message: String = ""
                switch error {
                case "not-allowed": message = "You have no permission to delete group"
                        .localizeString(id: "groupchats_no_permission_to_delete_group", arguments: [])
                case "fail": message = "Connection failed"
                        .localizeString(id: "grouchats_connection_failed", arguments: [])
                default: message = "Internal server error"
                        .localizeString(id: "error_internal_server", arguments: [])
                }
                ErrorMessagePresenter().present(in: self, message: message, animated: true, completion: nil)
            } else {
                self.dismissController()
            }
        }
    }
    
    @objc
    internal func onSave() {
        self.inSaveMode.accept(true)
        var modifiedForm: [[String: Any]] = []
        form.forEach {
            item in
            if self.isStatus {
                if (item["var"] as? String) != "status" {
                    return
                }
            } else {
                if (item["var"] as? String) == "status" {
                    return
                }
            }
            if let modified = changedValues.value.first(where: { $0["var"] as? String == item["var"] as? String }) {
                modifiedForm.append(modified)
            } else {
                modifiedForm.append(item)
            }
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            self.updateFormId = session.groupchat?.updateForm(stream, formType: self.isStatus ? .status : .settings, groupchat: self.jid, userData: modifiedForm) { (error) in
                DispatchQueue.main.async {
                    self.inSaveMode.accept(false)
                    if let error = error {
                        var message: String = "Internal server error"
                            .localizeString(id: "error_internal_server", arguments: [])
                        if error == "fail" {
                            message = "Connection failed"
                                .localizeString(id: "grouchats_connection_failed", arguments: [])
                        }
                        ErrorMessagePresenter().present(in: self, message: message, animated: true) {
                            self.navigationController?.popViewController(animated: true)
                        }
                    } else {
                        self.changedValues.accept([])
                        self.dismissController()
                    }
                }
            }
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                self.updateFormId = user.groupchats.updateForm(stream, formType: self.isStatus ? .status : .settings, groupchat: self.jid, userData: modifiedForm) { (error) in
                    DispatchQueue.main.async {
                        self.inSaveMode.accept(false)
                        if let error = error {
                            var message: String = "Internal server error"
                                .localizeString(id: "error_internal_server", arguments: [])
                            if error == "fail" {
                                message = "Connection failed"
                                    .localizeString(id: "grouchats_connection_failed", arguments: [])
                            }
                            ErrorMessagePresenter().present(in: self, message: message, animated: true) {
                                self.navigationController?.popViewController(animated: true)
                            }
                        } else {
                            self.changedValues.accept([])
                            self.dismissController()
                        }
                    }
                }
            })
        }
        
    }
    
}
