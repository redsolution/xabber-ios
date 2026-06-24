//
//  XEPMessageScheduleUITests.swift
//  xabberTests
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import RealmSwift
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
            sendButtonState: .send,
            inputState: .normal,
            isSendButtonEnabled: true,
            body: "  later  "
        ))

        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            sendButtonState: .record,
            inputState: .normal,
            isSendButtonEnabled: true,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            sendButtonState: .send,
            inputState: .record,
            isSendButtonEnabled: true,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            sendButtonState: .send,
            inputState: .normal,
            isSendButtonEnabled: false,
            body: "later"
        ))
        XCTAssertFalse(ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            sendButtonState: .send,
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

    func testModernInputViewUsesComposerFieldAsSendOptionsMenuSource() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))

        inputView.layoutIfNeeded()

        let sourceView = inputView.sendOptionsMenuSourceView
        let sourceFrame = sourceView.convert(sourceView.bounds, to: inputView)
        let sendFrame = inputView.sendButton.convert(inputView.sendButton.bounds, to: inputView)

        XCTAssertFalse(sourceView === inputView.sendButton)
        XCTAssertGreaterThan(sourceFrame.width, sendFrame.width)
        XCTAssertLessThanOrEqual(sourceFrame.maxX, sendFrame.minX)
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
        inputView.changeSendButtonState(to: .send)
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
        XCTAssertNotNil(buttonGlyphImage(inputView.sendButton))
        XCTAssertNotNil(inputView.scheduledMessagesButton.image(for: .normal))

        for button in [inputView.attachButton, inputView.sendButton] {
            if #available(iOS 26.0, *) {
                var configuration = button.configuration ?? UIButton.Configuration.clearGlass()
                configuration.image = nil
                button.configuration = configuration
            } else {
                button.configuration = nil
            }
            button.setImage(nil, for: .normal)
        }
        inputView.scheduledMessagesButton.configuration = nil
        inputView.scheduledMessagesButton.setImage(nil, for: .normal)

        viewController.refreshScheduledMessagesComposerButtonState()
        inputView.layoutIfNeeded()

        XCTAssertFalse(inputView.scheduledMessagesButton.isHidden)
        XCTAssertNotNil(inputView.scheduledMessagesButton.image(for: .normal))
        for button in [inputView.attachButton, inputView.sendButton] {
            XCTAssertNotNil(buttonGlyphImage(button))
            XCTAssertEqual(button.bounds.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            XCTAssertEqual(button.bounds.height, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
            if #available(iOS 26.0, *) {
                XCTAssertNotNil(button.configuration?.image)
            }
        }
    }

    func testAttachmentButtonStaysEnabledWhenSendReadinessIsBlocked() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.changeState(to: .normal)

        inputView.isSendButtonEnabled = false
        inputView.changeSendButtonState(to: .record)

        XCTAssertFalse(inputView.attachButton.isHidden)
        XCTAssertTrue(inputView.attachButton.isEnabled)
        XCTAssertFalse(inputView.sendButton.isEnabled)

        inputView.changeSendButtonState(to: .send)

        XCTAssertFalse(inputView.attachButton.isHidden)
        XCTAssertTrue(inputView.attachButton.isEnabled)
        XCTAssertFalse(inputView.sendButton.isEnabled)
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
}

private final class FakeScheduledMessageService: ChatScheduledMessageServicing {
    var available = true
    var nextQueryId: String? = "query-1"
    var scheduleRequests: [ChatScheduledMessageSendRequest] = []
    var scheduleCallback: XMPPMessageScheduleManager.ScheduleCallback?
    var cancelledIds: [String] = []
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
        return "cancel-1"
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
