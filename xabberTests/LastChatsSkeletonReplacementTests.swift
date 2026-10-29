import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LastChatsSkeletonReplacementTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var retainedRealm: Realm!
    private var previousAnimationsEnabled = true

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsSkeletonReplacementTests-\(UUID().uuidString)"
        )
        retainedRealm = try WRealm.safe()
        previousAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
    }

    override func tearDownWithError() throws {
        UIView.setAnimationsEnabled(previousAnimationsEnabled)
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        try super.tearDownWithError()
    }

    func testSkeletonReplacementWithOneChatDisablesAnimationsForSmallAndLargeDiffs() throws {
        for skeletonCount in [1, 10] {
            try withAttachedTable { controller, table in
                controller.skeletonItemsCount = skeletonCount
                controller.showSkeleton.accept(true)
                let skeleton = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
                let oldSections = install(skeleton, showsSkeleton: true, in: controller)
                XCTAssertTrue(table.visibleCells.contains { $0 is LastChatsViewController.SkeletonCell })
                let chats = try makeChatRows(count: 1, controller: controller)
                let newSections = LastChatsViewController.makeDatasourceSections(from: chats, showsSkeleton: false)
                var animationsDuringPrepare: Bool?
                table.resetObservations()

                controller.apply(
                    changes: LastChatsViewController.sectionedChanges(oldSections: oldSections, newSections: newSections),
                    oldSections: oldSections, newSections: newSections,
                    oldShowsSkeleton: true, newShowsSkeleton: false
                ) {
                    animationsDuringPrepare = UIView.areAnimationsEnabled
                    controller.setDatasource(chats, sections: newSections, showsSkeleton: false)
                }
                table.layoutIfNeeded()

                XCTAssertEqual(animationsDuringPrepare, false, "skeleton rows: \(skeletonCount)")
                XCTAssertEqual(table.reloadAnimationStates, [false])
                XCTAssertEqual(table.batchCount, 0)
                XCTAssertTrue(table.rowAnimations.isEmpty)
                XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
                XCTAssertFalse(table.visibleCells.contains { $0 is LastChatsViewController.SkeletonCell })
                XCTAssertTrue(table.visibleCells.contains { $0 is ChatListTableViewCell })
                XCTAssertTrue(UIView.areAnimationsEnabled)
            }
        }
    }

    func testSkeletonReplacementWithEmptyListAlsoDisablesAnimations() throws {
        try withAttachedTable { controller, table in
            controller.skeletonItemsCount = 1
            controller.showSkeleton.accept(true)
            let skeleton = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
            let oldSections = install(skeleton, showsSkeleton: true, in: controller)
            let chats = try makeChatRows(count: 0, controller: controller)
            let newSections = LastChatsViewController.makeDatasourceSections(from: chats, showsSkeleton: false)
            var animationsDuringPrepare: Bool?
            table.resetObservations()

            controller.apply(
                changes: LastChatsViewController.sectionedChanges(oldSections: oldSections, newSections: newSections),
                oldSections: oldSections, newSections: newSections,
                oldShowsSkeleton: true, newShowsSkeleton: false
            ) {
                animationsDuringPrepare = UIView.areAnimationsEnabled
                controller.setDatasource(chats, sections: newSections, showsSkeleton: false)
            }
            table.layoutIfNeeded()

            XCTAssertEqual(animationsDuringPrepare, false)
            XCTAssertEqual(table.reloadAnimationStates, [false])
            XCTAssertEqual(table.batchCount, 0)
            XCTAssertTrue(table.rowAnimations.isEmpty)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 0)
            XCTAssertTrue(table.visibleCells.isEmpty)
            XCTAssertTrue(UIView.areAnimationsEnabled)
        }
    }

    func testSubsequentRealChatInsertionPreservesNormalTableAnimations() throws {
        try withAttachedTable { controller, table in
            let initialChats = try makeChatRows(count: 1, controller: controller)
            let oldSections = install(initialChats, showsSkeleton: false, in: controller)
            let updatedChats = try makeChatRows(count: 2, controller: controller)
            let newSections = LastChatsViewController.makeDatasourceSections(from: updatedChats, showsSkeleton: false)
            var animationsDuringPrepare: Bool?
            table.resetObservations()

            controller.apply(
                changes: LastChatsViewController.sectionedChanges(oldSections: oldSections, newSections: newSections),
                oldSections: oldSections, newSections: newSections,
                oldShowsSkeleton: false, newShowsSkeleton: false
            ) {
                animationsDuringPrepare = UIView.areAnimationsEnabled
                controller.setDatasource(updatedChats, sections: newSections, showsSkeleton: false)
            }

            XCTAssertEqual(animationsDuringPrepare, true)
            XCTAssertTrue(table.reloadAnimationStates.isEmpty)
            XCTAssertEqual(table.batchCount, 1)
            XCTAssertEqual(table.rowAnimations, [.automatic])
            XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
            XCTAssertTrue(UIView.areAnimationsEnabled)
        }
    }

    private func install(
        _ rows: [LastChatsViewController.Datasource], showsSkeleton: Bool,
        in controller: LastChatsViewController
    ) -> [LastChatsViewController.DatasourceSection] {
        let sections = LastChatsViewController.makeDatasourceSections(from: rows, showsSkeleton: showsSkeleton)
        controller.setDatasource(rows, sections: sections, showsSkeleton: showsSkeleton)
        controller.tableView.reloadData()
        controller.tableView.layoutIfNeeded()
        return sections
    }

    private func makeChatRows(count: Int, controller: LastChatsViewController) throws -> [LastChatsViewController.Datasource] {
        let account = AccountStorageItem()
        account.jid = "skeleton-owner@example.test"
        try retainedRealm.write {
            retainedRealm.add(account, update: .modified)
            for index in 0..<count {
                let chat = LastChatsStorageItem()
                chat.owner = account.jid
                chat.jid = "peer-\(index)@example.test"
                chat.conversationType = .regular
                chat.setPrimary(withOwner: account.jid)
                retainedRealm.add(chat, update: .modified)
            }
        }
        controller.enabledAccounts.accept([account.jid])
        controller.showSkeleton.accept(false)
        return controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
    }

    private func withAttachedTable(_ body: (LastChatsViewController, RecordingTableView) throws -> Void) throws {
        let controller = FixtureViewController()
        let table = RecordingTableView(frame: .zero, style: .plain)
        table.register(LastChatsViewController.SkeletonCell.self, forCellReuseIdentifier: LastChatsViewController.SkeletonCell.cellName)
        table.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        controller.tableView = table
        table.dataSource = controller
        table.delegate = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let batchCompleted = XCTestExpectation(description: "native table batch completes before fixture teardown")
        table.onBatchCompletion = { batchCompleted.fulfill() }
        defer {
            if table.batchCount > 0 { wait(for: [batchCompleted], timeout: 2) }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        XCTAssertTrue(table.window === window)
        try body(controller, table)
    }

    private final class RecordingTableView: UITableView {
        var reloadAnimationStates: [Bool] = []
        var rowAnimations: [UITableView.RowAnimation] = []
        var batchCount = 0
        var onBatchCompletion: (() -> Void)?

        func resetObservations() { reloadAnimationStates = []; rowAnimations = []; batchCount = 0 }
        override func reloadData() { reloadAnimationStates.append(UIView.areAnimationsEnabled); super.reloadData() }
        override func insertRows(at indexPaths: [IndexPath], with animation: UITableView.RowAnimation) {
            rowAnimations.append(animation); super.insertRows(at: indexPaths, with: animation)
        }
        override func deleteRows(at indexPaths: [IndexPath], with animation: UITableView.RowAnimation) {
            rowAnimations.append(animation); super.deleteRows(at: indexPaths, with: animation)
        }
        override func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)? = nil) {
            batchCount += 1
            super.performBatchUpdates(updates) { result in completion?(result); self.onBatchCompletion?() }
        }
    }

    private final class FixtureViewController: LastChatsViewController {
        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 640))
            view.addSubview(tableView)
            tableView.frame = view.bounds
            tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        override func viewDidLoad() {}
        override func viewDidLayoutSubviews() {}
        override func viewSafeAreaInsetsDidChange() {}
        override func viewWillAppear(_ animated: Bool) {}
        override func viewDidAppear(_ animated: Bool) {}
        override func viewWillDisappear(_ animated: Bool) {}
        override func viewDidDisappear(_ animated: Bool) {}
        override func shouldChangeFrame() {}
    }
}
