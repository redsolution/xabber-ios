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


extension EditContactViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 1 && subscribtion.value == .undefined {
            return 1
        }
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .field:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TextEditBaseCell.cellName, for: indexPath) as? TextEditBaseCell else {
                fatalError()
            }
            var target: String = ""
            switch indexPath.section {
            case groupsSectionIndex:
                target = "contact_new_group"
                cell.textField.delegate = self
                cell.configure(target, value: item.fieldValue, placeholder: item.title)
            default: break
            }
            if item.key == "nickname" {
                cell.textFieldDidChangeValueCallback = self.textFieldDidChangeValue
                cell.targetField = "contact_edit_nickname"
            }
            
            return cell
        case .select:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SelectionCell.cellName, for: indexPath) as? SelectionCell else {
                fatalError()
            }
            
            cell.configure(title: item.title, isSelected: item.selectedValue ?? false)
            
            return cell
        case .simple:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SubscribtionCell.cellName, for: indexPath) as? SubscribtionCell else {
                fatalError()
            }
            
            var title: String = ""
            var showIndicator: Bool = false
            var highlight: SubscribtionCell.Highlight = .high
//            highlight = .low
            
            switch subscribtion.value {
            
            case .to:
                switch ask.value {
                case .in:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_to", fallback: "Receiving presence updates")
                    case "presence_send":
                        title = L10n.text("subscription_status_in_request_incoming", fallback: "Incoming subscription request")
                    default:
                        break
                    }
                case .none:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_to", fallback: "Receiving presence updates")
                    case "presence_send":
                        if approved.value {
                            title = L10n.text("subscription_status_is_allowed", fallback: "Allowing subscription")
                        } else {
                            title = L10n.text("subscription_status_in_not_allowed", fallback: "Not allowing subscription")
                        }
                    default:
                        break
                    }
                default:
                    break
                }
            case .from:
                switch ask.value {
                case .none:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_none", fallback: "Not subscribed")
                    case "presence_send":
                        title = L10n.text("subscription_status_in_from", fallback: "Sending presence updates")
                    default:
                        break
                    }
                case .out:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_requested", fallback: "Requested subscription")
                        showIndicator = false
                        highlight = .middle
                    case "presence_send":
                        title = L10n.text("subscription_status_in_from", fallback: "Sending presence updates")
                    default:
                        break
                    }
                default:
                    break
                }
            case .both:
                switch item.key {
                case "presence_receive":
                    title = L10n.text("subscription_status_out_to", fallback: "Receiving presence updates")
                case "presence_send":
                    title = L10n.text("subscription_status_in_from", fallback: "Sending presence updates")
                default:
                    break
                }
            case .none:
                switch ask.value {
                case .none:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_none", fallback: "Not subscribed")
                    case "presence_send":
                        if approved.value {
                            title = L10n.text("subscription_status_is_allowed", fallback: "Allowing subscription")
                        } else {
                            title = L10n.text("subscription_status_in_not_allowed", fallback: "Not allowing subscription")
                        }
                    default:
                        break
                    }
                case .in:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_none", fallback: "Not subscribed")
                    case "presence_send":
                        title = L10n.text("subscription_status_in_request_incoming", fallback: "Incoming subscription request")
                    default:
                        break
                    }
                case .out:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_requested", fallback: "Requested subscription")
                        showIndicator = true
                    case "presence_send":
                        if approved.value {
                            title = L10n.text("subscription_status_is_allowed", fallback: "Allowing subscription")
                        } else {
                            title = L10n.text("subscription_status_in_not_allowed", fallback: "Not allowing subscription")
                        }
                        highlight = .low
                    default:
                        break
                    }
                case .both:
                    switch item.key {
                    case "presence_receive":
                        title = L10n.text("subscription_status_out_requested", fallback: "Requested subscription")
                    case "presence_send":
                        title = L10n.text("subscription_status_in_request_incoming", fallback: "Incoming subscription request")
                    default:
                        break
                    }
                }
                
            case .undefined:
                title = "Add contact".localizeString(id: "application_action_no_contacts", arguments: [])
            }
            
            cell.configure(title: title, showIndicator: showIndicator, highlight: highlight)
            
            return cell
        case .danger:
            let cell = tableView.dequeueReusableCell(withIdentifier: "DangerCell", for: indexPath)
            
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemRed
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let item = datasource[indexPath.section][indexPath.row]
        return item.kind == .select
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if self.isCircleSelectView {
            return nil
        } else {
            if section == 0 {
                return "Nickname".localizeString(id: "vcard_nick_name", arguments: []).uppercased()
            } else if section == 1 {
                return "Subscription".localizeString(id: "subscription", arguments: []).uppercased()
            }
        }
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.isCircleSelectView {
            if isGroupchat {
                return "You can add group to more than one circle.".localizeString(id: "groupchats_more_than_one_circle", arguments: [])
            } else {
                return "You can add contact to more than one circle.".localizeString(id: "contact_more_than_one_circle", arguments: [])
            }
        } else {
            if section == 0 {
                return "You may assign a custom name for this contact.".localizeString(id: "contact_edit_name_description", arguments: [])
            } else if section == 1 {
                switch subscribtion.value {
                case .to:
                    switch ask.value {
                    case .none:
                        if approved.value {
                            return L10n.text("edit_contact__table_section_title__you_receive_presence_information_for_this_contact_but_the_contact_has_not", fallback: "You receive presence information for this contact, but the contact has not asked to see yours.\n\nIncoming subscription requests will be accepted automatically.").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        } else {
                            return L10n.text("edit_contact__table_section_title__you_receive_presence_information_for_this_contact_but_the_contact_has_not__variant_2", fallback: "You receive presence information for this contact, but the contact has not asked to see yours.\n\nIncoming subscription requests will not be accepted automatically.").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        }
                    case .in:
                        return L10n.text("edit_contact__table_section_title__you_receive_presence_information_for_this_contact_and_the_contact_has_sent", fallback: "You receive presence information for this contact, and the contact has sent you a request to see your presence information.")
                    default:
                        return nil
                    }
                case .from:
                    switch ask.value {
                    case .none:
                        return L10n.text("edit_contact__table_section_title__the_contact_receives_your_presence_information_you_have_not_sent_a_request", fallback: "The contact receives your presence information.\n\nYou have not sent a request to access presence information of this contact.")
                    case .out:
                        return L10n.text("subscription_status_description_out_requested_in_from", fallback: "You have sent a request to see presence information of this contact. It is not yet answered.\n \nThe contact receives your presence information.\n")
                    default:
                        return nil
                    }
                case .both:
                    return L10n.text("subscription_status_description_both", fallback: "You and this contact are sharing presence information with each other.")
                case .none:
                    switch ask.value {
                    case .none:
                        if approved.value {
                            return L10n.text("subscription_status_description_out_none_in_allowed", fallback: "Contact is added to your roster, but presence information is not shared in either direction.\n\nIncoming subscription requests will be accepted automatically.")
                        } else {
                            return L10n.text("subscription_status_description_out_none_in_not_allowed", fallback: "Contact is added to your roster, but presence information is not shared in either direction.\n \n Incoming subscription requests will not be accepted automatically.")
                        }
                    case .in:
                        return L10n.text("subscription_status_description_out_none_in_request_incoming", fallback: "Contact has sent you a request to see your presence information.\n \n You have not sent a request to access presence information of this contact.")
                    case .out:
                        if approved.value {
                            return L10n.text("subscription_status_description_out_requested_in_allowed", fallback: "You have sent a request to see presence information of this contact. It is not yet answered.\n\nIncoming subscription requests will be accepted automatically.")
                        } else {
                            return L10n.text("subscription_status_description_out_requested_in_not_allowed", fallback: "You have sent a request to see presence information of this contact. It is not yet answered.\n \n Incoming subscription requests will not be accepted automatically.")
                        }
                    case .both:
                        return L10n.text("subscription_status_description_out_requested_in_request_incoming", fallback: "You and this contact have both sent each other requests to see each other's presence information. Generally, mutual subscription requests are automatically accepted, so you should not be seeing this description, ever. But since you do, it means that something went wrong, huh.")
                    }
                case .undefined:
                    return nil
                }
            } else if section == tableView.numberOfSections - 1 {
                return "Contact will be deleted.".localizeString(id: "contact_will_be_deleted", arguments: [])
            } else {
                return nil
            }
        }
    }
    
}
