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

extension AccountBlockListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isGroupchatInvitation,
              let item = datasource?[indexPath.row] else {
            return
        }

        let route = AccountBlockListInteractionPolicy.contactRoute(
            owner: item.owner,
            jid: item.jid,
            conversationType: ClientSynchronizationManager.ConversationType(
                rawValue: CommonConfigManager.shared.config.locked_conversation_type
            ) ?? .regular
        )
        let viewController = ContactInfoViewController()
        viewController.owner = route.owner
        viewController.jid = route.jid
        viewController.conversationType = route.conversationType
        showModal(viewController, parent: self)
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = datasource?[indexPath.row] else {
            return nil
        }

        let actions = AccountBlockListInteractionPolicy.trailingActions.map { action in
            switch action {
            case .unblock:
                let contextualAction = UIContextualAction(
                    style: .destructive,
                    title: "Unblock".localizeString(
                        id: "contact_bar_unblock",
                        arguments: []
                    )
                ) { _, _, completion in
                    AccountManager.shared.find(for: item.owner)?.action { user, stream in
                        user.blocked.unblockContact(stream, jid: item.jid)
                    }
                    completion(true)
                }
                contextualAction.image = UIImage(systemName: "person.crop.circle.badge.checkmark")
                return contextualAction

            case .report:
                let contextualAction = UIContextualAction(
                    style: .normal,
                    title: "Report User".localizeString(
                        id: "report_user_action",
                        arguments: []
                    )
                ) { [weak self] _, _, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    let viewController = AbuseReportViewController()
                    viewController.configureUserReport(
                        owner: item.owner,
                        jid: item.jid,
                        reportedUserJid: item.jid,
                        roomJid: nil,
                        conversationType: .regular
                    )
                    showModal(viewController, parent: self)
                    completion(true)
                }
                contextualAction.image = UIImage(systemName: "exclamationmark.bubble")
                contextualAction.backgroundColor = .systemOrange
                return contextualAction
            }
        }

        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
