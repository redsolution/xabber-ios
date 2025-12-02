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

extension GroupchatDefaultRightsViewController {

    @objc
    func dismissController() {
        self.navigationController?.dismiss(animated: true, completion: nil)
    }
    
    
    internal func onSave() {
        inSaveMode.accept(true)
        if modifiedForm.value.isNotEmpty {
            var changes: [[String: Any]] = []
            form.forEach {
                item in
                if ["FORM_TYPE"].contains((item["var"] as? String) ?? "") {
                    changes.append(item)
                }
            }
            changes.append(contentsOf: modifiedForm.value)
//            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//                self.updateFormId = user.groupchats.updateForm(stream,
//                                           formType: .defaultRights,
//                                           groupchat: self.jid,
//                                           userData: changes,
//                                           callback: self.onSaveCallback)
//            })
        } else {
            onSaveCallback(nil)
        }
    }
    
    internal func onSaveCallback(_ error: String?) {
        inSaveMode.accept(false)
        modifiedForm.accept([])
        DispatchQueue.main.async {
            if let error = error {
                var message: String = ""
                switch error {
                case "conflict": message = "Some members already in groupchat"
                        .localizeString(id: "groupchats_members_in_groupchat_message", arguments: [])
                case "not-allowed": message = "You have no permission to invite members"
                        .localizeString(id: "groupchats_no_permission_to_invite", arguments: [])
                case "fail": message = "Connection failed"
                        .localizeString(id: "grouchats_connection_failed", arguments: [])
                default: message = "Internal server error"
                        .localizeString(id: "error_internal_server", arguments: [])
                }
                ErrorMessagePresenter().present(in: self, message: message, animated: true) {
                    self.navigationController?.popViewController(animated: true)
                }
            } else {
//                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                    user.groupchats.requestUsers(stream, groupchat: self.groupchat)
//                })
                self.dismissController()
            }
        }
    }
    
    internal func onReceiveForm(form: [[String: Any]]?, error: String?) {
        inSaveMode.accept(false)
        if let form = form {
            self.form = form
        }
        func transformDatasource(_ item: [String: Any]) -> Datasource? {
            switch item["type"] as? String {
            case "list-single":
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, h:mm a"
                var value: String? = nil
                if let stamp = item["value"] as? String, let timeInterval = TimeInterval(stamp) {
                    value = formatter.string(from: Date(timeIntervalSince1970: timeInterval))
                }
                if value == nil {
                    value = item["value"] as? String
                }
                return Datasource(item["var"] as? String ?? "",
                                  title: item["label"] as? String ?? "",
                                  value: value,
                                  values:  (item["values"] as? [[String: String]] ?? []).compactMap { return Value(label: $0["label"] ?? "", value: $0["value"] ?? "")},
                                  enabled: (item["value"] as? String) != nil)
            default: return nil
            }
        }
        
        DispatchQueue.main.async {
            if let form = form?.compactMap({ return transformDatasource($0) }), form.isNotEmpty {
                self.datasource = form
            }
            self.tableView.reloadData()
        }
    }
}
