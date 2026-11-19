import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatStickerPackSettingsTests: XCTestCase {
    private let owner = "first@example.com"
    private let otherOwner = "second@example.com"

    func testBuiltInPacksUseTheExistingManifestsAndCovers() throws {
        let packs = ChatStickerStarterPack.all

        XCTAssertEqual(packs.map(\.id), ["owls", "monsters"])
        for pack in packs {
            let directory = try XCTUnwrap(pack.previewURL).deletingLastPathComponent()
            XCTAssertEqual(pack.manifestURL, directory.appendingPathComponent("pack.xml"))
            XCTAssertEqual(pack.previewURL?.lastPathComponent, "cover.webp")
            XCTAssertEqual(pack.manifestURL.host, "cdn.jsdelivr.net")
            XCTAssertTrue(pack.manifestURL.path.contains("xabber-stickers@adf96ab/\(pack.id)/"))
        }
    }

    func testSettingsShowOnlyCurrentAccountsPacksAndRefreshAfterRemoval() async throws {
        let key = "ChatStickerPackSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in Self.manifest(for: url) }
        let packs = ChatStickerStarterPack.all
        try await catalogue.install(packs[0].manifestURL, owner: owner)
        try await catalogue.install(packs[1].manifestURL, owner: otherOwner)
        let settings = ChatStickerPackSettingsViewController(owner: owner, catalogue: catalogue)
        settings.loadViewIfNeeded()
        let installedSection = 0
        let row = settings.tableView(
            settings.tableView, cellForRowAt: IndexPath(row: 0, section: installedSection)
        )

        XCTAssertEqual(settings.tableView(settings.tableView, numberOfRowsInSection: installedSection), 1)
        XCTAssertEqual((row.contentConfiguration as? UIListContentConfiguration)?.text, packs[0].name)

        try catalogue.remove(packs[0].manifestURL, owner: owner)

        XCTAssertEqual(settings.tableView(settings.tableView, numberOfRowsInSection: installedSection), 0)
        XCTAssertEqual(catalogue.installed(for: otherOwner).map(\.manifestURL), [packs[1].manifestURL])
    }

    func testInstallingAndRefreshingAWrittenPackStartsImageCacheWarmup() async throws {
        let suite = "ChatStickerWarmupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preloader = StickerPackImagePreloaderSpy()
        var version = 2
        let catalogue = ChatStickerCatalogue(defaults: defaults, imagePreloader: preloader) { _, _ in
            Self.usageManifest(["First", "Second"], version: version)
        }
        let url = ChatStickerStarterPack.all[0].manifestURL
        let profile = ChatStickerImageProfile(scale: 3, traitStyle: .dark)

        let installed = try await catalogue.install(url, owner: owner, imageProfile: profile)
        version = 1
        try await catalogue.install(url, owner: owner, imageProfile: profile)

        XCTAssertEqual(catalogue.installed(for: owner), [installed])
        XCTAssertEqual(preloader.requests.map { $0.pack }, [installed, installed])
        XCTAssertEqual(preloader.requests.map { $0.owner }, [owner, owner])
        XCTAssertEqual(preloader.requests.map { $0.profile }, [profile, profile])
    }

    func testInvalidPackStartsNoImageWarmupAndRemovalCancelsActiveWork() async throws {
        let suite = "ChatStickerWarmupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preloader = StickerPackImagePreloaderSpy()
        let url = ChatStickerStarterPack.all[0].manifestURL
        let invalidURL = ChatStickerStarterPack.all[1].manifestURL
        let catalogue = ChatStickerCatalogue(defaults: defaults, imagePreloader: preloader) { url, _ in
            url == invalidURL ? Data("unavailable".utf8) : Self.usageManifest(["First"])
        }
        let profile = ChatStickerImageProfile(scale: 2, traitStyle: .light)

        do {
            try await catalogue.install(invalidURL, owner: owner, imageProfile: profile)
            XCTFail("An invalid manifest was accepted")
        } catch {
            XCTAssertTrue(preloader.requests.isEmpty)
        }

        try await catalogue.install(url, owner: owner, imageProfile: profile)
        try catalogue.remove(url, owner: owner)
        catalogue.removeAccount(owner)

        XCTAssertEqual(preloader.cancelledPacks.map { $0.url }, [url])
        XCTAssertEqual(preloader.cancelledPacks.map { $0.owner }, [owner])
        XCTAssertEqual(preloader.cancelledOwners, [owner])
    }

    func testSelectingBothBasicPacksInstallsThemForCurrentAccount() async throws {
        let key = "ChatStickerPackSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let preloader = StickerPackImagePreloaderSpy()
        let catalogue = ChatStickerCatalogue(defaults: defaults, imagePreloader: preloader) { url, _ in
            Self.manifest(for: url)
        }
        let settings = ChatStickerPackSettingsViewController(owner: owner, catalogue: catalogue)
        settings.loadViewIfNeeded()
        let packs = ChatStickerStarterPack.all
        let installed = expectation(description: "Both packs were installed")
        installed.expectedFulfillmentCount = packs.count
        let observer = NotificationCenter.default.addObserver(
            forName: ChatStickerCatalogue.changed, object: nil, queue: .main
        ) { [owner] note in
            if note.object as? String == owner { installed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for index in packs.indices {
            settings.tableView(settings.tableView, didSelectRowAt: IndexPath(row: index, section: 1))
        }
        await fulfillment(of: [installed], timeout: 3)

        XCTAssertEqual(Set(catalogue.installed(for: owner).map(\.manifestURL)), Set(packs.map(\.manifestURL)))
        XCTAssertEqual(settings.tableView(settings.tableView, numberOfRowsInSection: 0), packs.count)
        XCTAssertTrue(catalogue.installed(for: otherOwner).isEmpty)
        XCTAssertEqual(Set(preloader.requests.map { $0.pack.manifestURL }), Set(packs.map(\.manifestURL)))
        XCTAssertTrue(preloader.requests.allSatisfy { $0.owner == owner })
    }

    func testRecentStickersSortByLastUseAcrossCatalogueReload() async throws {
        let suite = "ChatStickerUsageTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in
            Self.usageManifest(["First", "Second", "Third", "Fourth"])
        }
        let url = ChatStickerStarterPack.all[0].manifestURL
        let pack = try await catalogue.install(url, owner: owner)
        XCTAssertTrue(catalogue.recentStickers(for: owner).isEmpty)

        for index in [0, 1, 0, 2, 1, 3] {
            catalogue.recordStickerUse(pack.stickers[index].descriptor(), owner: owner)
        }

        let reloaded = ChatStickerCatalogue(defaults: defaults)
        XCTAssertEqual(reloaded.recentStickers(for: owner).map(\.name), ["Fourth", "Second", "Third", "First"])
    }

    func testRecentStickerUsageIsAccountScopedAndClearedOnAccountRemoval() async throws {
        let suite = "ChatStickerUsageTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Self.usageManifest(["First", "Second"]) }
        let url = ChatStickerStarterPack.all[0].manifestURL
        let pack = try await catalogue.install(url, owner: owner)
        catalogue.recordStickerUse(pack.stickers[0].descriptor(), owner: owner)
        catalogue.recordStickerUse(pack.stickers[0].descriptor(), owner: otherOwner)
        try await catalogue.install(url, owner: otherOwner)
        XCTAssertTrue(catalogue.recentStickers(for: otherOwner).isEmpty)
        catalogue.recordStickerUse(pack.stickers[1].descriptor(), owner: otherOwner)

        catalogue.removeAccount(owner)
        try await catalogue.install(url, owner: owner)

        XCTAssertTrue(catalogue.recentStickers(for: owner).isEmpty)
        XCTAssertEqual(catalogue.recentStickers(for: otherOwner).map(\.name), ["Second"])
    }

    func testRecentStickersUseUpdatedMetadataAndDropUninstalledImages() async throws {
        let suite = "ChatStickerUsageTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var manifest = Self.usageManifest(["First", "Second"])
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in manifest }
        let url = ChatStickerStarterPack.all[0].manifestURL
        let pack = try await catalogue.install(url, owner: owner)
        pack.stickers.forEach { catalogue.recordStickerUse($0.descriptor(), owner: owner) }

        manifest = Self.usageManifest(["Second"], version: 2, labelPrefix: "Updated ")
        try await catalogue.install(url, owner: owner)

        XCTAssertEqual(catalogue.recentStickers(for: owner).map(\.name), ["Updated Second"])
        try catalogue.remove(url, owner: owner)
        try await catalogue.install(url, owner: owner)
        XCTAssertTrue(catalogue.recentStickers(for: owner).isEmpty)
    }

    func testRecentStickersShowsOnlySixAndMovesAResentStickerToTheFront() async throws {
        let suite = "ChatStickerUsageTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = (0..<8).map { "Sticker\($0)" }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Self.usageManifest(names) }
        let pack = try await catalogue.install(ChatStickerStarterPack.all[0].manifestURL, owner: owner)

        pack.stickers.forEach { catalogue.recordStickerUse($0.descriptor(), owner: owner) }

        XCTAssertEqual(catalogue.recentStickers(for: owner).map(\.name), Array(names.suffix(6).reversed()))

        catalogue.recordStickerUse(pack.stickers[0].descriptor(), owner: owner)
        catalogue.recordStickerUse(pack.stickers[0].descriptor(), owner: owner)

        XCTAssertEqual(
            catalogue.recentStickers(for: owner).map(\.name),
            [names[0]] + Array(names.suffix(5).reversed())
        )
    }

    private static func usageManifest(_ names: [String], version: Int = 1, labelPrefix: String = "") -> Data {
        let stickers = names.map { name in
            "<sticker name=\"\(labelPrefix)\(name)\"><file id=\"\(name)\"><name>\(name).webp</name></file></sticker>"
        }.joined()
        return Data("<sticker-pack name=\"Usage\" version=\"\(version)\"><stickers>\(stickers)</stickers></sticker-pack>".utf8)
    }

    private static func manifest(for url: URL) -> Data {
        Data("""
        <sticker-pack name="\(url.deletingLastPathComponent().lastPathComponent)">
          <stickers><sticker name="Example"><file id="1"><name>sticker.webp</name></file></sticker></stickers>
        </sticker-pack>
        """.utf8)
    }
}

@MainActor
private final class StickerPackImagePreloaderSpy: ChatStickerPackImagePreloading {
    private(set) var requests: [(pack: ChatStickerPack, owner: String, profile: ChatStickerImageProfile)] = []
    private(set) var cancelledPacks: [(url: URL, owner: String)] = []
    private(set) var cancelledOwners: [String] = []

    func preload(_ pack: ChatStickerPack, owner: String, profile: ChatStickerImageProfile) {
        requests.append((pack, owner, profile))
    }

    func cancel(manifestURL: URL, owner: String) {
        cancelledPacks.append((manifestURL, owner))
    }

    func cancel(owner: String) {
        cancelledOwners.append(owner)
    }
}
