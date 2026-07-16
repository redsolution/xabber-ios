import UIKit

#if DEBUG || CHAT_PERFORMANCE_LAB
final class ChatPerformanceFixtureViewController: ChatViewController {
    private enum AccessibilityID {
        static let timeline = "chat.performance.timeline"
        static let ready = "chat.performance.ready"
        static let state = "chat.performance.state"
        static let incoming = "chat.performance.incoming"
        static let edit = "chat.performance.edit"
        static let delete = "chat.performance.delete"
        static let mediaPrefetch = "chat.performance.media_prefetch"
        static let mediaVisible = "chat.performance.media_visible"
        static let skeleton = "chat.performance.skeleton"
        static let reveal = "chat.performance.reveal"
        static let search = "chat.performance.lastchats_search"
    }

    private let descriptor: ChatPerformanceUITestLaunchDescriptor
    private var scenarioState: ChatPerformanceScenarioState
    private var fixtureMessages: [MessageStorageItem] = []
    private var optimisticPrimary: String?
    private let releaseProbeStartedAt = CACurrentMediaTime()
    private var releaseProbeFirstStableMilliseconds: Double = 0
    private var releaseProbeResidentBytes: [UInt64] = []
    private let readyLabel = UILabel()
    private let stateLabel = UILabel()
    private let controlsScrollView = UIScrollView()
    private let controlsStack = UIStackView()

    init(descriptor: ChatPerformanceUITestLaunchDescriptor) {
        self.descriptor = descriptor
        self.scenarioState = ChatPerformanceScenarioContract.initial(scale: descriptor.scale)
        super.init(nibName: nil, bundle: nil)
        owner = "chat-performance-owner@invalid"
        jid = "chat-performance-peer@invalid"
        conversationType = .regular
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chat performance \(descriptor.scale.rowCount)"
        view.accessibilityIdentifier = "chat.performance.screen"
        messagesCollectionView.accessibilityIdentifier = AccessibilityID.timeline
        configureFixtureChrome()
        xabberInputView.isSendButtonEnabled = true
        xabberInputView.updateComposerActionReadiness()
        performanceFixtureSendHandler = { [weak self] text in
            self?.appendOptimisticMessage(body: text)
        }
        DispatchQueue.main.async { [weak self] in
            self?.loadInitialFixture()
        }
    }

    // The fixture owns deterministic, unmanaged rows. It intentionally skips
    // Realm/XMPP subscriptions while still exercising ChatViewController's
    // production mapping, layout, diff, collection and composer code paths.
    override func viewWillAppear(_ animated: Bool) {}
    override func viewDidAppear(_ animated: Bool) {}

    override func viewWillDisappear(_ animated: Bool) {
        performanceFixtureSendHandler = nil
        performTerminalChatResourceTeardownForTesting()
    }

    private func configureFixtureChrome() {
        readyLabel.accessibilityIdentifier = AccessibilityID.ready
        readyLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        readyLabel.textColor = .secondaryLabel
        readyLabel.numberOfLines = 1
        readyLabel.adjustsFontSizeToFitWidth = true
        readyLabel.minimumScaleFactor = 0.4

        stateLabel.accessibilityIdentifier = AccessibilityID.state
        stateLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 1
        stateLabel.adjustsFontSizeToFitWidth = true
        stateLabel.minimumScaleFactor = 0.4

        controlsScrollView.showsHorizontalScrollIndicator = false
        controlsScrollView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        controlsStack.axis = .horizontal
        controlsStack.spacing = 6
        controlsStack.alignment = .center

        [
            makeButton("Incoming", id: AccessibilityID.incoming, action: #selector(addIncoming)),
            makeButton("Edit", id: AccessibilityID.edit, action: #selector(editOptimistic)),
            makeButton("Delete", id: AccessibilityID.delete, action: #selector(deleteOptimistic)),
            makeButton("Prefetch", id: AccessibilityID.mediaPrefetch, action: #selector(prefetchMedia)),
            makeButton("Visible", id: AccessibilityID.mediaVisible, action: #selector(showPrefetchedMedia)),
            makeButton("Skeleton", id: AccessibilityID.skeleton, action: #selector(showFixtureSkeleton)),
            makeButton("Reveal", id: AccessibilityID.reveal, action: #selector(revealFixtureSkeleton)),
            makeButton("Search test", id: AccessibilityID.search, action: #selector(openLastChatsSearch))
        ].forEach(controlsStack.addArrangedSubview)

        [readyLabel, stateLabel, controlsScrollView, controlsStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(readyLabel)
        view.addSubview(stateLabel)
        view.addSubview(controlsScrollView)
        controlsScrollView.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            readyLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            readyLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            readyLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stateLabel.topAnchor.constraint(equalTo: readyLabel.bottomAnchor, constant: 1),
            stateLabel.leadingAnchor.constraint(equalTo: readyLabel.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: readyLabel.trailingAnchor),
            controlsScrollView.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 2),
            controlsScrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            controlsScrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            controlsScrollView.heightAnchor.constraint(equalToConstant: 34),
            controlsStack.leadingAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            controlsStack.trailingAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            controlsStack.topAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.bottomAnchor),
            controlsStack.heightAnchor.constraint(equalTo: controlsScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func makeButton(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func loadInitialFixture() {
        fixtureMessages = (0..<ChatPerformanceScenarioContract.firstFrameMessageCount).map(makeMessage)
        fixtureMessages[42].primary = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].messageId = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].archivedId = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].body = "test exact target"
        showSkeletonObserver.accept(false)
        applyFixtureMessages(mode: .fullReload(), ready: true) { [weak self] in
            self?.startReleaseProbeIfRequested()
        }
    }

    private func makeMessage(ordinal: Int) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = "chat-performance-row-\(ordinal)"
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.archivedId = "chat-performance-archive-\(ordinal)"
        item.messageId = "chat-performance-message-\(ordinal)"
        item.date = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(ordinal * 60))
        item.sentDate = item.date
        item.body = ordinal % 11 == 0
            ? String(repeating: "bounded formatted message ", count: 12)
            : "fixture message \(ordinal)"
        item.outgoing = ordinal.isMultiple(of: 3)
        item.isRead = true
        item.state = .read
        return item
    }

    private func applyFixtureMessages(
        mode: ChatDatasourceApplyMode,
        ready: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        scenarioState.residentMessageCount = fixtureMessages.count
        let isReady = ready || readyLabel.text?.hasPrefix("ready") == true
        renderStatus(isReady: isReady)
        let mapped = mapDataset(dataset: fixtureMessages)
        applyChatDatasource(
            mapped,
            mode: mode,
            animated: false,
            invalidateLayout: false,
            suppressDefaultBottomScroll: mode.isTargetedDiff,
            completion: { [weak self] in
                guard let self else { return }
                self.renderStatus(isReady: isReady)
                completion?()
            }
        )
    }

    private func startReleaseProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["XABBER_CHAT_PERFORMANCE_RELEASE_PROBE"] == "1" else {
            return
        }
        scrollFrameOperationCounter.setEnabled(true)
        scrollFrameOperationCounter.reset()
        releaseProbeFirstStableMilliseconds = (CACurrentMediaTime() - releaseProbeStartedAt) * 1_000
        releaseProbeResidentBytes.removeAll(keepingCapacity: true)
        runReleaseProbeCycle(index: 0)
    }

    private func runReleaseProbeCycle(index: Int) {
        guard index < 20 else {
            finishReleaseProbe()
            return
        }

        let item = makeMessage(ordinal: 30_000 + index)
        item.primary = "chat-performance-release-probe-\(index)"
        item.messageId = item.primary
        item.archivedId = item.primary
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff) { [weak self] in
            guard let self,
                  let itemIndex = self.fixtureMessages.firstIndex(where: { $0.primary == item.primary }) else {
                return
            }
            self.fixtureMessages.remove(at: itemIndex)
            self.applyFixtureMessages(mode: .targetedDiff) { [weak self] in
                guard let self else { return }
                self.releaseProbeResidentBytes.append(self.currentResidentMemoryBytes())
                self.runReleaseProbeCycle(index: index + 1)
            }
        }
    }

    private func finishReleaseProbe() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaPrefetch)
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaBecameVisible)

        let optimisticStart = CACurrentMediaTime()
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .optimisticSend)
        let item = makeMessage(ordinal: 40_000)
        item.primary = "chat-performance-release-optimistic"
        item.messageId = item.primary
        item.archivedId = item.primary
        item.body = "release optimistic probe"
        item.outgoing = true
        item.state = .sending
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff) { [weak self] in
            guard let self,
                  let index = self.fixtureMessages.firstIndex(where: { $0.primary == item.primary }) else {
                return
            }
            let optimisticMilliseconds = (CACurrentMediaTime() - optimisticStart) * 1_000
            self.fixtureMessages.remove(at: index)
            self.scenarioState = ChatPerformanceScenarioContract.reduce(
                self.scenarioState,
                event: .deleteOptimisticMessage
            )
            self.applyFixtureMessages(mode: .targetedDiff) { [weak self] in
                self?.emitReleaseProbeReport(optimisticMilliseconds: optimisticMilliseconds)
            }
        }
    }

    private func emitReleaseProbeReport(optimisticMilliseconds: Double) {
        let sample = ChatPerformanceReleaseSample(
            scale: descriptor.scale,
            firstStableMilliseconds: releaseProbeFirstStableMilliseconds,
            cycleResidentBytes: releaseProbeResidentBytes,
            optimisticLocalRowMilliseconds: optimisticMilliseconds,
            state: scenarioState,
            releaseOperations: scrollFrameOperationCounter.snapshot()
        )
        guard let line = try? sample.reportLine(),
              let data = (line + "\n").data(using: .utf8) else {
            return
        }
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            ChatPerformanceReleaseSample.reportFileName,
            isDirectory: false
        )
        try? data.write(to: reportURL, options: .atomic)
        FileHandle.standardOutput.write(data)
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func renderStatus(isReady: Bool) {
        let operation = scenarioState.operationSnapshot
        readyLabel.text = "\(isReady ? "ready" : "loading") scale=\(descriptor.scale.rawValue) logical=\(scenarioState.logicalMessageCount) resident=\(scenarioState.residentMessageCount) applies=\(operation.datasourceApplies) layouts=\(operation.forcedLayouts) offsets=\(operation.programmaticOffsets)"
        stateLabel.text = "anchor=\(scenarioState.anchorDrift) optimistic=\(scenarioState.optimisticMessageCount) edited=\(scenarioState.editedMessageCount) media=\(scenarioState.mediaDownloadCount)/\(scenarioState.mediaDecodeCount)/\(scenarioState.mediaVisibleCacheHitCount) skeleton=\(scenarioState.isSkeletonVisible) target=\(scenarioState.exactTargetPrimary ?? "-") corrections=\(scenarioState.operationSnapshot.delayedCorrections)"
    }

    @objc private func addIncoming() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .incomingWhileScrolled)
        let item = makeMessage(ordinal: 10_000 + fixtureMessages.count)
        item.primary = "chat-performance-incoming"
        item.body = "incoming while scrolled"
        item.outgoing = false
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff)
    }

    private func appendOptimisticMessage(body: String) {
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .optimisticSend)
        let item = makeMessage(ordinal: 20_000 + fixtureMessages.count)
        item.primary = "chat-performance-optimistic-\(UUID().uuidString)"
        item.messageId = item.primary
        item.archivedId = item.primary
        item.body = body
        item.outgoing = true
        item.state = .sending
        optimisticPrimary = item.primary
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func editOptimistic() {
        guard let optimisticPrimary,
              let item = fixtureMessages.first(where: { $0.primary == optimisticPrimary }) else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .editOptimisticMessage)
        item.body += " edited"
        item.editDate = Date()
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func deleteOptimistic() {
        guard let optimisticPrimary,
              let index = fixtureMessages.firstIndex(where: { $0.primary == optimisticPrimary }) else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .deleteOptimisticMessage)
        fixtureMessages.remove(at: index)
        self.optimisticPrimary = nil
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func prefetchMedia() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaPrefetch)
        renderStatus(isReady: true)
    }

    @objc private func showPrefetchedMedia() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaBecameVisible)
        renderStatus(isReady: true)
    }

    @objc private func showFixtureSkeleton() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .showSkeleton)
        renderStatus(isReady: true)
        showSkeletonObserver.accept(true)
        let skeleton = mapDataset(dataset: [])
        applyChatDatasource(
            skeleton,
            mode: .fullReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true,
            completion: { [weak self] in self?.renderStatus(isReady: true) }
        )
    }

    @objc private func revealFixtureSkeleton() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .revealSkeleton)
        renderStatus(isReady: true)
        showSkeletonObserver.accept(false)
        applyFixtureMessages(mode: .fullReload(keepOffset: true))
    }

    @objc private func openLastChatsSearch() {
        let controller = ChatPerformanceLastChatsSearchViewController { [weak self] query in
            self?.routeFromSearch(query: query)
        }
        navigationController?.pushViewController(controller, animated: false)
    }

    private func routeFromSearch(query: String) {
        scenarioState = ChatPerformanceScenarioContract.reduce(
            scenarioState,
            event: .searchExactTarget(query: query)
        )
        navigationController?.popViewController(animated: false)
        guard let index = datasource.firstIndex(where: {
            $0.primary == ChatPerformanceScenarioContract.exactTargetPrimary
        }) else {
            renderStatus(isReady: true)
            return
        }
        messagesCollectionView.layoutIfNeeded()
        messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: index),
            at: .centeredVertically,
            animated: false
        )
        renderStatus(isReady: true)
    }
}

private extension ChatDatasourceApplyMode {
    var isTargetedDiff: Bool {
        if case .targetedDiff = self { return true }
        return false
    }
}

final class ChatPerformanceLastChatsSearchViewController: UITableViewController, UISearchResultsUpdating {
    private let onSelect: (String) -> Void
    private var query = ""

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Last Chats Search"
        view.accessibilityIdentifier = "lastchats.performance.screen"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "result")
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.searchTextField.accessibilityIdentifier = "lastchats.performance.search_input"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        query.compare("test", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? 1 : 0
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "result", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "test exact target"
        content.secondaryText = ChatPerformanceScenarioContract.exactTargetPrimary
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "lastchats.performance.exact_result"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(query)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tableView.reloadData()
    }
}
#endif
