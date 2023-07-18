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

extension SettingsViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch datasource[section].section {
        case .xmppAccounts: return (accounts?.count ?? 0) + 1
        default: return datasource[section].childs.count
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        switch datasource[indexPath.section].section {
        
        case .xmppAccounts:
            if indexPath.row == (accounts?.count ?? 0) {
                let cell = tableView.dequeueReusableCell(withIdentifier: "AddAccountCell", for: indexPath)
                cell.textLabel?.text = "Add Account".localizeString(id: "account_add", arguments: [])
                cell.textLabel?.textColor = .systemBlue
                cell.imageView?.tintColor = .systemBlue
                cell.imageView?.image = #imageLiteral(resourceName: "contact-add").withRenderingMode(.alwaysTemplate)
                return cell
            }
            guard let item = accounts?[indexPath.row],
                let cell = tableView.dequeueReusableCell(withIdentifier: AccountCell.cellName, for: indexPath) as? AccountCell else {
                fatalError()
            }
            cell.configure(jid: item.jid,
                           username: item.username,
                           status: item.resource?.status ?? .offline,
                           statusText: item.statusMessage,
                           enabled: item.enabled)
            return cell
        
        default:
            let item = datasource[indexPath.section].childs[indexPath.row]
            
            if let key = item.key {
                switch key {
                case .languages:
                    let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemDetailViewController.SelectorCell.cellName, for: indexPath) as! SettingsItemDetailViewController.SelectorCell
                    cell.configure(key: item.key?.rawValue ?? "",
                                   for: item.title ?? "",
                                   value: TranslationsManager.shared.currentLang ?? "Default")
                    return cell
                
                case .accountSessions:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    
                    if self.accounts?.first?.isDevicesListReceived ?? false {
                        cell.detailTextLabel?.text = "\(sessionsCount)"
                    } else {
                        cell.detailTextLabel?.text = "    "
                        cell.detailTextLabel?.addSubview(spinner2)
                    }
                    cell.accessoryType = .disclosureIndicator
                    return cell
                
                case .manageStorage:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    if self.quota.isNotEmpty {
                        cell.detailTextLabel?.text = "\(used) of \(quota)"
                    } else {
                        cell.detailTextLabel?.text = "    "
                        cell.detailTextLabel?.addSubview(spinner)
                        cell.accessoryType = .disclosureIndicator
                    }
                    cell.accessoryType = .disclosureIndicator
                    return cell
                
                case .subscriptions:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    let trial = SubscribtionsManager.shared.trialEnd
                    let subscribtion = SubscribtionsManager.shared.subscribtionEnd
                    if trial != nil {
                        cell.detailTextLabel?.text = "Trial"// until \(dateFormatter.string(from: date))"
                    } else if subscribtion != nil {
                        cell.detailTextLabel?.text = "Premium"// at \(dateFormatter.string(from: date))"
                    } else {
                        cell.detailTextLabel?.text = "Expired" // at \(dateFormatter.string(from: date))"
                    }
                    
                    cell.accessoryType = .disclosureIndicator
                    return cell
                
                case .passcode:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    cell.detailTextLabel?.text = CredentialsManager.shared.isPincodeSetted() ? "On" : "Off"
                    cell.accessoryType = .disclosureIndicator
                    return cell
                
                default: break
                }
            }
            
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsItem", for: indexPath)
            cell.textLabel?.text = item.title
            cell.accessoryType = .disclosureIndicator
            if let asset = item.assetReference {
                cell.imageView?.image = #imageLiteral(resourceName: asset).withRenderingMode(.alwaysTemplate)
            }
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        
        guard datasource.isNotEmpty else { return false }
        
        switch datasource[indexPath.section].section {
        case .xmppAccounts:
            if indexPath.row == (accounts?.count ?? 0) {
                return false
            }
            return true
        default:
            return false
        }
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        switch datasource[indexPath.section].section {
        case .xmppAccounts:
            if indexPath.row == (accounts?.count ?? 0) {
                return false
            }
            return true
        default:
            return false
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return datasource[section].subtitle
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let value = scrollView.contentOffset.y
        self.scrollViewContentOffsetYCopy = value

        if value < 0 {
            UIView.performWithoutAnimation {
                self.headerView.frame = CGRect(x: 0, y: -(value + headerHeightMax - 20), width: view.frame.width, height: headerHeightMax)
            }
        }
    }
}
