import XCTest
import CoreLocation
import MapKit
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

    func testSearchControlsUseNativeGlassBottomBarMetricsAndScopeIcon() throws {
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: FakeTask16GeolocationAuthorizer(status: .authorized, requestResult: .authorized)
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 700))

        controller.loadViewIfNeeded()
        hostView.addSubview(controller.view)
        controller.view.frame = hostView.bounds
        hostView.layoutIfNeeded()

        let searchSurfaceView = try XCTUnwrap(
            controller.searchTextField.superview?.superview as? UIVisualEffectView
        )
        let currentLocationImage = try XCTUnwrap(
            controller.currentLocationButton.image(for: .normal)
                ?? controller.currentLocationButton.configuration?.image
        )

        XCTAssertEqual(ChatAttachmentGeolocationMapControlsStyle.currentLocationIconName, "scope")
        XCTAssertEqual(searchSurfaceView.frame.height, NativeGlassBarStyle.minimumHeight, accuracy: 0.001)
        XCTAssertEqual(searchSurfaceView.frame.minX, NativeGlassBarStyle.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(searchSurfaceView.layer.cornerRadius, NativeGlassBarStyle.cornerRadius, accuracy: 0.001)
        XCTAssertTrue(controller.searchTextField.isDescendant(of: searchSurfaceView.contentView))
        XCTAssertEqual(controller.searchTextField.borderStyle, .none)
        XCTAssertEqual(controller.searchTextField.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(controller.currentLocationButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(controller.currentLocationButton.frame.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(controller.currentLocationButton.tintColor, NativeGlassBarStyle.iconTintColor)
        XCTAssertEqual(
            controller.currentLocationButton.frame.minX - searchSurfaceView.frame.maxX,
            NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(currentLocationImage.renderingMode, .alwaysTemplate)
    }

    func testInitializationDoesNotQueryLocationServicesEnabled() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .authorized,
            requestResult: .authorized
        )

        _ = ChatAttachmentGeolocationSourceViewController(authorizer: authorizer)

        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
    }

    func testAuthorizedSourceShowsUserLocationAndCurrentLocationRecentersWithoutSelection() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .authorized,
            requestResult: .authorized
        )
        authorizer.isLocationServicesEnabled = false
        let currentCoordinate = AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246)
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: currentCoordinate,
                accuracy: 8.25
            )
        )
        let reverseGeocoder = FakeTask3ReverseGeocoder(address: "Current Address")
        let snapshotProvider = FakeTask4LocationSnapshotProvider(result: .success(URL(fileURLWithPath: "/tmp/current-map.png")))
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            currentLocationProvider: locationProvider,
            reverseGeocoder: reverseGeocoder,
            snapshotProvider: snapshotProvider,
            toastPresenter: toastPresenter
        )
        var emittedCounts: [Int] = []
        var emittedDrafts: [[AttachmentDraft]] = []
        controller.onSelectionCountChanged = { emittedCounts.append($0) }
        controller.onSelectedAttachmentDraftsChanged = { emittedDrafts.append($0) }

        controller.loadViewIfNeeded()
        layoutMapController(controller)

        XCTAssertTrue(controller.mapView.showsUserLocation)

        controller.currentLocationButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(toastPresenter.messages, [])
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(emittedCounts, [])
        XCTAssertEqual(emittedDrafts, [])
        XCTAssertEqual(reverseGeocoder.coordinates, [])
        XCTAssertEqual(snapshotProvider.locations, [])
        assertMapCenter(controller, equals: currentCoordinate)
    }

    func testNotDeterminedCurrentLocationWaitsForAuthorizationCallbackBeforeRecentering() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .authorized,
            completesImmediately: false
        )
        authorizer.isLocationServicesEnabled = false
        let currentCoordinate = AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246)
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: currentCoordinate,
                accuracy: 8.25
            )
        )
        let reverseGeocoder = FakeTask3ReverseGeocoder(address: "Current Address")
        let snapshotProvider = FakeTask4LocationSnapshotProvider(result: .success(URL(fileURLWithPath: "/tmp/current-map.png")))
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            currentLocationProvider: locationProvider,
            reverseGeocoder: reverseGeocoder,
            snapshotProvider: snapshotProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        layoutMapController(controller)

        XCTAssertFalse(controller.mapView.showsUserLocation)

        controller.currentLocationButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
        XCTAssertEqual(locationProvider.requestCount, 0)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)

        authorizer.completeAuthorization()

        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(toastPresenter.messages, [])
        XCTAssertTrue(controller.mapView.showsUserLocation)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(reverseGeocoder.coordinates, [])
        XCTAssertEqual(snapshotProvider.locations, [])
        assertMapCenter(controller, equals: currentCoordinate)
    }

    func testNotDeterminedAuthorizationCallbackKeepsWaitingWithoutToastOrLocationRequest() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .notDetermined,
            completesImmediately: false
        )
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                accuracy: 8.25
            )
        )
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            currentLocationProvider: locationProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)
        authorizer.completeAuthorization()

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(locationProvider.requestCount, 0)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [])
    }

    func testNotDeterminedCurrentLocationDeniedCallbackShowsAccessToastAndDoesNotRequestLocation() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .denied,
            completesImmediately: false
        )
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                accuracy: 8.25
            )
        )
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            currentLocationProvider: locationProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)
        authorizer.completeAuthorization()

        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
        XCTAssertEqual(locationProvider.requestCount, 0)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationDeniedMessage)
        ])
    }

    func testNotDeterminedCurrentLocationRestrictedCallbackShowsAccessToastAndDoesNotRequestLocation() {
        let authorizer = FakeTask16GeolocationAuthorizer(
            status: .notDetermined,
            requestResult: .restricted,
            completesImmediately: false
        )
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
                accuracy: 8.25
            )
        )
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: authorizer,
            currentLocationProvider: locationProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)
        authorizer.completeAuthorization()

        XCTAssertEqual(authorizer.locationServicesEnabledReadCount, 0)
        XCTAssertEqual(locationProvider.requestCount, 0)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationRestrictedMessage)
        ])
    }

    func testCurrentLocationProviderDeniedFailureShowsDeniedToast() {
        let locationProvider = FakeTask3CurrentLocationProvider(result: .failure(.denied))
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: FakeTask16GeolocationAuthorizer(status: .authorized, requestResult: .authorized),
            currentLocationProvider: locationProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationDeniedMessage)
        ])
    }

    func testCurrentLocationProviderUnavailableFailureStillShowsUnavailableToast() {
        let locationProvider = FakeTask3CurrentLocationProvider(result: .failure(.unavailable))
        let toastPresenter = FakeTask3GeolocationToastPresenter()
        let controller = ChatAttachmentGeolocationSourceViewController(
            authorizer: FakeTask16GeolocationAuthorizer(status: .authorized, requestResult: .authorized),
            currentLocationProvider: locationProvider,
            toastPresenter: toastPresenter
        )

        controller.loadViewIfNeeded()
        controller.currentLocationButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationUnavailableMessage)
        ])
    }

    func testCoreLocationCurrentProviderMapsDeniedErrorToDeniedFailure() {
        let locationManager = NoopTask16LocationManager()
        let provider = CoreLocationChatAttachmentCurrentLocationProvider(
            locationManager: locationManager,
            authorizationStatusProvider: { .denied }
        )
        var completionResult: Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>?

        provider.requestCurrentLocation { result in
            completionResult = result
        }
        provider.locationManager(locationManager, didFailWithError: CLError(.denied))

        XCTAssertEqual(locationManager.requestLocationCount, 1)
        switch completionResult {
        case .failure(.denied):
            break
        default:
            XCTFail("Expected denied location failure, got \(String(describing: completionResult))")
        }
    }

    func testCoreLocationCurrentProviderMapsDeniedErrorWithAuthorizedPermissionToUnavailableFailure() {
        let locationManager = NoopTask16LocationManager()
        let provider = CoreLocationChatAttachmentCurrentLocationProvider(
            locationManager: locationManager,
            authorizationStatusProvider: { .authorizedWhenInUse }
        )
        var completionResult: Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>?

        provider.requestCurrentLocation { result in
            completionResult = result
        }
        provider.locationManager(locationManager, didFailWithError: CLError(.denied))

        XCTAssertEqual(locationManager.requestLocationCount, 1)
        switch completionResult {
        case .failure(.unavailable):
            break
        default:
            XCTFail("Expected unavailable location failure, got \(String(describing: completionResult))")
        }
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
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: [try XCTUnwrap(emittedDrafts.first?.first)]))
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

    func testAuthorizedCurrentLocationPreservesSelectedDraftAndDoesNotEmitSelectionCallbacks() throws {
        let selectedCoordinate = AttachmentLocationCoordinate(latitude: 40.7128, longitude: -74.006)
        let currentCoordinate = AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246)
        let locationProvider = FakeTask3CurrentLocationProvider(
            currentLocation: ChatAttachmentCurrentLocation(
                coordinate: currentCoordinate,
                accuracy: 8.25
            )
        )
        let reverseGeocoder = FakeTask3ReverseGeocoder(address: "Current Address")
        let snapshotProvider = FakeTask4LocationSnapshotProvider(
            results: [
                .success(URL(fileURLWithPath: "/tmp/selected-map.png"))
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
        layoutMapController(controller)
        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 0)

        controller.selectResolvedLocation(
            ChatAttachmentResolvedLocation(
                coordinate: selectedCoordinate,
                displayAddress: "Selected Pin",
                accuracy: nil
            )
        )

        XCTAssertEqual(controller.selectedAttachmentDrafts.count, 1)
        let originalDraft = try XCTUnwrap(controller.selectedAttachmentDrafts.first)
        let originalLocation = try XCTUnwrap(originalDraft.preparedLocation)
        XCTAssertEqual(emittedCounts, [1, 1])
        XCTAssertEqual(originalLocation.coordinate, selectedCoordinate)
        XCTAssertEqual(originalLocation.displayAddress, "Selected Pin")
        XCTAssertEqual(originalLocation.localSnapshotURL, URL(fileURLWithPath: "/tmp/selected-map.png"))
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: controller.selectedAttachmentDrafts))

        emittedCounts.removeAll()
        controller.currentLocationButton.sendActions(for: .touchUpInside)

        let location = try XCTUnwrap(controller.selectedAttachmentDrafts.first?.preparedLocation)
        XCTAssertEqual(locationProvider.requestCount, 1)
        XCTAssertEqual(reverseGeocoder.coordinates, [])
        XCTAssertEqual(snapshotProvider.locations.map(\.coordinate), [selectedCoordinate])
        XCTAssertEqual(emittedCounts, [])
        XCTAssertEqual(location.coordinate, selectedCoordinate)
        XCTAssertEqual(location.displayAddress, "Selected Pin")
        XCTAssertEqual(location.localSnapshotURL, URL(fileURLWithPath: "/tmp/selected-map.png"))
        assertMapCenter(controller, equals: currentCoordinate)
    }

    func testSnapshotFailureKeepsLocationDraftSendableAndShowsToast() throws {
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
        XCTAssertTrue(ChatAttachmentSendabilityPolicy.canRequestSend(drafts: controller.selectedAttachmentDrafts))
        XCTAssertEqual(emittedDrafts.count, 1)
        XCTAssertEqual(toastPresenter.messages, [
            ChatAttachmentLocalization.string(.geolocationSnapshotFailedMessage)
        ])
    }

    private func assertMapCenter(
        _ controller: ChatAttachmentGeolocationSourceViewController,
        equals coordinate: AttachmentLocationCoordinate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let center = controller.mapView.region.center
        XCTAssertEqual(center.latitude, coordinate.latitude, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(center.longitude, coordinate.longitude, accuracy: 0.001, file: file, line: line)
    }

    private func layoutMapController(_ controller: ChatAttachmentGeolocationSourceViewController) {
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()
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
    private let result: Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>

    init(currentLocation: ChatAttachmentCurrentLocation) {
        self.result = .success(currentLocation)
    }

    init(result: Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) {
        self.result = result
    }

    func requestCurrentLocation(
        completion: @escaping (Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) -> Void
    ) {
        requestCount += 1
        completion(result)
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

    @discardableResult
    func makeSnapshot(
        for location: ChatAttachmentResolvedLocation,
        size: CGSize,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> ChatLocationSnapshotTask? {
        locations.append(location)
        sizes.append(size)
        guard !results.isEmpty else {
            completion(.failure(FakeTask4SnapshotError.failed))
            return nil
        }
        completion(results.removeFirst())
        return nil
    }
}

private final class FakeTask16GeolocationAuthorizer: ChatAttachmentGeolocationAuthorizing {
    private(set) var requestCount = 0
    private let requestResult: ChatAttachmentGeolocationAuthorizationStatus
    private let completesImmediately: Bool
    private var pendingCompletion: ((ChatAttachmentGeolocationAuthorizationStatus) -> Void)?
    private var locationServicesEnabledStorage = true
    private(set) var locationServicesEnabledReadCount = 0
    var authorizationStatus: ChatAttachmentGeolocationAuthorizationStatus
    var isLocationServicesEnabled: Bool {
        get {
            locationServicesEnabledReadCount += 1
            return locationServicesEnabledStorage
        }
        set {
            locationServicesEnabledStorage = newValue
        }
    }

    init(
        status: ChatAttachmentGeolocationAuthorizationStatus,
        requestResult: ChatAttachmentGeolocationAuthorizationStatus,
        completesImmediately: Bool = true
    ) {
        self.authorizationStatus = status
        self.requestResult = requestResult
        self.completesImmediately = completesImmediately
    }

    func requestWhenInUseAuthorization(
        completion: @escaping (ChatAttachmentGeolocationAuthorizationStatus) -> Void
    ) {
        requestCount += 1
        if completesImmediately {
            authorizationStatus = requestResult
            completion(requestResult)
        } else {
            pendingCompletion = completion
        }
    }

    func completeAuthorization() {
        guard let pendingCompletion else { return }
        self.pendingCompletion = nil
        authorizationStatus = requestResult
        pendingCompletion(requestResult)
    }
}

private final class NoopTask16LocationManager: CLLocationManager {
    private(set) var requestLocationCount = 0

    override func requestLocation() {
        requestLocationCount += 1
    }
}
