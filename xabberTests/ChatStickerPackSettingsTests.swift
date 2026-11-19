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

    func testSelectingBothBasicPacksInstallsThemForCurrentAccount() async throws {
        let key = "ChatStickerPackSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in Self.manifest(for: url) }
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
    }

    private static func manifest(for url: URL) -> Data {
        Data("""
        <sticker-pack name="\(url.deletingLastPathComponent().lastPathComponent)">
          <stickers><sticker name="Example"><file id="1"><name>sticker.webp</name></file></sticker></stickers>
        </sticker-pack>
        """.utf8)
    }
}
