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
import RealmSwift

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
                cell.imageView?.image = imageLiteral( "contact-add")?.withRenderingMode(.alwaysTemplate)
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
        case .session:
            guard let item = datasource[indexPath.section].childs.first else {
                return UITableViewCell()
            }
            
            let cell = VerificationSessionTableViewCell()
            cell.configure(title: item.title ?? "", subtitle: item.subtitle)
            cell.closeButton.addTarget(self, action: #selector(onCloseVerificationButtonPressed), for: .touchUpInside)
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.jid, sid: activeVerificationSessionSid ?? ""))
                
                switch instance?.state {
                case .receivedRequest:
                    cell.blueButton.setTitle("Proceed to Verification", for: .normal)
                    cell.blueButton.addTarget(self, action: #selector(onAcceptButtonPressed), for: .touchUpInside)
                    cell.labelsStack.addArrangedSubview(cell.blueButton)
                    cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                    break
                case .acceptedRequest:
                    cell.blueButton.setTitle("Show the code", for: .normal)
                    cell.blueButton.addTarget(self, action: #selector(onShowCodePressed), for: .touchUpInside)
                    cell.labelsStack.addArrangedSubview(cell.blueButton)
                    cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                    break
                case .receivedRequestAccept:
                    cell.blueButton.setTitle("Enter the code", for: .normal)
                    cell.blueButton.addTarget(self, action: #selector(onEnterCodePressed), for: .touchUpInside)
                    cell.labelsStack.addArrangedSubview(cell.blueButton)
                    cell.blueButton.leftAnchor.constraint(equalTo: cell.labelsStack.leftAnchor).isActive = true
                    break
                default:
                    break
                }
                
            } catch {
                //
            }

            return cell
            
        default:
            let item = datasource[indexPath.section].childs[indexPath.row]
            
            if let key = item.key {
                switch key {
                case .languages:
                    let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemDetailViewController.SelectorCell.cellName, for: indexPath) as! SettingsItemDetailViewController.SelectorCell
                    cell.configure(key: item.key?.rawValue ?? "",
                                   for: item.title ?? "",
                                   value: TranslationsManager.shared.currentLang ?? "Default", icon: item.icon ?? "", color: item.color ?? .systemRed)
                    return cell
                
                    case .accountSessions:
                        guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceCell.cellName, for: indexPath) as? DeviceCell else {
                            fatalError()
                        }
                        
                        cell.titleLabel.text = item.title
                        if self.accounts?.first?.isDevicesListReceived ?? false {
                            cell.subtitleButton.setTitle("\(sessionsCount)", for: .normal)
                            if self.omemoDeviceWarning {
                                cell.subtitleButton.setImage(UIImage(systemName: "exclamationmark.triangle.fill"), for: .normal)
                                cell.subtitleButton.imageView?.tintColor = .systemRed
                            } else if omemoDeviceActionsRequired {
                                cell.subtitleButton.setImage(UIImage(systemName: "exclamationmark.triangle.fill"), for: .normal)
                                cell.subtitleButton.imageView?.tintColor = .systemOrange
                            } else {
                                cell.subtitleButton.setImage(nil, for: .normal)
                            }
                            
                            cell.subtitleButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -8, bottom: 0, right: 0)
                            cell.subtitleButton.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                            cell.subtitleButton.titleLabel?.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                            cell.subtitleButton.imageView?.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                        } else {
                            cell.subtitleButton.setTitle("    ", for: .normal)
                            let activityIndicator = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
                            activityIndicator.color = UIColor.gray
                            activityIndicator.isHidden = false
                            activityIndicator.startAnimating()
                            activityIndicator.hidesWhenStopped = true
                            cell.subtitleButton.addSubview(activityIndicator)
                        }

                        cell.accessoryType = .disclosureIndicator
                        if let icon = item.icon,
                           let color = item.color {
                            cell.imageView?.image = UIImage(named: icon)?.upscale(dimension: 32).withRenderingMode(.alwaysTemplate)
                            cell.tintColor = color
                        }
                        return cell
                
                case .manageStorage:
                    let cell = UITableViewCell()
                    cell.textLabel?.text = item.title
                    if self.quota.isNotEmpty {
                        cell.detailTextLabel?.text = "\(used) of \(quota)"
                    } else {
//                        cell.detailTextLabel?.text = "    "
                        cell.detailTextLabel?.addSubview(spinner)
                        cell.accessoryType = .disclosureIndicator
                    }
                    cell.accessoryType = .disclosureIndicator
                    if let icon = item.icon,
                       let color = item.color {
                        cell.imageView?.image = UIImage(named: icon)?.upscale(dimension: 32).withRenderingMode(.alwaysTemplate)
                        cell.tintColor = color
                    }
                    return cell
                
                case .subscriptions:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    switch SubscribtionsManager.shared.getState(account: self.jid) {
                        case .active:
                            cell.detailTextLabel?.text = "Premium"
                        case .expired:
                            cell.detailTextLabel?.text = "Expired"
                        case .trial:
                            cell.detailTextLabel?.text = "Trial"
                    }
                    cell.accessoryType = .disclosureIndicator
                    if let icon = item.icon,
                       let color = item.color {
                        cell.imageView?.image = UIImage(named: icon)?.upscale(dimension: 32).withRenderingMode(.alwaysTemplate)
                        cell.tintColor = color
                    }
                    return cell
                
                case .passcode:
                    let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                    cell.textLabel?.text = item.title
                    cell.detailTextLabel?.text = CredentialsManager.shared.isPincodeSetted() ? "On" : "Off"
                    cell.accessoryType = .disclosureIndicator
                    if let icon = item.icon,
                       let color = item.color {
                        cell.imageView?.image = UIImage(named: icon)?.upscale(dimension: 32).withRenderingMode(.alwaysTemplate)
                        cell.tintColor = color
                    }
                    return cell
                    
                default: break
                }
            }
            
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsItem", for: indexPath)
            cell.textLabel?.text = item.title
            cell.accessoryType = .disclosureIndicator
            if let icon = item.icon,
               let color = item.color {
                cell.imageView?.image = UIImage(named: icon)?.upscale(dimension: 32).withRenderingMode(.alwaysTemplate)
                cell.tintColor = color
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
}
