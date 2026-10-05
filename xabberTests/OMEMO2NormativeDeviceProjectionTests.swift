import RealmSwift
import XCTest
@testable import xabber

@MainActor
final class OMEMO2NormativeDeviceProjectionTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!
    private let owner = "normative-device-projection@example.test"

    override func setUpWithError() throws {
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "OMEMO2NormativeDeviceProjection-" + UUID().uuidString
        )
        realm = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
    }

    func testRemovedDeviceIsNotDisplayedAsAnIncorrectlyPublishedDevice() throws {
        _ = try addDevice(42, isInDeviceList: true, state: .trusted)
        let removed = try addDevice(43, isInDeviceList: false, state: .distrusted)
        let controller = makeController()

        controller.load()
        controller.update()

        XCTAssertEqual(controller.omemoDevices.map(\.deviceId), [42])
        XCTAssertEqual(controller.brokenOmemoDevices.map(\.deviceId), [42])
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).count, 2)
        XCTAssertEqual(removed.state, .distrusted)
    }

    func testRemovedUnknownDeviceDoesNotRequestVerification() throws {
        _ = try addDevice(42, isInDeviceList: true, state: .trusted)
        _ = try addDevice(43, isInDeviceList: false, state: .unknown)
        let controller = makeController()

        controller.load()
        controller.update()

        XCTAssertFalse(controller.isVerificationRequired)
    }

    func testCurrentlyPublishedUnknownDeviceStillRequestsVerification() throws {
        _ = try addDevice(42, isInDeviceList: true, state: .unknown)
        let controller = makeController()

        controller.load()
        controller.update()

        XCTAssertTrue(controller.isVerificationRequired)
        XCTAssertEqual(controller.omemoDevices.map(\.deviceId), [42])
    }

    func testReloadAfterRemovalClearsTheDisplayWithoutChangingStoredTrust() throws {
        let device = try addDevice(42, isInDeviceList: true, state: .unknown)
        let controller = makeController()
        controller.load()
        controller.update()
        XCTAssertTrue(controller.isVerificationRequired)

        try realm.write { device.isInDeviceList = false }
        controller.load()
        controller.update()

        XCTAssertTrue(controller.omemoDevices.isEmpty)
        XCTAssertTrue(controller.brokenOmemoDevices.isEmpty)
        XCTAssertFalse(controller.isVerificationRequired)
        XCTAssertEqual(device.state, .unknown)
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).count, 1)
    }

    private func makeController() -> DevicesListViewController {
        let controller = DevicesListViewController()
        controller.owner = owner
        controller.jid = owner
        return controller
    }

    private func addDevice(
        _ deviceID: Int,
        isInDeviceList: Bool,
        state: SignalDeviceStorageItem.TrustState
    ) throws -> SignalDeviceStorageItem {
        let device = SignalDeviceStorageItem()
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: deviceID)
        device.owner = owner
        device.jid = owner
        device.deviceId = deviceID
        device.isInDeviceList = isInDeviceList
        device.state = state
        try realm.write { realm.add(device) }
        return device
    }
}
