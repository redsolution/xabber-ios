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

extension ContactInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .text:
            let cell = tableView.dequeueReusableCell(withIdentifier: "TextCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.subtitle
            return cell
        case .resource:
            fatalError()
        case .vcard:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: VCardCell.cellName,
                for: indexPath
            ) as? VCardCell else {
                fatalError()
            }
            cell.configure(title: item.title, subtitle: item.subtitle)
            return cell
        case .button:
            if item.key == "circles" {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: EditCirclesCell.cellName, for: indexPath) as? EditCirclesCell else {
                    fatalError()
                }
                
                cell.configure(icon: item.icon, title: item.title, circles: circles)
                
                return cell
            }
            
            if item.key == "fingerprints",
               let dcell =  tableView.dequeueReusableCell(withIdentifier: SettingsViewController.DeviceCell.cellName, for: indexPath) as? SettingsViewController.DeviceCell {
                
                dcell.subtitleButton.setTitle(item.subtitle, for: .normal)
                if let image = item.image {
                    dcell.subtitleButton.setImage(image, for: .normal)
                    dcell.subtitleButton.imageView?.tintColor = item.color
                } else {
                    dcell.subtitleButton.setImage(nil, for: .normal)
                }
                
                dcell.titleLabel.text = item.title
                
                dcell.subtitleButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -8, bottom: 0, right: 0)
                dcell.subtitleButton.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                dcell.subtitleButton.titleLabel?.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                dcell.subtitleButton.imageView?.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                dcell.accessoryType = .disclosureIndicator
                return dcell
            } else if item.key == "delete_chat_button" {
                let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
                var contentConfig = UITableViewCell().defaultContentConfiguration()
                
                contentConfig.text = item.title
                contentConfig.secondaryText = item.subtitle
                if item.key == "block_chat_button" {
                    if self.isBlocked {
                        contentConfig.text = "Unblock".localizeString(id: "contact_bar_unblock", arguments: [])
                    } else {
                        contentConfig.text = "Block".localizeString(id: "contact_bar_block", arguments: [])
                    }
                } else if item.key == "notify_chat_button" {
                    if self.isMuted {
                        contentConfig.text = "Enable notifications".localizeString(id: "groupchat_enable_notificaions", arguments: [])
                    } else {
                        contentConfig.text = "Disable notifications".localizeString(id: "groupchats_disable_notifications", arguments: [])
                    }
                }
                contentConfig.textProperties.color = .systemRed
                cell.contentConfiguration = contentConfig
                
                return cell
            } else if item.key == "reject_verification" {
                let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
                var contentConfig = UITableViewCell().defaultContentConfiguration()
                contentConfig.textProperties.color = .systemRed
                contentConfig.text = item.title
                cell.contentConfiguration = contentConfig
                
                return cell
            } else {
                let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
                var contentConfig = UITableViewCell().defaultContentConfiguration()
                
                contentConfig.text = item.title
                contentConfig.secondaryText = item.subtitle
                if let icon = item.icon {
                    contentConfig.image = UIImage(systemName: icon)
                    contentConfig.imageProperties.tintColor = item.isDanger ? .systemRed : .tintColor
                }
                if item.key == "block_chat_button" {
                    if self.isBlocked {
                        contentConfig.text = "Unblock".localizeString(id: "contact_bar_unblock", arguments: [])
                    } else {
                        contentConfig.text = "Block".localizeString(id: "contact_bar_block", arguments: [])
                    }
                    contentConfig.textProperties.color = item.isDanger ? .systemRed : .tintColor
                    
                } else if item.key == "notify_chat_button" {
                    if self.isMuted {
                        contentConfig.text = "Enable notifications".localizeString(id: "groupchat_enable_notificaions", arguments: [])
                    } else {
                        contentConfig.text = "Disable notifications".localizeString(id: "groupchats_disable_notifications", arguments: [])
                    }
                    contentConfig.textProperties.color = item.isDanger ? .systemRed : .tintColor
                    
                } else {
                    cell.accessoryType = .disclosureIndicator
                }
                
                if let subtitle = item.subtitle {
                    contentConfig.secondaryText = subtitle
                    contentConfig.secondaryTextProperties.color = .systemGray
                    contentConfig.secondaryTextProperties.font = contentConfig.textProperties.font
                    contentConfig.prefersSideBySideTextAndSecondaryText = true
                }
                
                cell.contentConfiguration = contentConfig
                
                return cell
            }
        case .session:
            let cell = VerificationSessionTableViewCell()
            cell.configure(title: item.title, subtitle: item.subtitle)
            cell.closeButton.addTarget(self, action: #selector(onCloseVerificationButtonPressed), for: .touchUpInside)
            
            switch activeVerificationSession?.state {
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
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let title = datasource[section].title
        return title.isEmpty ? nil : title
    }
    
//    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
//        if datasource[section].key == "about_section" {
//            return "View full vCard"
//        }
//        return nil
//    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        if datasource[section].key == "about_section" {
//            let label = UILabel()
            let button = UIButton()
            let attrsString = NSMutableAttributedString(string: "View full vCard".localizeString(id: "contact_view_full_vcard", arguments: []))
            let range = NSRange(location: 0, length: attrsString.string.count)
            attrsString.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
            attrsString.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .footnote), range: range)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
//            paragraph.lineHeightMultiple = 1.27
            attrsString.addAttribute(.paragraphStyle, value: paragraph, range: range)
            button.setAttributedTitle(attrsString, for: .normal)
            button.frame = CGRect(width: tableView.frame.width, height: 44)
            button.contentHorizontalAlignment = .left
            button.titleEdgeInsets = UIEdgeInsets(top: 0, bottom: 0, left: 20, right: 0)
            button.addTarget(self, action: #selector(showFullVCard), for: .touchUpInside)
            return button
        }
        return nil
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
//        let value = scrollView.contentOffset.y
////        self.scrollViewContentOffsetYCopy = value
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
//                self.headerView.frame = CGRect(x: 0, y: -(value + headerHeightMax - 64), width: view.frame.width, height: headerHeightMax)
//            }
//        }
    }
}
