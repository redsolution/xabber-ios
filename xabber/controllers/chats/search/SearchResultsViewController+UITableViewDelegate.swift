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
import RealmSwift
import CocoaLumberjack

extension SearchResultsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        if self.chatsDatasource.count > 0 {
//            
//        }
        let item: Datasource
        
        if self.chatsDatasource.count > 0 {
            switch indexPath.section {
                case 0: item = self.chatsDatasource[indexPath.row]
                case 1: item = self.messagesDatasource[indexPath.row]
                default: fatalError()
            }
        } else {
            item = self.messagesDatasource[indexPath.row]
        }
        
        let vc = ChatViewController()
        vc.owner = item.owner
        vc.jid = item.jid
        vc.conversationType = item.conversationType
        showStacked(vc, in: self.presenter ?? self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let archivedId = item.messageArchiveId {
                vc.scrollToMessageAtIndex(archivedId: archivedId, date: item.date ?? Date())
            }
        }
    }
}
