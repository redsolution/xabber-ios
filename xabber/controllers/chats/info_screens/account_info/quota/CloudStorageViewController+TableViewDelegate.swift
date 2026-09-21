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

extension CloudStorageViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let key = datasource[indexPath.section].children[indexPath.row].key
        if key == "quota_info" {
            return UITableView.automaticDimension
        }
        if key == "category_grid" {
            return UITableView.automaticDimension
        }
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        func showConfirmationToDelete(percent: Int) {
            let viewController = FileDeletionConfirmation(percent: percent, owner: self.jid)
            self.navigationController?.pushViewController(viewController, animated: true)
        }

        let item = datasource[indexPath.section].children[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        switch item.key {
        case "delete_files":
            if !canFreeUpSpace() {
                return
            }
            let freeQuotaAsPercentage = freeQuotaPercentage()
            let deleteItems = CloudStorageCleanupPolicy.supportedPercents.map { percent in
                ActionSheetPresenter.Item(
                    destructive: false,
                    title: L10n.format("cloud_storage__overview__free_up_of_space", fallback: "Free up %@%% of space", arguments: [String(describing: percent)]),
                    value: "\(percent)percent",
                    isEnabled: CloudStorageCleanupPolicy.isEnabled(
                        percent: percent,
                        currentFreePercent: freeQuotaAsPercentage
                    )
                )
            }

            ActionSheetPresenter()
                .present(in: self,
                         title: L10n.text("cloud_storage__overview__free_up_space", fallback: "Free up space"),
                         message: "Select how much space you want to free up on your cloud storage:".localizeString(id: "account_which_files_to_delete", arguments: []), // "Choose how many files will be deleted to free up space (as a percentage)"
                         cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                         values: deleteItems,
                         animated: true
                ) { result in

                    guard let rawPercent = result.components(separatedBy: "percent").first,
                          let percent = Int(rawPercent),
                          CloudStorageCleanupPolicy.supportedPercents.contains(percent) else {
                        return
                    }
                    showConfirmationToDelete(percent: percent)
                }
            return
        default:
            break
        }
    }

    func openStorageCategory(_ category: CloudStorageOverviewCategory) {
        guard canOpenStorageSection() else { return }
        let viewController = CloudStorageGalleryViewController(category: category, owner: jid)
        navigationController?.pushViewController(viewController, animated: true)
    }

    func openPremiumSubscription() {
        guard currentInlineUpsellState() != nil else { return }
        let viewController = PremiumSubscribtionViewController()
        viewController.owner = jid
        viewController.jid = jid
        navigationController?.pushViewController(viewController, animated: true)
    }

    private func canOpenStorageSection() -> Bool {
        switch currentDisplayState() {
        case .content, .empty, .unlimited:
            return true
        case .loading, .error, .unavailable:
            return false
        }
    }
}
