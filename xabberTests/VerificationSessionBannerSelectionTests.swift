import Foundation
import RealmSwift
import UIKit
import XCTest
@testable import xabber

/// Exercises the actual banner readers/renderers; transport is never started.
@MainActor
final class VerificationSessionBannerSelectionTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var values: [String: Data] = [:]
        func load(owner: String) throws -> Data? { values[owner] }
        func save(_ data: Data, owner: String) throws { values[owner] = data }
        func remove(owner: String) throws { values.removeValue(forKey: owner) }
    }
    private final class UnavailableBinding: XabberAxolotlStorage {
        let unavailableID: Int
        init(owner: String, id: Int) { unavailableID = id; super.init(withOwner: owner) }
        override func localDeviceId() -> Int { unavailableID }
    }

    private var previousRealm: Realm.Configuration!
    private var realm: Realm!
    private var previousUsers: [Account] = []
    private var fixtures: [Account] = []
    private let localSID = 42
    private let remoteSID = 99

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "VerificationBanner-\(UUID())")
        realm = try WRealm.safe()
        previousUsers = AccountManager.shared.users
    }

    override func tearDownWithError() throws {
        guard previousRealm != nil else { return }
        for account in fixtures {
            account.queue.sync {}
            account.cancelDelayedConnectTimer()
            account.omemo.omemo2MaintenanceWorkItem?.cancel()
            account.omemo.clearSession()
            account.xmppTaskScheduler.reset()
            account.messages.updateSendingMessagesTimer?.invalidate()
            CredentialsManager.shared.removeDeviceId(for: account.jid)
        }
        AccountManager.shared.users = previousUsers
        fixtures.removeAll()
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        try super.tearDownWithError()
    }

    func testDevicesTerminalHistoryCannotMaskCurrentIncomingRequest() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, state: .timeout)
        let current = try session(account, tag: 2)
        let controller = devices(account)
        XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
        try assertAction(devicesCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testSettingsTerminalHistoryCannotMaskCurrentIncomingRequest() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, state: .cancelled)
        let current = try session(account, tag: 2)
        let controller = settings(account)
        XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
        try assertAction(settingsCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testContactTerminalHistoryCannotMaskCurrentIncomingRequest() throws {
        let account = try fixture(), peer = "contact@example.test"
        _ = try session(account, tag: 1, peer: peer, state: .failed)
        let current = try session(account, tag: 2, peer: peer)
        let controller = trusted(account, peer: peer)
        XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
        try assertAction(contactCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testUnknownAndLegacyStatesCannotMaskCurrentProtocolRequest() throws {
        let account = try fixture()
        let unknown = try session(account, tag: 1, state: .none)
        try realm.write { unknown.state_ = "unrecognized-old-state" }
        _ = try session(account, tag: 2, state: .hashSentToOpponent)
        let current = try session(account, tag: 3)
        XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
    }

    func testPriorLocalDeviceRequestCannotMaskCurrentLocalDevice() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, local: 41)
        let current = try session(account, tag: 2)
        XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
    }

    func testExpiredRequestCannotMaskLiveRequestWithoutChangingExpiration() throws {
        let account = try fixture()
        let expired = try session(account, tag: 1, expires: Date().timeIntervalSince1970 - 1)
        let expiration = expired.expires
        let current = try session(account, tag: 2)
        XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(expired.state, .receivedRequest)
        XCTAssertEqual(expired.expires, expiration)
    }

    func testNewestAdmittedLiveRequestIsSelectedInsteadOfInsertionOrder() throws {
        let account = try fixture()
        let older = try session(account, tag: 1, timestamp: 100)
        let current = try session(account, tag: 2, timestamp: 200)
        XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(older.state, .receivedRequest)
    }

    func testNoCurrentLiveSessionRestoresVerifyActionWithoutDeletingHistory() throws {
        let account = try fixture()
        let old = try session(account, tag: 1, state: .cancelled)
        let controller = devices(account)
        XCTAssertNil(controller.activeVerificationSessionSid)
        XCTAssertNil(settings(account).activeVerificationSessionSid)
        try assertAction(devicesCell(controller), target: controller, selector: "onVerifyButtonPressed")
        XCTAssertNotNil(realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: old.primary))
        XCTAssertEqual(old.state, .cancelled)
    }

    func testCurrentDisplayAndEntryStatesKeepTheirExistingActions() throws {
        for (index, state, role, selector) in [
            (10, VerificationSessionStorageItem.VerififcationState.acceptedRequest, VerificationSessionStorageItem.VerificationRole.responder, "onShowCodePressed"),
            (11, .receivedRequestAccept, .initiator, "onEnterCodePressed")
        ] {
            let account = try fixture()
            let current = try session(account, tag: index, state: state, role: role)
            let controller = devices(account)
            XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
            try assertAction(devicesCell(controller), target: controller, selector: selector)
            let profile = settings(account)
            XCTAssertEqual(profile.activeVerificationSessionSid, current.sid)
            try assertAction(settingsCell(profile), target: profile, selector: selector)
        }
    }

    func testUnboundRoleCannotMaskAProtocolBoundIncomingRequest() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, role: .none)
        let current = try session(account, tag: 2)
        XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
        XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
    }

    func testCurrentIntermediateProtocolStatesRemainVisibleWhileWaiting() throws {
        for (index, state, role) in [
            (20, VerificationSessionStorageItem.VerififcationState.sentRequest, VerificationSessionStorageItem.VerificationRole.initiator),
            (21, .responseSent, .initiator),
            (22, .responseReceived, .responder),
            (23, .verifySent, .responder)
        ] {
            let account = try fixture()
            let current = try session(account, tag: index, state: state, role: role)
            XCTAssertEqual(devices(account).activeVerificationSessionSid, current.sid)
            XCTAssertEqual(settings(account).activeVerificationSessionSid, current.sid)
        }
    }

    func testContactSelectionUsesItsPeerAndCurrentLocalDevice() throws {
        let account = try fixture(), peer = "contact@example.test"
        _ = try session(account, tag: 1, peer: peer, local: 41)
        _ = try session(account, tag: 2, peer: "different-peer@example.test")
        let current = try session(account, tag: 3, peer: peer)
        let controller = trusted(account, peer: peer)
        XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
        try assertAction(contactCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testMissingCurrentAccountCannotSelectPersistedSession() throws {
        let account = try fixture()
        let old = try session(account, tag: 1)
        AccountManager.shared.users = previousUsers
        XCTAssertNil(devices(account).activeVerificationSessionSid)
        XCTAssertNil(settings(account).activeVerificationSessionSid)
        XCTAssertNil(trusted(account, peer: account.jid).activeVerificationSessionSid)
        XCTAssertEqual(old.state, .receivedRequest)
    }

    func testZeroAndUnavailableLocalBindingCannotSelectPersistedSession() throws {
        for id in [0, -1] {
            let account = try fixture()
            let old = try session(account, tag: 1)
            account.omemo.localStore = UnavailableBinding(owner: account.jid, id: id)
            XCTAssertNil(devices(account).activeVerificationSessionSid)
            XCTAssertNil(settings(account).activeVerificationSessionSid)
            XCTAssertNil(trusted(account, peer: account.jid).activeVerificationSessionSid)
            XCTAssertEqual(old.state, .receivedRequest)
        }
    }

    func testConfigureFromEmptyOwnerExposesIncomingRequestAction() throws {
        let account = try fixture()
        let current = try session(account, tag: 1)
        let controller = DevicesListViewController(); controller.view = UIView()
        XCTAssertTrue(controller.owner.isEmpty)
        controller.configure(for: account.jid)
        XCTAssertEqual(controller.owner, account.jid)
        XCTAssertEqual(controller.activeVerificationSessionSid, current.sid)
        try assertAction(devicesCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testConfigureFromEmptyOwnerExposesAcceptedRequestAction() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, state: .acceptedRequest)
        let controller = DevicesListViewController(); controller.view = UIView()
        controller.configure(for: account.jid)
        XCTAssertEqual(controller.owner, account.jid)
        try assertAction(devicesCell(controller), target: controller, selector: "onShowCodePressed")
    }

    func testConfigureFromEmptyOwnerExposesCodeEntryAction() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, state: .receivedRequestAccept, role: .initiator)
        let controller = DevicesListViewController(); controller.view = UIView()
        controller.configure(for: account.jid)
        XCTAssertEqual(controller.owner, account.jid)
        try assertAction(devicesCell(controller), target: controller, selector: "onEnterCodePressed")
    }

    func testConfigureReplacesPreviousAccountOwnerBeforeReadingSession() throws {
        let account = try fixture()
        _ = try session(account, tag: 1)
        let controller = DevicesListViewController(); controller.view = UIView()
        controller.owner = "previous-account@example.test"
        controller.configure(for: account.jid)
        XCTAssertEqual(controller.owner, account.jid)
        try assertAction(devicesCell(controller), target: controller, selector: "onAcceptButtonPressed")
    }

    func testActualSettingsDevicesNavigationKeepsSessionActionAccountScoped() throws {
        let account = try fixture()
        _ = try session(account, tag: 1, state: .receivedRequestAccept, role: .initiator)
        let profile = settings(account)
        let navigation = UINavigationController(rootViewController: profile)
        let section = try XCTUnwrap(profile.datasource.firstIndex { $0.childs.contains { $0.key == .accountSessions } })
        let row = try XCTUnwrap(profile.datasource[section].childs.firstIndex { $0.key == .accountSessions })
        profile.tableView(profile.tableView, didSelectRowAt: IndexPath(row: row, section: section))
        let controller = try XCTUnwrap(navigation.topViewController as? DevicesListViewController)
        XCTAssertEqual(controller.owner, account.jid)
        try assertAction(devicesCell(controller), target: controller, selector: "onEnterCodePressed")
    }

    func testSelectionPreservesTrustHistoryPrivateKeysAndNativeRatchet() throws {
        let account = try fixture(), memory = Memory()
        let local = try XabberOMEMO2Storage(owner: account.jid, persistence: memory)
        let peer = try XabberOMEMO2Storage(owner: "native-peer@example.test", persistence: memory)
        _ = try local.prepare(deviceID: localSID, preKeyCount: 3)
        let bundle = try peer.prepare(deviceID: remoteSID, preKeyCount: 3)
        let key = try XCTUnwrap(bundle.preKeys.first)
        let selected = try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: key.publicKey, preKeyID: key.id)
        try local.initiateSession(jid: peer.owner, deviceID: remoteSID, bundle: selected)
        let first = Data(repeating: 7, count: 48)
        XCTAssertTrue(try peer.decrypt(local.encrypt(first, jid: peer.owner, deviceID: remoteSID),
            jid: local.owner, deviceID: localSID) == first)
        account.omemo.omemo2Storage = local
        let old = try session(account, tag: 1, state: .cancelled)
        let current = try session(account, tag: 2)
        let protectedBefore = memory.values
        let oldExpiration = old.expires
        let trust = try XCTUnwrap(realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", account.jid, account.jid).first)
        let trustBefore = (trust.state_, trust.fingerprint, trust.lastTrustSharingTimestamp)
        _ = devices(account); _ = settings(account); _ = trusted(account, peer: account.jid)
        XCTAssertTrue(memory.values == protectedBefore, "Presentation must not write private state")
        XCTAssertEqual(old.state, .cancelled)
        XCTAssertEqual(old.expires, oldExpiration)
        XCTAssertEqual(current.state, .receivedRequest)
        XCTAssertEqual(realm.objects(VerificationSessionStorageItem.self).filter("owner == %@", account.jid).count, 2)
        XCTAssertEqual(trust.state_, trustBefore.0)
        XCTAssertEqual(trust.fingerprint, trustBefore.1)
        XCTAssertEqual(trust.lastTrustSharingTimestamp, trustBefore.2)
        let second = Data(repeating: 8, count: 48)
        XCTAssertTrue(try peer.decrypt(local.encrypt(second, jid: peer.owner, deviceID: remoteSID),
            jid: local.owner, deviceID: localSID) == second)
    }

    private func fixture() throws -> Account {
        let owner = "banner-\(UUID().uuidString.lowercased())@example.test"
        let row = AccountStorageItem(); row.jid = owner; row.username = "Banner fixture"
        row.deviceUuid = "current-device"; row.isEncryptionEnabled = true
        let device = DeviceStorageItem(); device.uid = "other-device"; device.owner = owner
        device.primary = DeviceStorageItem.genPrimary(uid: device.uid, owner: owner)
        device.omemoDeviceId = remoteSID
        try realm.write { realm.add(row); realm.add(device) }
        for jid in [owner, "contact@example.test"] {
            let signal = SignalDeviceStorageItem(); signal.owner = owner; signal.jid = jid; signal.deviceId = remoteSID
            signal.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: remoteSID)
            signal.state = .unknown; signal.isInDeviceList = true
            try realm.write { realm.add(signal) }
        }
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        try account.omemo.localStore.bindExistingDevice(deviceID: localSID)
        account.omemo.omemo2MaintenanceScheduler = { _, _ in }
        fixtures.append(account)
        AccountManager.shared.users = previousUsers + fixtures
        return account
    }

    @discardableResult
    private func session(_ account: Account, tag: Int, peer: String? = nil,
        state: VerificationSessionStorageItem.VerififcationState = .receivedRequest,
        role: VerificationSessionStorageItem.VerificationRole = .responder,
        local: Int = 42, timestamp: Int = 100, expires: TimeInterval = Date().timeIntervalSince1970 + 600) throws -> VerificationSessionStorageItem {
        let value = VerificationSessionStorageItem()
        value.owner = account.jid; value.ownerJid = account.jid
        value.jid = peer ?? account.jid; value.peerBareJid = value.jid
        value.myDeviceId = local; value.localDeviceId = local
        value.remoteDeviceId = remoteSID; value.opponentDeviceId = remoteSID
        value.sid = Data(repeating: UInt8(tag), count: 16).base64EncodedString()
        value.primary = VerificationSessionStorageItem.genPrimary(owner: account.jid, sid: value.sid)
        value.role = role; value.state = state; value.timestamp = String(timestamp); value.expires = expires
        try realm.write { realm.add(value) }
        return value
    }

    private func devices(_ account: Account) -> DevicesListViewController {
        let controller = DevicesListViewController(); controller.owner = account.jid; controller.jid = account.jid
        controller.view = UIView(); controller.load(); controller.update()
        return controller
    }
    private func settings(_ account: Account) -> SettingsViewController {
        let controller = SettingsViewController(); controller.owner = account.jid; controller.jid = account.jid
        controller.view = UIView()
        controller.accounts = realm.objects(AccountStorageItem.self).filter("jid == %@", account.jid)
        controller.load()
        return controller
    }
    private func trusted(_ account: Account, peer: String) -> TrustedDevicesViewController {
        let controller = TrustedDevicesViewController(); controller.owner = account.jid; controller.jid = peer
        controller.view = UIView(); controller.loadDatasource()
        return controller
    }
    private func devicesCell(_ controller: DevicesListViewController) throws -> VerificationSessionTableViewCell {
        let section = try XCTUnwrap(controller.datasource.firstIndex { $0.kind == .token && $0.childs.first?.kind == .session })
        return try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: section)) as? VerificationSessionTableViewCell)
    }
    private func settingsCell(_ controller: SettingsViewController) throws -> VerificationSessionTableViewCell {
        let section = try XCTUnwrap(controller.datasource.firstIndex { $0.section == .session })
        return try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: section)) as? VerificationSessionTableViewCell)
    }
    private func contactCell(_ controller: TrustedDevicesViewController) throws -> VerificationSessionTableViewCell {
        let section = try XCTUnwrap(controller.datasource.firstIndex { $0.first?.kind == .session })
        return try XCTUnwrap(controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: section)) as? VerificationSessionTableViewCell)
    }
    private func assertAction(_ cell: VerificationSessionTableViewCell, target: AnyObject, selector: String,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(cell.blueButton.accessibilityIdentifier, "verification_session_verify_button", file: file, line: line)
        XCTAssertTrue(cell.blueButton.isDescendant(of: cell), "The real banner must expose its action", file: file, line: line)
        XCTAssertTrue(cell.blueButton.actions(forTarget: target, forControlEvent: .touchUpInside)?.contains(selector) == true,
            "The action must address the selected session", file: file, line: line)
    }
}
