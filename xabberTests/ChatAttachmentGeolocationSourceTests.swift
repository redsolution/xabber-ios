import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentGeolocationSourceTests: XCTestCase {
    func testPermissionPolicyMapsNotDeterminedToRequestAccess() {
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .notDetermined,
                isLocationServicesEnabled: true
            ),
            .requestAccess
        )
    }

    func testPermissionPolicyMapsAuthorizedStatusesToReady() {
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .authorized,
                isLocationServicesEnabled: true
            ),
            .ready
        )
    }

    func testPermissionPolicyMapsDeniedRestrictedAndUnavailableToBlocked() {
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .denied,
                isLocationServicesEnabled: true
            ),
            .blocked(reason: .denied)
        )
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .restricted,
                isLocationServicesEnabled: true
            ),
            .blocked(reason: .restricted)
        )
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .authorized,
                isLocationServicesEnabled: false
            ),
            .blocked(reason: .unavailable)
        )
        XCTAssertEqual(
            ChatAttachmentGeolocationPermissionPolicy.state(
                for: .unavailable,
                isLocationServicesEnabled: true
            ),
            .blocked(reason: .unavailable)
        )
    }

    func testAvailabilityPolicyDisablesSourceWithoutWireContract() {
        XCTAssertEqual(
            ChatAttachmentGeolocationSourceAvailabilityPolicy.availability(
                isWireContractEnabled: false,
                isLocationServicesEnabled: true
            ),
            .disabled
        )
    }

    func testAvailabilityPolicyDisablesSourceWhenLocationServicesUnavailable() {
        XCTAssertEqual(
            ChatAttachmentGeolocationSourceAvailabilityPolicy.availability(
                isWireContractEnabled: true,
                isLocationServicesEnabled: false
            ),
            .disabled
        )
    }

    func testAvailabilityPolicyAllowsSourceOnlyWhenWireAndServicesAreAvailable() {
        XCTAssertEqual(
            ChatAttachmentGeolocationSourceAvailabilityPolicy.availability(
                isWireContractEnabled: true,
                isLocationServicesEnabled: true
            ),
            .available
        )
    }

    func testDefaultSourceBarConfigurationKeepsFutureSourcesVisibleDisabledUntilWireContract() {
        let configuration = ChatAttachmentGeolocationSourceAvailabilityPolicy.sourceBarConfiguration(
            isWireContractEnabled: false,
            isLocationServicesEnabled: true
        )

        XCTAssertEqual(configuration.visibleSources, [.gallery, .file, .geolocation, .contact])
        XCTAssertEqual(configuration.availability(for: .geolocation), .disabled)
        XCTAssertEqual(configuration.availability(for: .contact), .disabled)
    }

    func testRequestAccessAndCancelDoNotMutateSelectionCount() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .authorized
        )
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            isWireContractEnabled: true
        )
        var emittedCounts: [Int] = []
        controller.onSelectionCountChanged = { emittedCounts.append($0) }

        controller.loadViewIfNeeded()
        controller.requestAccessButton.sendActions(for: .touchUpInside)
        controller.cancelLocationSelection()

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(controller.permissionState, .ready)
        XCTAssertTrue(emittedCounts.isEmpty)
    }

    func testWireDisabledSourceDoesNotRequestLocationAccess() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .authorized
        )
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            isWireContractEnabled: false
        )

        controller.loadViewIfNeeded()
        controller.requestAccessButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(controller.permissionState, .blocked(reason: .wireContractUnavailable))
        XCTAssertTrue(controller.mapView.isHidden)
    }
}

private final class FakeTask16GeolocationAuthorizer: ChatAttachmentGeolocationAuthorizing {
    private(set) var requestCount = 0
    private let requestResult: ChatAttachmentGeolocationAuthorizationStatus
    var authorizationStatus: ChatAttachmentGeolocationAuthorizationStatus
    var isLocationServicesEnabled = true

    init(
        status: ChatAttachmentGeolocationAuthorizationStatus,
        requestResult: ChatAttachmentGeolocationAuthorizationStatus
    ) {
        self.authorizationStatus = status
        self.requestResult = requestResult
    }

    func requestWhenInUseAuthorization(
        completion: @escaping (ChatAttachmentGeolocationAuthorizationStatus) -> Void
    ) {
        requestCount += 1
        authorizationStatus = requestResult
        completion(requestResult)
    }
}
