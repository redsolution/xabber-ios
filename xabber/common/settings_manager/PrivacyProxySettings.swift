import Foundation
import XMPPFramework

@MainActor
final class PrivacyProxySettings {
    typealias Availability = PrivacyProxyReachability.Availability

    struct State: Equatable {
        let availability: Availability
        let showsSwitch: Bool
        let canChangeSwitch: Bool
        let isEnabled: Bool
        let requiresPremium: Bool
    }

    private(set) var state = State(
        availability: .checking,
        showsSwitch: false,
        canChangeSwitch: false,
        isEnabled: false,
        requiresPremium: false
    )
    var onChange: ((State) -> Void)?

    private let policy: CommonConfigManager.PrivacyProxyPolicy
    private let availability: () -> Availability
    private let hasActivePremium: () -> Bool
    private let readPreference: () -> Bool
    private let writePreference: (Bool) -> Void

    convenience init(owner: String) {
        let owner = XMPPJID(string: owner)?.bare ?? owner
        let policy = CommonConfigManager.shared.config.privacyProxyPolicy
        let preferenceKey = SettingManager.privacyProxyEnabledKey
        self.init(
            policy: policy,
            availability: { AccountManager.shared.find(for: owner)?.disco.privacyProxyAvailability ?? .checking },
            hasActivePremium: { SubscribtionsManager.shared.hasActiveSubsription(for: owner) },
            readPreference: {
                SettingManager.shared.getKeyBool(for: owner, scope: .security, key: preferenceKey) ?? false
            },
            writePreference: {
                SettingManager.shared.saveItem(for: owner, scope: .security, key: preferenceKey, value: $0)
                if $0 { PrivacyProxyMediaRouter.shared.clearImageConsent(owner: owner) }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .privacyProxyAvailabilityDidChange, object: nil, userInfo: ["owner": owner]
                    )
                }
            }
        )
    }

    init(
        policy: CommonConfigManager.PrivacyProxyPolicy,
        availability: @escaping () -> Availability,
        hasActivePremium: @escaping () -> Bool,
        readPreference: @escaping () -> Bool,
        writePreference: @escaping (Bool) -> Void
    ) {
        self.policy = policy
        self.availability = availability
        self.hasActivePremium = hasActivePremium
        self.readPreference = readPreference
        self.writePreference = writePreference
    }

    func refresh() {
        updateState(policy == .never ? .notAdvertised : availability())
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard policy.canEnableProxyInSettings(hasActivePremium: policy == .payed && hasActivePremium()),
              case .reachable = availability() else {
            refresh()
            return false
        }
        if readPreference() != enabled {
            writePreference(enabled)
        }
        refresh()
        return true
    }

    private func updateState(_ availability: Availability) {
        let reachable: Bool
        if case .reachable = availability {
            reachable = true
        } else {
            reachable = false
        }
        let hasPremium = policy == .payed && hasActivePremium()
        let next = State(
            availability: availability,
            showsSwitch: reachable && policy.showsProxyControls,
            canChangeSwitch: reachable && policy.canEnableProxyInSettings(hasActivePremium: hasPremium),
            isEnabled: reachable && policy.usesProxy(localProxyEnabled: readPreference(), hasActivePremium: hasPremium),
            requiresPremium: policy == .payed && !hasPremium
        )
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}

@MainActor
final class PrivacyProxyReachability {
    enum Availability: Equatable {
        case checking
        case notAdvertised
        case unreachable(host: String)
        case reachable(host: String)
    }

    private let probe: (URL) async -> Bool
    private let onChange: (Availability) -> Void
    private var discovery: ServerDiscoManager.PrivacyProxyDiscovery = .unknown
    private var isConnected = false
    private var task: Task<Void, Never>?

    private(set) var availability: Availability = .checking {
        didSet {
            if availability != oldValue { onChange(availability) }
        }
    }

    init(probe: @escaping (URL) async -> Bool, onChange: @escaping (Availability) -> Void) {
        self.probe = probe
        self.onChange = onChange
    }

    deinit { task?.cancel() }

    func connect(discovery: ServerDiscoManager.PrivacyProxyDiscovery) {
        updateDiscovery(discovery)
        guard !isConnected else { return }
        isConnected = true
        startProbeIfNeeded()
    }

    func disconnect() {
        isConnected = false
        cancelProbe()
    }

    func updateDiscovery(_ discovery: ServerDiscoManager.PrivacyProxyDiscovery) {
        guard self.discovery != discovery else { return }
        self.discovery = discovery
        cancelProbe()
        availability = discovery == .notAdvertised ? .notAdvertised : .checking
        startProbeIfNeeded()
    }

    func availability(for discovery: ServerDiscoManager.PrivacyProxyDiscovery) -> Availability {
        if discovery == self.discovery { return availability }
        return discovery == .notAdvertised ? .notAdvertised : .checking
    }

    private func cancelProbe() {
        task?.cancel()
        task = nil
    }

    private func startProbeIfNeeded() {
        guard isConnected, task == nil,
              case .advertised(let endpoint) = discovery else { return }
        if case .reachable = availability { return }
        task = Task { [weak self, probe] in
            guard !Task.isCancelled else { return }
            let reachable = await probe(endpoint)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            let host = endpoint.host ?? endpoint.absoluteString
            self.availability = reachable ? .reachable(host: host) : .unreachable(host: host)
        }
        availability = .checking
    }
}

final class PrivacyProxyHTTPProbe: NSObject, URLSessionTaskDelegate {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PrivacyProxyHTTPProbe(), delegateQueue: nil)
    }()

    static func check(_ endpoint: URL) async -> Bool {
        guard endpoint.scheme?.lowercased() == "https" else { return false }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The advertised host already answered. No request to its redirect target is needed.
        completionHandler(nil)
    }
}
