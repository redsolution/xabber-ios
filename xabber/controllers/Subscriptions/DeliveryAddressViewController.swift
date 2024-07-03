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
import XMPPFramework

class DeliveryAddressViewController: UITableViewController {
    
    struct Field {
        let title: String
        let key: String
        let placeholder: String
        let textContentType: UITextContentType
        let keyboardType: UIKeyboardType
        let necessary: Bool
        let footer: String?
    }
    
    let fields: [Field] = [
        Field(title: "Name *", key: "name", placeholder: "Name", textContentType: .name , keyboardType: .default, necessary: true, footer: nil),
        Field(title: "Postal Code *", key: "postal_code", placeholder: "Postal code", textContentType: .postalCode, keyboardType: .default, necessary: true, footer: nil),
        Field(title: "Country *", key: "country", placeholder: "Country", textContentType: .countryName, keyboardType: .default, necessary: true, footer: nil),
        Field(title: "City *", key: "city", placeholder: "City", textContentType: .addressCity, keyboardType: .default, necessary: true, footer: nil),
        Field(title: "Street Address *", key: "street", placeholder: "Street Address", textContentType: .streetAddressLine1, keyboardType: .default, necessary: true, footer: "All fields marked with \"*\" are required to send this form."),
        Field(title: "Phone Number", key: "phone_number", placeholder: "Phone Number", textContentType: .telephoneNumber, keyboardType: .phonePad, necessary: false, footer: nil),
        Field(title: "Delivery Notes", key: "delivery_notes", placeholder: "Delivery Notes", textContentType: .name, keyboardType: .default, necessary: false, footer: nil)
    ]
    
    open var jid: String = "igor.boldin@redsolution.com"
    var submitButton: UIBarButtonItem? = nil
    var cells: [TextEditBaseCell] = []
    
    convenience init() {
        self.init(style: .insetGrouped)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Yubikey Delivery Address"
        self.tabBarController?.tabBar.isHidden = true
        //self.navigationItem.setHidesBackButton(true, animated: false)
        
        for field in fields {
            let cell = TextEditBaseCell()
            cell.textField.textContentType = field.textContentType
            cell.textField.keyboardType = field.keyboardType
            cell.textField.placeholder = field.placeholder
            cell.textField.clearButtonMode = .always
            cell.textFieldDidChangeValueCallback = self.onTextFieldDidChange
            cell.textField.delegate = self
            cells.append(cell)
        }
        
        submitButton = UIBarButtonItem(title: "Submit", style: .plain, target: self, action: #selector(onSubmit))
        submitButton?.isEnabled = false
        self.navigationItem.setRightBarButtonItems([submitButton].compactMap { $0 }, animated: true)
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return fields.count
    }
    
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return cells[indexPath.section]
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return fields[section].title
    }
    
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return fields[section].footer
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    @objc func onSubmit() {
        self.submitButton?.isEnabled = false
        
        var messageText =  "Yubikey delivery request:\n\n"
        
        let textFields = cells.compactMap { $0.textField }
        
        var payload: [String: String] = [:]
        
        payload["action"] = "yubikey_request"
        
        textFields.enumerated().forEach {
            (index, item) in
            if let text = item.text {
                messageText += "\(fields[index].title.replacingOccurrences(of: "*", with: "")): \(text)\n"
            }
            
            payload[fields[index].key] = item.text ?? ""
        }
        
        let json = DDXMLElement(name: "json", xmlns: "urn:xmpp:json:0")
        
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: payload,
            options: .sortedKeys
           ),
           let jsonDumps = String(
            data: jsonData,
            encoding: String.Encoding.ascii
           ) {
            json.stringValue = jsonDumps
        }
        
        
        
        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
            user.messages.sendSimpleMessage(
                messageText,
                to: CommonConfigManager.shared.config.support_jid,
                childs: [json],
                forwarded: [],
                conversationType: .regular
            )
//            user.presences.subscribe(stream, jid: CommonConfigManager.shared.config.support_jid)
//            user.presences.subscribed(stream, jid: CommonConfigManager.shared.config.support_jid, storePreaproved: true)
            self.dismiss(animated: true) {
                let vc = ChatViewController()
                vc.jid = CommonConfigManager.shared.config.support_jid
                vc.owner = self.jid
                vc.conversationType = .regular
                
                if let presenterVc = self.presentationController {
                    showStacked(vc, in: presenterVc.presentingViewController)
                }
            }
        })
        
        
    }
    
    internal final func onTextFieldDidChange(target field: String, value: String?) {
        self.validateTextFiled(value: value) { result in
            DispatchQueue.main.async {
                self.submitButton?.isEnabled = result
            }
        }
    }
    
    func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        let textFields = cells.compactMap { $0.textField }
        
        for (index, item) in textFields.enumerated() {
            if !fields[index].necessary { continue }
            guard let text = item.text, text.isNotEmpty else {
                callback(false)
                return
            }
        }
        callback(true)
    }
}

extension DeliveryAddressViewController: UITextFieldDelegate {
    
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
