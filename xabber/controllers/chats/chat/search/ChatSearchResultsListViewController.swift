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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import UIKit

struct ChatSearchResultsListRenderModel: Equatable {
    enum Phase: Equatable {
        case loadingFirstPage
        case loadingNextPage
        case populated
        case empty
        case error
    }

    let generation: UInt64
    let results: [ChatSearchResult]
    let selectedID: ChatSearchResult.ID?
    let phase: Phase

    init(
        generation: UInt64,
        results: [ChatSearchResult],
        selectedID: ChatSearchResult.ID?,
        phase: Phase
    ) {
        self.generation = generation
        self.results = ChatSearchResultCollection.orderedAndDeduplicated(results)
        self.selectedID = selectedID
        self.phase = phase
    }

    var canPresent: Bool {
        guard let selectedID else { return false }
        return results.contains { $0.id == selectedID }
    }
}

struct ChatSearchResultsListScrollAnchor: Equatable {
    let id: ChatSearchResult.ID
    let offsetFromTop: CGFloat
}

struct ChatSearchResultsListSnapshotPlan: Equatable {
    let itemIDs: [ChatSearchResult.ID]
    let reconfiguredIDs: [ChatSearchResult.ID]
    let retainedAnchor: ChatSearchResultsListScrollAnchor?

    static func make(
        previous: [ChatSearchResult],
        incoming: [ChatSearchResult],
        visibleAnchor: ChatSearchResultsListScrollAnchor?
    ) -> ChatSearchResultsListSnapshotPlan {
        let normalized = ChatSearchResultCollection.orderedAndDeduplicated(incoming)
        let previousByID = Dictionary(
            previous.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let itemIDs = normalized.map(\.id)
        let reconfiguredIDs = normalized.compactMap { result -> ChatSearchResult.ID? in
            guard let previousResult = previousByID[result.id],
                  previousResult != result else {
                return nil
            }
            return result.id
        }
        let retainedAnchor = visibleAnchor.flatMap { anchor in
            itemIDs.contains(anchor.id) ? anchor : nil
        }
        return ChatSearchResultsListSnapshotPlan(
            itemIDs: itemIDs,
            reconfiguredIDs: reconfiguredIDs,
            retainedAnchor: retainedAnchor
        )
    }
}

enum ChatSearchResultsListInsetsPolicy {
    static let topChromeHeight: CGFloat = 60
    static let bottomBarHeight: CGFloat = 40

    static func contentInsets(
        safeAreaInsets: UIEdgeInsets,
        keyboardOverlap: CGFloat
    ) -> UIEdgeInsets {
        UIEdgeInsets(
            top: safeAreaInsets.top + topChromeHeight,
            left: safeAreaInsets.left,
            bottom: max(safeAreaInsets.bottom, max(0, keyboardOverlap)) + bottomBarHeight,
            right: safeAreaInsets.right
        )
    }
}

enum ChatSearchResultsListContainment {
    static func install(
        _ controller: ChatSearchResultsListViewController,
        in containerView: UIView,
        parent: UIViewController
    ) {
        if controller.parent === parent,
           controller.view.superview === containerView {
            return
        }

        if controller.parent != nil || controller.view.superview != nil {
            remove(controller)
        }

        parent.addChild(controller)
        containerView.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        controller.didMove(toParent: parent)
    }

    static func remove(_ controller: ChatSearchResultsListViewController) {
        controller.prepareForRemoval()
        let hadParent = controller.parent != nil
        if hadParent {
            controller.willMove(toParent: nil)
        }
        controller.view.removeFromSuperview()
        if hadParent {
            controller.removeFromParent()
        }
    }
}

private final class ChatSearchResultsListStateView: UIView {
    let label = UILabel()

    init(text: String, accessibilityIdentifier: String) {
        super.init(frame: .zero)
        backgroundColor = .clear
        self.accessibilityIdentifier = accessibilityIdentifier
        isAccessibilityElement = true
        accessibilityLabel = text

        label.text = text
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class ChatSearchResultsListViewController: UIViewController, UITableViewDelegate {
    enum Section: Hashable {
        case main
    }

    let tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .systemBackground
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = ChatSearchResultCellLayoutPolicy.standardRowHeight
        tableView.estimatedRowHeight = ChatSearchResultCellLayoutPolicy.standardRowHeight
        tableView.accessibilityIdentifier = "chat_search_results_list"
        return tableView
    }()

    let emptyView: UIView = ChatSearchResultsListStateView(
        text: "No messages found".localizeString(
            id: "chat_search_results_empty",
            arguments: []
        ),
        accessibilityIdentifier: "chat_search_results_empty"
    )

    let errorView = UIView()
    let errorRetryButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(
            "Try Again".localizeString(id: "try_again", arguments: []),
            for: .normal
        )
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "chat_search_results_retry"
        return button
    }()

    let firstPageLoadingView = UIView()
    let pagingIndicatorView: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.accessibilityIdentifier = "chat_search_results_paging"
        indicator.isAccessibilityElement = true
        indicator.accessibilityLabel = "Loading messages".localizeString(
            id: "chat_search_results_loading",
            arguments: []
        )
        return indicator
    }()

    var onSelectResult: ((ChatSearchResult.ID) -> Void)?
    var onRetry: ((UInt64) -> Void)?

    private(set) var diffableDataSource: UITableViewDiffableDataSource<Section, ChatSearchResult.ID>?
    private(set) var latestGeneration: UInt64?
    private(set) var displayedResultIDs: [ChatSearchResult.ID] = []
    private(set) var lastReconfiguredResultIDs: [ChatSearchResult.ID] = []
    private(set) var lastRetainedScrollAnchor: ChatSearchResultsListScrollAnchor?
    private(set) var lastProgrammaticScrollID: ChatSearchResult.ID?
    private(set) var isPreparedForRemoval = false
    private(set) var isPagingIndicatorVisible = false

    private var currentResults: [ChatSearchResult] = []
    private var resultsByID: [ChatSearchResult.ID: ChatSearchResult] = [:]
    private var currentModel: ChatSearchResultsListRenderModel?
    private let trackedCells = NSHashTable<ChatSearchResultCell>.weakObjects()
    private let firstPageIndicator = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private let pagingFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 44))

    override func viewDidLoad() {
        super.viewDidLoad()
        prepareView()
        configureDataSourceIfNeeded()
        renderCurrentState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let keyboardFrame = view.keyboardLayoutGuide.layoutFrame
        let keyboardOverlap = keyboardFrame.height > 0
            ? max(0, view.bounds.maxY - keyboardFrame.minY)
            : 0
        updateContentInsets(
            safeAreaInsets: view.safeAreaInsets,
            keyboardOverlap: keyboardOverlap
        )
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    func render(_ model: ChatSearchResultsListRenderModel, animated: Bool = false) {
        loadViewIfNeeded()
        if let latestGeneration, model.generation < latestGeneration {
            return
        }
        configureDataSourceIfNeeded()
        isPreparedForRemoval = false
        latestGeneration = model.generation

        let visibleAnchor = captureVisibleAnchor()
        let plan = ChatSearchResultsListSnapshotPlan.make(
            previous: currentResults,
            incoming: model.results,
            visibleAnchor: visibleAnchor
        )
        currentModel = ChatSearchResultsListRenderModel(
            generation: model.generation,
            results: model.results,
            selectedID: model.selectedID,
            phase: model.phase
        )
        currentResults = currentModel?.results ?? []
        resultsByID = Dictionary(
            currentResults.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        displayedResultIDs = plan.itemIDs
        lastReconfiguredResultIDs = plan.reconfiguredIDs
        lastRetainedScrollAnchor = plan.retainedAnchor

        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatSearchResult.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(plan.itemIDs, toSection: .main)
        if !plan.reconfiguredIDs.isEmpty {
            snapshot.reconfigureItems(plan.reconfiguredIDs)
        }
        diffableDataSource?.apply(
            snapshot,
            animatingDifferences: animated
        ) { [weak self] in
            guard let self, let anchor = plan.retainedAnchor else { return }
            self.restoreVisibleAnchor(anchor)
        }
        renderCurrentState()
    }

    func updateContentInsets(
        safeAreaInsets: UIEdgeInsets,
        keyboardOverlap: CGFloat
    ) {
        let insets = ChatSearchResultsListInsetsPolicy.contentInsets(
            safeAreaInsets: safeAreaInsets,
            keyboardOverlap: keyboardOverlap
        )
        if tableView.contentInset != insets {
            tableView.contentInset = insets
        }
        if tableView.scrollIndicatorInsets != insets {
            tableView.scrollIndicatorInsets = insets
        }
    }

    @discardableResult
    func scrollToResult(
        id: ChatSearchResult.ID,
        animated: Bool
    ) -> Bool {
        guard let index = displayedResultIDs.firstIndex(of: id) else {
            return false
        }
        lastProgrammaticScrollID = id
        let indexPath = IndexPath(row: index, section: 0)
        if tableView.numberOfSections > 0,
           tableView.numberOfRows(inSection: 0) > index {
            tableView.scrollToRow(at: indexPath, at: .middle, animated: animated)
        }
        return true
    }

    func prepareForRemoval() {
        trackedCells.allObjects.forEach { $0.prepareForReuse() }
        trackedCells.removeAllObjects()
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatSearchResult.ID>()
        snapshot.appendSections([.main])
        diffableDataSource?.apply(snapshot, animatingDifferences: false)
        tableView.dataSource = nil
        tableView.delegate = nil
        diffableDataSource = nil
        currentResults.removeAll()
        resultsByID.removeAll()
        displayedResultIDs.removeAll()
        lastReconfiguredResultIDs.removeAll()
        lastRetainedScrollAnchor = nil
        currentModel = nil
        latestGeneration = nil
        onSelectResult = nil
        onRetry = nil
        stopPagingIndicators()
        isPreparedForRemoval = true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let id = diffableDataSource?.itemIdentifier(for: indexPath) else {
            return
        }
        onSelectResult?(id)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        ChatSearchResultCellLayoutPolicy.rowHeight(
            for: traitCollection.preferredContentSizeCategory
        )
    }

    private func prepareView() {
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "chat_search_results_list"

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.register(
            ChatSearchResultCell.self,
            forCellReuseIdentifier: ChatSearchResultCell.reuseIdentifier
        )
        view.addSubview(tableView)

        prepareEmptyView()
        prepareErrorView()
        prepareFirstPageLoadingView()
        preparePagingFooter()

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func prepareEmptyView() {
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func prepareErrorView() {
        errorView.backgroundColor = .clear
        errorView.accessibilityIdentifier = "chat_search_results_error"
        errorView.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.text = "Search failed".localizeString(
            id: "chat_search_results_error",
            arguments: []
        )
        errorLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [errorLabel, errorRetryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        errorRetryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        view.addSubview(errorView)

        NSLayoutConstraint.activate([
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor)
        ])
    }

    private func prepareFirstPageLoadingView() {
        firstPageLoadingView.backgroundColor = .clear
        firstPageLoadingView.accessibilityIdentifier = "chat_search_results_paging"
        firstPageLoadingView.isAccessibilityElement = true
        firstPageLoadingView.accessibilityLabel = pagingIndicatorView.accessibilityLabel
        firstPageLoadingView.translatesAutoresizingMaskIntoConstraints = false
        firstPageIndicator.hidesWhenStopped = true
        firstPageIndicator.translatesAutoresizingMaskIntoConstraints = false
        firstPageLoadingView.addSubview(firstPageIndicator)
        view.addSubview(firstPageLoadingView)
        NSLayoutConstraint.activate([
            firstPageLoadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            firstPageLoadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            firstPageLoadingView.topAnchor.constraint(equalTo: view.topAnchor),
            firstPageLoadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            firstPageIndicator.centerXAnchor.constraint(equalTo: firstPageLoadingView.centerXAnchor),
            firstPageIndicator.centerYAnchor.constraint(equalTo: firstPageLoadingView.centerYAnchor)
        ])
    }

    private func preparePagingFooter() {
        pagingFooterView.backgroundColor = .clear
        pagingIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        pagingFooterView.addSubview(pagingIndicatorView)
        NSLayoutConstraint.activate([
            pagingIndicatorView.centerXAnchor.constraint(equalTo: pagingFooterView.centerXAnchor),
            pagingIndicatorView.centerYAnchor.constraint(equalTo: pagingFooterView.centerYAnchor)
        ])
    }

    private func configureDataSourceIfNeeded() {
        guard diffableDataSource == nil else {
            tableView.delegate = self
            return
        }
        tableView.delegate = self
        let dataSource = UITableViewDiffableDataSource<Section, ChatSearchResult.ID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            guard let self,
                  let result = self.resultsByID[id],
                  let cell = tableView.dequeueReusableCell(
                    withIdentifier: ChatSearchResultCell.reuseIdentifier,
                    for: indexPath
                  ) as? ChatSearchResultCell else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }
            cell.configure(with: result)
            cell.accessibilityIdentifier = "chat_search_result_row.\(self.accessibilityToken(for: id))"
            self.trackedCells.add(cell)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        diffableDataSource = dataSource
    }

    private func renderCurrentState() {
        let phase = currentModel?.phase ?? .loadingFirstPage
        let hasResults = displayedResultIDs.isNotEmpty

        tableView.isHidden = !hasResults
        emptyView.isHidden = true
        errorView.isHidden = true
        firstPageLoadingView.isHidden = true
        stopPagingIndicators()

        switch phase {
        case .loadingFirstPage:
            if hasResults {
                tableView.isHidden = false
            } else {
                firstPageLoadingView.isHidden = false
                firstPageIndicator.startAnimating()
            }
        case .loadingNextPage:
            tableView.isHidden = !hasResults
            if hasResults {
                tableView.tableFooterView = pagingFooterView
                pagingIndicatorView.startAnimating()
                isPagingIndicatorVisible = true
            }
        case .populated:
            tableView.isHidden = !hasResults
            if !hasResults {
                emptyView.isHidden = false
            }
        case .empty:
            tableView.isHidden = true
            emptyView.isHidden = false
        case .error:
            tableView.isHidden = !hasResults
            errorView.isHidden = false
        }
    }

    private func stopPagingIndicators() {
        firstPageIndicator.stopAnimating()
        pagingIndicatorView.stopAnimating()
        tableView.tableFooterView = nil
        isPagingIndicatorVisible = false
    }

    private func captureVisibleAnchor() -> ChatSearchResultsListScrollAnchor? {
        guard let indexPath = tableView.indexPathsForVisibleRows?.min(),
              let id = diffableDataSource?.itemIdentifier(for: indexPath) else {
            return nil
        }
        let frame = tableView.rectForRow(at: indexPath)
        return ChatSearchResultsListScrollAnchor(
            id: id,
            offsetFromTop: frame.minY - tableView.contentOffset.y
        )
    }

    private func restoreVisibleAnchor(_ anchor: ChatSearchResultsListScrollAnchor) {
        guard let index = displayedResultIDs.firstIndex(of: anchor.id) else {
            return
        }
        tableView.layoutIfNeeded()
        let indexPath = IndexPath(row: index, section: 0)
        guard tableView.numberOfRows(inSection: 0) > index else { return }
        let frame = tableView.rectForRow(at: indexPath)
        tableView.setContentOffset(
            CGPoint(
                x: tableView.contentOffset.x,
                y: frame.minY - anchor.offsetFromTop
            ),
            animated: false
        )
    }

    private func accessibilityToken(for id: ChatSearchResult.ID) -> String {
        switch id {
        case .archived(let value):
            return "archived.\(value)"
        case .primary(let value):
            return "primary.\(value)"
        }
    }

    @objc
    private func retryTapped() {
        guard let generation = latestGeneration else { return }
        onRetry?(generation)
    }
}

extension ChatViewController {
    func installChatSearchResultsListController(
        _ controller: ChatSearchResultsListViewController
    ) {
        if let current = searchResultsListViewController,
           current !== controller {
            ChatSearchResultsListContainment.remove(current)
        }
        ChatSearchResultsListContainment.install(
            controller,
            in: view,
            parent: self
        )
        searchResultsListViewController = controller
        view.bringSubviewToFront(xabberInputView)
        view.bringSubviewToFront(searchNavigationButtonsView)
        bringSearchInputOverlayToFront()
    }

    func removeChatSearchResultsListController() {
        guard let controller = searchResultsListViewController else { return }
        ChatSearchResultsListContainment.remove(controller)
        searchResultsListViewController = nil
    }
}
