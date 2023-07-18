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

extension NewEntityViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        if contacts?.isEmpty ?? true {
            return 2
        }
        return 3
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return datasource.count
        case 1: return 1
//        case 1: return contacts?.count ?? 0
        default: return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ItemCell.cellName,
                                     for: indexPath) as? ItemCell else {
                fatalError()
            }
            
            cell.configure(.button,
                           title: datasource[indexPath.row].title,
                           icon: datasource[indexPath.row].icon,
                           editable: true,
                           last: false)
            
            return cell
        case 1:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ItemCell.cellName,
                                     for: indexPath) as? ItemCell else {
                fatalError()
            }
            
            cell.configure(.button,
                           title: "Scan QR Code".localizeString(id: "scan_qr_code", arguments: []),
                           icon: #imageLiteral(resourceName: "qrcode-scan").withRenderingMode(.alwaysTemplate),
                           editable: true,
                           last: true)
            
            return cell
        case 2:
            guard let item = contacts?[indexPath.row],
                let cell = tableView
                .dequeueReusableCell(withIdentifier: ContactCell.cellName,
                                     for: indexPath) as? ContactCell else {
                fatalError()
            }
            let primaryResource = item.getPrimaryResource()
            cell.configure(item.jid,
                           username: item.displayName,
                           indicatorColor: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                           status: primaryResource?.status ?? .offline,
                           entity: primaryResource?.entity ?? .contact,
                           avatarKey: item.jid)
            cell.setMask()
            
            return cell
        default: fatalError()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
            case 0: return nil
//            case 1: return "Recent contacts"
            default: return nil
        }
    }
}
