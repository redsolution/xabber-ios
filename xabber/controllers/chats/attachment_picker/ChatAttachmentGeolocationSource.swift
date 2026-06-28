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

enum ChatAttachmentGeolocationBlockReason: Equatable {
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
        guard isWireContractEnabled else {
            return .disabled
        }

        return isLocationServicesEnabled ? .available : .disabled
    }

    static func sourceBarConfiguration(
        isWireContractEnabled: Bool,
        isLocationServicesEnabled: Bool
    ) -> ChatAttachmentSourceBarConfiguration {
        ChatAttachmentSourceBarConfiguration(
            sourceAvailability: [
                .gallery: .available,
                .file: .available,
                .geolocation: availability(
                    isWireContractEnabled: isWireContractEnabled,
                    isLocationServicesEnabled: isLocationServicesEnabled
                ),
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

        self.pendingCompletion = nil
        pendingCompletion(Self.mapAuthorizationStatus(manager.authorizationStatus))
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

final class ChatAttachmentGeolocationSourceViewController: UIViewController, ChatAttachmentSourceControlling {
    let source: ChatAttachmentSource = .geolocation
    var onSelectionCountChanged: ((Int) -> Void)?

    let requestAccessButton = UIButton(type: .system)
    let mapView = MKMapView()
    let statusLabel = UILabel()

    private let authorizer: ChatAttachmentGeolocationAuthorizing
    private let isWireContractEnabled: Bool

    private(set) var permissionState: ChatAttachmentGeolocationPermissionState = .blocked(
        reason: .wireContractUnavailable
    )

    var viewController: UIViewController {
        self
    }

    init(
        authorizer: ChatAttachmentGeolocationAuthorizing = CoreLocationChatAttachmentGeolocationAuthorizer(),
        isWireContractEnabled: Bool = false
    ) {
        self.authorizer = authorizer
        self.isWireContractEnabled = isWireContractEnabled
        super.init(nibName: nil, bundle: nil)
        refreshPermissionState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .systemBackground

        requestAccessButton.translatesAutoresizingMaskIntoConstraints = false
        requestAccessButton.accessibilityIdentifier = "chatAttachmentGeolocation.requestAccessButton"
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = ChatAttachmentLocalization.string(.geolocationAllowAccessAction)
        buttonConfiguration.image = UIImage(systemName: "location")
        buttonConfiguration.imagePadding = 8
        buttonConfiguration.cornerStyle = .capsule
        requestAccessButton.configuration = buttonConfiguration
        requestAccessButton.addTarget(self, action: #selector(requestLocationAccess), for: .touchUpInside)

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.accessibilityIdentifier = "chatAttachmentGeolocation.map"
        mapView.isHidden = true
        mapView.showsUserLocation = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "chatAttachmentGeolocation.status"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        rootView.addSubview(mapView)
        rootView.addSubview(requestAccessButton)
        rootView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: rootView.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            requestAccessButton.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            requestAccessButton.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            requestAccessButton.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            requestAccessButton.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            requestAccessButton.heightAnchor.constraint(equalToConstant: 44),

            statusLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderPermissionState()
    }

    func cancelLocationSelection() {
        // Selection drafts are intentionally not mutated until the geolocation wire/send contract lands.
    }

    @objc
    private func requestLocationAccess() {
        guard isWireContractEnabled,
              permissionState == .requestAccess else {
            return
        }

        authorizer.requestWhenInUseAuthorization { [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    private func refreshPermissionState() {
        guard isWireContractEnabled else {
            permissionState = .blocked(reason: .wireContractUnavailable)
            renderPermissionState()
            return
        }

        permissionState = ChatAttachmentGeolocationPermissionPolicy.state(
            for: authorizer.authorizationStatus,
            isLocationServicesEnabled: authorizer.isLocationServicesEnabled
        )
        renderPermissionState()
    }

    private func renderPermissionState() {
        guard isViewLoaded else {
            return
        }

        requestAccessButton.isHidden = true
        mapView.isHidden = true
        statusLabel.isHidden = true
        statusLabel.text = nil

        switch permissionState {
        case .requestAccess:
            requestAccessButton.isHidden = false
        case .ready:
            mapView.isHidden = false
        case .blocked(let reason):
            renderBlockedState(reason)
        }
    }

    private func renderBlockedState(_ reason: ChatAttachmentGeolocationBlockReason) {
        switch reason {
        case .wireContractUnavailable:
            statusLabel.isHidden = true
        case .denied:
            statusLabel.text = ChatAttachmentLocalization.string(.geolocationDeniedMessage)
            statusLabel.isHidden = false
        case .restricted:
            statusLabel.text = ChatAttachmentLocalization.string(.geolocationRestrictedMessage)
            statusLabel.isHidden = false
        case .unavailable:
            statusLabel.text = ChatAttachmentLocalization.string(.geolocationUnavailableMessage)
            statusLabel.isHidden = false
        }
    }
}
