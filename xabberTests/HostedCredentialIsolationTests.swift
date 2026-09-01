import XCTest
import SwiftKeychainWrapper
@testable import xabber

final class HostedCredentialIsolationTests: XCTestCase {
    func testKeychainAccessGroupUsesProcessedInfoValueInsteadOfApplicationGroup() {
        let resolved = CredentialsManager.resolvedKeychainAccessGroup(
            infoDictionary: [
                CredentialsManager.keychainAccessGroupInfoKey: "C423LXVKU5.xabber.ios"
            ],
            legacyAccessGroup: "group.xabber.ios"
        )

        XCTAssertEqual(resolved, "C423LXVKU5.xabber.ios")
        XCTAssertNotEqual(resolved, "group.xabber.ios")
    }

    func testKeychainAccessGroupFallsBackForMissingOrUnexpandedInfoValue() {
        for infoDictionary: [String: Any] in [
            [:],
            [CredentialsManager.keychainAccessGroupInfoKey: ""],
            [CredentialsManager.keychainAccessGroupInfoKey: "$(AppIdentifierPrefix)xabber.ios"]
        ] {
            XCTAssertEqual(
                CredentialsManager.resolvedKeychainAccessGroup(
                    infoDictionary: infoDictionary,
                    legacyAccessGroup: "group.xabber.ios"
                ),
                "group.xabber.ios"
            )
        }
    }

    func testBuiltApplicationContainsResolvedKeychainAccessGroup() {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: CredentialsManager.keychainAccessGroupInfoKey
        ) as? String

        XCTAssertNotNil(configured)
        XCTAssertFalse(configured?.contains("$(") ?? true)
        XCTAssertEqual(CredentialsManager.uniqueKeychainAccessGroup(), configured)
        XCTAssertNotEqual(
            CredentialsManager.uniqueKeychainAccessGroup(),
            CredentialsManager.uniqueAccessGroup()
        )
    }

    func testBuiltApplicationCanRoundTripValueInAuthorizedKeychainGroup() {
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueKeychainAccessGroup()
        )
        let key = "hosted-keychain-probe-\(UUID().uuidString)"

        defer {
            _ = keychain.removeObject(forKey: key)
        }

        XCTAssertTrue(
            keychain.set(
                "probe",
                forKey: key,
                withAccessibility: .alwaysThisDeviceOnly
            )
        )
        XCTAssertEqual(keychain.string(forKey: key), "probe")
    }

    func testNormalApplicationLaunchKeepsBundledCredentialNamespace() {
        let base = bundledStore

        let resolved = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: [:],
            processIdentifier: 101
        )

        XCTAssertEqual(resolved.uniqueServiceName, base.uniqueServiceName)
        XCTAssertEqual(resolved.uniqueAccessGroup, base.uniqueAccessGroup)
    }

    func testCustomIsolationFlagsWithoutHostedMarkerCannotChangeCredentialNamespace() {
        let base = bundledStore
        let environment = [
            AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
            AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
        ]

        let resolved = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: environment,
            processIdentifier: 101
        )

        XCTAssertEqual(resolved.uniqueServiceName, base.uniqueServiceName)
        XCTAssertEqual(resolved.uniqueAccessGroup, base.uniqueAccessGroup)
    }

    func testIncompleteHostedOptInCannotChangeCredentialNamespace() {
        let base = bundledStore
        let environment = [
            AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey: "/tmp/test.xctestconfiguration",
            AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1"
        ]

        let resolved = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: environment,
            processIdentifier: 101
        )

        XCTAssertEqual(resolved.uniqueServiceName, base.uniqueServiceName)
        XCTAssertEqual(resolved.uniqueAccessGroup, base.uniqueAccessGroup)
    }

    func testExactIsolatedHostedXCTestUsesDistinctServiceWithinAuthorizedAccessGroup() {
        let base = bundledStore

        let resolved = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: hostedUnitTestEnvironment,
            processIdentifier: 101
        )

        XCTAssertEqual(
            resolved.uniqueServiceName,
            base.uniqueServiceName + CredentialsManager.hostedXCTestServiceSuffix
        )
        XCTAssertNotEqual(resolved.uniqueServiceName, base.uniqueServiceName)
        XCTAssertEqual(resolved.uniqueAccessGroup, base.uniqueAccessGroup)
    }

    func testHostedCredentialNamespaceIsStableAcrossTestHostProcesses() {
        let base = bundledStore

        let first = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: hostedUnitTestEnvironment,
            processIdentifier: 101
        )
        let second = CredentialsManager.resolvedCredentialsStore(
            base: base,
            environment: hostedUnitTestEnvironment,
            processIdentifier: 102
        )

        XCTAssertEqual(first.uniqueServiceName, second.uniqueServiceName)
        XCTAssertEqual(first.uniqueAccessGroup, second.uniqueAccessGroup)
    }

    func testRunningHostedProcessCannotAddressBundledProductionService() {
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
        XCTAssertEqual(
            CredentialsManager.uniqueServiceName(),
            bundledStore.uniqueServiceName + CredentialsManager.hostedXCTestServiceSuffix
        )
        XCTAssertNotEqual(CredentialsManager.uniqueServiceName(), bundledStore.uniqueServiceName)
        XCTAssertEqual(CredentialsManager.uniqueAccessGroup(), bundledStore.uniqueAccessGroup)
    }

    private var bundledStore: CredentialsManager.CredentialsStore {
        CredentialsManager.CredentialsStore(
            uniqueServiceName: "xabber.ios",
            uniqueAccessGroup: "group.xabber.ios"
        )
    }

    private var hostedUnitTestEnvironment: [String: String] {
        [
            AppLaunchEnvironmentPolicy.hostedXCTestEnvironmentKey: "/tmp/test.xctestconfiguration",
            AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey: "1",
            AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey: "1"
        ]
    }
}
