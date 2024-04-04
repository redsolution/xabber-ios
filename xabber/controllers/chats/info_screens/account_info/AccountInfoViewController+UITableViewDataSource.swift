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
import CocoaLumberjack

extension AccountInfoViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section < datasource.count {
//            if datasource[section].kind == .resource {
//                return resources?.count ?? 0
//            }
            return datasource[section].childs.count
        } else {
            let item = tokensDatasource[section - datasource.count]
        
            switch item.kind {
            case .current, .button, .text:
                return item.childs.count
            case .token:
                return tokens?.count ?? 0
            }
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count + tokensDatasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
//        func getQuotaDetails(successCallback: @escaping ((Int, Int, Int, Int, Int) -> Void)) {
//            do {
//                let realm = try WRealm.safe()
//                guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self,
//                                                   forPrimaryKey: self.jid) else {
//                    if let account = AccountManager.shared.find(for: self.jid),
//                       let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol {
//                        uploader.getQuotaInfo() {
//                            getQuotaDetails() { rawImages, rawVideos, rawFiles, rawAudio, rawQuota in
//                                successCallback(rawImages, rawVideos, rawFiles, rawAudio, rawQuota)
//                            }
//                        }
//                    }
//                    return
//                }
//                let rawImages = quotaItem.rawImages
//                let rawVideos = quotaItem.rawVideos
//                let rawFiles = quotaItem.rawFiles
//                let rawAudio = quotaItem.rawVoices
//                let rawQuota = quotaItem.rawQuota
//
//                successCallback(rawImages, rawVideos, rawFiles, rawAudio, rawQuota)
//            } catch {
//                DDLogDebug("AccountInfoViewController: \(#function). \(error.localizedDescription)")
//            }
//        }
        
        if indexPath.section >= datasource.count {
            var item = tokensDatasource[indexPath.section - datasource.count]

            switch item.kind {
            case .current, .button:
                item = item.childs[indexPath.row]
                switch item.kind {
                case .token, .current, .text:
                    guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell,
                          let token = tokenInstance else {
                        return UITableViewCell(frame: .zero)
                    }
                    cell.configure(
                        client: token.client,
                        device: token.device,
                        description: token.descr,
                        ip: token.ip,
                        lastAuth: token.authDate,
                        current: true,
                        editable: false,
                        isOnline: token.resource != nil
                    )
                    cell.accessoryType = .none
                    return cell
                case .button:
                    guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                        return UITableViewCell(frame: .zero)
                    }
                    cell.configure(for: item.title, style: .danger)
                    return cell
                }
            
            case .token:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell,
                    let tokenItem = tokens?[indexPath.row] else {
                        return UITableViewCell(frame: .zero)
                }
                cell.configure(
                    client: tokenItem.client,
                    device: tokenItem.device,
                    description: tokenItem.descr,
                    ip: tokenItem.ip,
                    lastAuth: tokenItem.authDate,
                    current: false,
                    editable: false,
                    isOnline: tokenItem.resource != nil
                )
                cell.accessoryType = .none
                return cell
            
            case .text:
                item = item.childs[indexPath.row]
                switch item.kind {
                case .token, .current, .text:
                    return UITableViewCell()
                case .button:
                    guard let cell = tableView.dequeueReusableCell(withIdentifier: CenterButtonTableViewCell.cellName, for: indexPath) as? CenterButtonTableViewCell else {
                        return UITableViewCell(frame: .zero)
                    }
                    cell.configure(for: item.title, style: .danger)
                    return cell
                }
            }
        }
        
        let item = datasource[indexPath.section].childs[indexPath.row]
        
        if let key = item.key {
            switch key {
            case .manageStorage:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = "\(used) of \(quota)"
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
        
        
//        if datasource[indexPath.section].kind == .resource {
//            guard let resource = self.resources?[indexPath.row],
//                let cell = tableView.dequeueReusableCell(withIdentifier: ResourceInfoCell.cellName,
//                                                         for: indexPath) as? ResourceInfoCell else {
//                fatalError()
//            }
//            cell.configure(title: resource.displayedStatus, subtitle: resource.resource, status: resource.status, entity: resource.entity)
//            if resource.isCurrentResourceForAccount {
//                let resourceString = [resource.resource, "(this device)".localizeString(id: "settings_account__label_this_device_in_brackets", arguments: [])].joined(separator: " ")
//                let fullRange = NSRange(location: 0,
//                                        length: NSString(string: resourceString).length)
//                let additionalRange = NSRange(location: NSString(string: resource.resource).length,
//                                              length: NSString(string: " (this device)".localizeString(id: "settings_account__label_this_device_in_brackets", arguments: [])).length)
//                let resourceRange = NSRange(location: 0,
//                                            length: NSString(string: resource.resource).length)
//                let attributedResource = NSMutableAttributedString(string: resourceString)
//                attributedResource.addAttribute(.font,
//                                                value: UIFont.preferredFont(forTextStyle: .caption1),
//                                                range: fullRange)
//                if #available(iOS 13.0, *) {
//                    attributedResource.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: resourceRange)
//                } else {
//                    attributedResource.addAttribute(.foregroundColor, value: MDCPalette.grey.tint500, range: resourceRange)
//                }
//                attributedResource.addAttribute(.foregroundColor, value: UIColor.systemRed, range: additionalRange)
//                cell.subtitleLabel.attributedText = attributedResource
//            }
//            return cell
//        } else if datasource[indexPath.section].kind == .storage {
//            let item = datasource[indexPath.section].childs[indexPath.row]
//            switch item.kind {
//            case .storage:
//                guard let cell = tableView.dequeueReusableCell(withIdentifier: QuotaInfoCell.cellName,
//                                                               for: indexPath) as? QuotaInfoCell else {
//                    fatalError()
//                }
//                cell.selectionStyle = .none
//
//                getQuotaDetails() { rawImages, rawVideos, rawFiles, rawAudio, rawQuota in
//                    cell.setup(title: item.title,
//                               owner: self.jid,
//                               requiresDataFromServer: true,
//                               quotaDelegate: self)
//                }
//                return cell
//            case .text:
//                var cell = tableView.dequeueReusableCell(withIdentifier: "TextCell")
//                if cell == nil {
//                    cell = UITableViewCell(style: .value1, reuseIdentifier: "TextCell")
//                }
//                cell?.textLabel?.text = item.title
//                cell?.detailTextLabel?.text = item.subtitle
//                cell?.accessoryType = .disclosureIndicator
//
//                return cell!
//            case .status, .button, .resource:
//                fatalError()
//            }
//        } else {
//            let item = datasource[indexPath.section].childs[indexPath.row]
//            switch item.kind {
//            case .text:
//                    var cell = tableView.dequeueReusableCell(withIdentifier: "TextCell")
//                    if cell == nil {
//                        cell = UITableViewCell(style: .value1, reuseIdentifier: "TextCell")
//                    }
//                    cell?.textLabel?.text = item.title
//                    cell?.detailTextLabel?.text = item.subtitle
//                    cell?.accessoryType = .disclosureIndicator
//                    if let key = item.key {
//                        switch key {
//                        case "account_color": cell?.detailTextLabel?.text = AccountColorManager.shared.colorItem(for: self.jid).title
//                        case "account_sessions": cell?.detailTextLabel?.text = "\(self.sessionsCount)"
//                        case "account_groupchat_invitations": cell?.detailTextLabel?.text = "\(self.groupchatInvitationsCount)"
//                        case "account_blocked_contacts": cell?.detailTextLabel?.text = "\(self.blockedContactsCount)"
//                        default: break
//                        }
//                    }
//                    return cell!
//            case .status:
//                guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
//                    fatalError()
//                }
//                if let currentResource = self.currentResource,
//                    let resource = self.resources?.first(where: { $0.resource == currentResource }) {
//                    cell.configure(title: resource.displayedStatus, status: resource.status, entity: resource.entity, isTemporary: resource.isTemporary)
//                } else {
//                    cell.configure(title: "Offline".localizeString(id: "unavailable", arguments: []), status: .offline, entity: .contact, isTemporary: false)
//                }
//                return cell
//            case .resource, .storage:
//                fatalError()
//            case .button:
//                let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
//                cell.textLabel?.text = item.title
//                cell.detailTextLabel?.text = item.subtitle
//
//                if item.key == "account_quit" {
//                    cell.textLabel?.textColor = .systemRed
//                } else {
//                    cell.textLabel?.textColor = .systemBlue
//                }
//                return cell
//            }
//        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section < datasource.count {
            //return datasource[section].title.isNotEmpty ? datasource[section].title : nil
            return datasource[section].title
        } else {
            if section - datasource.count == 1 && self.tokens?.count == 1 {
                return nil
            }
            return tokensDatasource[section - datasource.count].title
        }
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section < datasource.count {
            return datasource[section].subtitle
        } else {
            if self.tokens?.isEmpty ?? true {
                return nil
            }
            return tokensDatasource[section - datasource.count].value
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
//        let value = scrollView.contentOffset.y
//        self.scrollViewContentOffsetYCopy = value
//        var height = abs(value)
//        print(value)
//        if height > self.headerHeightMax {
//            height = self.headerHeightMax
//        }
//        if height < self.headerHeightMin {
//            height = self.headerHeightMin
//            self.navigationController?.setNavigationBarHidden(false, animated: true)
//        }
//        if value < 0 {
//            UIView.performWithoutAnimation {
////                self.headerView.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: height)
////                self.headerView.update()
//                self.headerView.frame = CGRect(x: 0, y: -(value + headerHeightMax - 20), width: view.frame.width, height: headerHeightMax)
//            }
//        }
    }
}
