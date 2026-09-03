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

extension CloudStorageViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].children.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].children[indexPath.row]

        switch item.key {
        case "quota_info":
            let cell = tableView.dequeueReusableCell(withIdentifier: QuotaInfoCell.cellName, for: indexPath) as? QuotaInfoCell
            cell?.selectionStyle = .none
            cell?.setup(
                title: item.title,
                owner: jid,
                displayState: currentDisplayState(),
                increaseStorage: CommonConfigManager.shared.config.support_subscribtions
                    ? currentInlineUpsellState()
                    : nil,
                onIncreaseStorage: { [weak self] in
                    self?.openPremiumSubscription()
                }
            )
            return cell!
        case "category_grid":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: CloudStorageCategoryGridCell.cellName,
                for: indexPath
            ) as! CloudStorageCategoryGridCell
            let valueIsLoading = currentDisplayState() == .loading
            cell.configure(
                items: CloudStorageOverviewCategory.allCases.map { category in
                    CloudStorageCategoryGridItem(
                        category: category,
                        value: valueIsLoading ? nil : categoryValue(for: category)
                    )
                },
                onSelect: { [weak self] category in
                    self?.openStorageCategory(category)
                }
            )
            return cell
        case "delete_files":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
            var listContentConfiguration = cell.defaultContentConfiguration()
            listContentConfiguration.text = item.title
            listContentConfiguration.textProperties.color = .systemRed
            listContentConfiguration.image = UIImage(systemName: "trash.fill")
            listContentConfiguration.imageProperties.tintColor = .systemRed
            cell.selectionStyle = .default
            if !canFreeUpSpace() {
                cell.selectionStyle = UITableViewCell.SelectionStyle.none
                listContentConfiguration.textProperties.color = .systemGray
                listContentConfiguration.imageProperties.tintColor = .systemGray
            }
            cell.contentConfiguration = listContentConfiguration
            cell.accessibilityIdentifier = "cloudStorage.freeUpSpace"
            return cell
        default:
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
    }
}
