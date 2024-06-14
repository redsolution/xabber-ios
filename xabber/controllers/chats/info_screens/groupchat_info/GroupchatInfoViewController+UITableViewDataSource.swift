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

extension GroupchatInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if datasource[section].kind == .contact {
            return contacts?.count ?? 0
        }
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if datasource[indexPath.section].kind == .contact {
            guard let contact = self.contacts?[indexPath.row],
                let cell = tableView.dequeueReusableCell(withIdentifier: CommonMemberTableCell.cellName,
                                                         for: indexPath) as? CommonMemberTableCell else {
                fatalError()
            }
            if let date = contact.lastSeen {
                let today = Date()
                if abs(today.timeIntervalSince(date)) < 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen just now'"
                        .localizeString(id: "chat_seen_just_now", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen \(Int(abs(today.timeIntervalSince(date)) / 60)) minutes ago'"
                        .localizeString(id: "chat_seen_minutes_ago",
                                        arguments: ["\(Int(abs(today.timeIntervalSince(date)) / 60))"])
                } else if abs(today.timeIntervalSince(date)) < 2 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen an hour ago '"
                        .localizeString(id: "chat_seen_hour_ago", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen at 'HH:mm"
                        .localizeString(id: "chat_seen_at", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 24 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen yesterday at 'HH:mm"
                        .localizeString(id: "chat_seen_yesterday", arguments: [])
                }  else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                    lastSeenDateFormatter.dateFormat = "'last seen on 'E' at 'HH:mm"
                        .localizeString(id: "chat_seen_date_time", arguments: [])
                } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                    lastSeenDateFormatter.dateFormat = "'last seen 'dd MMM"
                        .localizeString(id: "chat_seen_date", arguments: [])
                } else {
                    lastSeenDateFormatter.dateFormat = "'last seen 'd MMM yyyy"
                        .localizeString(id: "chat_seen_date_year", arguments: [])
                }
            }
            
            cell.configure(
                avatarUrl: contact.avatarURI,
                jid: self.jid,
                owner: self.owner,
                userId: contact.userId,
                title: contact.nickname,
                badge: contact.badge,
                isMe: contact.isMe,
                subtitle: contact.isOnline ? "Online".localizeString(id: "account_state_connected", arguments: []) : lastSeenDateFormatter.string(from: contact.lastSeen ?? Date(timeIntervalSince1970: 1)),
                status: contact.isOnline ? .online : .offline,
                entity: .contact,
                role: contact.role
            )
            cell.setMask()
            return cell
        } else {
            let section = datasource[indexPath.section]
            let item = datasource[indexPath.section].childs[indexPath.row]
            switch item.kind {
            case .info:
                let cell = tableView.dequeueReusableCell(withIdentifier: "InfoCell", for: indexPath)
                cell.textLabel?.text = item.title
                cell.textLabel?.numberOfLines = 0
                cell.textLabel?.lineBreakMode = .byWordWrapping
                if #available(iOS 13.0, *) {
                    cell.textLabel?.textColor = .secondaryLabel
                } else {
                    cell.textLabel?.textColor = .gray
                }
                return cell
            case .contact:
                return UITableViewCell()
            case .text:
                if item.key == "gc_set_status" {
                    guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
                        fatalError()
                    }
                    
                    let verboseStatus: String = self.isTemporaryStatus ? "Updating group status...".localizeString(id: "groupchats_updating_status", arguments: []) : self.currentVerboseStatus
                    
                    if self.isIncognitoChat {
                        cell.configure(title: verboseStatus, status: self.currentStatus, entity: .incognitoChat, isTemporary: self.isTemporaryStatus)
                    } else {
                        cell.configure(title: verboseStatus, status: self.currentStatus, entity: .groupchat, isTemporary: self.isTemporaryStatus)
                    }
                    
                    if self.canChangeStatus {
                        cell.accessoryType = .disclosureIndicator
                    } else {
                        cell.accessoryType = .none
                        cell.statusIndicator.rightAnchor.constraint(equalTo: cell.stack.rightAnchor, constant: -40).isActive = true
                    }
                    
                    return cell
                } else {
                    var cell = tableView.dequeueReusableCell(withIdentifier: "TextCell")
                    if cell == nil {
                        cell = UITableViewCell(style: .value1, reuseIdentifier: "TextCell")
                    }
                    cell?.textLabel?.text = item.title
                    cell?.detailTextLabel?.text = item.subtitle
                    if let key = section.key,
                        ["gc_settings", "gc_participants", "gc_status"].contains(key) {
                        cell?.accessoryType = .disclosureIndicator
                        cell?.selectionStyle = .default
                    } else {
                        cell?.accessoryType = .none
                        cell?.selectionStyle = .none
                    }
                    if let key = item.key {
                        switch key {
                        case "gc_invitations": cell?.detailTextLabel?.text = "\(self.invitationsCount)"
                        case "gc_blocked": cell?.detailTextLabel?.text = "\(self.blockedCount)"
                        default: break
                        }
                    }
                    return cell!
                }
            case .button, .danger:
                if item.key == "gc_circles" {
                    guard let cell = tableView.dequeueReusableCell(withIdentifier: EditCirclesCell.cellName, for: indexPath) as? EditCirclesCell else {
                        fatalError()
                    }
                    
                    cell.configure(title: "Circles".localizeString(id: "contact_circle", arguments: []), circles: self.circles)
                    
                    return cell
                }
                let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = item.subtitle
                if item.key == "block_chat_button" {
                    if self.isBlocked {
                        cell.textLabel?.text = "Unblock".localizeString(id: "contact_bar_unblock", arguments: [])
                    } else {
                        cell.textLabel?.text = "Block".localizeString(id: "contact_bar_block", arguments: [])
                    }
                } else if item.key == "notify_chat_button" {
                    if self.isMuted {
                        cell.textLabel?.text = "Enable notifications".localizeString(id: "groupchat_enable_notificaions", arguments: [])
                    } else {
                        cell.textLabel?.text = "Disable notifications".localizeString(id: "groupchats_disable_notifications", arguments: [])
                    }
                }
                if item.kind == .danger {
                    cell.textLabel?.textColor = .systemRed
                    cell.imageView?.tintColor = .systemRed
                } else {
                    cell.textLabel?.textColor = .tintColor
                    cell.imageView?.tintColor = .tintColor
                }
                if let icon = item.icon {
                    cell.imageView?.image = UIImage(systemName: icon)
                }
                return cell
            }
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if datasource[section].kind == .contact {
            var participantsStr: String = "member"
            if self.membersCount > 1 {
//            if (contacts?.count ?? 0) > 1 {
                participantsStr = "members"
            }
            if self.onlineContacts > 0 {
                return "\(self.membersCount) \(participantsStr), \(self.onlineContacts) online"
//                return "\(contacts?.count ?? 0) \(participantsStr), \(self.onlineContacts) online"
            } else {
                return "\(self.membersCount) \(participantsStr)"
//                return "\(contacts?.count ?? 0) \(participantsStr)"
            }
        }
        return datasource[section].title
    }
}

