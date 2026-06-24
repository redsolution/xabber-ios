//
//  CallsListCoordinator.swift
//  xabber
//
//  Created by Codex on 25.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift

enum CallsListFilter: String, CaseIterable, Hashable {
    case all = "all"
    case missed = "missed"
    case incoming = "incoming"
    case outgoing = "outgoing"
    case declined = "declined"

    static let visibleCategoryCases: [CallsListFilter] = [
        .missed,
        .incoming,
        .outgoing,
        .declined
    ]

    var title: String {
        switch self {
        case .all:
            return "All Calls".localizeString(id: "calls_filter_all", arguments: [])
        case .missed:
            return "Missed".localizeString(id: "calls_filter_missed", arguments: [])
        case .incoming:
            return "Incoming".localizeString(id: "calls_filter_incoming", arguments: [])
        case .outgoing:
            return "Outgoing".localizeString(id: "calls_filter_outgoing", arguments: [])
        case .declined:
            return "Declined".localizeString(id: "calls_filter_declined", arguments: [])
        }
    }

    var iconName: String {
        switch self {
        case .all:
            return "phone"
        case .missed:
            return "phone.arrow.down.left"
        case .incoming:
            return "phone.arrow.down.left"
        case .outgoing:
            return "phone.arrow.up.right"
        case .declined:
            return "phone.down"
        }
    }

    var categoryIconColor: UIColor {
        switch self {
        case .missed, .declined:
            return .systemRed
        case .incoming, .outgoing:
            return .systemGreen
        case .all:
            return .tintColor
        }
    }

    func count(in counters: CallsListCoordinator.Counters) -> Int {
        switch self {
        case .all:
            return counters.total
        case .missed:
            return counters.missed
        case .incoming:
            return counters.incoming
        case .outgoing:
            return counters.outgoing
        case .declined:
            return counters.declined
        }
    }
}

struct CallsListCoordinator {
    struct CategoryItem {
        let title: String
        let icon: String
        let key: String
        let subtitle: String
        let color: UIColor
        let isHeader: Bool
        let isSelectable: Bool
    }

    struct Counters: Equatable {
        let total: Int
        let missed: Int
        let incoming: Int
        let outgoing: Int
        let declined: Int
    }

    struct DerivedState {
        let listDatasource: [LastCallsViewController.Datasource]
        let categoriesDatasource: [[CategoryItem]]
        let counters: Counters
    }

    static let listLimit = 50

    static func displayDirection(
        for state: MessageStorageItem.VoIPCallState,
        outgoing: Bool
    ) -> LastCallsViewController.DisplayCallDirection {
        switch state {
        case .missed:
            return .missed
        case .busy, .noanswer:
            return .rejected
        case .received:
            return .incoming
        case .made:
            return outgoing ? .outgoing : .incoming
        case .none:
            return outgoing ? .outgoing : .incoming
        }
    }

    static func filter(
        for state: MessageStorageItem.VoIPCallState,
        outgoing: Bool
    ) -> CallsListFilter {
        filter(for: displayDirection(for: state, outgoing: outgoing))
    }

    static func filter(for direction: LastCallsViewController.DisplayCallDirection) -> CallsListFilter {
        switch direction {
        case .missed:
            return .missed
        case .incoming:
            return .incoming
        case .outgoing:
            return .outgoing
        case .rejected:
            return .declined
        }
    }

    static func deriveState(
        realm: Realm,
        enabledAccounts: Set<String>,
        filter selectedFilter: CallsListFilter,
        searchQuery: String? = nil
    ) -> DerivedState {
        guard enabledAccounts.isNotEmpty else {
            let counters = Counters(total: 0, missed: 0, incoming: 0, outgoing: 0, declined: 0)
            return DerivedState(
                listDatasource: [],
                categoriesDatasource: categoryDatasource(counters: counters),
                counters: counters
            )
        }

        let results = callResults(in: realm, enabledAccounts: enabledAccounts)
        var counters = Counters(total: 0, missed: 0, incoming: 0, outgoing: 0, declined: 0)
        var filteredItems: [MessageStorageItem] = []

        for item in results {
            let itemFilter = callFilter(for: item)
            counters = increment(counters: counters, filter: itemFilter)

            guard selectedFilter == .all || itemFilter == selectedFilter else {
                continue
            }

            filteredItems.append(item)
        }

        let filteredDatasource = filterDatasource(
            mapDatasource(items: filteredItems, realm: realm),
            searchQuery: searchQuery
        )
        let limitedDatasource = Array(filteredDatasource.prefix(listLimit))

        return DerivedState(
            listDatasource: limitedDatasource,
            categoriesDatasource: categoryDatasource(counters: counters),
            counters: counters
        )
    }

    static func callFilter(for item: MessageStorageItem) -> CallsListFilter {
        let stateRaw = (item.callMetadata?["callState"] as? String) ?? ""
        let state = MessageStorageItem.VoIPCallState(rawValue: stateRaw) ?? .none
        return filter(for: state, outgoing: item.outgoing)
    }

    private static func callResults(
        in realm: Realm,
        enabledAccounts: Set<String>
    ) -> Results<MessageStorageItem> {
        realm.objects(MessageStorageItem.self)
            .filter(
                "owner IN %@ AND messageType == %@ AND isDeleted == false",
                Array(enabledAccounts),
                MessageStorageItem.MessageDisplayType.call.rawValue
            )
            .sorted(byKeyPath: "date", ascending: false)
    }

    private static func increment(counters: Counters, filter: CallsListFilter) -> Counters {
        Counters(
            total: counters.total + 1,
            missed: counters.missed + (filter == .missed ? 1 : 0),
            incoming: counters.incoming + (filter == .incoming ? 1 : 0),
            outgoing: counters.outgoing + (filter == .outgoing ? 1 : 0),
            declined: counters.declined + (filter == .declined ? 1 : 0)
        )
    }

    private static func mapDatasource(
        items: [MessageStorageItem],
        realm: Realm
    ) -> [LastCallsViewController.Datasource] {
        let owners = Array(Set(items.map { $0.owner }))
        let jids = Array(Set(items.map { $0.opponent }))
        let rosterItems = owners.isEmpty || jids.isEmpty
            ? []
            : realm.objects(RosterStorageItem.self)
                .filter("owner IN %@ AND jid IN %@", owners, jids)
                .toArray()
        let rosterByKey = Dictionary(
            uniqueKeysWithValues: rosterItems.map { item in
                (RosterStorageItem.genPrimary(jid: item.jid, owner: item.owner), item)
            }
        )

        return items.map { item in
            let rosterItem = rosterByKey[RosterStorageItem.genPrimary(jid: item.opponent, owner: item.owner)]
            let displayState = displayDirection(
                for: MessageStorageItem.VoIPCallState(rawValue: (item.callMetadata?["callState"] as? String) ?? "") ?? .none,
                outgoing: item.outgoing
            )

            return LastCallsViewController.Datasource(
                owner: item.owner,
                jid: item.opponent,
                username: rosterItem?.displayName ?? item.opponent,
                avatarUrl: rosterItem?.avatarMinUrl ?? rosterItem?.avatarMaxUrl ?? rosterItem?.oldschoolAvatarKey,
                date: item.date,
                direction: displayState,
                outgoing: item.outgoing,
                messagePrimary: item.primary,
                referencePrimary: item.references.first?.primary
            )
        }
    }

    private static func filterDatasource(
        _ items: [LastCallsViewController.Datasource],
        searchQuery: String?
    ) -> [LastCallsViewController.Datasource] {
        guard let query = normalizedSearchQuery(searchQuery) else {
            return items
        }

        return items.filter { item in
            [
                item.username,
                item.jid,
                item.owner,
                item.direction.title
            ].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private static func normalizedSearchQuery(_ query: String?) -> String? {
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func categoryDatasource(counters: Counters) -> [[CategoryItem]] {
        [
            [
                CategoryItem(
                    title: "Calls".localizeString(id: "chat_calls_title", arguments: []),
                    icon: "phone.fill",
                    key: CallsListFilter.all.rawValue,
                    subtitle: "Manage VoIP calls and settings".localizeString(id: "calls_categories_intro_subtitle", arguments: []),
                    color: .tintColor,
                    isHeader: true,
                    isSelectable: false
                )
            ],
            CallsListFilter.visibleCategoryCases.map { filter in
                CategoryItem(
                    title: filter.title,
                    icon: filter.iconName,
                    key: filter.rawValue,
                    subtitle: filter == .missed ? "\(filter.count(in: counters))" : "",
                    color: filter.categoryIconColor,
                    isHeader: false,
                    isSelectable: true
                )
            }
        ]
    }
}
