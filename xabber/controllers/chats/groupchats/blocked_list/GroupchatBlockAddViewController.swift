import Foundation
import UIKit
import CocoaLumberjack
import XMPPFramework

/// Adds canonical block targets. Only real JIDs/domains are sent; incognito
/// member IDs are intentionally not valid block targets.
final class GroupchatBlockAddViewController: SimpleBaseViewController {
    struct Datasource: Equatable {
        let memberID: String
        let jid: String
        let title: String
        let avatarURL: String?
    }

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.allowsMultipleSelection = true
        view.register(
            CommonMemberTableCell.self,
            forCellReuseIdentifier: CommonMemberTableCell.cellName
        )
        view.register(
            GroupchatSettingsViewControllerT.SettingsTextFieldCell.self,
            forCellReuseIdentifier: GroupchatSettingsViewControllerT.SettingsTextFieldCell.cellName
        )
        return view
    }()
    private let blockButton = UIBarButtonItem(
        title: "Block".localizeString(id: "contact_bar_block", arguments: []),
        style: .plain,
        target: nil,
        action: nil
    )
    private var datasource: [Datasource] = []
    private var selectedTargets = Set<String>()
    private var enteredTarget = ""
    private var loadTask: Task<Void, Never>?

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Block".localizeString(id: "contact_bar_block", arguments: [])
        tableView.delegate = self
        tableView.dataSource = self
        blockButton.tintColor = .systemRed
        blockButton.target = self
        blockButton.action = #selector(onSaveButtonTouchUpInside)
        navigationItem.rightBarButtonItem = blockButton
        updateBlockButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadMembers()
    }

    deinit {
        loadTask?.cancel()
    }

    private func loadMembers() {
        loadTask?.cancel()
        guard let account = AccountManager.shared.find(for: owner) else {
            present(error: GroupchatServiceError.notPrepared)
            return
        }
        loadTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let members = try await account.groupchatService.refreshMembers(groupJID: jid)
                try GroupRepository(realm: WRealm.safe()).replaceMembers(
                    members,
                    owner: owner,
                    groupJID: jid
                )
                try Task.checkCancellation()
                datasource = members.compactMap { member in
                    guard let realJID = member.jid, realJID.isNotEmpty else { return nil }
                    return Datasource(
                        memberID: member.id,
                        jid: realJID,
                        title: member.nickname?.isNotEmpty == true ? member.nickname! : realJID,
                        avatarURL: member.avatar?.url
                    )
                }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
            } catch is CancellationError {
                return
            } catch {
                present(error: error)
            }
        }
    }

    @objc private func onSaveButtonTouchUpInside() {
        var targets = selectedTargets
        if let normalized = normalizedTarget(enteredTarget) {
            targets.insert(normalized)
        }
        guard !targets.isEmpty,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                _ = try await account.groupchatService.block(
                    groupJID: jid,
                    targets: targets.sorted()
                )
                navigationController?.popViewController(animated: true)
            } catch {
                present(error: error)
            }
        }
    }

    private func normalizedTarget(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.isNotEmpty, !value.contains("/") else { return nil }
        if value.contains("@") {
            guard let parsed = XMPPJID(string: value), parsed.resource == nil else { return nil }
            return parsed.bare
        }
        guard value.contains("."), !value.contains(" ") else { return nil }
        return value
    }

    private func updateBlockButton() {
        blockButton.isEnabled = normalizedTarget(enteredTarget) != nil || !selectedTargets.isEmpty
    }

    private func present(error: Error) {
        DDLogDebug("GroupchatBlockAddViewController: \(error.localizedDescription)")
        ErrorMessagePresenter().present(
            in: self,
            message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
            animated: true,
            completion: nil
        )
    }
}

extension GroupchatBlockAddViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : datasource.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: GroupchatSettingsViewControllerT.SettingsTextFieldCell.cellName,
                for: indexPath
            ) as? GroupchatSettingsViewControllerT.SettingsTextFieldCell else {
                fatalError("SettingsTextFieldCell is not registered")
            }
            cell.configureField { field in
                field.keyboardType = .emailAddress
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.clearButtonMode = .always
            }
            cell.configure("name@example.com or example.com", value: enteredTarget, key: "target")
            cell.callback = { [weak self] _, value in
                self?.enteredTarget = value ?? ""
                self?.updateBlockButton()
            }
            return cell
        }

        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CommonMemberTableCell.cellName,
            for: indexPath
        ) as? CommonMemberTableCell else {
            fatalError("CommonMemberTableCell is not registered")
        }
        let item = datasource[indexPath.row]
        cell.configure(
            avatarUrl: item.avatarURL,
            jid: jid,
            owner: owner,
            userId: item.memberID,
            title: item.title,
            badge: "",
            isMe: false,
            subtitle: item.jid,
            status: .offline,
            entity: .contact,
            role: .member
        )
        return cell
    }
}

extension GroupchatBlockAddViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 64 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? "Block a specific XMPP address or domain. Blocked users will be unable to join this group in the future."
            : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        selectedTargets.insert(datasource[indexPath.row].jid)
        updateBlockButton()
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        selectedTargets.remove(datasource[indexPath.row].jid)
        updateBlockButton()
    }
}
