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

import Foundation
import UIKit

extension AccountEditViewController {
    class VcardEditedItem: UITableViewCell {
        static let cellName = "VCardEditedItemCell"

        private static let birthdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()

        var stack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            return stack
        }()

        var field: UITextField = {
            let field = UITextField()
            field.returnKeyType = .done
            return field
        }()

        let datePicker: UIDatePicker = {
            let picker = UIDatePicker()
            picker.datePickerMode = .date
            picker.preferredDatePickerStyle = .wheels
            picker.calendar = Calendar(identifier: .gregorian)
            picker.locale = .current
            picker.maximumDate = Calendar.current.startOfDay(for: Date())
            return picker
        }()

        var callback: ((UITextField) -> Bool)?

        private lazy var birthdayToolbar: UIToolbar = {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            toolbar.items = [
                UIBarButtonItem(
                    title: "Clear".localizeString(id: "clear", arguments: []),
                    style: .plain,
                    target: self,
                    action: #selector(clearBirthday)
                ),
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(
                    title: "Done".localizeString(id: "done", arguments: []),
                    style: .done,
                    target: self,
                    action: #selector(finishBirthdayEditing)
                )
            ]
            return toolbar
        }()

        func configure(_ key: String, for title: String, value: String) {
            field.text = value.isEmpty ? nil : value
            field.placeholder = title
            field.restorationIdentifier = key
            field.clearButtonMode = .always
            configureInput(for: key, value: value)
        }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .systemBackground
            contentView.backgroundColor = .systemBackground
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
            datePicker.addTarget(self, action: #selector(birthdayDidChange), for: .valueChanged)
        }

        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func configureInput(for key: String, value: String) {
            field.inputView = nil
            field.inputAccessoryView = nil
            field.tintColor = .tintColor
            VCardInputPolicy.apply(to: field, key: key)

            guard key == "ci_birthday" else { return }
            field.inputView = datePicker
            field.inputAccessoryView = birthdayToolbar
            field.tintColor = .clear
            if let date = Self.birthdayFormatter.date(from: value) {
                datePicker.setDate(date, animated: false)
            } else {
                datePicker.setDate(datePicker.maximumDate ?? Date(), animated: false)
            }
        }

        @objc
        private func birthdayDidChange() {
            field.text = Self.birthdayFormatter.string(from: datePicker.date)
            _ = callback?(field)
        }

        @objc
        private func clearBirthday() {
            field.text = nil
            _ = callback?(field)
            field.resignFirstResponder()
        }

        @objc
        private func finishBirthdayEditing() {
            birthdayDidChange()
            field.resignFirstResponder()
        }

        @objc
        internal func fieldDidChange(_ sender: UITextField) {
            _ = callback?(sender)
        }
    }

    enum VCardInputPolicy {
        static func apply(to field: UITextField, key: String) {
            field.keyboardType = .default
            field.textContentType = nil
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .default
            field.spellCheckingType = .default

            switch key {
            case "ci_given_name":
                configureName(field, contentType: .givenName)
            case "ci_middle_name":
                configureName(field, contentType: .middleName)
            case "ci_family_name":
                configureName(field, contentType: .familyName)
            case "ci_full_name":
                configureName(field, contentType: .name)
            case "ci_nickname":
                field.textContentType = .nickname
                field.autocapitalizationType = .none
            case "desc_email_work", "desc_email_home":
                field.keyboardType = .emailAddress
                field.textContentType = .emailAddress
                disableCorrection(for: field)
            case "desc_url":
                field.keyboardType = .URL
                field.textContentType = .URL
                disableCorrection(for: field)
            case let key where key.hasPrefix("ph_"):
                field.keyboardType = .phonePad
                field.textContentType = .telephoneNumber
                disableCorrection(for: field)
            case "wp_orgname", "wp_orgunit":
                field.textContentType = .organizationName
                field.autocapitalizationType = .words
            case "wp_title", "wp_role":
                field.textContentType = .jobTitle
                field.autocapitalizationType = .words
            case "ha_street", "ha_address", "wa_street", "wa_address":
                field.textContentType = .streetAddressLine1
                field.autocapitalizationType = .words
            case "ha_locality", "wa_locality":
                field.textContentType = .addressCity
                field.autocapitalizationType = .words
            case "ha_region", "wa_region":
                field.textContentType = .addressState
                field.autocapitalizationType = .words
            case "ha_pcode", "wa_pcode":
                field.keyboardType = .asciiCapable
                field.textContentType = .postalCode
                field.autocapitalizationType = .allCharacters
                field.autocorrectionType = .no
            case "ha_pobox", "wa_pobox":
                field.keyboardType = .asciiCapable
                field.autocapitalizationType = .allCharacters
                field.autocorrectionType = .no
                field.spellCheckingType = .no
            case "ha_country", "wa_country":
                field.textContentType = .countryName
                field.autocapitalizationType = .words
            default:
                break
            }
        }

        private static func configureName(
            _ field: UITextField,
            contentType: UITextContentType
        ) {
            field.keyboardType = .namePhonePad
            field.textContentType = contentType
            field.autocapitalizationType = .words
            field.autocorrectionType = .no
        }

        private static func disableCorrection(for field: UITextField) {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
    }
}
