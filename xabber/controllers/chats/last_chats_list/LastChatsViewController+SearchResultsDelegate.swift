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

extension LastChatsViewController: SearchResultsDelegateProtocol {
    func openChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.stackNewChat(owner: owner, jid: jid, conversationType: conversationType)
    }

    internal func openSearchResult(_ item: SearchResultsViewController.Datasource) {
        InPlaceSearchResultRouteHelper.open(
            item,
            updater: chatSearchResultsController,
            dismissSearch: { [weak self] in
                self?.dismissBottomSearchForRoute()
            },
            reload: { [weak self] in
                self?.reloadInPlaceSearchResultsIfNeeded()
            },
            onUnavailable: { [weak self] presentation in
                self?.presentUnavailableSearchResult(presentation)
            },
            openNewChat: { [weak self] item, openMessageRequest, completion in
                self?.stackNewChat(
                    owner: item.owner,
                    jid: item.jid,
                    conversationType: item.conversationType,
                    openMessageRequest: openMessageRequest
                ) { chatVc in
                    completion(chatVc)
                }
            }
        )
    }

    private func presentUnavailableSearchResult(
        _ presentation: LastChatsSearchUnavailablePresentation
    ) {
        let alert = UIAlertController(
            title: presentation.title,
            message: presentation.message,
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = presentation.accessibilityIdentifier
        alert.addAction(
            UIAlertAction(
                title: "OK".localizeString(id: "ok", arguments: []),
                style: .default
            )
        )
        present(alert, animated: true)
    }
}
