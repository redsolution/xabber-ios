import AVFoundation
import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatAttachmentCaptionInputTests: XCTestCase {
    func testPreviewShowsCaptionInputAndStartsEmpty() {
        let preview = makePreview(drafts: [makeTask13AssetDraft(localIdentifier: "asset-1")])

        preview.loadViewIfNeeded()

        XCTAssertNotNil(preview.captionInputView.superview)
        XCTAssertEqual(preview.captionInputView.text, "")
        XCTAssertEqual(preview.captionInputView.placeholderLabel.text, "Message")
    }

    func testCaptionInputUsesChatInputTextViewAndComposerPlaceholder() {
        let captionInputView = ChatAttachmentCaptionInputView()

        XCTAssertTrue(captionInputView.textView is InputTextView)
        XCTAssertEqual(captionInputView.textView.textContainerInset, UIEdgeInsets(top: 7, left: 4, bottom: 9, right: 8))
        XCTAssertEqual(captionInputView.textView.placeholder, "Message")
        XCTAssertEqual(captionInputView.placeholderLabel.text, "Message")
        XCTAssertEqual(captionInputView.placeholderLabel.textColor, .secondaryLabel)
    }

    func testCaptionInputHostsTextAndPlaceholderAboveRoundedGlassSurface() {
        let captionInputView = ChatAttachmentCaptionInputView()

        captionInputView.layoutIfNeeded()

        XCTAssertEqual(captionInputView.backgroundColor ?? .clear, .clear)
        XCTAssertFalse(captionInputView.isOpaque)
        XCTAssertTrue(captionInputView.backgroundEffectView.superview === captionInputView)
        XCTAssertTrue(captionInputView.subviews.first === captionInputView.backgroundEffectView)
        XCTAssertTrue(captionInputView.backgroundEffectView.isUserInteractionEnabled)
        XCTAssertEqual(captionInputView.backgroundEffectView.layer.cornerRadius, NativeGlassBarStyle.cornerRadius, accuracy: 0.001)
        XCTAssertTrue(captionInputView.textView.superview === captionInputView.backgroundEffectView.contentView)
        XCTAssertTrue(captionInputView.placeholderLabel.superview === captionInputView.textView)
    }

    func testCaptionInputMatchesChatComposerHeightBehavior() {
        let captionInputView = ChatAttachmentCaptionInputView()
        captionInputView.frame = CGRect(x: 0, y: 0, width: 320, height: NativeGlassBarStyle.minimumHeight)

        captionInputView.layoutIfNeeded()

        let heightConstraint = captionInputView.constraints.first { $0.firstAttribute == .height }
        XCTAssertNotNil(heightConstraint)
        XCTAssertEqual(
            heightConstraint?.constant ?? 0,
            NativeGlassBarStyle.minimumHeight,
            accuracy: 0.001
        )
        XCTAssertFalse(captionInputView.textView.isScrollEnabled)

        captionInputView.textView.text = Array(repeating: "Long caption line", count: 40).joined(separator: "\n")
        captionInputView.textViewDidChange(captionInputView.textView)

        XCTAssertEqual(
            heightConstraint?.constant ?? 0,
            138,
            accuracy: 0.001
        )
        XCTAssertTrue(captionInputView.textView.isScrollEnabled)
    }

    func testCaptionInputTogglesChatPlaceholderVisibilityOnTextChanges() {
        let captionInputView = ChatAttachmentCaptionInputView()

        XCTAssertFalse(captionInputView.placeholderLabel.isHidden)

        captionInputView.textView.text = "Caption"
        captionInputView.textViewDidChange(captionInputView.textView)

        XCTAssertTrue(captionInputView.placeholderLabel.isHidden)

        captionInputView.textView.text = ""
        captionInputView.textViewDidChange(captionInputView.textView)

        XCTAssertFalse(captionInputView.placeholderLabel.isHidden)
    }

    func testTypingUpdatesSheetOwnedCaptionState() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        let preview = try openPreview(from: sheet)
        preview.captionInputView.textView.text = "Trip photo"
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)

        XCTAssertEqual(sheet.captionState.rawText, "Trip photo")
        XCTAssertEqual(preview.captionInputView.text, "Trip photo")
    }

    func testCaptionIsPreservedAfterPreviewCloseReopenSourceSwitchAndPresentationChange() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        var preview = try openPreview(from: sheet)
        preview.captionInputView.textView.text = "Keep me"
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)
        preview.closeButton.sendActions(for: .touchUpInside)

        sheet.switchSource(to: .file)
        sheet.switchSource(to: .gallery)
        sheet.chatAttachmentSheetPresentationStateDidChange(.expanded)
        sheet.chatAttachmentSheetPresentationStateDidChange(.compact)
        preview = try openPreview(from: sheet)

        XCTAssertEqual(preview.captionInputView.text, "Keep me")
        XCTAssertEqual(sheet.captionState.rawText, "Keep me")
    }

    func testCaptionStaysWhenRemovingOneItemFromMultiItemBatch() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let first = makeTask13AssetDraft(localIdentifier: "asset-1")
        let second = makeTask13AssetDraft(localIdentifier: "asset-2")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([first, second])
        let preview = try openPreview(from: sheet)
        preview.captionInputView.textView.text = "Batch caption"
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)
        preview.removeCurrentDraft()

        XCTAssertEqual(sheet.captionState.rawText, "Batch caption")
        XCTAssertEqual(preview.captionInputView.text, "Batch caption")
        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [second.id])
    }

    func testRemovingLastSelectedItemDismissesPreviewAndClearsCaption() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        var dismissedCount = 0
        let sheet = makeSheet(
            source: source,
            previewDismissalHandler: { _, _, completion in
                dismissedCount += 1
                completion?()
            }
        )
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        let preview = try openPreview(from: sheet)
        preview.captionInputView.textView.text = "Remove me"
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)
        preview.removeCurrentDraft()

        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertNil(sheet.previewViewController)
        XCTAssertEqual(dismissedCount, 1)
    }

    func testWhitespaceOnlyCaptionMapsToEmptyOutgoingBody() {
        let result = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            caption: " \n\t ",
            conversationType: .regular
        )

        XCTAssertEqual(result.body, "")
        XCTAssertEqual(result.legacyBody, "")
    }

    func testNonEmptyCaptionMapsToOutgoingBodyWithoutMutatingMediaReferenceOffsets() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.begin = 0
        reference.end = 0

        let result = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            caption: "  Hello media  ",
            conversationType: .regular,
            references: [reference]
        )

        XCTAssertEqual(result.body, "  Hello media  ")
        XCTAssertEqual(result.legacyBody, "  Hello media  ")
        XCTAssertEqual(reference.begin, 0)
        XCTAssertEqual(reference.end, 0)
    }

    func testCaptionBodyPolicyIsSameForRegularGroupAndEncryptedConversations() {
        let captions = [
            ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(caption: "Hello", conversationType: .regular),
            ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(caption: "Hello", conversationType: .group),
            ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(caption: "Hello", conversationType: .omemo)
        ]

        XCTAssertEqual(captions.map(\.body), ["Hello", "Hello", "Hello"])
        XCTAssertEqual(captions.map(\.legacyBody), ["Hello", "Hello", "Hello"])
    }

    func testSheetShowsTabsAtZeroSelectedAndCaptionSendBarWhenSelected() {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()

        XCTAssertFalse(sheet.sourceBarView.isHidden)
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
        XCTAssertTrue(sheet.selectionPreviewBarView.isHidden)

        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1")])

        XCTAssertTrue(sheet.sourceBarView.isHidden)
        XCTAssertFalse(sheet.selectionComposerBarView.isHidden)
        XCTAssertTrue(sheet.selectionPreviewBarView.isHidden)
        XCTAssertEqual(sheet.selectionComposerBarView.selectedCount, 1)
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)
        XCTAssertTrue(sheet.statusBannerView.isHidden)
    }

    func testSheetBottomControlsAreAnchoredToKeyboardLayoutGuide() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()

        let bottomConstraint = try XCTUnwrap(sheet.bottomControlsBottomConstraint)
        XCTAssertTrue(bottomConstraint.firstItem === sheet.bottomControlsContainerView)
        XCTAssertEqual(bottomConstraint.firstAttribute, .bottom)
        XCTAssertTrue(bottomConstraint.secondItem === sheet.view.keyboardLayoutGuide)
        XCTAssertEqual(bottomConstraint.secondAttribute, .top)
        XCTAssertEqual(bottomConstraint.constant, 0)
    }

    func testSheetSendButtonIsIconOnlyCircularNativeGlassButton() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1")])

        let sendButton = sheet.selectionComposerBarView.sendButton
        XCTAssertNil(sendButton.title(for: .normal))
        XCTAssertNil(sendButton.configuration?.title)
        XCTAssertNotNil(sendButton.image(for: .normal) ?? sendButton.configuration?.image)
        XCTAssertEqual(sendButton.accessibilityLabel, "Send")
        XCTAssertTrue(
            sendButton.constraints.contains {
                $0.firstAttribute == .width && $0.constant == NativeGlassBarStyle.buttonSize
            }
        )
        XCTAssertTrue(
            sendButton.constraints.contains {
                $0.firstAttribute == .height && $0.constant == NativeGlassBarStyle.buttonSize
            }
        )
        XCTAssertNil(
            sheet.selectionComposerBarView
                .subviews
                .first { $0.accessibilityIdentifier == "chatAttachmentSheet.selectionComposerBar.count" }
        )
    }

    func testSheetSendButtonUsesComposerTintFromFlowContext() {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let composerTintColor = UIColor(red: 0.4, green: 0.2, blue: 0.9, alpha: 1)
        let sheet = makeSheet(source: source, composerTintColor: composerTintColor)

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1")])

        XCTAssertEqual(sheet.selectionComposerBarView.sendButton.tintColor, composerTintColor)
    }

    func testSheetSelectionComposerMatchesChatComposerLayoutWithResetButton() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1")])
        sheet.view.layoutIfNeeded()

        let composer = sheet.selectionComposerBarView
        let resetButton = try XCTUnwrap(
            firstSubview(
                in: composer,
                accessibilityIdentifier: "chatAttachmentSheet.selectionComposerBar.resetButton",
                as: UIButton.self
            )
        )
        let captionInputView = composer.captionInputView
        let sendButton = composer.sendButton

        XCTAssertTrue(resetButton.isDescendant(of: composer))
        XCTAssertTrue(captionInputView.isDescendant(of: composer))
        XCTAssertTrue(sendButton.isDescendant(of: composer))
        XCTAssertEqual(resetButton.frame.minX, NativeGlassBarStyle.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(resetButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(resetButton.frame.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(
            captionInputView.frame.minX,
            resetButton.frame.maxX + NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(
            captionInputView.frame.height,
            NativeGlassBarStyle.minimumHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sendButton.frame.minX,
            captionInputView.frame.maxX + NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertEqual(sendButton.frame.maxX, composer.bounds.maxX - NativeGlassBarStyle.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(sendButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(sendButton.frame.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertNil(resetButton.title(for: .normal))
        XCTAssertNil(resetButton.configuration?.title)
        XCTAssertNotNil(resetButton.image(for: .normal) ?? resetButton.configuration?.image)
    }

    func testSheetSelectionComposerGrowsWithMultilineCaptionAndCollapsesWhenCleared() {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1")])
        sheet.view.layoutIfNeeded()

        let composer = sheet.selectionComposerBarView
        let captionInputView = composer.captionInputView
        let collapsedBarHeight = NativeGlassBarStyle.minimumHeight
            + 8
            + NativeGlassBarStyle.bottomOffset

        XCTAssertEqual(sheet.bottomControlsContainerView.frame.height, collapsedBarHeight, accuracy: 0.001)
        XCTAssertEqual(composer.frame.height, collapsedBarHeight, accuracy: 0.001)

        captionInputView.textView.text = Array(repeating: "Long caption line", count: 40).joined(separator: "\n")
        captionInputView.textViewDidChange(captionInputView.textView)
        sheet.view.layoutIfNeeded()

        let expandedCaptionHeight = captionInputView.frame.height
        XCTAssertEqual(expandedCaptionHeight, 138, accuracy: 0.001)
        XCTAssertTrue(captionInputView.textView.isScrollEnabled)
        XCTAssertEqual(
            sheet.bottomControlsContainerView.frame.height,
            expandedCaptionHeight + 8 + NativeGlassBarStyle.bottomOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(composer.frame.height, sheet.bottomControlsContainerView.frame.height, accuracy: 0.001)
        XCTAssertEqual(composer.resetButton.frame.maxY, captionInputView.frame.maxY, accuracy: 0.001)
        XCTAssertEqual(composer.sendButton.frame.maxY, captionInputView.frame.maxY, accuracy: 0.001)

        captionInputView.textView.text = ""
        captionInputView.textViewDidChange(captionInputView.textView)
        sheet.view.layoutIfNeeded()

        XCTAssertEqual(captionInputView.frame.height, NativeGlassBarStyle.minimumHeight, accuracy: 0.001)
        XCTAssertFalse(captionInputView.textView.isScrollEnabled)
        XCTAssertEqual(sheet.bottomControlsContainerView.frame.height, collapsedBarHeight, accuracy: 0.001)
        XCTAssertEqual(composer.resetButton.frame.maxY, captionInputView.frame.maxY, accuracy: 0.001)
        XCTAssertEqual(composer.sendButton.frame.maxY, captionInputView.frame.maxY, accuracy: 0.001)
    }

    func testSheetCaptionPersistsForBatchAndClearsWhenLastDraftIsRemoved() {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        sheet.selectionComposerBarView.captionInputView.textView.text = "Grid caption"
        sheet.selectionComposerBarView.captionInputView.textViewDidChange(
            sheet.selectionComposerBarView.captionInputView.textView
        )

        XCTAssertEqual(sheet.captionState.rawText, "Grid caption")

        source.replaceSelectedDrafts([])

        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
        XCTAssertFalse(sheet.sourceBarView.isHidden)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
    }

    func testLocationSelectionShowsReadOnlyInfoAndKeepsSendEnabledBeforeSnapshot() {
        let source = FakeTask13SelectableSourceController(source: .geolocation)
        let sheet = makeSheet(source: source)
        let locationDraft = makeTask13LocationDraft(
            address: "  Westminster  ",
            snapshotURL: nil
        )

        sheet.loadViewIfNeeded()
        sheet.switchSource(to: .geolocation)
        source.replaceSelectedDrafts([locationDraft])

        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
        XCTAssertTrue(sheet.selectionComposerBarView.captionInputView.isHidden)
        assertLocationInfo(
            sheet.selectionComposerBarView,
            address: "Westminster",
            coordinates: "51.5007:-0.1246"
        )
        XCTAssertFalse(sheet.selectionComposerBarView.isHidden)
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)
    }

    func testLocationReplacementUpdatesReadOnlyInfoWithoutDisablingSend() {
        let source = FakeTask13SelectableSourceController(source: .geolocation)
        let sheet = makeSheet(source: source)
        let first = makeTask13LocationDraft(
            latitude: 51.5007,
            longitude: -0.1246,
            address: "Westminster",
            snapshotURL: nil
        )
        let second = makeTask13LocationDraft(
            latitude: 40.7128,
            longitude: -74.006,
            address: "New York City",
            snapshotURL: nil
        )

        sheet.loadViewIfNeeded()
        sheet.switchSource(to: .geolocation)
        source.replaceSelectedDrafts([first])
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)

        source.replaceSelectedDrafts([second])

        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
        assertLocationInfo(
            sheet.selectionComposerBarView,
            address: "New York City",
            coordinates: "40.7128:-74.006"
        )
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)
        XCTAssertEqual(sheet.selectedAttachmentDrafts.map(\.id), [second.id])
    }

    func testLocationSnapshotAndPointChangeKeepCaptionEmptyAndUpdateReadOnlyInfo() {
        let source = FakeTask13SelectableSourceController(source: .geolocation)
        let sheet = makeSheet(source: source)
        let first = makeTask13LocationDraft(
            latitude: 51.5007,
            longitude: -0.1246,
            address: "Westminster",
            snapshotURL: nil
        )
        let firstWithSnapshot = makeTask13LocationDraft(
            latitude: 51.5007,
            longitude: -0.1246,
            address: "Westminster",
            snapshotURL: URL(fileURLWithPath: "/tmp/westminster.png")
        )
        let second = makeTask13LocationDraft(
            latitude: 40.7128,
            longitude: -74.006,
            address: "New York City",
            snapshotURL: nil
        )

        sheet.loadViewIfNeeded()
        sheet.switchSource(to: .geolocation)
        source.replaceSelectedDrafts([first])

        source.replaceSelectedDrafts([firstWithSnapshot])
        XCTAssertTrue(sheet.captionState.isEmpty)
        assertLocationInfo(
            sheet.selectionComposerBarView,
            address: "Westminster",
            coordinates: "51.5007:-0.1246"
        )

        source.replaceSelectedDrafts([second])

        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
        assertLocationInfo(
            sheet.selectionComposerBarView,
            address: "New York City",
            coordinates: "40.7128:-74.006"
        )
        XCTAssertTrue(sheet.selectionComposerBarView.sendButton.isEnabled)
    }

    func testLocationResetClearsReadOnlyInfoAndRestoresSourceBar() throws {
        let source = FakeTask13SelectableSourceController(source: .geolocation)
        let sheet = makeSheet(source: source)

        sheet.loadViewIfNeeded()
        sheet.switchSource(to: .geolocation)
        source.replaceSelectedDrafts([
            makeTask13LocationDraft(address: "Westminster", snapshotURL: nil)
        ])
        assertLocationInfo(
            sheet.selectionComposerBarView,
            address: "Westminster",
            coordinates: "51.5007:-0.1246"
        )

        let resetButton = try XCTUnwrap(
            firstSubview(
                in: sheet.selectionComposerBarView,
                accessibilityIdentifier: "chatAttachmentSheet.selectionComposerBar.resetButton",
                as: UIButton.self
            )
        )
        resetButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(sheet.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(source.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertTrue(sheet.selectionComposerBarView.locationInfoView.isHidden)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
        XCTAssertFalse(sheet.sourceBarView.isHidden)
    }

    func testSheetResetButtonClearsSelectedBatchCaptionAndRestoresSourceBar() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let sheet = makeSheet(source: source)
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1")

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        sheet.selectionComposerBarView.captionInputView.textView.text = "Reset me"
        sheet.selectionComposerBarView.captionInputView.textViewDidChange(
            sheet.selectionComposerBarView.captionInputView.textView
        )

        let resetButton = try XCTUnwrap(
            firstSubview(
                in: sheet.selectionComposerBarView,
                accessibilityIdentifier: "chatAttachmentSheet.selectionComposerBar.resetButton",
                as: UIButton.self
            )
        )
        resetButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(sheet.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(source.selectedAttachmentDrafts.isEmpty)
        XCTAssertTrue(sheet.captionState.isEmpty)
        XCTAssertEqual(sheet.selectionComposerBarView.captionInputView.text, "")
        XCTAssertTrue(sheet.selectionComposerBarView.isHidden)
        XCTAssertFalse(sheet.sourceBarView.isHidden)
        XCTAssertTrue(sheet.statusBannerView.isHidden)
    }

    func testSheetStartsPreparationWhenDraftIsSelectedAndSendRequestsPreparedDrafts() {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let preparation = FakeTask13MediaPreparationCoordinator()
        let delegate = FakeTask13SheetDelegate()
        let sheet = makeSheet(source: source, mediaPreparationCoordinator: preparation)
        sheet.delegate = delegate
        let draft = makeTask13AssetDraft(localIdentifier: "asset-1", prepared: false)

        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([draft])
        sheet.selectionComposerBarView.captionInputView.textView.text = "Batch caption"
        sheet.selectionComposerBarView.captionInputView.textViewDidChange(
            sheet.selectionComposerBarView.captionInputView.textView
        )

        XCTAssertEqual(preparation.prepareCallCount, 1)
        XCTAssertEqual(preparation.receivedDrafts.first?.map(\.id), [draft.id])
        XCTAssertEqual(preparation.receivedDrafts.first?.first?.preparationState, .pending)
        XCTAssertEqual(delegate.sendCount, 0)
        XCTAssertTrue(sheet.selectedAttachmentDrafts.allSatisfy { draft in
            if case .prepared = draft.preparationState {
                return true
            }
            return false
        })

        sheet.selectionComposerBarView.sendButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(preparation.prepareCallCount, 1)
        XCTAssertEqual(delegate.requestedDraftIDs, [draft.id])
        XCTAssertEqual(delegate.requestedCaption.rawText, "Batch caption")
    }

    func testSendButtonRemainsDisabledAndDoesNotCallCoordinatorSend() throws {
        let source = FakeTask13SelectableSourceController(source: .gallery)
        let delegate = FakeTask13SheetDelegate()
        let sheet = makeSheet(source: source)
        sheet.delegate = delegate
        sheet.loadViewIfNeeded()
        source.replaceSelectedDrafts([makeTask13AssetDraft(localIdentifier: "asset-1", prepared: false)])
        let preview = try openPreview(from: sheet)
        preview.captionInputView.textView.text = "Caption"
        preview.captionInputView.textViewDidChange(preview.captionInputView.textView)
        preview.sendButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(preview.sendButton.isEnabled)
        XCTAssertEqual(delegate.sendCount, 0)
        XCTAssertEqual(sheet.captionState.rawText, "Caption")
    }

    private func makeSheet(
        source: ChatAttachmentSourceControlling,
        composerTintColor: UIColor = .systemBlue,
        mediaPreparationCoordinator: ChatAttachmentMediaPreparing = ChatAttachmentMediaPreparationCoordinator(),
        previewDismissalHandler: @escaping ChatAttachmentSheetViewController.PreviewDismissalHandler = { _, _, completion in completion?() }
    ) -> ChatAttachmentSheetViewController {
        ChatAttachmentSheetViewController(
            context: ChatAttachmentFlowContext(
                owner: "alice@example.com",
                jid: "bob@example.com",
                conversationType: .regular,
                forwardedMessageIds: [],
                composerTintColor: composerTintColor
            ),
            sourceControllerFactory: FakeTask13SourceControllerFactory(source: source),
            mediaPreparationCoordinator: mediaPreparationCoordinator,
            previewPresentationHandler: { _, _, _, completion in completion?() },
            previewDismissalHandler: previewDismissalHandler
        )
    }

    private func makePreview(drafts: [AttachmentDraft]) -> ChatAttachmentPreviewViewController {
        ChatAttachmentPreviewViewController(
            drafts: drafts,
            mediaProvider: FakeTask13PreviewMediaProvider(),
            videoPresenter: FakeTask13PreviewVideoPresenter()
        )
    }

    private func openPreview(
        from sheet: ChatAttachmentSheetViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatAttachmentPreviewViewController {
        sheet.selectionPreviewBarView.previewButton.sendActions(for: .touchUpInside)
        return try XCTUnwrap(sheet.previewViewController, file: file, line: line)
    }

    private func firstSubview<T: UIView>(
        in root: UIView,
        accessibilityIdentifier: String,
        as type: T.Type
    ) -> T? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root as? T
        }

        for subview in root.subviews {
            if let match = firstSubview(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier,
                as: type
            ) {
                return match
            }
        }

        return nil
    }

    private func assertLocationInfo(
        _ composer: ChatAttachmentSelectionComposerBarView,
        address: String,
        coordinates: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(composer.locationInfoView.isHidden, file: file, line: line)
        XCTAssertEqual(composer.locationAddressLabel.text, address, file: file, line: line)
        XCTAssertEqual(composer.locationCoordinatesLabel.text, coordinates, file: file, line: line)
        XCTAssertEqual(
            composer.locationInfoView.accessibilityIdentifier,
            "chatAttachmentSheet.selectionComposerBar.locationInfo",
            file: file,
            line: line
        )
        XCTAssertEqual(
            composer.locationAddressLabel.accessibilityIdentifier,
            "chatAttachmentSheet.selectionComposerBar.locationAddress",
            file: file,
            line: line
        )
        XCTAssertEqual(
            composer.locationCoordinatesLabel.accessibilityIdentifier,
            "chatAttachmentSheet.selectionComposerBar.locationCoordinates",
            file: file,
            line: line
        )
    }
}

private final class FakeTask13SourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private let source: ChatAttachmentSourceControlling

    init(source: ChatAttachmentSourceControlling) {
        self.source = source
    }

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        self.source.source == source ? self.source : ChatAttachmentPlaceholderSourceViewController(source: source)
    }
}

private final class FakeTask13SelectableSourceController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?
    private(set) var selectedAttachmentDrafts: [AttachmentDraft] = []

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func replaceSelectedDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        onSelectionCountChanged?(drafts.count)
        onSelectedAttachmentDraftsChanged?(drafts)
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        onSelectionCountChanged?(drafts.count)
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        selectedAttachmentDrafts.removeAll { $0.id == draftID }
        onSelectionCountChanged?(selectedAttachmentDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedAttachmentDrafts)
        return selectedAttachmentDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        guard let index = selectedAttachmentDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedAttachmentDrafts
        }

        selectedAttachmentDrafts[index] = updatedDraft
        onSelectionCountChanged?(selectedAttachmentDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedAttachmentDrafts)
        return selectedAttachmentDrafts
    }
}

private final class FakeTask13PreviewMediaProvider: ChatAttachmentPreviewMediaProviding {
    @discardableResult
    func requestPreviewMedia(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentPreviewMedia) -> Void
    ) -> Int {
        completion(.filePlaceholder(filename: draft.filename, byteSize: draft.byteSize))
        return 1
    }

    func cancelPreviewMediaRequest(_ requestID: Int) {}
}

private final class FakeTask13PreviewVideoPresenter: ChatAttachmentPreviewVideoPresenting {
    func presentVideo(playerItem: AVPlayerItem, from viewController: UIViewController) {}
}

private final class FakeTask13SheetDelegate: ChatAttachmentSheetViewControllerDelegate {
    private(set) var sendCount = 0
    private(set) var requestedDraftIDs: [String] = []
    private(set) var requestedCaption = ChatAttachmentCaptionState()

    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentSheetViewController) {
        sendCount += 1
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        sendCount += 1
        requestedDraftIDs = drafts.map(\.id)
        requestedCaption = captionState
    }

    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentSheetViewController) {}
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didRequestPremiumFor owner: String
    ) {}
    func chatAttachmentSheetViewController(_ sheet: ChatAttachmentSheetViewController, didFailWith error: ChatAttachmentFlowError) {}
    func chatAttachmentSheetViewController(_ sheet: ChatAttachmentSheetViewController, didUpdateSelectionCount count: Int) {}
}

private final class FakeTask13MediaPreparationCoordinator: ChatAttachmentMediaPreparing {
    private(set) var prepareCallCount = 0
    private(set) var receivedDrafts: [[AttachmentDraft]] = []

    @discardableResult
    func prepare(
        drafts: [AttachmentDraft],
        completion: @escaping ([AttachmentDraft]) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        prepareCallCount += 1
        receivedDrafts.append(drafts)
        completion(drafts.map(makePreparedDraft(from:)))
        return FakeTask13PreparationTask()
    }

    private func makePreparedDraft(from draft: AttachmentDraft) -> AttachmentDraft {
        if case .prepared = draft.preparationState {
            return draft
        }

        var preparedDraft = draft
        let filename = draft.filename.isEmpty ? "\(draft.id).jpg" : draft.filename
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        preparedDraft.preparationState = .prepared(
            AttachmentPreparedFile(
                localFileURL: url,
                referenceURL: url,
                filename: filename,
                byteSize: max(1, draft.byteSize),
                mediaType: "image/jpeg",
                dimensions: draft.dimensions,
                duration: draft.duration,
                videoPreviewKey: nil,
                videoOrientation: nil,
                videoDurationLabel: nil,
                videoPreviewLocalURL: nil,
                temporaryData: nil
            )
        )
        return preparedDraft
    }
}

private final class FakeTask13PreparationTask: ChatAttachmentMediaPreparationCancellable {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private func makeTask13AssetDraft(localIdentifier: String, prepared: Bool = true) -> AttachmentDraft {
    var draft = AttachmentDraft(
        id: AttachmentAssetDraft(assetLocalIdentifier: localIdentifier).id,
        source: .gallery,
        mediaKind: .image,
        thumbnailState: .none,
        filename: "\(localIdentifier).jpg",
        byteSize: 0,
        duration: nil,
        dimensions: CGSize(width: 12, height: 8),
        preparationState: .pending
    )
    guard prepared else {
        return draft
    }

    let url = URL(fileURLWithPath: "/tmp/\(localIdentifier).jpg")
    draft.byteSize = 1
    draft.preparationState = .prepared(
        AttachmentPreparedFile(
            localFileURL: url,
            referenceURL: url,
            filename: draft.filename,
            byteSize: draft.byteSize,
            mediaType: "image/jpeg",
            dimensions: draft.dimensions,
            duration: draft.duration,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )
    )
    return draft
}

private func makeTask13LocationDraft(
    latitude: Double = 51.5007,
    longitude: Double = -0.1246,
    address: String?,
    snapshotURL: URL?
) -> AttachmentDraft {
    let coordinate = AttachmentLocationCoordinate(latitude: latitude, longitude: longitude)
    let geoURI = "geo:\(latitude),\(longitude)"
    let location = AttachmentPreparedLocation(
        coordinate: coordinate,
        displayAddress: address,
        accuracy: nil,
        geoURI: geoURI,
        createdAt: Date(timeIntervalSince1970: 0),
        localSnapshotURL: snapshotURL
    )
    return AttachmentDraft(
        id: "location:\(geoURI)",
        source: .geolocation,
        mediaKind: .location,
        thumbnailState: .none,
        filename: address ?? "Location",
        byteSize: 0,
        duration: nil,
        dimensions: nil,
        preparationState: .preparedLocation(location)
    )
}
