import CoreLocation
import MapKit
import UIKit

enum ChatAttachmentGeolocationAuthorizationStatus: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

enum ChatAttachmentGeolocationBlockReason: Error, Equatable {
    case denied
    case restricted
    case unavailable
    case wireContractUnavailable
}

enum ChatAttachmentGeolocationPermissionState: Equatable {
    case requestAccess
    case ready
    case blocked(reason: ChatAttachmentGeolocationBlockReason)
}

struct ChatAttachmentGeolocationSearchCompletion: Equatable {
    let title: String
    let subtitle: String
}

struct ChatAttachmentResolvedLocation: Equatable {
    let coordinate: AttachmentLocationCoordinate
    let displayAddress: String?
    let accuracy: Double?
}

struct ChatAttachmentCurrentLocation: Equatable {
    let coordinate: AttachmentLocationCoordinate
    let accuracy: Double?
}

enum ChatAttachmentGeolocationPermissionPolicy {
    static func state(
        for status: ChatAttachmentGeolocationAuthorizationStatus,
        isLocationServicesEnabled: Bool
    ) -> ChatAttachmentGeolocationPermissionState {
        guard isLocationServicesEnabled else {
            return .blocked(reason: .unavailable)
        }

        switch status {
        case .notDetermined:
            return .requestAccess
        case .authorized:
            return .ready
        case .denied:
            return .blocked(reason: .denied)
        case .restricted:
            return .blocked(reason: .restricted)
        case .unavailable:
            return .blocked(reason: .unavailable)
        }
    }
}

enum ChatAttachmentGeolocationSourceAvailabilityPolicy {
    static func availability(
        isWireContractEnabled: Bool,
        isLocationServicesEnabled: Bool
    ) -> ChatAttachmentSourceAvailability {
        .available
    }

    static func sourceBarConfiguration(
        isWireContractEnabled: Bool,
        isLocationServicesEnabled: Bool
    ) -> ChatAttachmentSourceBarConfiguration {
        ChatAttachmentSourceBarConfiguration(
            sourceAvailability: [
                .gallery: .available,
                .file: .available,
                .geolocation: .available,
                .contact: .disabled
            ],
            orderedSources: [.gallery, .file, .geolocation, .contact]
        )
    }
}

protocol ChatAttachmentGeolocationAuthorizing: AnyObject {
    var authorizationStatus: ChatAttachmentGeolocationAuthorizationStatus { get }
    var isLocationServicesEnabled: Bool { get }

    func requestWhenInUseAuthorization(
        completion: @escaping (ChatAttachmentGeolocationAuthorizationStatus) -> Void
    )
}

protocol ChatAttachmentGeolocationSearchProviding: AnyObject {
    var onResultsChanged: (([ChatAttachmentGeolocationSearchCompletion]) -> Void)? { get set }

    func updateQuery(_ query: String)
    func resolve(
        _ completion: ChatAttachmentGeolocationSearchCompletion,
        completionHandler: @escaping (Result<ChatAttachmentResolvedLocation, Error>) -> Void
    )
}

protocol ChatAttachmentCurrentLocationProviding: AnyObject {
    func requestCurrentLocation(
        completion: @escaping (Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) -> Void
    )
}

protocol ChatAttachmentGeolocationReverseGeocoding: AnyObject {
    func reverseGeocode(
        coordinate: AttachmentLocationCoordinate,
        completion: @escaping (String?) -> Void
    )
}

protocol ChatAttachmentGeolocationToastPresenting: AnyObject {
    func showToast(message: String, in view: UIView)
}

protocol ChatLocationSnapshotProviding: AnyObject {
    func makeSnapshot(
        for location: ChatAttachmentResolvedLocation,
        size: CGSize,
        completion: @escaping (Result<URL, Error>) -> Void
    )
}

enum ChatAttachmentGeolocationMapControlsStyle {
    static let currentLocationIconName = "scope"

    static var currentLocationIcon: UIImage? {
        UIImage(systemName: currentLocationIconName)?
            .upscale(dimension: NativeGlassBarStyle.iconSize)
            .withRenderingMode(.alwaysTemplate)
    }
}

final class CoreLocationChatAttachmentGeolocationAuthorizer: NSObject,
    ChatAttachmentGeolocationAuthorizing,
    CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    private var pendingCompletion: ((ChatAttachmentGeolocationAuthorizationStatus) -> Void)?

    var authorizationStatus: ChatAttachmentGeolocationAuthorizationStatus {
        Self.mapAuthorizationStatus(locationManager.authorizationStatus)
    }

    var isLocationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        self.locationManager.delegate = self
    }

    func requestWhenInUseAuthorization(
        completion: @escaping (ChatAttachmentGeolocationAuthorizationStatus) -> Void
    ) {
        guard authorizationStatus == .notDetermined else {
            completion(authorizationStatus)
            return
        }

        pendingCompletion = completion
        locationManager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let pendingCompletion else {
            return
        }

        let status = Self.mapAuthorizationStatus(manager.authorizationStatus)
        guard status != .notDetermined else {
            return
        }

        self.pendingCompletion = nil
        pendingCompletion(status)
    }

    private static func mapAuthorizationStatus(
        _ status: CLAuthorizationStatus
    ) -> ChatAttachmentGeolocationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }
}

final class MapKitChatAttachmentGeolocationSearchProvider: NSObject,
    ChatAttachmentGeolocationSearchProviding,
    MKLocalSearchCompleterDelegate {
    var onResultsChanged: (([ChatAttachmentGeolocationSearchCompletion]) -> Void)?

    private let completer: MKLocalSearchCompleter

    init(completer: MKLocalSearchCompleter = MKLocalSearchCompleter()) {
        self.completer = completer
        super.init()
        self.completer.delegate = self
        self.completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateQuery(_ query: String) {
        completer.queryFragment = query
    }

    func resolve(
        _ completion: ChatAttachmentGeolocationSearchCompletion,
        completionHandler: @escaping (Result<ChatAttachmentResolvedLocation, Error>) -> Void
    ) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [completion.title, completion.subtitle]
            .filter { $0.isNotEmpty }
            .joined(separator: ", ")
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            if let error {
                completionHandler(.failure(error))
                return
            }
            guard let item = response?.mapItems.first else {
                completionHandler(.failure(ChatAttachmentGeolocationSearchError.noResult))
                return
            }
            let coordinate = item.placemark.coordinate.attachmentCoordinate
            completionHandler(
                .success(
                    ChatAttachmentResolvedLocation(
                        coordinate: coordinate,
                        displayAddress: Self.address(from: item.placemark) ?? completion.title,
                        accuracy: nil
                    )
                )
            )
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResultsChanged?(
            completer.results.map {
                ChatAttachmentGeolocationSearchCompletion(
                    title: $0.title,
                    subtitle: $0.subtitle
                )
            }
        )
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onResultsChanged?([])
    }

    private static func address(from placemark: MKPlacemark) -> String? {
        if let title = placemark.title, title.isNotEmpty {
            return title
        }
        let parts = [
            placemark.name,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isNotEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private enum ChatAttachmentGeolocationSearchError: Error {
    case noResult
}

final class CoreLocationChatAttachmentCurrentLocationProvider: NSObject,
    ChatAttachmentCurrentLocationProviding,
    CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    private let authorizationStatusProvider: () -> CLAuthorizationStatus
    private var pendingCompletion: ((Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) -> Void)?

    init(
        locationManager: CLLocationManager = CLLocationManager(),
        authorizationStatusProvider: (() -> CLAuthorizationStatus)? = nil
    ) {
        self.locationManager = locationManager
        self.authorizationStatusProvider = authorizationStatusProvider ?? { locationManager.authorizationStatus }
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentLocation(
        completion: @escaping (Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) -> Void
    ) {
        pendingCompletion = completion
        locationManager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            complete(.failure(.unavailable))
            return
        }
        complete(
            .success(
                ChatAttachmentCurrentLocation(
                    coordinate: location.coordinate.attachmentCoordinate,
                    accuracy: location.horizontalAccuracy.isFinite ? location.horizontalAccuracy : nil
                )
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.Code.denied.rawValue {
            complete(.failure(blockReasonForLocationDeniedError()))
        } else {
            complete(.failure(.unavailable))
        }
    }

    private func blockReasonForLocationDeniedError() -> ChatAttachmentGeolocationBlockReason {
        switch authorizationStatusProvider() {
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined, .authorizedAlways, .authorizedWhenInUse:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    private func complete(_ result: Result<ChatAttachmentCurrentLocation, ChatAttachmentGeolocationBlockReason>) {
        guard let pendingCompletion else { return }
        self.pendingCompletion = nil
        pendingCompletion(result)
    }
}

final class CoreLocationChatAttachmentReverseGeocoder: ChatAttachmentGeolocationReverseGeocoding {
    private let geocoder: CLGeocoder

    init(geocoder: CLGeocoder = CLGeocoder()) {
        self.geocoder = geocoder
    }

    func reverseGeocode(
        coordinate: AttachmentLocationCoordinate,
        completion: @escaping (String?) -> Void
    ) {
        let location = CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            completion(Self.address(from: placemarks?.first))
        }
    }

    private static func address(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        let parts = [
            placemark.name,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isNotEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

final class ToastSwiftChatAttachmentGeolocationToastPresenter: ChatAttachmentGeolocationToastPresenting {
    func showToast(message: String, in view: UIView) {
        view.makeToast(message)
    }
}

private enum ChatLocationSnapshotError: Error {
    case imageEncodingFailed
    case outputWriteFailed
}

final class MapKitChatLocationSnapshotProvider: ChatLocationSnapshotProviding {
    private let outputDirectory: URL
    private let fileManager: FileManager
    private let uuidProvider: () -> UUID

    init(
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-location-snapshots", isDirectory: true),
        fileManager: FileManager = .default,
        uuidProvider: @escaping () -> UUID = UUID.init
    ) {
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.uuidProvider = uuidProvider
    }

    func makeSnapshot(
        for location: ChatAttachmentResolvedLocation,
        size: CGSize,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let snapshotSize = CGSize(
            width: max(1, size.width),
            height: max(1, size.height)
        )
        let coordinate = location.coordinate.clLocationCoordinate
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1_000,
            longitudinalMeters: 1_000
        )
        options.size = snapshotSize
        options.scale = UIScreen.main.scale
        options.mapType = .standard

        MKMapSnapshotter(options: options).start { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let snapshot else {
                completion(.failure(ChatLocationSnapshotError.imageEncodingFailed))
                return
            }

            do {
                let destinationURL = try self.writeSnapshotImage(snapshot.image)
                completion(.success(destinationURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func writeSnapshotImage(_ image: UIImage) throws -> URL {
        guard let data = Self.imageWithMarker(image).pngData() else {
            throw ChatLocationSnapshotError.imageEncodingFailed
        }

        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let url = outputDirectory
                .appendingPathComponent("\(uuidProvider().uuidString).png")
                .standardizedFileURL
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ChatLocationSnapshotError.outputWriteFailed
        }
    }

    private static func imageWithMarker(_ image: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let center = CGPoint(x: image.size.width / 2, y: image.size.height / 2)
            let radius = max(6, min(image.size.width, image.size.height) * 0.035)
            let markerRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: markerRect).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: markerRect.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 3
            ring.stroke()
        }
    }
}

final class ChatAttachmentGeolocationSourceViewController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing,
    UITableViewDataSource,
    UITableViewDelegate {
    let source: ChatAttachmentSource = .geolocation
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?

    let mapView = MKMapView()
    let searchSurfaceView = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(role: .bar, interactive: true))
    let searchTextField = UITextField()
    let searchResultsTableView = UITableView(frame: .zero, style: .plain)
    let currentLocationButton = UIButton(type: .system)
    let requestAccessButton = UIButton(type: .system)
    let statusLabel = UILabel()

    private let authorizer: ChatAttachmentGeolocationAuthorizing
    private let currentLocationProvider: ChatAttachmentCurrentLocationProviding
    private let searchProvider: ChatAttachmentGeolocationSearchProviding
    private let reverseGeocoder: ChatAttachmentGeolocationReverseGeocoding
    private let snapshotProvider: ChatLocationSnapshotProviding
    private let toastPresenter: ChatAttachmentGeolocationToastPresenting
    private var searchResults: [ChatAttachmentGeolocationSearchCompletion] = []
    private var selectedDrafts: [AttachmentDraft] = []
    private var selectedAnnotation: MKPointAnnotation?
    private var activeSnapshotRequestID: UUID?

    private(set) var permissionState: ChatAttachmentGeolocationPermissionState

    var viewController: UIViewController {
        self
    }

    var selectedAttachmentDrafts: [AttachmentDraft] {
        selectedDrafts
    }

    init(
        authorizer: ChatAttachmentGeolocationAuthorizing = CoreLocationChatAttachmentGeolocationAuthorizer(),
        currentLocationProvider: ChatAttachmentCurrentLocationProviding = CoreLocationChatAttachmentCurrentLocationProvider(),
        searchProvider: ChatAttachmentGeolocationSearchProviding = MapKitChatAttachmentGeolocationSearchProvider(),
        reverseGeocoder: ChatAttachmentGeolocationReverseGeocoding = CoreLocationChatAttachmentReverseGeocoder(),
        snapshotProvider: ChatLocationSnapshotProviding = MapKitChatLocationSnapshotProvider(),
        toastPresenter: ChatAttachmentGeolocationToastPresenting = ToastSwiftChatAttachmentGeolocationToastPresenter(),
        isWireContractEnabled: Bool = true
    ) {
        self.authorizer = authorizer
        self.currentLocationProvider = currentLocationProvider
        self.searchProvider = searchProvider
        self.reverseGeocoder = reverseGeocoder
        self.snapshotProvider = snapshotProvider
        self.toastPresenter = toastPresenter
        self.permissionState = ChatAttachmentGeolocationPermissionPolicy.state(
            for: authorizer.authorizationStatus,
            isLocationServicesEnabled: true
        )
        super.init(nibName: nil, bundle: nil)
        self.searchProvider.onResultsChanged = { [weak self] results in
            self?.updateSearchResults(results)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .systemBackground

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.accessibilityIdentifier = "chatAttachmentGeolocation.map"
        mapView.showsUserLocation = false

        searchSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        searchSurfaceView.isUserInteractionEnabled = true
        searchSurfaceView.contentView.isUserInteractionEnabled = true
        NativeGlassBarStyle.applySurface(to: searchSurfaceView, cornerStyle: .capsule, interactive: true)

        searchTextField.translatesAutoresizingMaskIntoConstraints = false
        searchTextField.accessibilityIdentifier = "chatAttachmentGeolocation.searchField"
        searchTextField.placeholder = ChatAttachmentLocalization.string(.geolocationSearchPlaceholder)
        searchTextField.borderStyle = .none
        searchTextField.returnKeyType = .search
        searchTextField.clearButtonMode = .whileEditing
        searchTextField.backgroundColor = .clear
        searchTextField.textColor = .label
        searchTextField.font = .preferredFont(forTextStyle: .body)
        searchTextField.adjustsFontForContentSizeCategory = true
        searchTextField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)

        searchResultsTableView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsTableView.accessibilityIdentifier = "chatAttachmentGeolocation.searchResults"
        searchResultsTableView.dataSource = self
        searchResultsTableView.delegate = self
        searchResultsTableView.isHidden = true
        searchResultsTableView.keyboardDismissMode = .onDrag
        searchResultsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "locationSearchCell")

        currentLocationButton.translatesAutoresizingMaskIntoConstraints = false
        currentLocationButton.accessibilityIdentifier = "chatAttachmentGeolocation.currentLocationButton"
        currentLocationButton.addTarget(self, action: #selector(currentLocationTapped), for: .touchUpInside)
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: currentLocationButton,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: ChatAttachmentGeolocationMapControlsStyle.currentLocationIcon
        )

        requestAccessButton.isHidden = true
        statusLabel.isHidden = true

        rootView.addSubview(mapView)
        rootView.addSubview(searchSurfaceView)
        rootView.addSubview(searchResultsTableView)
        rootView.addSubview(currentLocationButton)
        searchSurfaceView.contentView.addSubview(searchTextField)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: rootView.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            searchSurfaceView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 12),
            searchSurfaceView.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: NativeGlassBarStyle.horizontalInset
            ),
            searchSurfaceView.trailingAnchor.constraint(
                equalTo: currentLocationButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),
            searchSurfaceView.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.minimumHeight),

            searchTextField.topAnchor.constraint(equalTo: searchSurfaceView.contentView.topAnchor),
            searchTextField.leadingAnchor.constraint(
                equalTo: searchSurfaceView.contentView.leadingAnchor,
                constant: NativeGlassBarStyle.contentInset
            ),
            searchTextField.trailingAnchor.constraint(
                equalTo: searchSurfaceView.contentView.trailingAnchor,
                constant: -NativeGlassBarStyle.contentInset
            ),
            searchTextField.bottomAnchor.constraint(equalTo: searchSurfaceView.contentView.bottomAnchor),

            currentLocationButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            currentLocationButton.centerYAnchor.constraint(equalTo: searchSurfaceView.centerYAnchor),
            currentLocationButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            currentLocationButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),

            searchResultsTableView.topAnchor.constraint(
                equalTo: searchSurfaceView.bottomAnchor,
                constant: NativeGlassBarStyle.interItemSpacing
            ),
            searchResultsTableView.leadingAnchor.constraint(equalTo: searchSurfaceView.leadingAnchor),
            searchResultsTableView.trailingAnchor.constraint(equalTo: currentLocationButton.trailingAnchor),
            searchResultsTableView.heightAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(mapTapped(_:)))
        mapView.addGestureRecognizer(tapRecognizer)
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(mapLongPressed(_:)))
        mapView.addGestureRecognizer(longPressRecognizer)

        view = rootView
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        selectedDrafts = drafts
        if !drafts.contains(where: { $0.source == .geolocation }) {
            activeSnapshotRequestID = nil
        }
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        let previousDrafts = selectedDrafts
        selectedDrafts.removeAll { $0.id == draftID }
        if selectedDrafts != previousDrafts {
            notifySelectionChanged()
        }
        return selectedDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        guard let index = selectedDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedDrafts
        }
        selectedDrafts[index] = updatedDraft
        notifySelectionChanged()
        return selectedDrafts
    }

    func cancelLocationSelection() {
        selectedDrafts.removeAll { $0.source == .geolocation }
        activeSnapshotRequestID = nil
        notifySelectionChanged()
    }

    func selectResolvedLocation(_ location: ChatAttachmentResolvedLocation) {
        let requestID = UUID()
        activeSnapshotRequestID = requestID
        let draft = makeLocationDraft(from: location, localSnapshotURL: nil)
        selectedDrafts = [draft]
        updateMapSelection(location)
        notifySelectionChanged()
        snapshotProvider.makeSnapshot(
            for: location,
            size: Self.snapshotSize
        ) { [weak self] result in
            let applyResult: () -> Void = {
                self?.completeSnapshotResult(result, for: location, requestID: requestID)
            }
            if Thread.isMainThread {
                applyResult()
            } else {
                DispatchQueue.main.async(execute: applyResult)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "locationSearchCell", for: indexPath)
        let result = searchResults[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = result.title
        configuration.secondaryText = result.subtitle
        cell.contentConfiguration = configuration
        cell.accessibilityIdentifier = "chatAttachmentGeolocation.searchResult.\(indexPath.row)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard searchResults.indices.contains(indexPath.row) else { return }
        let result = searchResults[indexPath.row]
        searchProvider.resolve(result) { [weak self] resolution in
            guard let self else { return }
            switch resolution {
            case .success(let location):
                self.searchResults = []
                self.searchResultsTableView.reloadData()
                self.searchResultsTableView.isHidden = true
                self.searchTextField.text = location.displayAddress ?? result.title
                self.selectResolvedLocation(location)
            case .failure:
                self.showToast(for: .unavailable)
            }
        }
    }

    @objc
    private func searchTextChanged() {
        searchProvider.updateQuery(searchTextField.text ?? "")
    }

    @objc
    private func currentLocationTapped() {
        switch authorizer.authorizationStatus {
        case .authorized:
            requestCurrentLocation()
        case .notDetermined:
            authorizer.requestWhenInUseAuthorization { [weak self] status in
                guard let self else { return }
                self.permissionState = ChatAttachmentGeolocationPermissionPolicy.state(
                    for: status,
                    isLocationServicesEnabled: true
                )
                switch status {
                case .authorized:
                    self.requestCurrentLocation()
                case .notDetermined:
                    break
                case .denied, .restricted, .unavailable:
                    self.showToast(for: self.blockReason(for: status))
                }
            }
        case .denied:
            showToast(for: .denied)
        case .restricted:
            showToast(for: .restricted)
        case .unavailable:
            showToast(for: .unavailable)
        }
    }

    @objc
    private func mapTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        selectMapCoordinate(at: recognizer.location(in: mapView))
    }

    @objc
    private func mapLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        selectMapCoordinate(at: recognizer.location(in: mapView))
    }

    private func requestCurrentLocation() {
        currentLocationProvider.requestCurrentLocation { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let currentLocation):
                self.reverseGeocoder.reverseGeocode(coordinate: currentLocation.coordinate) { [weak self] address in
                    self?.selectResolvedLocation(
                        ChatAttachmentResolvedLocation(
                            coordinate: currentLocation.coordinate,
                            displayAddress: address,
                            accuracy: currentLocation.accuracy
                        )
                    )
                }
            case .failure(let reason):
                self.showToast(for: reason)
            }
        }
    }

    private func selectMapCoordinate(at point: CGPoint) {
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView).attachmentCoordinate
        reverseGeocoder.reverseGeocode(coordinate: coordinate) { [weak self] address in
            self?.selectResolvedLocation(
                ChatAttachmentResolvedLocation(
                    coordinate: coordinate,
                    displayAddress: address,
                    accuracy: nil
                )
            )
        }
    }

    private func updateSearchResults(_ results: [ChatAttachmentGeolocationSearchCompletion]) {
        searchResults = results
        searchResultsTableView.reloadData()
        searchResultsTableView.isHidden = results.isEmpty
    }

    private func makeLocationDraft(
        from location: ChatAttachmentResolvedLocation,
        localSnapshotURL: URL?
    ) -> AttachmentDraft {
        let preparedLocation = AttachmentPreparedLocation(
            coordinate: location.coordinate,
            displayAddress: location.displayAddress,
            accuracy: location.accuracy,
            geoURI: Self.geoURI(for: location.coordinate),
            createdAt: Date(),
            localSnapshotURL: localSnapshotURL
        )
        return AttachmentDraft(
            id: "location:\(preparedLocation.geoURI)",
            source: .geolocation,
            mediaKind: .location,
            thumbnailState: .none,
            filename: location.displayAddress ?? ChatAttachmentLocalization.string(.sourceLocationTitle),
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .preparedLocation(preparedLocation)
        )
    }

    private func completeSnapshotResult(
        _ result: Result<URL, Error>,
        for location: ChatAttachmentResolvedLocation,
        requestID: UUID
    ) {
        guard activeSnapshotRequestID == requestID else {
            return
        }

        switch result {
        case .success(let snapshotURL):
            selectedDrafts = [makeLocationDraft(from: location, localSnapshotURL: snapshotURL)]
            notifySelectionChanged()
        case .failure:
            showToast(message: ChatAttachmentLocalization.string(.geolocationSnapshotFailedMessage))
        }
    }

    private func updateMapSelection(_ location: ChatAttachmentResolvedLocation) {
        if let selectedAnnotation {
            mapView.removeAnnotation(selectedAnnotation)
        }
        let annotation = MKPointAnnotation()
        annotation.coordinate = location.coordinate.clLocationCoordinate
        annotation.title = location.displayAddress
        selectedAnnotation = annotation
        mapView.addAnnotation(annotation)
        mapView.setRegion(
            MKCoordinateRegion(
                center: annotation.coordinate,
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            ),
            animated: false
        )
    }

    private func notifySelectionChanged() {
        onSelectionCountChanged?(selectedDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedDrafts)
    }

    private func showToast(for reason: ChatAttachmentGeolocationBlockReason) {
        showToast(message: toastMessage(for: reason))
    }

    private func showToast(message: String) {
        toastPresenter.showToast(message: message, in: view)
    }

    private func toastMessage(for reason: ChatAttachmentGeolocationBlockReason) -> String {
        switch reason {
        case .denied:
            return ChatAttachmentLocalization.string(.geolocationDeniedMessage)
        case .restricted:
            return ChatAttachmentLocalization.string(.geolocationRestrictedMessage)
        case .unavailable, .wireContractUnavailable:
            return ChatAttachmentLocalization.string(.geolocationUnavailableMessage)
        }
    }

    private func blockReason(for status: ChatAttachmentGeolocationAuthorizationStatus) -> ChatAttachmentGeolocationBlockReason {
        switch status {
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined, .authorized, .unavailable:
            return .unavailable
        }
    }

    private static func geoURI(for coordinate: AttachmentLocationCoordinate) -> String {
        "geo:\(coordinate.latitude),\(coordinate.longitude)"
    }

    private static var snapshotSize: CGSize {
        CGSize(width: 640, height: 640)
    }
}

private extension CLLocationCoordinate2D {
    var attachmentCoordinate: AttachmentLocationCoordinate {
        AttachmentLocationCoordinate(latitude: latitude, longitude: longitude)
    }
}

private extension AttachmentLocationCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
