//
//  XEPMessageScheduleUITests.swift
//  xabberTests
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class XEPMessageScheduleUITests: XCTestCase {
    private final class ContextMenuDelegateSpy: ContextMenuDelegate {
        func contextMenuDidSelect(
            _ contextMenu: ContextMenu,
            cell: ContextMenuCell,
            targetedView: UIView,
            didSelect value: String,
            primary: String?
        ) -> Bool {
            false
        }

        func contextMenuDidDeselect(
            _ contextMenu: ContextMenu,
            cell: ContextMenuCell,
            targetedView: UIView,
            didDeselect value: String,
            primary: String?
        ) {}
    }

    private var previousRealmConfiguration: Realm.Configuration!

    @MainActor
    func testScheduledAttachmentPreviewUsesVisibleBodyAndExistingMarkup() throws {
        let item = richScheduledItem()

        let content = ScheduledMessageDisplayContent(item: item)

        XCTAssertEqual(content.body, "Important")
        XCTAssertEqual(content.attachments.map(\.title), ["report.pdf"])
        XCTAssertEqual(content.attachments.first?.kind, .file)
        let body = content.attributedBody(font: .systemFont(ofSize: 17), color: .label, mentionColor: .systemBlue)
        let font = try XCTUnwrap(body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @MainActor
    func testRemovingAllAttachmentsFromAnEditedCaptionProducesAnExplicitEmptySelection() throws {
        let content = try XCTUnwrap(ScheduledMessageContent.read(richScheduledItem()))
        var draft = ScheduledMessageEditDraft(content: content)
        let original = try XCTUnwrap(draft.attachments.first)

        draft.remove(original.id)

        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.action, .editContent(body: "Important", retainedAttachmentIDs: [], addedAttachmentXML: []))

        draft.body = " "
        XCTAssertFalse(draft.canSave)
    }

    @MainActor
    func testScheduledAttachmentPreviewRejectsLocalURLsAndProtectedMetadata() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.url = "file:///private/secret.pdf"
        XCTAssertNil(ScheduledMessageAttachmentPresentation(reference: reference).url)

        reference.url = "https://example.test/secret.pdf"
        reference.metadata = ["encryption-key": "malformed"]
        XCTAssertNil(ScheduledMessageAttachmentPresentation(reference: reference).url)
    }

    @MainActor
    func testScheduledStickerPreviewUsesStickerKindWithoutManifest() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .sticker
        reference.url = "https://stickers.example.test/party.webp"
        reference.metadata = ["media-type": "image/webp"]

        let preview = ScheduledMessageAttachmentPresentation(reference: reference)

        XCTAssertEqual(preview.kind, .sticker)
        XCTAssertEqual(preview.url?.absoluteString, reference.url)
    }

    private func richScheduledItem() -> ScheduledMessageListItem {
        let uri = "https://example.test/report.pdf"
        return ScheduledMessageListItem(
            scheduledId: "rich",
            deliverAt: Date(),
            status: .pending,
            bodyPreview: "Important\n\(uri)",
            owner: "me@example.test",
            conversation: "peer@example.test",
            messageXML: """
            <message xmlns='jabber:client' to='peer@example.test' type='chat'>
              <body>Important
            \(uri)</body>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='9'>
                <bold xmlns='https://xabber.com/protocol/markup'/>
              </reference>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='10' end='\(10 + uri.count)'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><name>report.pdf</name><media-type>application/pdf</media-type><size>125</size></file>
                  <sources><uri>\(uri)</uri></sources>
                </file-sharing>
              </reference>
            </message>
            """
        )
    }

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "XEPMessageScheduleUITests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testTextLongPressMenuPolicyAllowsOnlyEnabledSendStateWithText() {
        XCTAssertTrue(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: .textSend,
            inputState: .normal,
            isSendButtonEnabled: true,
            body: "  later  "
        ))

        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: .record,
            inputState: .normal,
            isSendButtonEnabled: true,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: .textSend,
            inputState: .record,
            isSendButtonEnabled: true,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: .textSend,
            inputState: .normal,
            isSendButtonEnabled: false,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: .textSend,
            inputState: .normal,
            isSendButtonEnabled: true,
            body: " \n\t "
        ))
    }

    func testScheduleMenuAvailabilityPolicyExplainsDisabledStates() {
        let enabled = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: true,
            isEditingMessage: false,
            hasRecordedAudio: false,
            hasUnsupportedMediaAttachment: false,
            conversationType: .regular
        ))
        XCTAssertFalse(enabled.sendWithoutSound.isEnabled)
        XCTAssertEqual(enabled.sendWithoutSound.disabledReason, .silentSendUnsupported)
        XCTAssertTrue(enabled.schedule.isEnabled)
        XCTAssertNil(enabled.schedule.disabledReason)

        XCTAssertEqual(disabledScheduleReason(scheduleAvailable: false), .scheduleUnavailable)
        XCTAssertEqual(disabledScheduleReason(isEditingMessage: true), .editingMessage)
        XCTAssertEqual(disabledScheduleReason(hasRecordedAudio: true), .unsupportedMedia)
        XCTAssertEqual(disabledScheduleReason(hasUnsupportedMediaAttachment: true), .unsupportedMedia)
        XCTAssertEqual(disabledScheduleReason(conversationType: .omemo), .encryptedConversation)
    }

    func testScheduleContextMenuItemsUseRightAnchoredDisabledStates() {
        let enabledState = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: true,
            isEditingMessage: false,
            hasRecordedAudio: false,
            hasUnsupportedMediaAttachment: false,
            conversationType: .regular
        ))
        let menu = ContextMenu(window: UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844)))

        ChatSendOptionsContextMenuBuilder.configure(menu)
        let items = ChatSendOptionsContextMenuBuilder.makeItems(menuState: enabledState)

        XCTAssertEqual(menu.MenuConstants.verticalPlacement, .aboveTarget)
        XCTAssertEqual(menu.MenuConstants.horizontalDirection, .right)
        XCTAssertEqual(menu.MenuConstants.MenuWidth, 250)
        XCTAssertEqual(menu.MenuConstants.ItemDefaultHeight, 44)
        XCTAssertFalse(menu.MenuConstants.targetedViewShadowEnabled)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].map(\.value), [
            ChatSendOptionsContextMenuBuilder.sendWithoutSoundValue,
            ChatSendOptionsContextMenuBuilder.scheduleValue
        ])
        XCTAssertFalse(items[0][0].isEnabled)
        XCTAssertTrue(items[0][1].isEnabled)

        let disabledState = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: false,
            isEditingMessage: false,
            hasRecordedAudio: false,
            hasUnsupportedMediaAttachment: false,
            conversationType: .regular
        ))
        let disabledItems = ChatSendOptionsContextMenuBuilder.makeItems(menuState: disabledState)

        XCTAssertFalse(disabledItems[0][0].isEnabled)
        XCTAssertFalse(disabledItems[0][1].isEnabled)
    }

    func testContextMenuDefaultVerticalPlacementRemainsAutomatic() {
        let menu = ContextMenu(window: UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844)))

        XCTAssertEqual(menu.MenuConstants.verticalPlacement, .automatic)
        XCTAssertTrue(menu.MenuConstants.targetedViewShadowEnabled)
    }

    func testScheduleContextMenuAboveTargetStaysAboveComposerField() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let composerField = UIView(frame: CGRect(x: 64, y: 730, width: 250, height: 44))
        container.addSubview(composerField)
        let menu = ContextMenu(window: container)
        ChatSendOptionsContextMenuBuilder.configure(menu)
        menu.items = [[
            ContextMenuItemWithImage(title: "Silent", image: nil, value: "silent", danger: false, isEnabled: false),
            ContextMenuItemWithImage(title: "Schedule", image: nil, value: "schedule", danger: false)
        ]]
        let delegate = ContextMenuDelegateSpy()

        menu.showMenu(viewTargeted: composerField, delegate: delegate, animated: false)
        let layoutExpectation = expectation(description: "ContextMenu layout")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                layoutExpectation.fulfill()
            }
        }
        wait(for: [layoutExpectation], timeout: 1)

        let menuFrame = menu.tableView.convert(menu.tableView.bounds, to: container)

        XCTAssertLessThanOrEqual(menuFrame.maxY, composerField.frame.minY - menu.MenuConstants.MenuMarginSpace + 0.001)
        XCTAssertGreaterThan(composerField.bounds.width, 44)
        XCTAssertEqual(menu.MenuConstants.verticalPlacement, .aboveTarget)
        XCTAssertEqual(menu.MenuConstants.horizontalDirection, .right)

        menu.closeMenu(withAnimation: false)
    }

    func testModernInputViewUsesWholeComposerCapsuleAsSendOptionsMenuSource() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.textField.text = "Scheduled text"
        inputView.textViewDidChange(force: true)

        inputView.layoutIfNeeded()

        let sourceView = inputView.sendOptionsMenuSourceView
        let sourceFrame = sourceView.convert(sourceView.bounds, to: inputView)
        let sendFrame = inputView.sendButton.convert(inputView.sendButton.bounds, to: inputView)

        XCTAssertFalse(sourceView === inputView.sendButton)
        XCTAssertGreaterThan(sourceFrame.width, sendFrame.width)
        XCTAssertTrue(sourceFrame.contains(sendFrame))
    }

    @MainActor
    func testSendOptionsMenuPreviewKeepsTheComposerGlassCorners() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let inputView = ModernXabberInputView(frame: CGRect(x: 16, y: 460, width: window.bounds.width - 32, height: 49))
        host.view.addSubview(inputView)
        inputView.setComposerText("Scheduled text")
        inputView.textViewDidChange(force: true)
        inputView.layoutIfNeeded()
        let sourceView = inputView.sendOptionsMenuSourceView
        let glassView = try XCTUnwrap(sourceView.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let menu = ContextMenu(window: window)
        ChatSendOptionsContextMenuBuilder.configure(menu)
        let state = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: true,
            isEditingMessage: false,
            hasRecordedAudio: false,
            hasUnsupportedMediaAttachment: false,
            conversationType: .regular
        ))
        menu.items = ChatSendOptionsContextMenuBuilder.makeItems(menuState: state)
        let delegate = ContextMenuDelegateSpy()
        let didAppear = expectation(description: "Send options preview appeared")
        menu.onViewAppear = { _ in didAppear.fulfill() }

        menu.showMenu(viewTargeted: sourceView, delegate: delegate, animated: false)
        wait(for: [didAppear], timeout: 1)
        defer { menu.closeMenu(withAnimation: false) }

        let preview = try XCTUnwrap(window.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(preview.image?.size, sourceView.bounds.size)
        XCTAssertGreaterThan(glassView.layer.cornerRadius, 0)
        XCTAssertEqual(preview.layer.cornerRadius, glassView.layer.cornerRadius)
        XCTAssertEqual(preview.layer.cornerCurve, glassView.layer.cornerCurve)
        XCTAssertTrue(preview.clipsToBounds)
    }

    func testContextMenuDisabledRowsCannotBeSelectedOrInvokeTap() {
        let menu = ContextMenu(window: UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844)))
        menu.items = [[
            ContextMenuItemWithImage(
                title: "Disabled",
                image: nil,
                value: "disabled",
                danger: false,
                isEnabled: false
            )
        ]]
        var tappedValues: [String] = []
        menu.onItemTap = { value in
            tappedValues.append(value)
            return true
        }
        let tableView = UITableView()
        let indexPath = IndexPath(row: 0, section: 0)

        XCTAssertNil(menu.tableView(tableView, willSelectRowAt: indexPath))
        menu.tableView(tableView, didSelectRowAt: indexPath)

        XCTAssertTrue(tappedValues.isEmpty)
    }

    func testContextMenuItemsDefaultToEnabledForExistingMessageMenuBehavior() {
        let item = ContextMenuItemWithImage(
            title: "Copy",
            image: nil,
            value: "copy",
            danger: false
        )

        XCTAssertTrue(item.isEnabled)
    }

    func testScheduleContextMenuSelectionOnlyTriggersScheduleAction() {
        var scheduleTapCount = 0

        XCTAssertTrue(ChatSendOptionsContextMenuBuilder.handleSelection(
            ChatSendOptionsContextMenuBuilder.scheduleValue,
            onSchedule: { scheduleTapCount += 1 }
        ))
        XCTAssertEqual(scheduleTapCount, 1)

        XCTAssertFalse(ChatSendOptionsContextMenuBuilder.handleSelection(
            ChatSendOptionsContextMenuBuilder.sendWithoutSoundValue,
            onSchedule: { scheduleTapCount += 1 }
        ))
        XCTAssertEqual(scheduleTapCount, 1)
    }

    func testDatePolicyMinimumNormalizationAndConfirmTitles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let policy = ScheduledMessageDatePolicy(
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: calendar.timeZone
        )
        let now = makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 5, second: 30)
        let today = makeDate(year: 2026, month: 6, day: 15, hour: 12, minute: 7, second: 45)
        let tomorrow = makeDate(year: 2026, month: 6, day: 16, hour: 8, minute: 3, second: 9)
        let later = makeDate(year: 2026, month: 6, day: 18, hour: 18, minute: 40, second: 12)

        XCTAssertEqual(policy.minimumDate(now: now).timeIntervalSince1970, now.addingTimeInterval(60).timeIntervalSince1970)
        XCTAssertFalse(policy.canConfirm(now, now: now))
        XCTAssertTrue(policy.canConfirm(today, now: now))
        XCTAssertEqual(policy.normalizedToMinute(today), makeDate(year: 2026, month: 6, day: 15, hour: 12, minute: 7, second: 0))
        XCTAssertTrue(policy.confirmTitle(for: today, now: now).hasPrefix("Send today at "))
        XCTAssertTrue(policy.confirmTitle(for: tomorrow, now: now).hasPrefix("Send tomorrow at "))
        XCTAssertTrue(policy.confirmTitle(for: later, now: now).hasPrefix("Send on "))
    }

    func testDatePolicyStartsAnHourAheadPreservesFutureSeedAndClampsExpiredSeed() throws {
        let now = makeDate(year: 2026, month: 6, day: 15, hour: 23, minute: 5, second: 30)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let policy = ScheduledMessageDatePolicy(locale: Locale(identifier: "en_US"), timeZone: timeZone)
        let original = now.addingTimeInterval(7200)

        XCTAssertEqual(policy.initialDate(preferred: nil, now: now), now.addingTimeInterval(3570))
        XCTAssertEqual(policy.initialDate(preferred: original, now: now), original.addingTimeInterval(-30))
        XCTAssertEqual(policy.initialDate(preferred: now, now: now), now.addingTimeInterval(90))
    }

    func testDatePolicyPreservesSecondOccurrenceOfRepeatedMinute() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let policy = ScheduledMessageDatePolicy(locale: Locale(identifier: "en_US"), timeZone: timeZone)
        let secondOccurrence = makeDate(year: 2026, month: 11, day: 1, hour: 9, minute: 30, second: 45)

        XCTAssertEqual(policy.normalizedToMinute(secondOccurrence), secondOccurrence.addingTimeInterval(-45))
    }

    func testReschedulePickerKeepsSeedAndRefreshesEstimateWhenSelectionChanges() throws {
        var now = makeDate(year: 2026, month: 6, day: 15, hour: 18, minute: 0)
        let scheduled = now.addingTimeInterval(10_800)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let policy = ScheduledMessageDatePolicy(locale: Locale(identifier: "en_US"), timeZone: timeZone)
        let controller = ScheduledMessageDatePickerViewController(
            initialDate: scheduled,
            policy: policy,
            nowProvider: { now },
            onConfirm: { _ in XCTFail("Editing the picker does not confirm delivery.") }
        )
        controller.loadViewIfNeeded()
        let controls = controller.view.subviews.flatMap(\.subviews)
        let picker = try XCTUnwrap(controls.compactMap { $0 as? UIDatePicker }.first)
        let countdown = try XCTUnwrap(controls.first {
            $0.accessibilityIdentifier == ScheduledMessageDatePickerViewController.countdownIdentifier
        } as? UILabel)

        XCTAssertEqual(picker.date, scheduled)
        XCTAssertEqual(countdown.text, "in 3 hours")

        now = now.addingTimeInterval(3600)
        XCTAssertEqual(countdown.text, "in 3 hours")
        picker.date = scheduled.addingTimeInterval(1800)
        picker.sendActions(for: .valueChanged)
        XCTAssertEqual(countdown.text, "in 2 hours")
    }

    func testScheduledDaySectionsSortByDeliveryAndRespectLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 5 * 3600))
        let beforeMidnight = makeDate(year: 2026, month: 6, day: 15, hour: 18, minute: 55)
        let midnight = makeDate(year: 2026, month: 6, day: 15, hour: 19, minute: 0)
        let later = midnight.addingTimeInterval(60)
        let rows: [ScheduledMessageListItem] = [
            .init(scheduledId: "late", deliverAt: later, status: .failed, bodyPreview: "Late"),
            .init(scheduledId: "midnight", deliverAt: midnight, status: .pending, bodyPreview: "Midnight"),
            .init(scheduledId: "early", deliverAt: beforeMidnight, status: .pending, bodyPreview: "Early")
        ]

        let sections = ScheduledMessageDaySection.make(from: rows, calendar: calendar)

        XCTAssertEqual(sections.map(\.day), [calendar.startOfDay(for: beforeMidnight), midnight])
        XCTAssertEqual(sections.map { $0.items.map(\.scheduledId) }, [["early"], ["midnight", "late"]])
    }

    func testScheduleCoordinatorSuccessUsesScheduleServiceAndDoesNotSendRegularMessage() throws {
        let service = FakeScheduledMessageService()
        let coordinator = ChatScheduledMessageSendCoordinator(service: service)
        let request = makeRequest(body: "Schedule this", forwardedMessagePrimaries: ["forward-1"])
        var success: XMPPMessageScheduleManager.ScheduledEntry?
        var failure: XMPPMessageScheduleManager.ScheduleError?

        let queryId = coordinator.schedule(
            request,
            onSuccess: { success = $0 },
            onFailure: { failure = $0 }
        )

        XCTAssertEqual(queryId, "query-1")
        XCTAssertEqual(service.scheduleRequests.count, 1)
        XCTAssertEqual(service.scheduleRequests.first?.body, "Schedule this")
        XCTAssertEqual(service.scheduleRequests.first?.forwardedMessagePrimaries, ["forward-1"])
        XCTAssertEqual(service.sendSimpleMessageCallCount, 0)
        XCTAssertNil(success)
        XCTAssertNil(failure)

        let entry = XMPPMessageScheduleManager.ScheduledEntry(
            scheduledId: "scheduled-1",
            conversation: request.conversation,
            conversationType: request.conversationType,
            deliverAt: request.deliverAt,
            status: .pending,
            messageXML: "<message><body>Schedule this</body></message>"
        )
        service.scheduleCallback?(.success(entry))

        XCTAssertEqual(success, entry)
        XCTAssertNil(failure)
    }

    func testScheduleCoordinatorNilOrErrorResultKeepsCallerOnFailurePath() {
        let nilService = FakeScheduledMessageService()
        nilService.nextQueryId = nil
        let nilCoordinator = ChatScheduledMessageSendCoordinator(service: nilService)
        var nilFailure: XMPPMessageScheduleManager.ScheduleError?

        XCTAssertNil(nilCoordinator.schedule(
            makeRequest(body: "Keep draft"),
            onSuccess: { _ in XCTFail("Unexpected success") },
            onFailure: { nilFailure = $0 }
        ))
        XCTAssertEqual(nilFailure, .sendRejected)

        let errorService = FakeScheduledMessageService()
        let errorCoordinator = ChatScheduledMessageSendCoordinator(service: errorService)
        var errorFailure: XMPPMessageScheduleManager.ScheduleError?

        XCTAssertEqual(errorCoordinator.schedule(
            makeRequest(body: "Keep draft"),
            onSuccess: { _ in XCTFail("Unexpected success") },
            onFailure: { errorFailure = $0 }
        ), "query-1")
        errorService.scheduleCallback?(.failure(.forbidden))

        XCTAssertEqual(errorFailure, .forbidden)
    }

    func testScheduledMessagesListModelFiltersSortsAndParsesPreview() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        try seedSchedule(
            owner: owner,
            id: "late",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 14, minute: 0),
            status: .failed,
            body: "Later body"
        )
        try seedSchedule(
            owner: owner,
            id: "early",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Early & tea"
        )
        try seedSchedule(
            owner: owner,
            id: "other-chat",
            conversation: "carol@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 9, minute: 0),
            status: .pending,
            body: "Other"
        )

        let items = try ScheduledMessagesListModel.items(
            owner: owner,
            conversation: conversation,
            conversationType: .regular,
            realm: WRealm.safe()
        )

        XCTAssertEqual(items.map(\.scheduledId), ["early", "late"])
        XCTAssertEqual(items.first?.bodyPreview, "Early & tea")
        XCTAssertEqual(items.first?.status, .pending)
        XCTAssertEqual(items.last?.status, .failed)
    }

    func testScheduledMessagesListCancelUsesServiceWithoutOptimisticDelete() throws {
        let service = FakeScheduledMessageService()
        let owner = "alice@example.com"
        try seedSchedule(
            owner: owner,
            id: "scheduled-1",
            conversation: "bob@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Cancel me"
        )

        let queryId = service.cancelScheduledMessage(
            owner: owner,
            scheduledId: "scheduled-1",
            callback: { _ in }
        )

        XCTAssertEqual(queryId, "cancel-1")
        XCTAssertEqual(service.cancelledIds, ["scheduled-1"])
        XCTAssertNotNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "scheduled-1")
        ))
    }

    @MainActor
    func testRescheduleKeepsTheVisibleRowInPlaceUntilItsReplacementIsConfirmed() async throws {
        let owner = "alice@example.test"
        let conversation = "bob@example.test"
        let calendar = L10n.formatters.calendar
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: Date()))
        let oldDate = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow))
        let newDate = oldDate.addingTimeInterval(180)
        let messageXML = "<message xmlns='jabber:client' to='\(conversation)' type='chat'><body>Draft</body></message>"
        let realm = try WRealm.safe()
        func store(_ id: String, date: Date) throws {
            let row = XMPPMessageScheduleStorageItem()
            row.configure(
                owner: owner, scheduledId: id, conversation: conversation, conversationType: .regular,
                deliverAt: date, status: .pending, messageXML: messageXML
            )
            try realm.write { realm.add(row) }
        }
        try store("original", date: oldDate)
        let rows = realm.objects(XMPPMessageScheduleStorageItem.self)
        let originalWasRemoved = expectation(description: "Realm published the cancel")
        let token = rows.observe { change in
            if case .update(let rows, let deletions, _, _) = change, rows.isEmpty, !deletions.isEmpty {
                originalWasRemoved.fulfill()
            }
        }
        defer { token.invalidate() }

        let service = FakeScheduledMessageService()
        let cancelRequested = expectation(description: "Cancel requested")
        let replacementRequested = expectation(description: "Replacement requested")
        service.onCancelRequest = { cancelRequested.fulfill() }
        service.onPreparedScheduleRequest = { replacementRequested.fulfill() }
        defer {
            service.cancelCallback?(.failure(.sendRejected))
            service.preparedScheduleCallback?(.failure(.sendRejected))
        }
        let journalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let list = ScheduledMessagesViewController()
        list.owner = owner
        list.jid = conversation
        list.scheduledMessageService = service
        list.actionCoordinator = ScheduledMessageActionCoordinator(
            service: service, journal: ScheduledMessageActionJournal(directory: journalDirectory)
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UINavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        let table = try XCTUnwrap(list.view.subviews.compactMap { $0 as? UITableView }.first)
        let indexPath = IndexPath(row: 0, section: 0)
        let originalCell = try XCTUnwrap(table.cellForRow(at: indexPath))
        let originalFrame = originalCell.convert(originalCell.bounds, to: list.view)
        let originalLabel = originalCell.accessibilityLabel
        let originalValue = originalCell.accessibilityValue
        let reschedule = try XCTUnwrap(originalCell.accessibilityCustomActions?.first {
            $0.name == L10n.text("scheduled_message_reschedule", fallback: "Reschedule")
        })
        XCTAssertTrue(reschedule.actionHandler?(reschedule) == true)
        let picker = try XCTUnwrap(list.presentedViewController as? ScheduledMessageDatePickerViewController)
        let pickerControls = picker.view.subviews.flatMap(\.subviews)
        let wheel = try XCTUnwrap(pickerControls.compactMap { $0 as? UIDatePicker }.first)
        let confirm = try XCTUnwrap(pickerControls.first {
            $0.accessibilityIdentifier == ScheduledMessageDatePickerViewController.confirmButtonIdentifier
        } as? UIButton)
        wheel.date = newDate
        confirm.sendActions(for: .touchUpInside)

        await fulfillment(of: [cancelRequested], timeout: 3)
        window.layoutIfNeeded()
        XCTAssertEqual(originalCell.convert(originalCell.bounds, to: list.view), originalFrame)
        let cancelled = try XCTUnwrap(service.cancelCallback)
        let original = try XCTUnwrap(rows.first)
        try realm.write { realm.delete(original) }
        cancelled(.success("original"))
        await fulfillment(of: [originalWasRemoved, replacementRequested], timeout: 3)
        window.layoutIfNeeded()
        XCTAssertEqual(table.numberOfSections, 1)
        XCTAssertTrue(table.cellForRow(at: indexPath) === originalCell)
        XCTAssertEqual(originalCell.accessibilityValue, originalValue)
        XCTAssertEqual(originalCell.convert(originalCell.bounds, to: list.view), originalFrame)

        let replacement = try XCTUnwrap(service.preparedScheduleCallback)
        try store("replacement", date: newDate)
        replacement(.success(.init(
            scheduledId: "replacement", conversation: conversation, conversationType: .regular,
            deliverAt: newDate, status: .pending, messageXML: messageXML
        )))
        let time = L10n.formatters.dateFormatter(timeStyle: .short).string(from: newDate)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.layoutIfNeeded()
            return table.cellForRow(at: indexPath)?.accessibilityValue?.hasPrefix(time) == true
        }, object: nil)
        await fulfillment(of: [updated], timeout: 3)
        let newCell = try XCTUnwrap(table.cellForRow(at: indexPath))
        XCTAssertEqual(newCell.convert(newCell.bounds, to: list.view), originalFrame)
        XCTAssertEqual(newCell.accessibilityLabel, originalLabel)
    }

    func testChatControllerRefreshShowsScheduledMessagesButtonAfterScheduleRowExists() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        let viewController = makeChatViewController(owner: owner, conversation: conversation)
        viewController.xabberInputView.clearComposer()

        XCTAssertTrue(viewController.xabberInputView.scheduledMessagesButton.isHidden)

        try seedSchedule(
            owner: owner,
            id: "scheduled-1",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Scheduled"
        )

        viewController.refreshScheduledMessagesComposerButtonState()

        XCTAssertFalse(viewController.xabberInputView.scheduledMessagesButton.isHidden)
    }

    func testChatControllerRefreshRestoresComposerGlyphsAfterScheduledModalDismiss() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        let viewController = makeChatViewController(owner: owner, conversation: conversation)
        let inputView = viewController.xabberInputView!
        inputView.isSendButtonEnabled = true
        inputView.changeComposerActionMode(to: .textSend)
        inputView.clearComposer()

        try seedSchedule(
            owner: owner,
            id: "scheduled-1",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Scheduled"
        )

        viewController.refreshScheduledMessagesComposerButtonState()
        inputView.layoutIfNeeded()

        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertNotNil(buttonGlyphImage(inputView.attachButton))
        XCTAssertNotNil(buttonGlyphImage(inputView.recordButton))
        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertNotNil(inputView.scheduledMessagesButton.image(for: .normal))

        for button in [inputView.attachButton, inputView.recordButton] {
            if #available(iOS 26.0, *) {
                var configuration = button.configuration ?? UIButton.Configuration.clearGlass()
                configuration.image = nil
                button.configuration = configuration
            } else {
                button.configuration = nil
            }
            button.setImage(nil, for: .normal)
        }
        inputView.sendButton.configuration = nil
        inputView.sendButton.setImage(nil, for: .normal)
        inputView.scheduledMessagesButton.configuration = nil
        inputView.scheduledMessagesButton.setImage(nil, for: .normal)

        viewController.refreshScheduledMessagesComposerButtonState()
        inputView.layoutIfNeeded()

        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertNotNil(inputView.scheduledMessagesButton.image(for: .normal))
        for button in [inputView.attachButton, inputView.recordButton] {
            XCTAssertNotNil(buttonGlyphImage(button))
            XCTAssertEqual(button.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(button.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            if #available(iOS 26.0, *) {
                XCTAssertNotNil(button.configuration?.image)
            }
        }
        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertNil(inputView.sendButton.configuration)
    }

    func testAttachmentButtonStaysEnabledWhenSendReadinessIsBlocked() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.changeState(to: .normal)

        inputView.isSendButtonEnabled = false
        inputView.changeComposerActionMode(to: .record)

        XCTAssertFalse(inputView.attachButton.isHidden)
        XCTAssertTrue(inputView.attachButton.isEnabled)
        XCTAssertFalse(inputView.recordButton.isEnabled)
        XCTAssertFalse(inputView.sendButton.isEnabled)

        inputView.changeComposerActionMode(to: .textSend)

        XCTAssertFalse(inputView.attachButton.isHidden)
        XCTAssertTrue(inputView.attachButton.isEnabled)
        XCTAssertFalse(inputView.sendButton.isEnabled)
    }

    func testModernInputComposerActionGlyphsUse24PointCanvasWithoutShrinkingTapTargets() throws {
        let expectedGlyphDimension: CGFloat = 24
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.layoutIfNeeded()
        inputView.isSendButtonEnabled = true
        inputView.changeComposerActionMode(to: .textSend)

        for button in [inputView.attachButton, inputView.recordButton, inputView.sendButton] {
            XCTAssertEqual(button.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(button.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(try buttonGlyphMaxDimension(button), expectedGlyphDimension, accuracy: 0.001)
        }

        inputView.changeComposerActionMode(to: .record)

        XCTAssertEqual(inputView.recordButton.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(inputView.recordButton.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(try buttonGlyphMaxDimension(inputView.recordButton), expectedGlyphDimension, accuracy: 0.001)
    }

    func testChatControllerRefreshHidesScheduledMessagesButtonAfterRowsDisappear() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        let viewController = makeChatViewController(owner: owner, conversation: conversation)
        try seedSchedule(
            owner: owner,
            id: "scheduled-1",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Scheduled"
        )
        viewController.refreshScheduledMessagesComposerButtonState()
        XCTAssertFalse(viewController.xabberInputView.scheduledMessagesButton.isHidden)

        let realm = try WRealm.safe()
        let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "scheduled-1")
        try realm.write {
            if let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary) {
                realm.delete(item)
            }
        }

        viewController.refreshScheduledMessagesComposerButtonState()

        XCTAssertTrue(viewController.xabberInputView.scheduledMessagesButton.isHidden)
    }

    func testChatControllerRefreshDoesNotShowScheduledMessagesButtonWhenComposerHasText() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        let viewController = makeChatViewController(owner: owner, conversation: conversation)
        viewController.xabberInputView.setComposerText("Draft")
        viewController.xabberInputView.textViewDidChange(force: true)
        try seedSchedule(
            owner: owner,
            id: "scheduled-1",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Scheduled"
        )

        viewController.refreshScheduledMessagesComposerButtonState()

        XCTAssertTrue(viewController.xabberInputView.scheduledMessagesButton.isHidden)
    }

    func testScheduledMessagesModalDidDisappearInvokesRefreshCallback() {
        let viewController = ScheduledMessagesViewController()
        var callbackCount = 0
        viewController.onDidDisappear = {
            callbackCount += 1
        }

        viewController.viewDidDisappear(false)

        XCTAssertEqual(callbackCount, 1)
    }

    func testComposerScheduledMessagesButtonPolicyRequiresNormalEmptyComposerWithRows() {
        XCTAssertTrue(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .normal,
            body: "",
            hasScheduledMessages: true
        ))
        XCTAssertTrue(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .normal,
            body: " \n\t ",
            hasScheduledMessages: true
        ))

        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .normal,
            body: "",
            hasScheduledMessages: false
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .normal,
            body: "Draft",
            hasScheduledMessages: true
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .record,
            body: "",
            hasScheduledMessages: true
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .search,
            body: "",
            hasScheduledMessages: true
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .selection,
            body: "",
            hasScheduledMessages: true
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: .skeleton,
            body: "",
            hasScheduledMessages: true
        ))
    }

    func testModernInputScheduledMessagesButtonVisibilityTracksTextAndState() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.layoutIfNeeded()

        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)
        XCTAssertFalse(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertFalse(inputView.scheduledMessagesButton.isUserInteractionEnabled)

        inputView.hasScheduledMessagesForCurrentChat = true
        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertTrue(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertTrue(inputView.scheduledMessagesButton.isUserInteractionEnabled)

        inputView.setComposerText("Test")
        inputView.textViewDidChange(force: true)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)
        XCTAssertFalse(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertFalse(inputView.scheduledMessagesButton.isUserInteractionEnabled)

        inputView.clearComposer()
        inputView.textViewDidChange(force: true)
        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertTrue(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertTrue(inputView.scheduledMessagesButton.isUserInteractionEnabled)

        inputView.changeState(to: .record)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)

        inputView.changeState(to: .normal)
        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)

        inputView.changeState(to: .search)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)

        inputView.changeState(to: .selection)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)

        inputView.changeState(to: .skeleton)
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)

        inputView.changeState(to: .normal)
        inputView.hasScheduledMessagesForCurrentChat = false
        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)
        XCTAssertFalse(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertFalse(inputView.scheduledMessagesButton.isUserInteractionEnabled)
    }

    func testModernInputScheduledMessagesButtonTapUsesDelegateWithoutSending() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        let delegate = InputBarDelegateSpy()
        inputView.delegate = delegate
        inputView.hasScheduledMessagesForCurrentChat = true

        inputView.scheduledMessagesButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.scheduledMessagesButtonTapCount, 1)
        XCTAssertEqual(delegate.sendButtonTapCount, 0)
    }

    func testModernInputScheduledMessagesButtonLayoutReservesTrailingTextSpace() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.hasScheduledMessagesForCurrentChat = true
        inputView.layoutIfNeeded()

        let buttonFrame = inputView.scheduledMessagesButton.convert(inputView.scheduledMessagesButton.bounds, to: inputView)
        let textFrame = inputView.textField.convert(inputView.textField.bounds, to: inputView)
        let contentFrame = inputView.contentView.convert(inputView.contentView.bounds, to: inputView)

        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertNotNil(inputView.scheduledMessagesButton.image(for: .normal))
        XCTAssertEqual(buttonFrame.width, 44, accuracy: 0.5)
        XCTAssertEqual(buttonFrame.height, textFrame.height, accuracy: 0.5)
        XCTAssertEqual(buttonFrame.maxX, contentFrame.maxX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(textFrame.maxX, buttonFrame.minX)
    }

    func testModernInputScheduledMessagesButtonDoesNotInterceptTextFieldTouches() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.hasScheduledMessagesForCurrentChat = true
        inputView.layoutIfNeeded()

        let buttonFrame = inputView.scheduledMessagesButton.convert(inputView.scheduledMessagesButton.bounds, to: inputView)
        let textFrame = inputView.textField.convert(inputView.textField.bounds, to: inputView)
        let textPoint = CGPoint(x: textFrame.minX + min(24, textFrame.width / 2), y: textFrame.midY)
        let buttonPoint = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)

        XCTAssertFalse(inputView.hitTest(textPoint, with: nil) === inputView.scheduledMessagesButton)
        XCTAssertTrue(inputView.hitTest(buttonPoint, with: nil) === inputView.scheduledMessagesButton)
    }

    func testModernInputScheduledMessagesButtonHidesAndRestoresFullTextWidthWithoutRows() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.hasScheduledMessagesForCurrentChat = false
        inputView.layoutIfNeeded()

        let textFrame = inputView.textField.convert(inputView.textField.bounds, to: inputView)
        let contentFrame = inputView.contentView.convert(inputView.contentView.bounds, to: inputView)

        XCTAssertTrue(inputView.scheduledMessagesButton.isHidden)
        XCTAssertFalse(inputView.scheduledMessagesButton.isEnabled)
        XCTAssertFalse(inputView.scheduledMessagesButton.isUserInteractionEnabled)
        XCTAssertEqual(textFrame.maxX, contentFrame.maxX, accuracy: 0.5)
    }

    func testScheduledMessagesComposerButtonModelFiltersCurrentChatRows() throws {
        let owner = "alice@example.com"
        let conversation = "bob@example.com"
        try seedSchedule(
            owner: owner,
            id: "pending-current",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            status: .pending,
            body: "Pending"
        )
        try seedSchedule(
            owner: owner,
            id: "failed-current",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 11, minute: 0),
            status: .failed,
            body: "Failed"
        )
        try seedSchedule(
            owner: "other@example.com",
            id: "other-owner",
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 12, minute: 0),
            status: .pending,
            body: "Other owner"
        )
        try seedSchedule(
            owner: owner,
            id: "other-chat",
            conversation: "carol@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 13, minute: 0),
            status: .pending,
            body: "Other chat"
        )

        let realm = try WRealm.safe()

        XCTAssertTrue(ScheduledMessagesComposerButtonModel.hasRows(
            owner: owner,
            conversation: conversation,
            conversationType: .regular,
            realm: realm
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonModel.hasRows(
            owner: owner,
            conversation: conversation,
            conversationType: .group,
            realm: realm
        ))
        XCTAssertFalse(ScheduledMessagesComposerButtonModel.hasRows(
            owner: owner,
            conversation: "carol@example.com",
            conversationType: .group,
            realm: realm
        ))
    }

    private func disabledScheduleReason(
        scheduleAvailable: Bool = true,
        isEditingMessage: Bool = false,
        hasRecordedAudio: Bool = false,
        hasUnsupportedMediaAttachment: Bool = false,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatSendOptionsDisabledReason? {
        ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: scheduleAvailable,
            isEditingMessage: isEditingMessage,
            hasRecordedAudio: hasRecordedAudio,
            hasUnsupportedMediaAttachment: hasUnsupportedMediaAttachment,
            conversationType: conversationType
        )).schedule.disabledReason
    }

    private func makeRequest(
        body: String,
        forwardedMessagePrimaries: [String] = []
    ) -> ChatScheduledMessageSendRequest {
        ChatScheduledMessageSendRequest(
            owner: "alice@example.com",
            conversation: "bob@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 15, hour: 10, minute: 0),
            body: body,
            references: [],
            forwardedMessagePrimaries: forwardedMessagePrimaries
        )
    }

    private func makeChatViewController(owner: String, conversation: String) -> ChatViewController {
        let viewController = ChatViewController()
        viewController.owner = owner
        viewController.jid = conversation
        viewController.conversationType = .regular
        viewController.xabberInputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        viewController.xabberInputView.layoutIfNeeded()
        return viewController
    }

    private func seedSchedule(
        owner: String,
        id: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        status: XMPPMessageScheduleStorageItem.Status,
        body: String
    ) throws {
        let realm = try WRealm.safe()
        try realm.write {
            let item = XMPPMessageScheduleStorageItem()
            item.configure(
                owner: owner,
                scheduledId: id,
                conversation: conversation,
                conversationType: conversationType,
                deliverAt: deliverAt,
                status: status,
                messageXML: "<message xmlns='jabber:client'><body>\(body.xmlEscaped)</body></message>"
            )
            realm.add(item, update: .modified)
        }
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    private func buttonGlyphImage(_ button: UIButton) -> UIImage? {
        button.image(for: .normal) ?? button.configuration?.image
    }

    private func buttonGlyphMaxDimension(_ button: UIButton) throws -> CGFloat {
        let image = try XCTUnwrap(buttonGlyphImage(button))
        return max(image.size.width, image.size.height)
    }
}

private final class FakeScheduledMessageService: ChatScheduledMessageServicing {
    var available = true
    var nextQueryId: String? = "query-1"
    var scheduleRequests: [ChatScheduledMessageSendRequest] = []
    var scheduleCallback: XMPPMessageScheduleManager.ScheduleCallback?
    var preparedScheduleCallback: XMPPMessageScheduleManager.ScheduleCallback?
    var cancelledIds: [String] = []
    var cancelCallback: XMPPMessageScheduleManager.CancelCallback?
    var onCancelRequest: (() -> Void)?
    var onPreparedScheduleRequest: (() -> Void)?
    var sendSimpleMessageCallCount = 0

    func isScheduleAvailable(owner: String) -> Bool {
        available
    }

    @discardableResult
    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        scheduleRequests.append(request)
        scheduleCallback = callback
        return nextQueryId
    }

    @discardableResult
    func listScheduledMessages(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        callback: XMPPMessageScheduleManager.ListCallback?
    ) -> String? {
        callback?(.success([]))
        return "list-1"
    }

    @discardableResult
    func cancelScheduledMessage(
        owner: String,
        scheduledId: String,
        callback: XMPPMessageScheduleManager.CancelCallback?
    ) -> String? {
        cancelledIds.append(scheduledId)
        cancelCallback = callback
        onCancelRequest?()
        return "cancel-1"
    }

    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        preparedScheduleCallback = callback
        onPreparedScheduleRequest?()
        return "prepared-1"
    }
}

private final class InputBarDelegateSpy: XabberInputBarDelegate {
    var scheduledMessagesButtonTapCount = 0
    var sendButtonTapCount = 0

    func sendButtonTouchUp(with text: String) {
        sendButtonTapCount += 1
    }

    func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload) {}

    func scheduledMessagesButtonTouchUp() {
        scheduledMessagesButtonTapCount += 1
    }

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

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
