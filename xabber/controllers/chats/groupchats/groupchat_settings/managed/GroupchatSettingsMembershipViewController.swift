import UIKit
import CocoaLumberjack

class GroupchatSettingsMembershipViewController: SimpleBaseViewController {
    final class SettingsItemCell: UITableViewCell {
        static let cellName = "GroupMembershipSettingsItemCell"

        func configure(title: String) {
            textLabel?.text = title
        }
    }

    struct Datasource {
        let title: String
        let value: GroupMembership
    }

    private let datasource: [Datasource] = [
        Datasource(
            title: "Open".localizeString(id: "groupchat_membership_type_open", arguments: []),
            value: .open
        ),
        Datasource(
            title: "Private".localizeString(id: "groupchat_membership_type_private", arguments: []),
            value: .privateGroup
        )
    ]
    private var currentValue: GroupMembership?
    private var repository: GroupRepository?
    private var projectionObservation: GroupRepositoryObservation?
    private var updateTask: Task<Void, Never>?

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        return view
    }()

    override func loadDatasource() {
        super.loadDatasource()
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            self.repository = repository
            apply(try repository.projection(owner: owner, groupJID: jid))
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Membership".localizeString(id: "groupchat_membership", arguments: [])
        tableView.dataSource = self
        tableView.delegate = self
    }

    override func subscribe() {
        super.subscribe()
        do {
            let repository: GroupRepository
            if let existingRepository = self.repository {
                repository = existingRepository
            } else {
                repository = GroupRepository(realm: try WRealm.safe())
            }
            self.repository = repository
            projectionObservation?.invalidate()
            projectionObservation = try repository.observeProjection(
                owner: owner,
                groupJID: jid
            ) { [weak self] projection in
                DispatchQueue.main.async {
                    self?.apply(projection)
                }
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
    }

    override func onAppear() {
        super.onAppear()
        refreshAuthoritativeSettings()
    }

    deinit {
        updateTask?.cancel()
        projectionObservation?.invalidate()
    }

    private func apply(_ projection: GroupRepositoryProjection) {
        currentValue = projection.state.snapshot.settings?.membership
        tableView.reloadData()
    }

    private func refreshAuthoritativeSettings() {
        guard updateTask == nil,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        updateTask = Task { [weak self, weak account] in
            guard let self, let account else { return }
            defer { self.updateTask = nil }
            do {
                let settings = try await account.groupchatService.refreshSettings(groupJID: self.jid)
                try self.persist(settings)
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    private func updateMembership(_ membership: GroupMembership) {
        guard updateTask == nil,
              membership != currentValue,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        tableView.isUserInteractionEnabled = false
        updateTask = Task { [weak self, weak account] in
            guard let self, let account else { return }
            defer {
                self.updateTask = nil
                self.tableView.isUserInteractionEnabled = true
            }
            do {
                let settings = try await account.groupchatService.updateSettings(
                    groupJID: self.jid,
                    settings: GroupSettings(membership: membership)
                )
                try self.persist(settings)
                ToastPresenter().presentSuccess(message: "Membership updated")
            } catch is CancellationError {
                return
            } catch {
                ToastPresenter().presentError(message: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func persist(_ settings: GroupSettings) throws {
        let repository: GroupRepository
        if let existingRepository = self.repository {
            repository = existingRepository
        } else {
            repository = GroupRepository(realm: try WRealm.safe())
        }
        self.repository = repository
        try repository.applyPatch(
            GroupPatch(
                settings: .value(
                    GroupSettingsPatch(
                        membership: .value(settings.membership),
                        contacts: .value(settings.contacts),
                        domains: .value(settings.domains),
                        index: .value(settings.index),
                        state: .value(settings.state)
                    )
                )
            ),
            owner: owner,
            groupJID: jid
        )
    }
}

extension GroupchatSettingsMembershipViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        52
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        updateMembership(datasource[indexPath.row].value)
    }
}

extension GroupchatSettingsMembershipViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        datasource.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Private groups can be joined only by invitation."
            .localizeString(id: "groupchats_private_membership_hint", arguments: [])
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SettingsItemCell.cellName,
            for: indexPath
        ) as? SettingsItemCell else {
            fatalError("Unexpected membership cell")
        }
        let item = datasource[indexPath.row]
        cell.configure(title: item.title)
        cell.selectionStyle = .none
        cell.accessoryType = item.value == currentValue ? .checkmark : .none
        return cell
    }
}
