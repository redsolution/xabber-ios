import Foundation
import XMPPFramework

@MainActor
final class PrivacyProxySettings {
    enum Availability: Equatable {
        case checking
        case notAdvertised
        case unreachable(host: String)
        case reachable(host: String)
    }

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
    private let discovery: () -> ServerDiscoManager.PrivacyProxyDiscovery
    private let hasActivePremium: () -> Bool
    private let readPreference: () -> Bool
    private let writePreference: (Bool) -> Void
    private let probe: (URL) async -> Bool

    private var probeTask: Task<Void, Never>?
    private var probingEndpoint: URL?
    private var lastProbe: (endpoint: URL, reachable: Bool)?

    convenience init(owner: String) {
        let owner = XMPPJID(string: owner)?.bare ?? owner
        let policy = CommonConfigManager.shared.config.privacyProxyPolicy
        let preferenceKey = SettingManager.privacyProxyEnabledKey
        self.init(
            policy: policy,
            discovery: { AccountManager.shared.find(for: owner)?.disco.privacyProxyDiscovery ?? .unknown },
            hasActivePremium: { SubscribtionsManager.shared.hasActiveSubsription(for: owner) },
            readPreference: {
                SettingManager.shared.getKeyBool(for: owner, scope: .security, key: preferenceKey) ?? false
            },
            writePreference: {
                SettingManager.shared.saveItem(for: owner, scope: .security, key: preferenceKey, value: $0)
            },
            probe: PrivacyProxyReachability.check
        )
    }

    init(
        policy: CommonConfigManager.PrivacyProxyPolicy,
        discovery: @escaping () -> ServerDiscoManager.PrivacyProxyDiscovery,
        hasActivePremium: @escaping () -> Bool,
        readPreference: @escaping () -> Bool,
        writePreference: @escaping (Bool) -> Void,
        probe: @escaping (URL) async -> Bool
    ) {
        self.policy = policy
        self.discovery = discovery
        self.hasActivePremium = hasActivePremium
        self.readPreference = readPreference
        self.writePreference = writePreference
        self.probe = probe
    }

    deinit {
        probeTask?.cancel()
    }

    func refresh(forceProbe: Bool = false) {
        guard policy != .never else {
            reset(to: .notAdvertised)
            return
        }
        switch discovery() {
        case .unknown:
            reset(to: .checking)
        case .notAdvertised:
            reset(to: .notAdvertised)
        case .advertised(let endpoint):
            refresh(endpoint: endpoint, forceProbe: forceProbe)
        }
    }

    func stopProbing() {
        probeTask?.cancel()
        probeTask = nil
        probingEndpoint = nil
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard probingEndpoint == nil,
              let lastProbe, lastProbe.reachable,
              discovery() == .advertised(lastProbe.endpoint),
              policy.canEnableProxyInSettings(hasActivePremium: policy == .payed && hasActivePremium()) else {
            refresh()
            return false
        }
        if readPreference() != enabled {
            writePreference(enabled)
        }
        updateState(.reachable(host: host(for: lastProbe.endpoint)))
        return true
    }

    private func refresh(endpoint: URL, forceProbe: Bool) {
        guard endpoint != probingEndpoint else { return }
        stopProbing()
        if !forceProbe, let lastProbe, lastProbe.endpoint == endpoint {
            updateState(availability(for: endpoint, reachable: lastProbe.reachable))
            return
        }

        lastProbe = nil
        probingEndpoint = endpoint
        probeTask = Task { [weak self, probe] in
            let reachable = await probe(endpoint)
            guard !Task.isCancelled, let self else { return }
            self.probeTask = nil
            self.probingEndpoint = nil
            guard self.discovery() == .advertised(endpoint) else {
                self.refresh()
                return
            }
            self.lastProbe = (endpoint, reachable)
            self.updateState(self.availability(for: endpoint, reachable: reachable))
        }
        updateState(.checking)
    }

    private func reset(to availability: Availability) {
        stopProbing()
        lastProbe = nil
        updateState(availability)
    }

    private func availability(for endpoint: URL, reachable: Bool) -> Availability {
        let host = host(for: endpoint)
        return reachable ? .reachable(host: host) : .unreachable(host: host)
    }

    private func host(for endpoint: URL) -> String {
        endpoint.host ?? endpoint.absoluteString
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

private final class PrivacyProxyReachability: NSObject, URLSessionTaskDelegate {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PrivacyProxyReachability(), delegateQueue: nil)
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
