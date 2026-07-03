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

extension LastChatsViewController {
    internal enum SwipeActionKind: CaseIterable {
        case delete
        case archive
        case unarchive
        case mute
        case unmute
        case block
        case pin
        case call

        var iconName: String {
            switch self {
            case .delete:
                return "trash"
            case .archive:
                return "archivebox.fill"
            case .unarchive:
                return "archivebox"
            case .mute:
                return "bell.slash"
            case .unmute:
                return "bell"
            case .block:
                return "hand.raised.fill"
            case .pin:
                return "pin"
            case .call:
                return "phone.fill"
            }
        }
    }

    internal struct SwipeActionDescriptor {
        let kind: SwipeActionKind
        let style: UIContextualAction.Style
        let title: String
        let image: UIImage?
        let backgroundColor: UIColor
    }

    internal static let swipeActionIconNames = SwipeActionKind.allCases.map(\.iconName)

    internal static func swipeActionDescriptor(for kind: SwipeActionKind) -> SwipeActionDescriptor {
        LastChatsSwipeActionAssetCache.descriptor(for: kind)
    }

    internal static func canShowCallAction(for item: Datasource) -> Bool {
        guard item.specialMessageKind == .none else { return false }
        return [.regular, .omemo, .omemo1, .axolotl].contains(item.conversationType)
    }

    internal static func canShowBlockAction(for item: Datasource) -> Bool {
        guard item.specialMessageKind == .none else { return false }
        return ![.saved, .notifications].contains(item.conversationType)
    }

    internal static func trailingSwipeActionKinds(for item: Datasource, filter: Filter) -> [SwipeActionKind] {
        guard item.specialMessageKind == .none else {
            return []
        }
        var kinds: [SwipeActionKind] = filter == .archived
            ? [.unarchive, .delete, item.isMute ? .unmute : .mute]
            : [.archive, .delete, item.isMute ? .unmute : .mute]
        if canShowBlockAction(for: item) {
            kinds.append(.block)
        }
        return kinds
    }

    internal static func leadingSwipeActionKinds(for item: Datasource) -> [SwipeActionKind] {
        guard item.specialMessageKind == .none else {
            return []
        }
        var kinds: [SwipeActionKind] = [.pin]
        if canShowCallAction(for: item) {
            kinds.append(.call)
        }
        return kinds
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = self.item(at: indexPath),
              item.specialMessageKind == .none,
              AccountManager.shared.connectingUsers.value.isEmpty else {
            return nil
        }
        let actions = Self.trailingSwipeActionKinds(for: item, filter: filter.value).map {
            makeSwipeAction(kind: $0, item: item)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = self.item(at: indexPath),
              item.specialMessageKind == .none,
              AccountManager.shared.connectingUsers.value.isEmpty else {
            return nil
        }
        let actions = Self.leadingSwipeActionKinds(for: item).map {
            makeSwipeAction(kind: $0, item: item)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    private func makeSwipeAction(kind: SwipeActionKind, item: Datasource) -> UIContextualAction {
        let descriptor = Self.swipeActionDescriptor(for: kind)
        let action = UIContextualAction(style: descriptor.style, title: descriptor.title) { [weak self] _, _, handler in
            guard let self else {
                handler(false)
                return
            }
            switch kind {
            case .delete:
                self.onDelete(
                    item.jid,
                    owner: item.owner,
                    conversationType: item.conversationType,
                    displayName: item.username
                )
            case .archive:
                self.onArchive(
                    item.jid,
                    owner: item.owner,
                    conversationType: item.conversationType,
                    reverse: false
                )
            case .unarchive:
                self.onArchive(
                    item.jid,
                    owner: item.owner,
                    conversationType: item.conversationType,
                    reverse: true
                )
            case .mute, .unmute:
                self.onChangeNotifications(
                    jid: item.jid,
                    owner: item.owner,
                    isMuted: item.isMute,
                    conversationType: item.conversationType
                )
            case .block:
                self.onBlock(jid: item.jid, owner: item.owner, displayName: item.username)
            case .pin:
                self.pinChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType)
            case .call:
                self.onCall(jid: item.jid, owner: item.owner)
            }
            handler(true)
        }
        action.image = descriptor.image
        action.backgroundColor = descriptor.backgroundColor
        return action
    }
}

private enum LastChatsSwipeActionAssetCache {
    private static let images: [LastChatsViewController.SwipeActionKind: UIImage] = Dictionary(
        uniqueKeysWithValues: LastChatsViewController.SwipeActionKind.allCases.compactMap { kind in
            guard let image = imageLiteral(kind.iconName)?.withRenderingMode(.alwaysTemplate) else {
                return nil
            }
            return (kind, image)
        }
    )

    // Current localization is process-lifetime stable; centralize titles so delegate snapshots do not localize repeatedly.
    private static let titles: [LastChatsViewController.SwipeActionKind: String] = [
        .delete: "Delete".localizeString(id: "delete", arguments: []),
        .archive: "Archive".localizeString(id: "archive_chat", arguments: []),
        .unarchive: "Unarchive".localizeString(id: "unarchive_chat", arguments: []),
        .mute: "Mute".localizeString(id: "mute_chat", arguments: []),
        .unmute: "Unmute".localizeString(id: "unmute_chat", arguments: []),
        .block: "Block".localizeString(id: "contact_bar_block", arguments: []),
        .pin: "Pin".localizeString(id: "message_pin", arguments: []),
        .call: "Call".localizeString(id: "call", arguments: [])
    ]

    static func descriptor(
        for kind: LastChatsViewController.SwipeActionKind
    ) -> LastChatsViewController.SwipeActionDescriptor {
        LastChatsViewController.SwipeActionDescriptor(
            kind: kind,
            style: style(for: kind),
            title: titles[kind] ?? "",
            image: images[kind],
            backgroundColor: backgroundColor(for: kind)
        )
    }

    private static func style(for kind: LastChatsViewController.SwipeActionKind) -> UIContextualAction.Style {
        kind == .delete ? .destructive : .normal
    }

    private static func backgroundColor(for kind: LastChatsViewController.SwipeActionKind) -> UIColor {
        switch kind {
        case .delete, .block:
            return .systemRed
        case .archive, .pin:
            return .systemGreen
        case .unarchive:
            return .systemGray3
        case .mute, .unmute, .call:
            return .systemBlue
        }
    }
}
