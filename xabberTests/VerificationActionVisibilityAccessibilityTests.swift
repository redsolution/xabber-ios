import RealmSwift
import UIKit
import XCTest
@testable import xabber

/// Real banner renderers with isolated local state; never starts transport or changes trust.
@MainActor
final class VerificationActionVisibilityAccessibilityTests: XCTestCase {
    private var previousRealm: Realm.Configuration!
    private var realm: Realm!
    private var previousUsers: [Account] = []
    private var accounts: [Account] = []
    private let peer = "contact@example.test"

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "VerificationAction-\(UUID())")
        realm = try WRealm.safe()
        previousUsers = AccountManager.shared.users
    }

    override func tearDownWithError() throws {
        guard previousRealm != nil else { return }
        for account in accounts {
            account.queue.sync {}
            account.cancelDelayedConnectTimer()
            account.omemo.omemo2MaintenanceWorkItem?.cancel()
            account.omemo.clearSession()
            account.xmppTaskScheduler.reset()
            account.messages.updateSendingMessagesTimer?.invalidate()
            CredentialsManager.shared.removeDeviceId(for: account.jid)
        }
        AccountManager.shared.users = previousUsers
        accounts.removeAll()
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        try super.tearDownWithError()
    }

    func testSettingsIncomingRequestShowsAccessibleProceed() throws {
        try assertSettings(.receivedRequest, key: "settings__action__proceed_to_verification", fallback: "Proceed to Verification", action: "onAcceptButtonPressed")
    }

    func testSettingsAcceptedRequestShowsAccessibleCodeDisplayAction() throws {
        try assertSettings(.acceptedRequest, key: "settings__action__show_the_code", fallback: "Show the code", action: "onShowCodePressed")
    }

    func testSettingsAcceptedOutgoingRequestShowsAccessibleCodeEntryAction() throws {
        try assertSettings(.receivedRequestAccept, role: .initiator, key: "settings__action__enter_the_code", fallback: "Enter the code", action: "onEnterCodePressed")
    }

    func testContactIncomingRequestShowsAccessibleProceed() throws {
        try assertContact(.receivedRequest, key: "contact_device__verification__proceed_to_verification", fallback: "Proceed to Verification", action: "onAcceptButtonPressed")
    }

    func testContactAcceptedRequestShowsAccessibleCodeDisplayAction() throws {
        try assertContact(.acceptedRequest, key: "contact_device__verification__show_the_code", fallback: "Show the code", action: "onShowCodePressed")
    }

    func testContactAcceptedOutgoingRequestShowsAccessibleCodeEntryAction() throws {
        try assertContact(.receivedRequestAccept, role: .initiator, key: "contact_device__verification__enter_the_code", fallback: "Enter the code", action: "onEnterCodePressed")
    }

    func testUnverifiedContactWithoutSessionShowsVerifyAndNoCloseAction() throws {
        let controller = contact(try fixture())
        XCTAssertNil(controller.activeVerificationSessionSid)
        let cell = try contactCell(controller)
        assertVisibleAction(cell, title: L10n.text("action_verify", fallback: "VERIFY"), target: controller, action: "onVerifyButtonPressed")
        XCTAssertFalse(cell.closeButton.isDescendant(of: cell))
    }

    func testSettingsWithoutSessionDoesNotInventVerificationAction() throws {
        let controller = settings(try fixture())
        XCTAssertNil(controller.activeVerificationSessionSid)
        XCTAssertFalse(controller.datasource.contains { $0.section == .session })
    }

    func testSettingsWaitingForPeerDoesNotShowStaleAction() throws {
        let account = try fixture()
        _ = try session(account, state: .sentRequest, role: .initiator)
        assertHiddenAction(try settingsCell(settings(account)))
    }

    func testContactWaitingForPeerDoesNotShowStaleAction() throws {
        let account = try fixture()
        _ = try session(account, jid: peer, state: .sentRequest, role: .initiator)
        assertHiddenAction(try contactCell(contact(account)))
    }

    func testSettingsTerminalTransitionBeforeRenderingKeepsActionHidden() throws {
        for state in [VerificationSessionStorageItem.VerififcationState.cancelled, .timeout, .failed, .trusted] {
            let account = try fixture()
            let row = try session(account, state: .receivedRequest)
            let controller = settings(account)
            try realm.write { row.state = state }
            assertHiddenAction(try settingsCell(controller))
            XCTAssertEqual(row.state, state)
        }
    }

    func testContactTerminalTransitionBeforeRenderingKeepsActionHidden() throws {
        for state in [VerificationSessionStorageItem.VerififcationState.cancelled, .timeout, .failed, .trusted] {
            let account = try fixture()
            let row = try session(account, jid: peer, state: .receivedRequest)
            let controller = contact(account)
            try realm.write { row.state = state }
            assertHiddenAction(try contactCell(controller))
            XCTAssertEqual(row.state, state)
        }
    }

    func testSettingsRerenderFollowsCurrentActionWithoutStaleTitleOrTarget() throws {
        let account = try fixture()
        let row = try session(account, state: .receivedRequest)
        let controller = settings(account)
        for (state, role, key, fallback, action) in actionStates(prefix: "settings__action__") {
            try realm.write { row.state = state; row.role = role }
            controller.load()
            assertVisibleAction(try settingsCell(controller), title: L10n.text(key, fallback: fallback), target: controller, action: action)
        }
    }

    func testContactRerenderFollowsCurrentActionWithoutStaleTitleOrTarget() throws {
        let account = try fixture()
        let row = try session(account, jid: peer, state: .receivedRequest)
        let controller = contact(account)
        for (state, role, key, fallback, action) in actionStates(prefix: "contact_device__verification__") {
            try realm.write { row.state = state; row.role = role }
            controller.loadDatasource()
            assertVisibleAction(try contactCell(controller), title: L10n.text(key, fallback: fallback), target: controller, action: action)
        }
    }

    func testSharedCellReconfigurationAndReuseDoNotExposePriorAction() {
        let cell = VerificationSessionTableViewCell()
        let target = UIButton()
        cell.configure(title: "Incoming request", subtitle: nil)
        cell.showVerificationButton(title: "Proceed")
        cell.blueButton.addTarget(target, action: #selector(UIButton.setNeedsLayout), for: .touchUpInside)
        assertVisibleAction(cell, title: "Proceed", target: target, action: "setNeedsLayout")
        cell.configure(title: "Waiting for peer", subtitle: nil)
        assertHiddenAction(cell)
        cell.showVerificationButton(title: "Enter the code")
        assertVisibleAction(cell, title: "Enter the code", target: target, action: "setNeedsLayout")
        XCTAssertEqual(cell.labelsStack.arrangedSubviews.filter { $0 === cell.blueButton }.count, 1)
        cell.prepareForReuse()
        assertHiddenAction(cell)
        XCTAssertTrue(cell.blueButton.allTargets.isEmpty)
        cell.configure(title: "New request", subtitle: nil)
        cell.showVerificationButton(title: "Show the code")
        XCTAssertEqual(cell.blueButton.accessibilityLabel, "Show the code")
        XCTAssertEqual(cell.blueButton.configuration?.title, "Show the code")
    }

    private func assertSettings(_ state: VerificationSessionStorageItem.VerififcationState,
        role: VerificationSessionStorageItem.VerificationRole = .responder, key: String, fallback: String, action: String) throws {
        let account = try fixture()
        let row = try session(account, state: state, role: role)
        let controller = settings(account)
        XCTAssertEqual(controller.activeVerificationSessionSid, row.sid)
        let cell = try settingsCell(controller)
        assertVisibleAction(cell, title: L10n.text(key, fallback: fallback), target: controller, action: action)
        XCTAssertFalse(cell.closeButton.isHidden)
        XCTAssertTrue(cell.closeButton.actions(forTarget: controller, forControlEvent: .touchUpInside)?.contains("onCloseVerificationButtonPressed") == true)
        XCTAssertEqual(row.state, state)
    }

    private func assertContact(_ state: VerificationSessionStorageItem.VerififcationState,
        role: VerificationSessionStorageItem.VerificationRole = .responder, key: String, fallback: String, action: String) throws {
        let account = try fixture()
        let row = try session(account, jid: peer, state: state, role: role)
        let controller = contact(account)
        XCTAssertEqual(controller.activeVerificationSessionSid, row.sid)
        let cell = try contactCell(controller)
        assertVisibleAction(cell, title: L10n.text(key, fallback: fallback), target: controller, action: action)
        XCTAssertFalse(cell.closeButton.isHidden)
        XCTAssertTrue(cell.closeButton.actions(forTarget: controller, forControlEvent: .touchUpInside)?.contains("onCloseButtonPressed") == true)
        XCTAssertEqual(row.state, state)
    }

    private func assertVisibleAction(_ cell: VerificationSessionTableViewCell, title: String, target: AnyObject, action: String,
        file: StaticString = #filePath, line: UInt = #line) {
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        let button = cell.blueButton
        XCTAssertFalse(button.isHidden, "The rendered action must be visible", file: file, line: line)
        XCTAssertTrue(button.isEnabled, file: file, line: line)
        XCTAssertTrue(button.isDescendant(of: cell), file: file, line: line)
        XCTAssertTrue(cell.labelsStack.arrangedSubviews.contains(button), file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44, file: file, line: line)
        XCTAssertGreaterThan(button.bounds.width, 0, file: file, line: line)
        XCTAssertEqual(button.currentTitle, title, file: file, line: line)
        XCTAssertEqual(button.configuration?.title, title, file: file, line: line)
        XCTAssertEqual(button.accessibilityLabel, title, file: file, line: line)
        XCTAssertEqual(button.accessibilityIdentifier, "verification_session_verify_button", file: file, line: line)
        XCTAssertTrue(button.accessibilityHint?.isEmpty == false, file: file, line: line)
        XCTAssertTrue(button.actions(forTarget: target, forControlEvent: .touchUpInside)?.contains(action) == true, file: file, line: line)
    }

    private func assertHiddenAction(_ cell: VerificationSessionTableViewCell, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cell.blueButton.isHidden, file: file, line: line)
        XCTAssertFalse(cell.blueButton.isDescendant(of: cell), file: file, line: line)
        XCTAssertFalse(cell.labelsStack.arrangedSubviews.contains(cell.blueButton), file: file, line: line)
    }

    private func actionStates(prefix: String) -> [(VerificationSessionStorageItem.VerififcationState, VerificationSessionStorageItem.VerificationRole, String, String, String)] {
        [(.receivedRequest, .responder, prefix + "proceed_to_verification", "Proceed to Verification", "onAcceptButtonPressed"),
         (.acceptedRequest, .responder, prefix + "show_the_code", "Show the code", "onShowCodePressed"),
         (.receivedRequestAccept, .initiator, prefix + "enter_the_code", "Enter the code", "onEnterCodePressed")]
    }

    private func fixture() throws -> Account {
        let owner = "action-\(UUID().uuidString.lowercased())@example.test"
        let row = AccountStorageItem(); row.jid = owner; row.username = "Action fixture"
        row.deviceUuid = "current-device"; row.isEncryptionEnabled = true
        let device = DeviceStorageItem(); device.uid = "other-device"; device.owner = owner
        device.primary = DeviceStorageItem.genPrimary(uid: device.uid, owner: owner); device.omemoDeviceId = 99
        try realm.write { realm.add(row); realm.add(device) }
        for jid in [owner, peer] {
            let signal = SignalDeviceStorageItem(); signal.owner = owner; signal.jid = jid; signal.deviceId = 99
            signal.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: 99)
            signal.state = .unknown; signal.isInDeviceList = true
            try realm.write { realm.add(signal) }
        }
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        try account.omemo.localStore.bindExistingDevice(deviceID: 42)
        account.omemo.omemo2MaintenanceScheduler = { _, _ in }
        accounts.append(account)
        AccountManager.shared.users = previousUsers + accounts
        return account
    }

    @discardableResult
    private func session(_ account: Account, jid: String? = nil, state: VerificationSessionStorageItem.VerififcationState,
        role: VerificationSessionStorageItem.VerificationRole = .responder) throws -> VerificationSessionStorageItem {
        let row = VerificationSessionStorageItem()
        row.owner = account.jid; row.ownerJid = account.jid; row.jid = jid ?? account.jid; row.peerBareJid = row.jid
        row.myDeviceId = 42; row.localDeviceId = 42; row.remoteDeviceId = 99; row.opponentDeviceId = 99
        row.sid = UUID().uuidString; row.primary = VerificationSessionStorageItem.genPrimary(owner: account.jid, sid: row.sid)
        row.role = role; row.state = state; row.timestamp = "100"; row.expires = Date().timeIntervalSince1970 + 600
        try realm.write { realm.add(row) }
        return row
    }

    private func settings(_ account: Account) -> SettingsViewController {
        let controller = SettingsViewController(); controller.owner = account.jid; controller.jid = account.jid
        controller.view = UIView(); controller.accounts = realm.objects(AccountStorageItem.self).filter("jid == %@", account.jid)
        controller.load()
        return controller
    }

    private func contact(_ account: Account) -> TrustedDevicesViewController {
        let controller = TrustedDevicesViewController(); controller.owner = account.jid; controller.jid = peer
        controller.view = UIView(); controller.loadDatasource()
        return controller
    }

    private func settingsCell(_ controller: SettingsViewController) throws -> VerificationSessionTableViewCell {
        let section = try XCTUnwrap(controller.datasource.firstIndex { $0.section == .session })
        return try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: section)) as? VerificationSessionTableViewCell)
    }

    private func contactCell(_ controller: TrustedDevicesViewController) throws -> VerificationSessionTableViewCell {
        let section = try XCTUnwrap(controller.datasource.firstIndex { $0.first?.kind == .session })
        return try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: section)) as? VerificationSessionTableViewCell)
    }
}
