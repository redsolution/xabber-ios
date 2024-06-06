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

extension GroupchatContactInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section >= datasource.count {
            return formDatasource[section - datasource.count].count
        }
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count + formDatasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section >= datasource.count {
            let section = indexPath.section - datasource.count
            if section >= formDatasource.count { fatalError() }
            if indexPath.row >= formDatasource[section].count { fatalError() }
            let item = formDatasource[section][indexPath.row]
            switch item.kind {
            case .fixed:
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: InfoCell.cellName,
                                         for: indexPath) as? InfoCell else {
                    fatalError()
                }
                var value: String? = item.value
                if value == "0" {
                    value = " "
                } else if let stringValue = item.value,
                    let interval = TimeInterval(stringValue) {
                    let currentDate = Date()
                    if currentDate.timeIntervalSince1970 > interval {
                        value = nil
                    } else {
                        let expireDate = Date(timeIntervalSince1970: interval - Double(TimeZone.current.secondsFromGMT()))
                        let result = NSCalendar.current.dateComponents([.month, .day, .hour, .minute], from: currentDate, to: expireDate)
                        if let months = result.month,
                            months > 0 {
                            value = "in \(months == 1 ? "a" : "\(months)") month\(months == 1 ? "" : "s")".localizeString(id: "groupchats_in_months", arguments: ["\(months)"])
                        } else if let days = result.day,
                            days > 0 {
                            value = "in \(days == 1 ? "a" : "\(days)") day\(days == 1 ? "" : "s")".localizeString(id: "groupchats_in_days", arguments: ["\(days)"])
                        } else if let hours = result.hour,
                            hours > 0 {
                            value = "in \(hours == 1 ? "a" : "\(hours)") hour\(hours == 1 ? "" : "s")".localizeString(id: "groupchats_in_hours", arguments: ["\(hours)"])
                        } else if let minutes = result.minute,
                            minutes > 0 {
                            value = "in \(minutes == 1 ? "a" : "\(minutes)") minute\(minutes == 1 ? "" : "s")".localizeString(id: "groupchats_in_minutes", arguments: ["\(minutes)"])
                        }
                    }
                }
                cell.configure(.list, itemId: item.itemId, title: item.title, value: value, editable: false, last: false)
                
                cell.switchItem.isEnabled = false
                
                cell.selectionStyle = .none
                return cell
            case .boolItem:
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: ItemCell.cellName,
                                         for: indexPath) as? ItemCell else {
                    fatalError()
                }
                
                cell.configure(item.itemId,
                               title: item.title,
                               enabled: item.state,
                               editable: false,
                               last: false)
                cell.delegate = self

                cell.selectionStyle = .none
                
                return cell
            case .listItem:
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: InfoCell.cellName,
                                         for: indexPath) as? InfoCell else {
                    fatalError()
                }
                cell.delegate = self
                var value: String? = item.value
                if value == "0" {
                    value = ""
                } else if let stringValue = item.value,
                    let interval = TimeInterval(stringValue) {
                    let currentDate = Date()
                    if currentDate.timeIntervalSince1970 > interval {
                        value = nil
                    } else {
                        let expireDate = Date(timeIntervalSince1970: interval - Double(TimeZone.current.secondsFromGMT()))
                        let result = NSCalendar.current.dateComponents([.month, .day, .hour, .minute], from: currentDate, to: expireDate)
                        if let months = result.month,
                            months > 0 {
                            value = "in \(months == 1 ? "a" : "\(months)") month\(months == 1 ? "" : "s")".localizeString(id: "groupchats_in_months", arguments: ["\(months)"])
                        } else if let days = result.day,
                            days > 0 {
                            value = "in \(days == 1 ? "a" : "\(days)") day\(days == 1 ? "" : "s")".localizeString(id: "groupchats_in_days", arguments: ["\(days)"])
                        } else if let hours = result.hour,
                            hours > 0 {
                            value = "in \(hours == 1 ? "a" : "\(hours)") hour\(hours == 1 ? "" : "s")".localizeString(id: "groupchats_in_hours", arguments: ["\(hours)"])
                        } else if let minutes = result.minute,
                            minutes > 0 {
                            value = "in \(minutes == 1 ? "a" : "\(minutes)") minute\(minutes == 1 ? "" : "s")".localizeString(id: "groupchats_in_minutes", arguments: ["\(minutes)"])
                        }
                    }
                }
                cell.configure(.list, itemId: item.itemId, title: item.title, value: value, editable: false, last: false)

                cell.selectionStyle = .none
                return cell
            }
        }
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .status:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName,
                                                           for: indexPath) as? StatusInfoCell else {
                fatalError()
            }
            if isBlocked {
                cell.configure(title: "Blocked".localizeString(id: "groupchat_blocked", arguments: []), status: .online, entity: .contact, isTemporary: false)
            } else {
                if self.userOnline {
                    cell.configure(title: "Online".localizeString(id: "account_state_connected", arguments: []), status: .online, entity: .contact, isTemporary: false)
                } else {
                    cell.configure(title: "Offline".localizeString(id: "unavailable", arguments: []), status: .offline, entity: .contact, isTemporary: false)
                }
            }
            
            cell.accessoryType = .none
            return cell
        case .text:
            var cell = tableView.dequeueReusableCell(withIdentifier: "TextCell")
            if cell == nil {
                cell = UITableViewCell(style: .value1, reuseIdentifier: "TextCell")
            }
            cell?.textLabel?.text = item.title
            cell?.detailTextLabel?.text = item.subtitle
            if item.key == "gcc_role" {
                if isBlocked {
                    cell?.detailTextLabel?.text = "Not a member".localizeString(id: "settings_group_member__placeholder_not_a_member", arguments: [])
                } else if isKicked {
                    cell?.detailTextLabel?.text = "Not a member".localizeString(id: "settings_group_member__placeholder_not_a_member", arguments: [])
                } else {
                    cell?.detailTextLabel?.text = self.userRole.localized
                }
            }
            cell?.selectionStyle = .none
            return cell!
        case .button:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.subtitle
            if item.key == "delete_chat_button" {
                cell.textLabel?.textColor = .systemRed
            } else {
                cell.textLabel?.textColor = .systemBlue
            }
            cell.selectionStyle = .none
            return cell
        case .selection:
            fatalError()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section >= datasource.count {
            return formSectionTitles[section - datasource.count]
        }
        return datasource[section].title
    }
}
