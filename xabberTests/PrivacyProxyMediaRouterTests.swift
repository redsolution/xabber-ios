import XCTest
@testable import xabber

final class PrivacyProxyMediaRouterTests: XCTestCase {
    private let owner = "alice@example.com"
    private let endpoint = URL(string: "https://proxy.example.net/service/")!
    private let external = URL(string: "https://files.example.org/photo.jpg?x=1&y=2")!
    private let resolved = URL(string: "https://proxy.example.net/service/proxy/files/123/")!

    func testExternalImageConsentIsScopedAndBackgroundCannotUseIt() async throws {
        let router = makeRouter(policy: .never, enabled: false) { _, _ in
            XCTFail("Never must not contact the proxy")
            return self.resolved
        }
        XCTAssertTrue(router.imageRequiresConsent(external, owner: owner))
        do {
            _ = try await router.resolveImage(external, owner: owner)
            XCTFail("Original image must wait for consent")
        } catch PrivacyProxyMediaRouter.RoutingError.imageConsentRequired {}
        XCTAssertTrue(router.grantDirectImage(external, owner: owner))
        let approved = try await router.resolveImage(external, owner: owner)
        XCTAssertEqual(approved, external)
        XCTAssertTrue(router.imageRequiresConsent(external, owner: "bob@example.com"))
        XCTAssertTrue(router.imageRequiresConsent(external.appendingPathComponent("other"), owner: owner))
        do {
            _ = try await router.resolveAutomaticImage(external, owner: owner)
            XCTFail("Background work must not use a foreground grant")
        } catch PrivacyProxyMediaRouter.RoutingError.imageConsentRequired {}
        router.clearImageConsent(owner: owner)
        XCTAssertTrue(router.imageRequiresConsent(external, owner: owner))
    }

    func testOptionalProxyCanFallBackOnlyAfterApprovalAndAlwaysCannot() async throws {
        let optional = makeRouter(policy: .manual, enabled: true) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await optional.resolveImage(external, owner: owner)
            XCTFail("A failed proxy must not authorize direct loading")
        } catch PrivacyProxyMediaRouter.RoutingError.imageConsentRequired {}
        XCTAssertTrue(optional.grantDirectImage(external, owner: owner))
        let approved = try await optional.resolveImage(external, owner: owner)
        XCTAssertEqual(approved, external)

        let mandatory = makeRouter(policy: .always, enabled: true, advertised: false) { _, _ in
            XCTFail("No endpoint to use")
            return self.resolved
        }
        XCTAssertFalse(mandatory.canRequestDirectImage(external, owner: owner))
        XCTAssertFalse(mandatory.grantDirectImage(external, owner: owner))
        do {
            _ = try await mandatory.resolveImage(external, owner: owner)
            XCTFail("Always requires proxy for an external image")
        } catch PrivacyProxyMediaRouter.RoutingError.unavailable {}
    }

    func testAutomaticImageUsesProxyOrTrustedHostWithoutConsent() async throws {
        let router = makeRouter(policy: .manual, enabled: true) { url, owner in
            XCTAssertEqual(url, self.external)
            XCTAssertEqual(owner, self.owner)
            return self.resolved
        }
        let proxied = try await router.resolveImage(external, owner: owner)
        XCTAssertEqual(proxied, resolved)
        let trusted = URL(string: "https://gallery.example.net/photo.jpg")!
        let direct = try await router.resolveAutomaticImage(trusted, owner: owner)
        XCTAssertEqual(direct, trusted)
    }

    func testManualOffAndNeverKeepExistingURLs() async throws {
        for policy in [CommonConfigManager.PrivacyProxyPolicy.manual, .never] {
            let router = makeRouter(policy: policy, enabled: false) { _, _ in
                XCTFail("Disabled proxy must not resolve the URL")
                return self.resolved
            }
            let url = try await router.resolve(external, owner: owner)
            XCTAssertEqual(url, external)
        }
    }

    func testMandatoryProxyRoutesExternalButKeepsLocalAndOwnGallery() async throws {
        let router = makeRouter(policy: .always, enabled: false) { url, owner in
            XCTAssertEqual(url, self.external)
            XCTAssertEqual(owner, self.owner)
            return self.resolved
        }
        let proxied = try await router.resolve(external, owner: owner)
        XCTAssertEqual(proxied, resolved)
        for rawURL in ["data:image/png;base64,AAAA", "file:///tmp/a", "https://media.example.com/a",
                       "https://gallery.example.net/a"] {
            let url = try XCTUnwrap(URL(string: rawURL))
            let result = try await router.resolve(url, owner: owner)
            XCTAssertEqual(result, url)
        }
    }

    func testMissingProxyAndLookupFailureDoNotReturnExternalURL() async {
        let missing = makeRouter(policy: .always, enabled: false, advertised: false) { _, _ in
            XCTFail("There is no endpoint")
            return self.resolved
        }
        let failed = makeRouter(policy: .manual, enabled: true) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        for router in [missing, failed] {
            do {
                _ = try await router.resolve(external, owner: owner)
                XCTFail("An external source requires a successful proxy lookup")
            } catch {}
        }
    }

    func testPaidPreferenceRequiresCurrentEntitlement() async throws {
        let router = makeRouter(policy: .payed, enabled: true, premium: false) { _, _ in
            XCTFail("The account has no active Premium")
            return self.resolved
        }
        let url = try await router.resolve(external, owner: owner)
        XCTAssertEqual(url, external)
    }

    func testRedirectsKeepOriginAndNeverDowngradeTLS() {
        let origin = URL(string: "https://proxy.example.net/file")!
        XCTAssertTrue(PrivacyProxyMediaRouter.allowsRedirect(from: origin, to: URL(string: "https://proxy.example.net/other")!))
        XCTAssertFalse(PrivacyProxyMediaRouter.allowsRedirect(from: origin, to: URL(string: "https://proxy.example.net.evil/other")!))
        XCTAssertFalse(PrivacyProxyMediaRouter.allowsRedirect(from: origin, to: URL(string: "http://proxy.example.net/other")!))
        XCTAssertFalse(PrivacyProxyMediaRouter.allowsRedirect(from: origin, to: URL(string: "https://proxy.example.net:8080/other")!))
    }

    func testNotificationUsesOnlyMatchingShortLivedProxyMapping() throws {
        let suite = "PrivacyProxyMediaRouterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PrivacyProxyPushRouting(defaults: defaults)
        let now = Date()

        store.publish(endpoint: endpoint, trustedHosts: ["gallery.example.net"], owner: owner)
        store.remember(source: external, resolved: resolved, endpoint: endpoint, owner: owner, now: now)
        XCTAssertEqual(store.route(external, owner: owner, now: now), resolved)
        XCTAssertNil(store.route(external, owner: "bob@example.com", now: now))
        XCTAssertNil(store.route(external, owner: owner, now: now.addingTimeInterval(601)))
        XCTAssertNil(store.route(external, owner: owner, requiresPremium: true, now: now))
        store.publishPremiumExpiration(now.addingTimeInterval(20), owner: owner)
        XCTAssertEqual(store.route(external, owner: owner, requiresPremium: true, now: now), resolved)
        XCTAssertNil(store.route(external, owner: owner, requiresPremium: true, now: now.addingTimeInterval(21)))
        store.publish(endpoint: URL(string: "https://new-proxy.example.net/")!, trustedHosts: [], owner: owner)
        XCTAssertNil(store.route(external, owner: owner, now: now))
    }

    private func makeRouter(
        policy: CommonConfigManager.PrivacyProxyPolicy,
        enabled: Bool,
        premium: Bool = false,
        advertised: Bool = true,
        resolve: @escaping (URL, String) async throws -> URL
    ) -> PrivacyProxyMediaRouter {
        PrivacyProxyMediaRouter(context: { _ in
            .init(
                policy: policy,
                localEnabled: enabled,
                premium: premium,
                endpoint: advertised ? self.endpoint : nil,
                trustedHosts: ["gallery.example.net"]
            )
        }, resolveExternal: resolve)
    }
}
