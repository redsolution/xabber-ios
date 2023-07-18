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

class ChangePasswordTableViewController: UITableViewController {
    
    let loadingIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        view.startAnimating()
        
        return view
    }()
    
    var saveButton: UIBarButtonItem? = nil
    var eyeButton: UIBarButtonItem? = nil
    var cells: [TextEditBaseCell] = []
    let sections: [String] = ["Old password",
                              "New password"]
    let placeholders: [String] = ["old password", "new password", "repeat new password"]
    open var jid: String = ""
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Change password"
        for placeholder in placeholders {
            let cell = TextEditBaseCell()
            cell.textField.textContentType = .newPassword
            cell.textField.isSecureTextEntry = true
            cell.textField.keyboardType = .asciiCapable
            cell.textField.placeholder = placeholder
            cell.textField.clearButtonMode = .always
            cell.textFieldDidChangeValueCallback = self.onTextFieldDidChange
            cell.textField.delegate = self
            cells.append(cell)
        }
        saveButton = UIBarButtonItem(title: "Change", style: .plain, target: self, action: #selector(onSave))
        saveButton?.isEnabled = false
        eyeButton = UIBarButtonItem(image: UIImage(named: "eye-off"), style: .plain, target: self, action: #selector(showPassword))
        self.navigationItem.setRightBarButtonItems([saveButton].compactMap { $0 }, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return 2
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return cells[indexPath.section + indexPath.row]
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section]
    }
    
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 {
            return "It is recommended to make your passwords at least 12-14 characters long. In general, the longer the password, the better it is against a brute force attack.\n\nThird party servers may have different password difficulty requirements."
        }
        return nil
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    @objc func showPassword() {
        let textFields = cells.compactMap { $0.textField }
        
        if textFields[0].isSecureTextEntry {
            self.eyeButton?.image = UIImage(named: "eye")
            textFields.forEach {
                $0.isSecureTextEntry = false
            }
        } else {
            self.eyeButton?.image = UIImage(named: "eye-off")
            textFields.forEach {
                $0.isSecureTextEntry = true
            }
        }
    }
    
    @objc func onSave() {
        self.saveButton?.isEnabled = false
        let textFields = cells.compactMap { $0.textField }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let setNewPasswordAction = UIAlertAction(title: "Confirm change password", style: .destructive, handler: { [weak self] _ in
            guard let self = self,
                  let oldPassword = textFields.first?.text,
                  let newpPassword = textFields.last?.text else {
                return
            }
            self.saveButton?.customView = self.loadingIndicator
            XMPPChangePasswordManager.shared.changePassword(jid: self.jid, oldPassword: oldPassword, newPassword: newpPassword, delegate: self)
        })
        alert.addAction(setNewPasswordAction)
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in self.saveButton?.isEnabled = true })
        alert.addAction(cancelAction)
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        self.present(alert, animated: true, completion: nil)
    }
    
    internal final func onTextFieldDidChange(target field: String, value: String?) {
        self.validateTextFiled(value: value) { result in
            DispatchQueue.main.async {
                self.saveButton?.isEnabled = result
            }
        }
    }
    
    func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        let textFields = cells.compactMap { $0.textField }
        guard let value = value,
              value.count > 2,
              let text_1 = textFields[0].text,
              let text_2 = textFields[1].text,
              let text_3 = textFields[2].text,
              text_1.count > 2,
              text_2.count > 2,
              text_3 == text_2 else {
            callback(false)
            return
        }
        callback(true)
    }
}

extension ChangePasswordTableViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let textFields = cells.compactMap { $0.textField }
        if let index = textFields.firstIndex(where: { $0 == textField }) {
            if index == textFields.count - 1 {
                textFields[index].resignFirstResponder()
            } else {
                textFields[index + 1].becomeFirstResponder()
            }
        }
        return true
    }
}

extension ChangePasswordTableViewController: XMPPChangePasswordManagerDelegate {
    func didReceiveResponse(title: String, description: String) {
        DispatchQueue.main.async {
            self.saveButton?.customView = nil
            let alert = UIAlertController(title: title, message: description, preferredStyle: .alert)
            let action = UIAlertAction(title: "OK", style: .default, handler: { _ in
                self.navigationController?.popViewController(animated: true)
            })
            alert.addAction(action)
            self.present(alert, animated: true, completion: nil)
            self.saveButton?.isEnabled = true
        }
    }
}

