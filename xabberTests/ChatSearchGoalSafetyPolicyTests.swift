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
//

import XCTest
import RealmSwift
@testable import xabber

final class ChatSearchGoalSafetyPolicyTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = Realm.Configuration.defaultConfiguration
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testNormalLaunchCannotEnableIsolatedStorageWithCustomFlags() {
        let descriptor = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: [
                AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
                AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
            ],
            processIdentifier: 101
        )

        XCTAssertNil(descriptor)
    }

    func testHostedXCTestWithoutIsolatedStorageFlagKeepsPersistentConfiguration() {
        let persistentConfiguration = Realm.Configuration.defaultConfiguration

        let descriptor = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: [
                AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey: "/tmp/test.xctestconfiguration",
                AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1"
            ],
            processIdentifier: 101
        )

        XCTAssertNil(descriptor)
        XCTAssertEqual(Realm.Configuration.defaultConfiguration, persistentConfiguration)
    }

    func testHostedXCTestWithBothFlagsBuildsInMemoryConfiguration() {
        let descriptor = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: hostedUnitTestEnvironment,
            processIdentifier: 101
        )

        let configuration = makeRealmMigrationConfiguration(
            scheme: 11,
            inMemoryIdentifier: try! XCTUnwrap(descriptor?.inMemoryIdentifier)
        )

        XCTAssertEqual(configuration.inMemoryIdentifier, "xabber-hosted-xctest-101")
        XCTAssertNil(configuration.fileURL)
        XCTAssertFalse(configuration.deleteRealmIfMigrationNeeded)
        XCTAssertEqual(configuration.schemaVersion, 11)
    }

    func testEachHostedTestProcessGetsDistinctInMemoryIdentifier() throws {
        let first = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: hostedUnitTestEnvironment,
            processIdentifier: 101
        )
        let second = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: hostedUnitTestEnvironment,
            processIdentifier: 102
        )

        XCTAssertNotEqual(
            try XCTUnwrap(first?.inMemoryIdentifier),
            try XCTUnwrap(second?.inMemoryIdentifier)
        )
    }

    func testApplyingIsolatedConfigurationCanBeRestoredWithoutPersistentFileAccess() throws {
        let persistentConfiguration = Realm.Configuration.defaultConfiguration
        let descriptor = try XCTUnwrap(AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: hostedUnitTestEnvironment,
            processIdentifier: 101
        ))

        defer {
            Realm.Configuration.defaultConfiguration = persistentConfiguration
        }

        realmMigrations(scheme: 11, inMemoryIdentifier: descriptor.inMemoryIdentifier)

        XCTAssertEqual(
            Realm.Configuration.defaultConfiguration.inMemoryIdentifier,
            descriptor.inMemoryIdentifier
        )
        XCTAssertNil(Realm.Configuration.defaultConfiguration.fileURL)
        XCTAssertFalse(Realm.Configuration.defaultConfiguration.deleteRealmIfMigrationNeeded)
    }

    func testLiveProcessWithoutHostedMarkerKeepsAccountAndStoragePolicies() {
        let liveEnvironment = [
            AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
            AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
        ]

        XCTAssertTrue(AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(
            isPushKit: false,
            environment: liveEnvironment
        ))
        XCTAssertNil(AppLaunchEnvironmentPolicy.isolatedStorageDescriptor(
            environment: liveEnvironment,
            processIdentifier: 101
        ))
    }

    func testXcodebuildCommandFlagsMapToRuntimePolicyKeys() {
        XCTAssertEqual(
            "TEST_RUNNER_\(AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey)",
            "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT"
        )
        XCTAssertEqual(
            "TEST_RUNNER_\(AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey)",
            "TEST_RUNNER_XABBER_ISOLATED_STORAGE"
        )
    }

    func testHostedCommandActuallyLaunchesWithIsolatedDefaultRealm() {
        let environment = ProcessInfo.processInfo.environment

        XCTAssertNotNil(environment[AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey])
        XCTAssertEqual(
            environment[AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey],
            "1"
        )
        XCTAssertEqual(
            environment[AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey],
            "1"
        )
        XCTAssertTrue(
            Realm.Configuration.defaultConfiguration.inMemoryIdentifier?
                .hasPrefix("xabber-hosted-xctest-") == true
        )
        XCTAssertNil(Realm.Configuration.defaultConfiguration.fileURL)
    }

    private var hostedUnitTestEnvironment: [String: String] {
        [
            AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey: "/tmp/test.xctestconfiguration",
            AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
            AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
        ]
    }
}
