import UIKit

enum RosterCircleRowAction: Equatable {
    case delete
    case rename
}

enum RosterCircleInteractionPolicy {
    static let trailingActions: [RosterCircleRowAction] = [.delete, .rename]
}

final class AccountCirclesViewController: BaseViewController {
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 76
        view.register(RosterCircleCell.self, forCellReuseIdentifier: RosterCircleCell.reuseIdentifier)
        view.applyContinuousSplitInsetGroupedAppearance()
        view.accessibilityIdentifier = "settings_circles_list"
        return view
    }()

    let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "No circles".localizeString(id: "contact_circles_empty", arguments: [])
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "settings_circles_empty"
        return label
    }()

    private(set) var circles: [RosterCircleSnapshot] = []
    private var service: RosterCircleServicing?
    private var isBusy = false

    func configure(for jid: String, service: RosterCircleServicing? = nil) {
        self.jid = GroupStorageKey.bareJID(jid)
        owner = self.jid
        self.service = service ?? RosterCircleService(owner: self.jid)
        if isViewLoaded {
            reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Circles".localizeString(
            id: "settings_account__section_header_circles",
            arguments: []
        )
        view.backgroundColor = .systemGroupedBackground
        if service == nil, jid.isNotEmpty {
            service = RosterCircleService(owner: jid)
        }
        configureNavigationBar()
        configureTableView()
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    private func configureNavigationBar() {
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addCircle)
        )
        addItem.accessibilityLabel = "Add circle".localizeString(id: "add_new_circle", arguments: [])
        addItem.accessibilityIdentifier = "settings_circles_add"
        navigationItem.rightBarButtonItem = addItem
    }

    private func configureTableView() {
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundView = emptyStateLabel
    }

    func reloadData() {
        guard isViewLoaded, let service else { return }
        do {
            circles = try service.loadCircles()
            emptyStateLabel.isHidden = circles.isNotEmpty
            tableView.reloadData()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func addCircle() {
        guard let service else { return }
        do {
            let editor = RosterCircleSelectionViewController(
                mode: .create(existingNames: circles.map(\.name)),
                service: service,
                members: try service.loadMembers()
            )
            navigationController?.pushViewController(editor, animated: true)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentRename(circle: RosterCircleSnapshot) {
        let alert = UIAlertController(
            title: "Rename circle".localizeString(id: "circle_rename", arguments: []),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = circle.name
            textField.placeholder = "Circle name".localizeString(id: "circle_name", arguments: [])
            textField.autocapitalizationType = .words
            textField.clearButtonMode = .whileEditing
            textField.accessibilityIdentifier = "settings_circles_rename_field"
        }
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Rename".localizeString(id: "input_widget__button_rename", arguments: []),
            style: .default,
            handler: { [weak self, weak alert] _ in
                guard let self, let name = alert?.textFields?.first?.text else { return }
                self.rename(circle: circle, to: name)
            }
        ))
        present(alert, animated: true)
    }

    private func rename(circle: RosterCircleSnapshot, to name: String) {
        runMutation(
            operation: { [weak self] completion in
                self?.service?.rename(oldName: circle.name, newName: name, completion: completion)
            },
            retry: { [weak self] in self?.rename(circle: circle, to: name) }
        )
    }

    private func presentDelete(circle: RosterCircleSnapshot) {
        let memberCount = circle.members.count
        let message = "Delete “%@” from %@ members?".localizeString(
            id: "settings_circles_delete_message",
            arguments: [circle.name, "\(memberCount)"]
        )
        let alert = UIAlertController(
            title: "Delete circle".localizeString(id: "circle_remove", arguments: []),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Delete".localizeString(id: "delete", arguments: []),
            style: .destructive,
            handler: { [weak self] _ in self?.delete(circle: circle) }
        ))
        present(alert, animated: true)
    }

    private func delete(circle: RosterCircleSnapshot) {
        runMutation(
            operation: { [weak self] completion in
                self?.service?.delete(name: circle.name, completion: completion)
            },
            retry: { [weak self] in self?.delete(circle: circle) }
        )
    }

    private func runMutation(
        operation: (@escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void) -> Void,
        retry: @escaping () -> Void
    ) {
        guard isBusy == false else { return }
        setBusy(true)
        operation { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            self.reloadData()
            switch result {
            case .success(let batch) where batch.isComplete:
                break
            case .success(let batch):
                self.presentPartialFailure(count: batch.failures.count, retry: retry)
            case .failure(let error):
                self.presentServiceError(error)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        tableView.isUserInteractionEnabled = !busy
        if busy {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            indicator.accessibilityLabel = "Saving".localizeString(
                id: "settings_circles_saving",
                arguments: []
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        } else {
            configureNavigationBar()
        }
    }

    private func presentPartialFailure(count: Int, retry: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "Some changes were not saved".localizeString(
                id: "settings_circles_partial_title",
                arguments: []
            ),
            message: "%@ roster updates failed. Retry sends only the remaining difference.".localizeString(
                id: "settings_circles_partial_message",
                arguments: ["\(count)"]
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Retry".localizeString(id: "settings_circles_retry", arguments: []),
            style: .default
        ) { _ in retry() })
        present(alert, animated: true)
    }

    private func presentServiceError(_ error: RosterCircleServiceError) {
        switch error {
        case .validation(.emptyName):
            presentError("Circle name cannot be empty.".localizeString(
                id: "settings_circles_error_empty_name",
                arguments: []
            ))
        case .validation(.duplicateName):
            presentError("A circle with this name already exists.".localizeString(
                id: "settings_circles_error_duplicate_name",
                arguments: []
            ))
        case .validation(.noMembers):
            presentError("Select at least one contact.".localizeString(
                id: "settings_circles_error_no_members",
                arguments: []
            ))
        case .validation(.circleNotFound):
            presentError("The circle no longer exists.".localizeString(
                id: "settings_circles_error_not_found",
                arguments: []
            ))
        case .storage(let message):
            presentError(message)
        }
    }

    private func presentError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Error".localizeString(id: "error", arguments: []),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "OK".localizeString(id: "ok", arguments: []),
            style: .default
        ))
        present(alert, animated: true)
    }
}

extension AccountCirclesViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        circles.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: RosterCircleCell.reuseIdentifier,
            for: indexPath
        ) as? RosterCircleCell else {
            return UITableViewCell()
        }
        cell.configure(circle: circles[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let service else { return }
        let controller = RosterCircleMembersViewController(
            circleName: circles[indexPath.row].name,
            service: service
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let circle = circles[indexPath.row]
        let actions = RosterCircleInteractionPolicy.trailingActions.map { action -> UIContextualAction in
            switch action {
            case .delete:
                let action = UIContextualAction(
                    style: .destructive,
                    title: "Delete".localizeString(id: "delete", arguments: [])
                ) { [weak self] _, _, completion in
                    self?.presentDelete(circle: circle)
                    completion(true)
                }
                action.image = UIImage(systemName: "trash")
                return action
            case .rename:
                let action = UIContextualAction(
                    style: .normal,
                    title: "Rename".localizeString(id: "input_widget__button_rename", arguments: [])
                ) { [weak self] _, _, completion in
                    self?.presentRename(circle: circle)
                    completion(true)
                }
                action.image = UIImage(systemName: "pencil")
                action.backgroundColor = .systemBlue
                return action
            }
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

final class RosterCircleMembersViewController: BaseViewController {
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(
            ContactsViewController.ContactCell.self,
            forCellReuseIdentifier: ContactsViewController.ContactCell.cellName
        )
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 84
        view.applyContinuousSplitInsetGroupedAppearance()
        view.accessibilityIdentifier = "settings_circle_members_list"
        return view
    }()

    let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "No contacts".localizeString(
            id: "settings_circles_no_contacts",
            arguments: []
        )
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private(set) var members: [RosterCircleMemberSnapshot] = []
    private let circleName: String
    private let service: RosterCircleServicing
    private var isBusy = false

    init(circleName: String, service: RosterCircleServicing) {
        self.circleName = circleName
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = circleName
        view.backgroundColor = .systemGroupedBackground
        configureAddButton()
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundView = emptyStateLabel
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    private func configureAddButton() {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(editMembers)
        )
        item.accessibilityLabel = "Add contacts".localizeString(
            id: "settings_circles_add_contacts",
            arguments: []
        )
        item.accessibilityIdentifier = "settings_circle_members_add"
        navigationItem.rightBarButtonItem = item
    }

    private func reloadData() {
        do {
            members = RosterCircleCatalog.members(in: circleName, from: try service.loadMembers())
            emptyStateLabel.isHidden = members.isNotEmpty
            tableView.reloadData()
            if members.isEmpty, isMovingFromParent == false, view.window != nil {
                navigationController?.popViewController(animated: true)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func editMembers() {
        do {
            let allMembers = try service.loadMembers()
            let selected = Set(
                RosterCircleCatalog.members(in: circleName, from: allMembers).map(\.primary)
            )
            let editor = RosterCircleSelectionViewController(
                mode: .edit(circleName: circleName),
                service: service,
                members: allMembers,
                initiallySelected: selected
            )
            navigationController?.pushViewController(editor, animated: true)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func remove(member: RosterCircleMemberSnapshot) {
        if members.count == 1 {
            let alert = UIAlertController(
                title: "Delete circle?".localizeString(
                    id: "settings_circles_delete_last_title",
                    arguments: []
                ),
                message: "Removing the last contact deletes “%@”.".localizeString(
                    id: "settings_circles_delete_last_message",
                    arguments: [circleName]
                ),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: "Cancel".localizeString(id: "cancel", arguments: []),
                style: .cancel
            ))
            alert.addAction(UIAlertAction(
                title: "Delete".localizeString(id: "delete", arguments: []),
                style: .destructive
            ) { [weak self] _ in
                self?.performRemove(member: member)
            })
            present(alert, animated: true)
        } else {
            performRemove(member: member)
        }
    }

    private func performRemove(member: RosterCircleMemberSnapshot) {
        guard isBusy == false else { return }
        setBusy(true)
        service.removeMember(primary: member.primary, circleName: circleName) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let batch) where batch.isComplete:
                if self.members.count == 1 {
                    self.navigationController?.popViewController(animated: true)
                } else {
                    self.reloadData()
                }
            case .success:
                self.presentRetryRemove(member: member)
            case .failure(let error):
                self.presentError(String(describing: error))
            }
        }
    }

    private func presentRetryRemove(member: RosterCircleMemberSnapshot) {
        let alert = UIAlertController(
            title: "Contact was not removed".localizeString(
                id: "settings_circles_remove_failed_title",
                arguments: []
            ),
            message: "The server did not confirm this roster update.".localizeString(
                id: "settings_circles_remove_failed_message",
                arguments: []
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Retry".localizeString(id: "settings_circles_retry", arguments: []),
            style: .default
        ) { [weak self] _ in
            self?.performRemove(member: member)
        })
        present(alert, animated: true)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        tableView.isUserInteractionEnabled = !busy
        if busy {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        } else {
            configureAddButton()
        }
    }

    private func presentError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Error".localizeString(id: "error", arguments: []),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "OK".localizeString(id: "ok", arguments: []),
            style: .default
        ))
        present(alert, animated: true)
    }
}

extension RosterCircleMembersViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ContactsViewController.ContactCell.cellName,
            for: indexPath
        ) as? ContactsViewController.ContactCell else {
            return UITableViewCell()
        }
        configureContactCell(cell, member: members[indexPath.row])
        cell.accessoryType = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let member = members[indexPath.row]
        let remove = UIContextualAction(
            style: .destructive,
            title: "Remove".localizeString(id: "remove", arguments: [])
        ) { [weak self] _, _, completion in
            self?.remove(member: member)
            completion(true)
        }
        remove.image = UIImage(systemName: "person.crop.circle.badge.minus")
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

final class RosterCircleSelectionViewController: BaseViewController {
    enum Mode: Equatable {
        case create(existingNames: [String])
        case edit(circleName: String)
    }

    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(
            ContactsViewController.ContactCell.self,
            forCellReuseIdentifier: ContactsViewController.ContactCell.cellName
        )
        view.register(RosterCircleNameCell.self, forCellReuseIdentifier: RosterCircleNameCell.reuseIdentifier)
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 84
        view.keyboardDismissMode = .onDrag
        view.applyContinuousSplitInsetGroupedAppearance()
        view.accessibilityIdentifier = "settings_circle_selection_list"
        return view
    }()

    private(set) var selectionState: RosterCircleSelectionState
    private let mode: Mode
    private let service: RosterCircleServicing
    private let searchController = UISearchController(searchResultsController: nil)
    private var circleName: String = ""
    private var isBusy = false
    private(set) var checkmarkItem: UIBarButtonItem!

    init(
        mode: Mode,
        service: RosterCircleServicing,
        members: [RosterCircleMemberSnapshot],
        initiallySelected: Set<String> = []
    ) {
        self.mode = mode
        self.service = service
        selectionState = RosterCircleSelectionState(
            members: members,
            initiallySelected: initiallySelected
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch mode {
        case .create:
            title = "New circle".localizeString(id: "new_circle", arguments: [])
        case .edit:
            title = "Contacts".localizeString(id: "contacts", arguments: [])
        }
        view.backgroundColor = .systemGroupedBackground
        configureNavigation()
        configureSearch()
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tableView.dataSource = self
        tableView.delegate = self
        updateCheckmark()
    }

    private func configureNavigation() {
        checkmarkItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            style: .done,
            target: self,
            action: #selector(save)
        )
        checkmarkItem.accessibilityLabel = "Save".localizeString(id: "save", arguments: [])
        checkmarkItem.accessibilityIdentifier = "settings_circle_selection_save"
        navigationItem.rightBarButtonItem = checkmarkItem
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.placeholder = "Search".localizeString(id: "search", arguments: [])
        searchController.searchBar.accessibilityIdentifier = "settings_circle_selection_search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    @objc private func save() {
        guard checkmarkItem.isEnabled, isBusy == false else { return }
        switch mode {
        case .create(let existingNames):
            do {
                let name = try RosterCircleName.validate(circleName, existingNames: existingNames)
                execute(
                    operation: { [weak self] completion in
                        self?.service.create(
                            name: name,
                            selectedPrimaries: self?.selectionState.selectedPrimaries ?? [],
                            completion: completion
                        )
                    },
                    retry: { [weak self] in self?.save() },
                    popToCircleList: false
                )
            } catch {
                updateCheckmark()
            }
        case .edit(let circleName):
            if selectionState.selectedPrimaries.isEmpty {
                confirmDeletingCircle(named: circleName)
            } else {
                saveMembers(circleName: circleName, popToCircleList: false)
            }
        }
    }

    private func confirmDeletingCircle(named circleName: String) {
        let alert = UIAlertController(
            title: "Delete circle?".localizeString(
                id: "settings_circles_delete_last_title",
                arguments: []
            ),
            message: "A circle cannot be empty. Saving will delete “%@”.".localizeString(
                id: "settings_circles_delete_empty_message",
                arguments: [circleName]
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Delete".localizeString(id: "delete", arguments: []),
            style: .destructive
        ) { [weak self] _ in
            self?.saveMembers(circleName: circleName, popToCircleList: true)
        })
        present(alert, animated: true)
    }

    private func saveMembers(circleName: String, popToCircleList: Bool) {
        execute(
            operation: { [weak self] completion in
                self?.service.setMembers(
                    circleName: circleName,
                    selectedPrimaries: self?.selectionState.selectedPrimaries ?? [],
                    completion: completion
                )
            },
            retry: { [weak self] in
                self?.saveMembers(circleName: circleName, popToCircleList: popToCircleList)
            },
            popToCircleList: popToCircleList
        )
    }

    private func execute(
        operation: (@escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void) -> Void,
        retry: @escaping () -> Void,
        popToCircleList: Bool
    ) {
        setBusy(true)
        operation { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let batch) where batch.isComplete:
                self.finish(popToCircleList: popToCircleList)
            case .success(let batch):
                let alert = UIAlertController(
                    title: "Some changes were not saved".localizeString(
                        id: "settings_circles_partial_title",
                        arguments: []
                    ),
                    message: "%@ roster updates failed. Retry sends only the remaining difference.".localizeString(
                        id: "settings_circles_partial_message",
                        arguments: ["\(batch.failures.count)"]
                    ),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(
                    title: "Cancel".localizeString(id: "cancel", arguments: []),
                    style: .cancel
                ))
                alert.addAction(UIAlertAction(
                    title: "Retry".localizeString(id: "settings_circles_retry", arguments: []),
                    style: .default
                ) { _ in retry() })
                self.present(alert, animated: true)
            case .failure(let error):
                let alert = UIAlertController(
                    title: "Error".localizeString(id: "error", arguments: []),
                    message: String(describing: error),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(
                    title: "OK".localizeString(id: "ok", arguments: []),
                    style: .default
                ))
                self.present(alert, animated: true)
            }
        }
    }

    private func finish(popToCircleList: Bool) {
        guard popToCircleList,
              let list = navigationController?.viewControllers.first(where: {
                  $0 is AccountCirclesViewController
              }) else {
            navigationController?.popViewController(animated: true)
            return
        }
        navigationController?.popToViewController(list, animated: true)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        tableView.isUserInteractionEnabled = !busy
        searchController.searchBar.isUserInteractionEnabled = !busy
        if busy {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        } else {
            navigationItem.rightBarButtonItem = checkmarkItem
            updateCheckmark()
        }
    }

    private func updateCheckmark() {
        guard checkmarkItem != nil else { return }
        switch mode {
        case .create(let existingNames):
            checkmarkItem.isEnabled = selectionState.canCreate(
                name: circleName,
                existingNames: existingNames
            )
        case .edit:
            checkmarkItem.isEnabled = selectionState.hasChanges
        }
    }
}

extension RosterCircleSelectionViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        switch mode {
        case .create: return 2
        case .edit: return 1
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if case .create = mode, section == 0 { return 1 }
        return selectionState.filteredMembers.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if case .create = mode, indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: RosterCircleNameCell.reuseIdentifier,
                for: indexPath
            ) as? RosterCircleNameCell else {
                return UITableViewCell()
            }
            cell.configure(text: circleName) { [weak self] text in
                self?.circleName = text
                self?.updateCheckmark()
            }
            return cell
        }

        let member = selectionState.filteredMembers[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ContactsViewController.ContactCell.cellName,
            for: indexPath
        ) as? ContactsViewController.ContactCell else {
            return UITableViewCell()
        }
        configureContactCell(cell, member: member)
        cell.accessoryType = selectionState.selectedPrimaries.contains(member.primary) ? .checkmark : .none
        cell.accessibilityTraits = selectionState.selectedPrimaries.contains(member.primary)
            ? [.button, .selected]
            : [.button]
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if case .create = mode, indexPath.section == 0 { return }
        let member = selectionState.filteredMembers[indexPath.row]
        selectionState.toggle(primary: member.primary)
        tableView.reloadRows(at: [indexPath], with: .none)
        updateCheckmark()
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if case .create = mode, section == 0 {
            return "Circle name".localizeString(id: "circle_name", arguments: [])
        }
        return "Contacts".localizeString(id: "contacts", arguments: [])
    }
}

extension RosterCircleSelectionViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        selectionState.query = searchController.searchBar.text ?? ""
        tableView.reloadData()
    }
}

final class RosterCircleNameCell: UITableViewCell, UITextFieldDelegate {
    static let reuseIdentifier = "RosterCircleNameCell"

    let textField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = "Circle name".localizeString(id: "circle_name", arguments: [])
        field.autocapitalizationType = .words
        field.autocorrectionType = .yes
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.accessibilityIdentifier = "settings_circle_name"
        return field
    }()

    private var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textField.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textField.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, onChange: @escaping (String) -> Void) {
        if textField.isFirstResponder == false {
            textField.text = text
        }
        self.onChange = onChange
    }

    @objc private func textChanged() {
        onChange?(textField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

final class RosterCircleCell: UITableViewCell {
    static let reuseIdentifier = "RosterCircleCell"

    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }()

    let avatarStrip = RosterCircleAvatarStripView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        contentView.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(avatarStrip)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        avatarStrip.configure(members: [])
    }

    func configure(circle: RosterCircleSnapshot) {
        titleLabel.text = circle.name
        avatarStrip.configure(members: circle.members)
        accessibilityIdentifier = "settings_circle_\(circle.name)"
        accessibilityLabel = "\(circle.name), \(circle.members.count) contacts"
    }
}

final class RosterCircleAvatarStripView: UIView {
    private static let avatarSize: CGFloat = 32
    private static let visibleStep: CGFloat = 23
    private var trailingConstraint: NSLayoutConstraint?
    private var generation = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(members: [RosterCircleMemberSnapshot]) {
        generation = UUID()
        let currentGeneration = generation
        subviews.forEach { $0.removeFromSuperview() }
        trailingConstraint?.isActive = false

        let summary = RosterCircleAvatarSummary(members: members)
        var trailingAnchorForContent: NSLayoutXAxisAnchor = leadingAnchor
        summary.visibleMembers.enumerated().forEach { index, member in
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = Self.avatarSize / 2
            imageView.layer.borderWidth = 2
            imageView.layer.borderColor = UIColor.systemBackground.cgColor
            imageView.image = UIImageView.getDefaultAvatar(
                for: member.displayName.capitalized,
                owner: member.owner,
                size: Self.avatarSize
            )
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: CGFloat(index) * Self.visibleStep
                ),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
                imageView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
                imageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
                imageView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
            ])
            trailingAnchorForContent = imageView.trailingAnchor

            if let cached = DefaultAvatarManager.shared.cachedAvatarImage(url: member.avatarURL) {
                imageView.image = cached
            } else {
                DefaultAvatarManager.shared.getAvatar(
                    url: member.avatarURL,
                    jid: member.jid,
                    owner: member.owner,
                    size: Self.avatarSize
                ) { [weak self, weak imageView] image in
                    guard let self, self.generation == currentGeneration else { return }
                    if let image {
                        imageView?.image = image
                    }
                }
            }
        }

        if summary.overflowCount > 0 {
            let moreLabel = UILabel()
            moreLabel.translatesAutoresizingMaskIntoConstraints = false
            moreLabel.font = .preferredFont(forTextStyle: .caption1)
            moreLabel.adjustsFontForContentSizeCategory = true
            moreLabel.textColor = .secondaryLabel
            moreLabel.text = "+%@ more".localizeString(
                id: "settings_circles_avatar_overflow",
                arguments: ["\(summary.overflowCount)"]
            )
            addSubview(moreLabel)
            NSLayoutConstraint.activate([
                moreLabel.leadingAnchor.constraint(equalTo: trailingAnchorForContent, constant: 8),
                moreLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                moreLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
                moreLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
            ])
            trailingAnchorForContent = moreLabel.trailingAnchor
        }

        trailingConstraint = trailingAnchorForContent.constraint(equalTo: trailingAnchor)
        trailingConstraint?.isActive = true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            subviews.compactMap { $0 as? UIImageView }.forEach {
                $0.layer.borderColor = UIColor.systemBackground.cgColor
            }
        }
    }
}

private func configureContactCell(
    _ cell: ContactsViewController.ContactCell,
    member: RosterCircleMemberSnapshot
) {
    cell.configure(
        title: member.displayName,
        subtitle: member.jid,
        bottomLine: nil,
        groups: [],
        jid: member.jid,
        owner: member.owner,
        showAvatar: true,
        avatarUrl: member.avatarURL,
        entity: member.kind == .groupchat ? .groupchat : .contact,
        status: member.status
    )
    cell.accessibilityIdentifier = "settings_circle_member_\(member.primary)"
    cell.accessibilityLabel = "\(member.displayName), \(member.jid)"
    cell.titleLabel.adjustsFontForContentSizeCategory = true
    cell.subtitleLabel.adjustsFontForContentSizeCategory = true
}
