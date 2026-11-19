import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatStickerPickerTests: XCTestCase {
    private let manifestURL = URL(string: "https://stickers.example.com/owls/pack.xml")!
    private let owner = "first@example.com"

    func testInlinePickerUsesSystemGlassForItsToolbarAndGrid() throws {
        let panel = ChatStickerPickerViewController(
            owner: owner, canSchedule: { false }, onSend: { _ in }, onSchedule: { _ in }
        )
        panel.loadViewIfNeeded()
        panel.updatePanelSurface(reduceTransparency: false)

        let surface = try XCTUnwrap(panel.view.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(surface.effect is UIGlassEffect)
        } else {
            XCTAssertTrue(surface.effect is UIBlurEffect)
        }
        XCTAssertEqual(panel.view.backgroundColor, UIColor.clear)
        XCTAssertEqual(surface.backgroundColor, UIColor.clear)
        XCTAssertNotNil(viewWithIdentifier("chat.stickers.keyboard", in: surface.contentView))
        XCTAssertNotNil(viewWithIdentifier("chat.stickers.picker", in: surface.contentView))
    }

    func testInlinePickerBecomesOpaqueWhenTransparencyIsReduced() throws {
        let panel = ChatStickerPickerViewController(
            owner: owner, canSchedule: { false }, onSend: { _ in }, onSchedule: { _ in }
        )
        panel.loadViewIfNeeded()

        panel.updatePanelSurface(reduceTransparency: true)

        let surface = try XCTUnwrap(panel.view.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        XCTAssertEqual(surface.backgroundColor, UIColor.secondarySystemBackground)
        XCTAssertEqual(surface.contentView.backgroundColor, UIColor.secondarySystemBackground)

        panel.updatePanelSurface(reduceTransparency: false)

        XCTAssertNotNil(surface.effect)
        XCTAssertEqual(surface.backgroundColor, UIColor.clear)
        XCTAssertEqual(surface.contentView.backgroundColor, UIColor.clear)
    }

    func testManifestPreservesEmojiMetadataAndEscapesFilenames() throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 2).utf8), url: manifestURL)
        let entry = try XCTUnwrap(pack.stickers.first)

        XCTAssertEqual(pack.manifestURL, manifestURL)
        XCTAssertEqual(pack.version, 2)
        XCTAssertEqual(pack.coverURL?.absoluteString, "https://stickers.example.com/owls/cover.webp")
        XCTAssertEqual(entry.imageURL.absoluteString, "https://stickers.example.com/owls/Daffodil%20%23%201.webp")
        XCTAssertEqual(entry.name, "Daffodil")
        XCTAssertEqual(entry.emojis, ["🦉", "💐"])
        XCTAssertEqual(entry.width, 512)
        XCTAssertEqual(entry.descriptor(preferredEmoji: "💐").emoji, "💐")
    }

    func testStickerGridExtendsToPanelBottomWithSafeAreaAsScrollInset() throws {
        let panel = ChatStickerPickerViewController(
            owner: owner, canSchedule: { false }, onSend: { _ in }, onSchedule: { _ in }
        )
        panel.additionalSafeAreaInsets.bottom = 34
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 344))
        window.rootViewController = panel
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        panel.view.layoutIfNeeded()
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let bottomSafeArea = panel.view.safeAreaInsets.bottom

        XCTAssertGreaterThan(bottomSafeArea, 0)
        XCTAssertEqual(grid.convert(grid.bounds, to: panel.view).maxY, panel.view.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(grid.adjustedContentInset.bottom, bottomSafeArea)
        XCTAssertEqual(grid.verticalScrollIndicatorInsets.bottom, bottomSafeArea)
    }

    func testStickerGridShowsLargerTilesOnPhoneAndFitsMoreTilesOnTablet() throws {
        let panel = ChatStickerPickerViewController(
            owner: owner, canSchedule: { false }, onSend: { _ in }, onSchedule: { _ in }
        )
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let layout = try XCTUnwrap(grid.collectionViewLayout as? UICollectionViewFlowLayout)

        func visibleColumns(at width: CGFloat) -> Int {
            grid.bounds.size.width = width
            let tile = panel.collectionView(grid, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0))
            XCTAssertGreaterThan(tile.width, 100)
            let available = width - layout.sectionInset.left - layout.sectionInset.right
            return Int((available + layout.minimumInteritemSpacing) / (tile.width + layout.minimumInteritemSpacing))
        }

        XCTAssertEqual(visibleColumns(at: 390), 3)
        XCTAssertGreaterThan(visibleColumns(at: 768), 3)
    }

    func testManifestRejectsExternalEntitiesAndUnsafeMediaURLs() {
        let externalEntity = """
        <!DOCTYPE sticker-pack [<!ENTITY content SYSTEM 'file:///private/stickers'>]>
        <sticker-pack name="Unsafe"><stickers><sticker name="&content;"/></stickers></sticker-pack>
        """
        let unsafeURL = xml(version: 1, fileURL: "file:///private/secrets.webp")

        XCTAssertThrowsError(try ChatStickerPackManifest.parse(Data(externalEntity.utf8), url: manifestURL))
        XCTAssertThrowsError(try ChatStickerPackManifest.parse(Data(unsafeURL.utf8), url: manifestURL))
        XCTAssertNil(ChatStickerPackManifest.manifestURL("https://user:pass@stickers.example.com/pack.xml"))
    }

    func testInstallPersistsPerOwnerAndRefreshCannotDowngrade() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        var version = 3
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Data(self.xml(version: version).utf8) }

        try await catalogue.install(manifestURL, owner: owner)
        version = 2
        try await catalogue.install(manifestURL, owner: owner)

        let restored = ChatStickerCatalogue(defaults: defaults) { _, _ in throw ChatStickerPackManifest.Failure.invalidManifest }
        XCTAssertEqual(restored.installed(for: owner).map(\.version), [3])
        XCTAssertTrue(restored.installed(for: "second@example.com").isEmpty)
        try restored.remove(manifestURL, owner: owner)
        XCTAssertTrue(catalogue.installed(for: owner).isEmpty)
    }

    func testSuggestionsMatchALoneEmojiAndKeepAlternatives() throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 1, secondSticker: true).utf8), url: manifestURL)

        XCTAssertEqual(ChatStickerSuggestion.matches(text: " 🦉 ", packs: [pack]).map(\.name), ["Daffodil", "Owl"])
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "Hello 🦉", packs: [pack]).isEmpty)
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "🦉🦉", packs: [pack]).isEmpty)
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "x", packs: [pack]).isEmpty)
    }

    func testStickerThumbnailResumesCancelledRequestAndRetainsRenderedImage() async throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 1).utf8), url: manifestURL)
        let sticker = try XCTUnwrap(pack.stickers.first)
        let pipeline = PickerThumbnailPipeline()
        let view = ChatStickerThumbnailView(thumbnails: pipeline)
        let imageSize = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: imageSize).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }
        view.load(sticker, owner: owner, size: 72)
        let original = pipeline.request

        view.pauseThumbnailLoad()
        pipeline.complete(image)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(view.inlineThumbnail(for: sticker), "A cancelled request must not change the binding")

        view.resumeThumbnailLoad()
        view.resumeThumbnailLoad()
        XCTAssertEqual(pipeline.acquisitionCount, 2)
        XCTAssertEqual(pipeline.request, original)
        pipeline.complete(image)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        view.pauseThumbnailLoad()
        view.resumeThumbnailLoad()
        XCTAssertNotNil(view.inlineThumbnail(for: sticker))
        XCTAssertEqual(pipeline.acquisitionCount, 2)
    }

    func testInstalledStickerThumbnailReplacesEmojiUsingStickerRoute() async throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 1).utf8), url: manifestURL)
        let entry = try XCTUnwrap(pack.stickers.first)
        let pipeline = PickerThumbnailPipeline()
        let view = ChatStickerThumbnailView(thumbnails: pipeline)

        view.load(entry, owner: owner, size: 72)

        let request = try XCTUnwrap(pipeline.request)
        XCTAssertEqual(request.url, entry.imageURL)
        XCTAssertEqual(request.owner, owner)
        XCTAssertTrue(request.isSticker)
        XCTAssertNil(view.inlineThumbnail(for: entry))
        let placeholder = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(placeholder.text, "🦉")
        XCTAssertFalse(placeholder.isHidden)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        pipeline.complete(image)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertTrue(placeholder.isHidden)
        XCTAssertNotNil(view.inlineThumbnail(for: entry))
    }

    func testStickerThumbnailCacheIsSeparateFromPhotosAndOtherAccounts() throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 1).utf8), url: manifestURL)
        let imageURL = try XCTUnwrap(pack.stickers.first?.imageURL)
        let size = ChatCollectionPrefetchSize(width: 72, height: 72)
        let photo = ChatThumbnailRequest(url: imageURL, displaySize: size, scale: 2, owner: owner)
        let sticker = ChatThumbnailRequest(url: imageURL, displaySize: size, scale: 2, owner: owner,
                                           isSticker: true)
        let secondAccount = ChatThumbnailRequest(url: imageURL, displaySize: size, scale: 2,
                                                 owner: "second@example.com", isSticker: true)

        XCTAssertNotEqual(sticker.cacheKey, photo.cacheKey)
        XCTAssertNotEqual(sticker.cacheKey, secondAccount.cacheKey)
    }

    func testUninstallFencesAPendingInstallResponse() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let started = expectation(description: "Manifest request started")
        var receipt: CheckedContinuation<Data, Error>?
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in
            try await withCheckedThrowingContinuation {
                receipt = $0
                started.fulfill()
            }
        }
        let install = Task { try await catalogue.install(manifestURL, owner: owner) }
        await fulfillment(of: [started], timeout: 2)
        try catalogue.remove(manifestURL, owner: owner)
        try XCTUnwrap(receipt).resume(returning: Data(xml(version: 2).utf8))

        if case .success = await install.result {
            XCTFail("A late manifest response restored a removed pack")
        }
        XCTAssertTrue(catalogue.installed(for: owner).isEmpty)
    }

    func testInlinePickerSendsOncePerTapAndKeepsItsPackSelected() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Data(self.xml(version: 1).utf8) }
        try await catalogue.install(manifestURL, owner: owner)
        var sent: [ChatStickerDescriptor] = []
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { true },
                                                    onSend: { sent.append($0) }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)

        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 0))
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 0))

        XCTAssertEqual(sent.map(\.name), ["Daffodil", "Daffodil"])
        XCTAssertFalse(grid.isHidden)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1)
    }

    func testRemovingSelectedPackFallsBackToRemainingInstalledPack() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let otherURL = manifestURL.deletingLastPathComponent().appendingPathComponent("another.xml")
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in
            Data(self.xml(version: 1, secondSticker: url == otherURL).utf8)
        }
        try await catalogue.install(manifestURL, owner: owner)
        try await catalogue.install(otherURL, owner: owner)
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { false },
                                                    onSend: { _ in }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1)

        try catalogue.remove(manifestURL, owner: owner)

        XCTAssertFalse(grid.isHidden)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 2)
    }

    func testInlinePickerKeepsAllPacksInTheGridAndRibbonScrollsToASection() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let otherURL = manifestURL.deletingLastPathComponent().appendingPathComponent("another.xml")
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in
            Data(self.xml(version: 1, secondSticker: url == otherURL).utf8)
        }
        try await catalogue.install(manifestURL, owner: owner)
        try await catalogue.install(otherURL, owner: owner)
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { false },
                                                    onSend: { _ in }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let ribbon = try XCTUnwrap(viewWithIdentifier("chat.stickers.packs", in: panel.view) as? UICollectionView)
        panel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 176)
        panel.view.layoutIfNeeded()

        XCTAssertEqual(panel.numberOfSections(in: grid), 2)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 1), 2)
        XCTAssertEqual(ribbon.numberOfItems(inSection: 0), 2)

        panel.collectionView(ribbon, didSelectItemAt: IndexPath(item: 1, section: 0))

        XCTAssertGreaterThan(grid.contentOffset.y, 0)
        XCTAssertEqual(panel.numberOfSections(in: grid), 2)
    }

    func testStickerCellBelowRecentsKeepsItsPlaceholderWhenRedisplayed() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in
            Data(self.xml(version: 1, secondSticker: true).utf8)
        }
        let pack = try await catalogue.install(manifestURL, owner: owner)
        let recent = try XCTUnwrap(pack.stickers.first)
        catalogue.recordStickerUse(recent.descriptor(), owner: owner)
        let panel = ChatStickerPickerViewController(
            owner: owner, catalogue: catalogue, canSchedule: { false }, onSend: { _ in }, onSchedule: { _ in }
        )
        panel.setKeyboardHostBottomInset(34)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 344))
        window.rootViewController = panel
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        panel.view.layoutIfNeeded()
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let path = IndexPath(item: 0, section: 1)
        let cell = try XCTUnwrap(grid.cellForItem(at: path))
        let thumbnail = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? ChatStickerThumbnailView }.first)
        let placeholder = try XCTUnwrap(thumbnail.subviews.compactMap { $0 as? UILabel }.first)
        let emoji = try XCTUnwrap(recent.emojis.first)
        XCTAssertEqual(placeholder.text, emoji)

        grid.delegate?.collectionView?(grid, didEndDisplaying: cell, forItemAt: path)
        grid.delegate?.collectionView?(grid, willDisplay: cell, forItemAt: path)

        XCTAssertEqual(placeholder.text, emoji)
        XCTAssertFalse(placeholder.isHidden)
    }

    func testAddingARecentSectionPreservesTheVisiblePackPosition() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let otherURL = manifestURL.deletingLastPathComponent().appendingPathComponent("other/pack.xml")
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Data(self.xml(version: 1).utf8) }
        let first = try await catalogue.install(manifestURL, owner: owner)
        try await catalogue.install(otherURL, owner: owner)
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { false },
                                                    onSend: { _ in }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let ribbon = try XCTUnwrap(viewWithIdentifier("chat.stickers.packs", in: panel.view) as? UICollectionView)
        panel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 176)
        panel.view.layoutIfNeeded()
        panel.collectionView(ribbon, didSelectItemAt: IndexPath(item: 1, section: 0))

        func headerY(in section: Int) throws -> CGFloat {
            try XCTUnwrap(grid.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
            )).frame.minY
        }

        let offsetInPack = grid.contentOffset.y - (try headerY(in: 1))
        let sticker = try XCTUnwrap(first.stickers.first)

        catalogue.recordStickerUse(sticker.descriptor(), owner: owner)

        XCTAssertEqual(panel.numberOfSections(in: grid), 3)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1)
        XCTAssertEqual(grid.contentOffset.y - (try headerY(in: 2)), offsetInPack, accuracy: 0.5)

        panel.collectionView(ribbon, didSelectItemAt: IndexPath(item: 0, section: 0))

        XCTAssertEqual(grid.contentOffset.y, 0, accuracy: 0.5)
    }

    func testRecentlyUsedDisappearsFromGridAndRibbonAfterRemovingItsLastSticker() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let otherURL = manifestURL.deletingLastPathComponent().appendingPathComponent("other/pack.xml")
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in
            Data(self.xml(version: 1, secondSticker: url == otherURL).utf8)
        }
        let first = try await catalogue.install(manifestURL, owner: owner)
        try await catalogue.install(otherURL, owner: owner)
        let sticker = try XCTUnwrap(first.stickers.first)
        catalogue.recordStickerUse(sticker.descriptor(), owner: owner)
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { false },
                                                    onSend: { _ in }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let ribbon = try XCTUnwrap(viewWithIdentifier("chat.stickers.packs", in: panel.view) as? UICollectionView)

        XCTAssertEqual(grid.numberOfSections, 3)
        XCTAssertEqual(ribbon.numberOfItems(inSection: 0), 3)

        try catalogue.remove(manifestURL, owner: owner)

        XCTAssertFalse(grid.isHidden)
        XCTAssertEqual(grid.numberOfSections, 1)
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(ribbon.numberOfItems(inSection: 0), 1)
    }

    func testInlinePickerScheduleMenuDoesNotTriggerImmediateSend() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Data(self.xml(version: 1).utf8) }
        try await catalogue.install(manifestURL, owner: owner)
        var canSchedule = true
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { canSchedule },
                onSend: { _ in XCTFail("Opening the menu sent a sticker") },
                onSchedule: { _ in XCTFail("Opening the menu scheduled a sticker") })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let item = IndexPath(item: 0, section: 0)

        XCTAssertNotNil(panel.collectionView(grid, contextMenuConfigurationForItemAt: item, point: .zero))

        canSchedule = false
        XCTAssertNil(panel.collectionView(grid, contextMenuConfigurationForItemAt: item, point: .zero))
    }

    func testInlineStarterInstallOffersRetryAndOpensInstalledPack() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let starters = ChatStickerStarterPack.all
        XCTAssertEqual(starters.map(\.id), ["owls", "monsters"])
        let starter = try XCTUnwrap(starters.first)
        let other = try XCTUnwrap(starters.last)
        var attempts: [URL] = []
        let catalogue = ChatStickerCatalogue(defaults: defaults) { url, _ in
            attempts.append(url)
            guard attempts.count > 1 else { throw ChatStickerPackManifest.Failure.unavailable }
            return Data(self.xml(version: 1).utf8)
        }
        var lastSent: ChatStickerDescriptor?
        let panel = ChatStickerPickerViewController(owner: owner, catalogue: catalogue, canSchedule: { false },
                                                    onSend: { lastSent = $0 }, onSchedule: { _ in })
        let grid = try XCTUnwrap(viewWithIdentifier("chat.stickers.picker", in: panel.view) as? UICollectionView)
        let buttonID = "chat.stickers.install.\(starter.id)"
        let add = try XCTUnwrap(viewWithIdentifier(buttonID, in: panel.view) as? UIButton)
        let addTitle = add.configuration?.title
        XCTAssertTrue(grid.isHidden)

        add.sendActions(for: .touchUpInside)
        try await waitFor { add.isEnabled && add.configuration?.title != addTitle }
        XCTAssertTrue(catalogue.installed(for: owner).isEmpty)
        add.sendActions(for: .touchUpInside)
        try await waitFor { !grid.isHidden }

        let openStarters = try XCTUnwrap(viewWithIdentifier("chat.stickers.add_packs", in: panel.view) as? UIButton)
        openStarters.sendActions(for: .touchUpInside)
        XCTAssertTrue(grid.isHidden)
        let installOther = try XCTUnwrap(viewWithIdentifier("chat.stickers.install.\(other.id)", in: panel.view) as? UIButton)
        installOther.sendActions(for: .touchUpInside)
        try await waitFor { !grid.isHidden }
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 1))

        XCTAssertEqual(attempts, [starter.manifestURL, starter.manifestURL, other.manifestURL])
        XCTAssertEqual(catalogue.installed(for: owner).map(\.manifestURL), starters.map(\.manifestURL))
        XCTAssertEqual(lastSent?.packURL, other.manifestURL)
    }

    func testComposerStickerActionHasSeparateDelegateRouteAndKeepsDraft() {
        let delegate = StickerComposerDelegate()
        let view = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        view.delegate = delegate
        view.stickerOwner = owner
        view.setComposerText("Unrelated draft")

        view.stickerButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.opened, 1)
        XCTAssertEqual(view.textField.text, "Unrelated draft")
        view.changeState(to: .selection)
        XCTAssertTrue(view.stickerButton.isHidden)
        view.stickerButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.opened, 1)

        view.changeState(to: .normal)
        view.showSelectionPanel()
        XCTAssertTrue(view.stickerButton.isHidden)
        view.hideSelectionPanel()
        XCTAssertFalse(view.stickerButton.isHidden)
    }

    private func xml(version: Int, fileURL: String = "", secondSticker: Bool = false) -> String {
        """
        <sticker-pack name="Owls" version="\(version)">
          <cover><file><name>cover.webp</name></file></cover>
          <stickers>
            <sticker name="Daffodil"><file id="01"><name>Daffodil # 1.webp</name><url>\(fileURL)</url><media-type>image/webp</media-type><width>512</width><height>400</height></file><emojis><emoji>🦉</emoji><emoji>💐</emoji></emojis></sticker>
            \(secondSticker ? "<sticker name='Owl'><file id='02'><name>owl.webp</name></file><emojis><emoji>🦉</emoji></emojis></sticker>" : "")
          </stickers>
        </sticker-pack>
        """
    }

    private func viewWithIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let result = viewWithIdentifier(identifier, in: child) { return result }
        }
        return nil
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for the sticker panel to update", file: file, line: line)
    }

    private final class PickerThumbnailPipeline: ChatThumbnailServing {
        private(set) var request: ChatThumbnailRequest?
        private(set) var acquisitionCount = 0
        private var completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?

        func acquire(
            _ request: ChatThumbnailRequest,
            consumer: ChatThumbnailConsumer,
            completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
        ) -> ChatThumbnailSubscription {
            acquisitionCount += 1
            self.request = request
            self.completion = completion
            return Subscription()
        }

        func complete(_ image: UIImage) {
            completion?(.success(ChatThumbnailDelivery(image: image,
                pixelSize: ChatCollectionPrefetchSize(width: 8, height: 8), source: .loader)))
        }

        private final class Subscription: ChatThumbnailSubscription {
            func cancel() {}
        }
    }

    private final class StickerComposerDelegate: XabberInputBarDelegate {
        private(set) var opened = 0
        func stickerPickerButtonTouchUp() { opened += 1 }
        func sendButtonTouchUp(with text: String) {}
        func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload) {}
        func scheduledMessagesButtonTouchUp() {}
        func attachmentButtonTouchUp() {}
        func onAfterburnButtonTouchUp() {}
        func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {}
        func onCheckDevices() {}
        func onCheckContactDevices() {}
        func onUpdateSignature() {}
        func onIdentityVerification() {}
        func onTextDidChange(to text: String?) {}
        func onAudioMessageStartRecord(sessionID: UUID) {}
        func onAudioMessageDidCancel(sessionID: UUID) {}
        func onAudioMessageDidFinish(sessionID: UUID, intent: VoiceRecordingFinishIntent) {}
        func onAudioMessagePreviewSend(sessionID: UUID) {}
        func onAudioMessagePreviewDelete(sessionID: UUID) {}
        func recordAndPlayPanelPlayButtonTouchUp(sessionID: UUID) {}
        func didStopPlayingAudio() {}
        func didSetAudioPositionBar(percentage: Float) -> TimeInterval { 0 }
    }
}
