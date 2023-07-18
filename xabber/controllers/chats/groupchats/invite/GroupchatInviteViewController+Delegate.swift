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

protocol GroupchatInviteViewControllerDelegate {
    func onCollapse(group: String)
    func onSelect(group: String)
}

extension GroupchatInviteViewController: GroupchatInviteViewControllerDelegate {
    func onCollapse(group: String) {
        if collapsedGroups.value.contains(group) {
            var values = collapsedGroups.value
            values.remove(group)
            collapsedGroups.accept(values)
            if let index = self.datasource.firstIndex(where: { $0.name == group }) {
//                let indexSet = IndexSet( [index] )
//                self.tableView.reloadSections(indexSet, with: .automatic)
                if #available(iOS 11.0, *) {
                    self.tableView.performBatchUpdates({
                        self.tableView.insertRows(at: (0..<self.datasource[index].childs.count).compactMap { return IndexPath(row: $0, section: index)}, with: .none)
                    }, completion: nil)
                } else {
                    self.tableView.beginUpdates()
                    self.tableView.insertRows(at: (0..<self.datasource[index].childs.count).compactMap { return IndexPath(row: $0, section: index)}, with: .none)
                    self.tableView.endUpdates()
                }
                
            }
        } else {
            var values = collapsedGroups.value
            values.insert(group)
            collapsedGroups.accept(values)
            if let index = self.datasource.firstIndex(where: { $0.name == group }) {
//                let indexSet = IndexSet( [index] )
//                self.tableView.reloadSections(indexSet, with: .automatic)
                
                if #available(iOS 11.0, *) {
                    self.tableView.performBatchUpdates({
                        self.tableView.deleteRows(at: (0..<self.datasource[index].childs.count).compactMap { return IndexPath(row: $0, section: index)}.sorted(), with: .none)
                    }, completion: nil)
                } else {
                    self.tableView.beginUpdates()
                    self.tableView.deleteRows(at: (0..<self.datasource[index].childs.count).compactMap { return IndexPath(row: $0, section: index)}.sorted(), with: .none)
                    self.tableView.endUpdates()
                }
            }
        }
//        if let index = self.datasource.firstIndex(where: { $0.name == group }) {
//            let indexSet = IndexSet( [index] )
//            self.tableView.reloadSections(indexSet, with: .automatic)
//        }
//        self.tableView.reload
    }
    
    func onSelect(group: String) {
        if let selectedGroup = datasource.first(where: {  $0.name == group }) {
            if selectedGroups.value.contains(group) {
                selectedGroup
                    .childs
                    .compactMap { return $0.jid }
                    .forEach {
                        var values = selectedJids.value
                        values.remove($0)
                        selectedJids.accept(values)
                    }
                
                var values = selectedGroups.value
                values.remove(group)
                selectedGroups.accept(values)
            } else {
                selectedGroup
                    .childs
                    .compactMap { return $0.jid }
                    .forEach {
                        var values = selectedJids.value
                        values.insert($0)
                        selectedJids.accept(values)
                    }
                var values = selectedGroups.value
                values.insert(group)
                selectedGroups.accept(values)
            }
            if let section = datasource.firstIndex(of: selectedGroup) {
                if #available(iOS 11.0, *) {
                    self.tableView.performBatchUpdates({
                        self.tableView.reloadRows(at: (0..<datasource[section].childs.count).compactMap { return IndexPath(row: $0, section: section)}, with: .none)
//                        self.tableView.reloadSections(IndexSet([section]), with: .automatic)
                    }, completion: nil)
                } else {
                    self.tableView.beginUpdates()
//                    self.tableView.reloadSections(IndexSet([section]), with: .automatic)
                    self.tableView.reloadRows(at: (0..<datasource[section].childs.count).compactMap { return IndexPath(row: $0, section: section)}, with: .none)
                    self.tableView.endUpdates()
                }
            }
        }
    }
}
