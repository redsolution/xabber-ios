import Foundation
import UIKit
import CocoaLumberjack

/// Canonical blocklist UI. The server currently has no blocklist repository
/// projection, so its GET result is kept as immutable screen-local state.
final class GroupchatBlockedViewController: SimpleBaseViewController {
    struct Datasource: Equatable {
        let target: String
        let title: String
        let subtitle: String
        let avatarURL: String?
    }

    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate?

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(
            CommonMemberTableCell.self,
            forCellReuseIdentifier: CommonMemberTableCell.cellName
        )
        return view
    }()
    private var datasource: [Datasource] = []
    private var refreshTask: Task<Void, Never>?

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Blocked".localizeString(id: "groupchat_blocked", arguments: [])
        tableView.delegate = self
        tableView.dataSource = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: imageLiteral("custom.nosign.badge.plus"),
            style: .plain,
            target: self,
            action: #selector(onBlockBarButtonTouchUpInside)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    @objc private func onBlockBarButtonTouchUpInside() {
        let controller = GroupchatBlockAddViewController()
        controller.jid = jid
        controller.owner = owner
        navigationController?.pushViewController(controller, animated: true)
    }

    private func refresh() {
        refreshTask?.cancel()
        guard let account = AccountManager.shared.find(for: owner) else {
            present(error: GroupchatServiceError.notPrepared)
            return
        }
        refreshTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let targets = try await account.groupchatService.refreshBlocklist(
                    groupJID: jid
                )
                try Task.checkCancellation()
                datasource = targets
                    .map { target in
                        Datasource(
                            target: target,
                            title: target,
                            subtitle: target.contains("@") ? "XMPP ID" : "Domain",
                            avatarURL: nil
                        )
                    }
                    .sorted { $0.target.localizedCaseInsensitiveCompare($1.target) == .orderedAscending }
                tableView.reloadData()
            } catch is CancellationError {
                return
            } catch {
                present(error: error)
            }
        }
    }

    private func unblock(_ target: String) {
        guard let account = AccountManager.shared.find(for: owner) else {
            present(error: GroupchatServiceError.notPrepared)
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let targets = try await account.groupchatService.unblock(
                    groupJID: jid,
                    target: target
                )
                datasource = targets
                    .map { Datasource(target: $0, title: $0, subtitle: $0.contains("@") ? "XMPP ID" : "Domain", avatarURL: nil) }
                    .sorted { $0.target.localizedCaseInsensitiveCompare($1.target) == .orderedAscending }
                tableView.reloadData()
            } catch {
                present(error: error)
            }
        }
    }

    private func present(error: Error) {
        DDLogDebug("GroupchatBlockedViewController: \(error.localizedDescription)")
        ErrorMessagePresenter().present(
            in: self,
            message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
            animated: true,
            completion: nil
        )
    }
}

extension GroupchatBlockedViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        datasource.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
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
            userId: item.target,
            title: item.title,
            badge: "",
            isMe: false,
            subtitle: item.subtitle,
            status: .offline,
            entity: .contact,
            role: .member
        )
        return cell
    }
}

extension GroupchatBlockedViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 64 }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let target = datasource[indexPath.row].target
        let action = UIContextualAction(
            style: .destructive,
            title: "Unblock".localizeString(id: "groupchat_unblock", arguments: [])
        ) { [weak self] _, _, completion in
            self?.unblock(target)
            completion(true)
        }
        action.image = imageLiteral("xmark")
        return UISwipeActionsConfiguration(actions: [action])
    }
}
