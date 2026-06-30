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

    func testAvailabilityPolicyKeepsSourceAvailableWithoutPermissionGate() {
        XCTAssertEqual(
            ChatAttachmentGeolocationSourceAvailabilityPolicy.availability(
                isWireContractEnabled: false,
                isLocationServicesEnabled: false
            ),
            .available
        )
        XCTAssertEqual(
            ChatAttachmentGeolocationSourceAvailabilityPolicy.availability(
                isWireContractEnabled: true,
                isLocationServicesEnabled: false
            ),
            .available
        )
    }

    func testDefaultSourceBarConfigurationKeepsLocationVisibleAvailable() {
        let configuration = ChatAttachmentGeolocationSourceAvailabilityPolicy.sourceBarConfiguration(
            isWireContractEnabled: false,
            isLocationServicesEnabled: false
        )

        XCTAssertEqual(configuration.visibleSources, [.gallery, .file, .geolocation, .contact])
        XCTAssertEqual(configuration.availability(for: .geolocation), .available)
        XCTAssertEqual(configuration.availability(for: .contact), .disabled)
    }

    func testSearchResultSelectionProducesPreparedLocationDraftMetadata() throws {
        let searchProvider = FakeTask3GeolocationSearchProvider(
            resolvedLocation: ChatAttachmentResolvedLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                displayAddress: "Westminster",
                accuracy: nil
            )
        )
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .authorized,
            requestResult: .authorized
        )
        let snapshotURL = URL(fileURLWithPath: "/tmp/westminster-map.png")
        let snapshotProvider = FakeTask4LocationSnapshotProvider(result: .success(snapshotURL))
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            searchProvider: searchProvider,
            snapshotProvider: snapshotProvider
        )
        var emittedCounts: [Int] = []
        var emittedDrafts: [[AttachmentDraft]] = []
        controller.onSelectionCountChanged = { emittedCounts.append($0) }
        controller.onSelectedAttachmentDraftsChanged = { emittedDrafts.append($0) }

        controller.loadViewIfNeeded()
        let completion = ChatAttachmentGeolocationSearchCompletion(
            title: "Westminster",
            subtitle: "London"
        )
        searchProvider.emit([completion])
        controller.searchResultsTableView.delegate?.tableView?(
            controller.searchResultsTableView,
            didSelectRowAt: IndexPath(row: 0, section: 0)
        )

        let draft = try XCTUnwrap(controller.selectedAttachmentDrafts.first)
        let location = try XCTUnwrap(draft.preparedLocation)

        XCTAssertEqual(searchProvider.queries, [])
        XCTAssertEqual(searchProvider.resolvedCompletions, [completion])
        XCTAssertEqual(emittedCounts, [1, 1])
        XCTAssertEqual(emittedDrafts.last?.map(\.id), [draft.id])
        XCTAssertEqual(draft.source, .geolocation)
        XCTAssertEqual(draft.mediaKind, .location)
        XCTAssertEqual(location.coordinate, AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246))
        XCTAssertEqual(location.displayAddress, "Westminster")
        XCTAssertEqual(location.geoURI, "geo:51.5007,-0.1246")
        XCTAssertEqual(location.localSnapshotURL, snapshotURL)
        XCTAssertEqual(snapshotProvider.locations.map(\.coordinate), [location.coordinate])
        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [try XCTUnwrap(emittedDrafts.first?.first)]))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [draft]))
    }

    func testCurrentLocationDeniedShowsToastAndDoesNotMutateSelection() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .denied,
            requestResult: .denied
        )
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationDeniedMessage)
        ])
    }

    func testAuthorizedCurrentLocationSelectsAndReplacesSingleDraft() throws {
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                accuracy: 8.25
            )
        )
        let reverseGeocoder = FakeTask3ReverseGeocoder(address: "Current Address")
        let snapshotProvider = FakeTask4LocationSnapshotProvider(
            results: [
                .success(URL(fileURLWithPath: "/tmp/current-map.png")),
                .success(URL(fileURLWithPath: "/tmp/replacement-map.png"))
            ]
        )
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: FakeTask16GeolocationAuthorizer(status: .authorized, requestResult: .authorized),
            currentLocationProvider: locationProvider,
            reverseGeocoder: reverseGeocoder,
            snapshotProvider: snapshotProvider
        )
        var emittedCounts: [Int] = []
        controller.onSelectionCountChanged = { emittedCounts.append($0) }

        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)

        controller.currentLocationButton.sendActions(for: .touchUpInside)

        var location = try XCTUnwrap(controller.selectedAttachmentDrafts.first?.preparedLocation)
        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(reverseGeocoder.coordinates, [
            AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246)
        ])
        XCTAssertEqual(emittedCounts, [1, 1])
        XCTAssertEqual(location.displayAddress, "Current Address")
        XCTAssertEqual(location.accuracy, 8.25)
        XCTAssertEqual(location.localSnapshotURL, URL(fileURLWithPath: "/tmp/current-map.png"))

        controller.selectResolvedLocation(
            ChatAttachmentResolvedLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 40.7128, longitude: -74.006),
                displayAddress: "Replacement",
                accuracy: nil
            )
        )

        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 1)
        location = try XCTUnwrap(controller.selectedAttachmentDrafts.first?.preparedLocation)
        XCTAssertEqual(emittedCounts, [1, 1, 1, 1])
        XCTAssertEqual(location.coordinate, AttachmentLocationCoordinate(latitude: 40.7128, longitude: -74.006))
        XCTAssertEqual(location.displayAddress, "Replacement")
        XCTAssertEqual(location.localSnapshotURL, URL(fileURLWithPath: "/tmp/replacement-map.png"))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: controller.selectedAttachmentDrafts))
    }

    func testSnapshotFailureKeepsLocationDraftUnsendableAndShowsToast() throws {
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let snapshotProvider = FakeTask4LocationSnapshotProvider(result: .failure(FakeTask4SnapshotError.failed))
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: FakeTask16GeolocationAuthorizer(status: .authorized, requestResult: .authorized),
            snapshotProvider: snapshotProvider,
            toastPresenter: toastPresenter
        )
        var emittedDrafts: [[AttachmentDraft]] = []
        controller.onSelectedAttachmentDraftsChanged = { emittedDrafts.append($0) }

        controller.loadViewIfNeeded()
        controller.selectResolvedLocation(
            ChatAttachmentResolvedLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                displayAddress: "Westminster",
                accuracy: nil
            )
        )

        let draft = try XCTUnwrap(controller.selectedAttachmentDrafts.first)
        let location = try XCTUnwrap(draft.preparedLocation)
        XCTAssertNil(location.localSnapshotURL)
        XCTAssertFalse(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: controller.selectedAttachmentDrafts))
        XCTAssertEqual(emittedDrafts.count, 1)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationSnapshotFailedMessage)
        ])
    }
}

private final class FakeTask3GeolocationSearchProvider: ChatAttachmentGeolocationSearchProviding {
    var onResultsChanged: (([ChatAttachmentGeolocationSearchCompletion]) -> Void)?
    private(set) var queries: [String] = []
    private(set) var resolvedCompletions: [ChatAttachmentGeolocationSearchCompletion] = []
    let resolvedLocation: ChatAttachmentResolvedLocation

    init(resolvedLocation: ChatAttachmentResolvedLocation) {
        self.resolvedLocation = resolvedLocation
    }

    func updateQuery(_ query: String) {
        queries.append(query)
    }

    func resolve(
        _ completion: ChatAttachmentGeolocationSearchCompletion,
        completionHandler: @escaping (Result<ChatAttachmentResolvedLocation, Error>) -> Void
    ) {
        resolvedCompletions.append(completion)
        completionHandler(.success(resolvedLocation))
    }

    func emit(_ completions: [ChatAttachmentGeolocationSearchCompletion]) {
        onResultsChanged?(completions)
    }
}

private final class FakeTask3CurrentLocationProvider: ChatAttachmentCurrentLocationProviding {
    private(set) var requestCount = 0
    let currentLocation: ChatAttachmentCurrentLocation

    init(currentLocation: ChatAttachmentCurrentLocation) {
        self.currentLocation = currentLocation
    }

    func requestCurrentLocation(
        completion: @escaping (Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) -> Void
    ) {
        requestCount += 1
        completion(.success(currentLocation))
    }
}

private final class FakeTask3ReverseGeocoder: ChatAttachmentGeolocationReverseGeocoding {
    private(set) var coordinates: [AttachmentLocationCoordinate] = []
    let address: String?

    init(address: String?) {
        self.address = address
    }

    func reverseGeocode(
        coordinate: AttachmentLocationCoordinate,
        completion: @escaping (String?) -> Void
    ) {
        coordinates.append(coordinate)
        completion(address)
    }
}

private final class FakeTask3GeolocationToastPresenter: ChatAttachmentGeolocationToastPresenting {
    private(set) var messages: [String] = []

    func showToast(message: String, in view: UIView) {
        messages.append(message)
    }
}

private enum FakeTask4SnapshotError: Error {
    case failed
}

private final class FakeTask4LocationSnapshotProvider: ChatLocationSnapshotProviding {
    private var results: [Result<URL, Error>]
    private(set) var locations: [ChatAttachmentResolvedLocation] = []
    private(set) var sizes: [CGSize] = []

    init(result: Result<URL, Error>) {
        self.results = [result]
    }

    init(results: [Result<URL, Error>]) {
        self.results = results
    }

    func makeSnapshot(
        for location: ChatAttachmentResolvedLocation,
        size: CGSize,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        locations.append(location)
        sizes.append(size)
        completion(results.removeFirst())
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
