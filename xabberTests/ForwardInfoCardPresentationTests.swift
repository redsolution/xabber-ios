import UIKit
import XCTest
import CoreLocation
import RealmSwift
import QuartzCore
import MaterialComponents.MDCPalettes
@testable import xabber

@MainActor
final class ForwardInfoCardPresentationTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.test"
    private let delegate = ForwardInfoCardDelegateSpy()

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ForwardInfoCardPresentationTests-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testAvailableForwardAuthorExposesAccessibleButton() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")

        XCTAssertTrue(view.authorLabel.isAccessibilityElement)
        XCTAssertTrue(view.authorLabel.accessibilityTraits.contains(.button))
        XCTAssertTrue(view.authorLabel.isUserInteractionEnabled)
    }

    func testAvailableForwardAuthorCanBeActivatedWithoutTouchCoordinates() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")

        XCTAssertTrue(view.authorLabel.accessibilityActivate())
        XCTAssertEqual(delegate.messagePrimaries, ["forward-author"])
        XCTAssertEqual(delegate.cards, [individual(name: "Juliet", jid: "juliet@example.test")])
    }

    func testReuseRemovesPreviousForwardAuthorAction() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")

        view.prepareForReuse()

        XCTAssertFalse(view.authorLabel.accessibilityTraits.contains(.button))
        XCTAssertFalse(view.authorLabel.accessibilityActivate())
        XCTAssertNil(view.authorLabel.accessibilityHint)
    }

    func testUnavailableForwardAuthorDoesNotExposeButtonAction() {
        let view = makeInlineView(author: "", jid: "")

        XCTAssertFalse(view.authorLabel.accessibilityTraits.contains(.button))
        XCTAssertFalse(view.authorLabel.accessibilityActivate())
    }

    func testReconfiguredAuthorActivationUsesNewOwnerAndSnapshot() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")
        let replacement = ForwardCardSnapshot(kind: .individual, owner: "second@example.test",
                                              name: "Alice", jid: "alice@example.test")
        let attachment = messageAttachment(author: "Alice", jid: "alice@example.test")
        attachment.primary = "replacement-forward"
        attachment.forwardCard = replacement

        view.configure(attachment, palette: .blue)
        XCTAssertTrue(view.authorLabel.accessibilityActivate())

        XCTAssertEqual(delegate.messagePrimaries, ["replacement-forward"])
        XCTAssertEqual(delegate.cards, [replacement])
    }

    func testReuseCannotActivatePreviouslyCapturedAuthor() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")

        view.prepareForReuse()

        XCTAssertFalse(view.activateForwardAuthor())
        XCTAssertTrue(delegate.cards.isEmpty)
    }

    func testAuthorTouchRoutesCapturedCardAtHeaderCoordinates() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")
        view.containerView.frame = view.bounds
        view.authorLabel.frame = CGRect(x: 12, y: 8, width: 180, height: 28)
        let point = view.authorLabel.convert(CGPoint(x: 20, y: 14), to: view)

        XCTAssertTrue(view.handleTouch(at: point))

        XCTAssertEqual(delegate.cards, [individual(name: "Juliet", jid: "juliet@example.test")])
        XCTAssertEqual(delegate.messagePrimaries, ["forward-author"])
    }

    func testContactPayloadTouchStillRoutesContactWithoutOpeningAuthorCard() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")
        view.containerView.frame = view.bounds
        view.authorLabel.frame = CGRect(x: 12, y: 8, width: 180, height: 28)
        view.contactsView.frame = CGRect(x: 10, y: 50, width: 220, height: 44)
        let contact = ContactAttachment(primary: "shared-contact", jid: "alice@example.test",
            title: "Alice", nickname: "Alice", given: nil, family: nil, avatarURL: nil, avatarMetadata: [:])
        view.contactsView.configure([contact], palette: .blue)

        XCTAssertTrue(view.handleTouch(at: CGPoint(x: 22, y: 62)))

        XCTAssertEqual(delegate.contacts.map(\.primary), ["shared-contact"])
        XCTAssertTrue(delegate.cards.isEmpty)
    }

    func testSelectionModeDoesNotOpenForwardAuthorCard() {
        let view = makeInlineView(author: "Juliet", jid: "juliet@example.test")
        view.containerView.frame = view.bounds
        view.authorLabel.frame = CGRect(x: 12, y: 8, width: 180, height: 28)
        let point = view.authorLabel.convert(CGPoint(x: 20, y: 14), to: view)
        delegate.inSelection = true

        XCTAssertFalse(view.authorLabel.accessibilityActivate())
        XCTAssertFalse(view.handleTouch(at: point))

        XCTAssertTrue(delegate.cards.isEmpty)
        XCTAssertTrue(delegate.messagePrimaries.isEmpty)
    }

    func testIndividualProjectionPreservesOwnerAndBareOriginalAddressWithCarriedAvatar() throws {
        let forward = makeForward(jid: "juliet@example.test/phone")
        forward.references.append(storedCard(jid: "juliet@example.test", name: "Juliet",
                                             avatarURI: "https://example.test/juliet.png"))

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.kind, .individual)
        XCTAssertEqual(snapshot.owner, owner)
        XCTAssertEqual(snapshot.jid, "juliet@example.test")
        XCTAssertEqual(snapshot.name, "Juliet")
        XCTAssertEqual(snapshot.avatarURL?.absoluteString, "https://example.test/juliet.png")
        XCTAssertNil(snapshot.badge)
        XCTAssertNil(snapshot.privacy)
        XCTAssertNil(snapshot.sourceGroup)
    }

    func testGroupMemberProjectionUsesMemberIdentityAndSeparateOriginGroup() throws {
        let forward = makeGroupForward(memberJID: "juliet@example.test/phone")

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.kind, .individual)
        XCTAssertEqual(snapshot.jid, "juliet@example.test")
        XCTAssertEqual(snapshot.name, "Historical Juliet")
        XCTAssertEqual(snapshot.badge, "Architect")
        XCTAssertEqual(snapshot.avatarURL?.absoluteString, "https://example.test/member.png")
        XCTAssertNil(snapshot.privacy)
        XCTAssertEqual(snapshot.sourceGroup?.jid, "council@example.test")
        XCTAssertEqual(snapshot.sourceGroup?.name, "Historical Council")
        XCTAssertEqual(snapshot.sourceGroup?.privacy, .incognito)
    }

    func testUnknownGroupMemberDoesNotBorrowOriginGroupAddressOrAvatar() {
        let forward = makeGroupForward(memberJID: nil, memberAvatar: nil)

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.kind, .individual)
        XCTAssertEqual(snapshot.name, "Historical Juliet")
        XCTAssertNil(snapshot.jid)
        XCTAssertNil(snapshot.avatarURL)
        XCTAssertEqual(snapshot.sourceGroup?.jid, "council@example.test")
        XCTAssertEqual(snapshot.sourceGroup?.avatarURL?.absoluteString, "https://example.test/group.png")
    }

    func testUnsafeMemberAvatarIsOmittedWithoutDiscardingMemberIdentity() {
        for uri in ["file:///tmp/avatar.png", "data:image/png;base64,AAAA", "javascript:alert(1)",
                    "https://example:synthetic@example.test/avatar.png"] {
            let forward = makeGroupForward(memberJID: "juliet@example.test", memberAvatar: uri)

            let snapshot = ForwardCardSnapshot.capture(forward)

            XCTAssertNil(snapshot.avatarURL, uri)
            XCTAssertEqual(snapshot.name, "Historical Juliet")
            XCTAssertEqual(snapshot.jid, "juliet@example.test")
            XCTAssertEqual(snapshot.sourceGroup?.jid, "council@example.test")
        }
    }

    func testGroupTitleAndExplicitMemberAddressDoNotInferPublicPrivacy() {
        let forward = makeGroupForward(memberJID: "juliet@example.test", privacy: nil)

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.jid, "juliet@example.test")
        XCTAssertEqual(snapshot.sourceGroup?.name, "Historical Council")
        XCTAssertNil(snapshot.sourceGroup?.privacy)
    }

    func testIndividualCardBoundToGroupAddressCannotSupplyOriginGroupPresentation() throws {
        let forward = makeGroupForward(memberJID: "juliet@example.test", privacy: nil)
        let member = try XCTUnwrap(forward.references.first { $0.kind == .groupchat })
        forward.references.removeAll()
        forward.references.append(member)
        forward.references.append(storedCard(jid: "council@example.test", name: "Fake Group Name",
                                             kind: .individual, avatarURI: "https://example.test/fake-group.png"))

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.name, "Historical Juliet")
        XCTAssertEqual(snapshot.jid, "juliet@example.test")
        XCTAssertEqual(snapshot.avatarURL?.absoluteString, "https://example.test/member.png")
        XCTAssertEqual(snapshot.sourceGroup?.jid, "council@example.test")
        XCTAssertEqual(snapshot.sourceGroup?.name, "council@example.test")
        XCTAssertNil(snapshot.sourceGroup?.avatarURL)
        XCTAssertNil(snapshot.sourceGroup?.privacy)
    }

    func testGroupCardWithoutMemberContextCapturesGroupSubject() {
        let forward = makeForward(jid: "council@example.test/server")
        forward.references.append(storedCard(jid: "council@example.test", name: "Council",
                                             kind: .group, privacy: .incognito,
                                             avatarURI: "https://example.test/group.png"))

        let snapshot = ForwardCardSnapshot.capture(forward)

        XCTAssertEqual(snapshot.kind, .group)
        XCTAssertEqual(snapshot.jid, "council@example.test")
        XCTAssertEqual(snapshot.name, "Council")
        XCTAssertEqual(snapshot.privacy, .incognito)
        XCTAssertEqual(snapshot.avatarURL?.absoluteString, "https://example.test/group.png")
        XCTAssertNil(snapshot.sourceGroup)
    }

    func testSourceGroupCardPreservesOwnerAndUsesOnlyGroupFields() throws {
        let snapshot = ForwardCardSnapshot.capture(makeGroupForward(memberJID: "juliet@example.test"))

        let group = try XCTUnwrap(snapshot.sourceGroupCard)

        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.owner, owner)
        XCTAssertEqual(group.jid, "council@example.test")
        XCTAssertEqual(group.name, "Historical Council")
        XCTAssertEqual(group.privacy, .incognito)
        XCTAssertEqual(group.avatarURL?.absoluteString, "https://example.test/group.png")
        XCTAssertNil(group.badge)
        XCTAssertNil(group.sourceGroup)
    }

    func testCapturedAuthorAndOriginRemainImmutableAfterSourceMutation() {
        let forward = makeGroupForward(memberJID: "juliet@example.test")
        let snapshot = ForwardCardSnapshot.capture(forward)

        forward.owner = "other-owner@example.test"
        forward.forwardJid = "different-group@example.test"
        forward.references.removeAll()
        forward.forwardNickname = "Changed sender"

        XCTAssertEqual(snapshot.owner, owner)
        XCTAssertEqual(snapshot.jid, "juliet@example.test")
        XCTAssertEqual(snapshot.name, "Historical Juliet")
        XCTAssertEqual(snapshot.sourceGroup?.jid, "council@example.test")
    }

    func testDescendantCardCannotSupplyParentAuthorIdentity() {
        let parent = makeForward(jid: "parent-author@example.test")
        parent.forwardNickname = "Parent Author"
        let child = makeForward(jid: "child-author@example.test")
        child.references.append(storedCard(jid: "parent-author@example.test", name: "Child assertion",
                                           avatarURI: "https://example.test/child.png"))
        parent.subforwards.append(child)

        let snapshot = ForwardCardSnapshot.capture(parent)

        XCTAssertEqual(snapshot.name, "Parent Author")
        XCTAssertEqual(snapshot.jid, "parent-author@example.test")
        XCTAssertNil(snapshot.avatarURL)
        XCTAssertNil(snapshot.sourceGroup)
    }

    func testForwardDisplaySnapshotAndAttachmentCarrySameImmutableCard() {
        let forward = makeGroupForward(memberJID: nil)
        let expected = ForwardCardSnapshot.capture(forward)
        let display = ChatMessageForwardSnapshot(forward)
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = "recipient@example.test"
        controller.conversationType = .regular

        let attachment = controller.mapAttachment(forward)

        XCTAssertEqual(display.forwardCard, expected)
        XCTAssertEqual(attachment.forwardCard, expected)
    }

    func testUnknownIndividualOffersAddContactAndKnownIndividualOffersOpenChat() throws {
        let snapshot = individual()
        let unknown = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: snapshot,
            hasContact: false, hasChat: false, hasGroup: false))
        let contact = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: snapshot,
            hasContact: true, hasChat: false, hasGroup: false))
        let chat = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: snapshot,
            hasContact: false, hasChat: true, hasGroup: false))

        XCTAssertEqual(unknown.kind, .addContact)
        XCTAssertTrue(unknown.isEnabled)
        XCTAssertEqual(contact.kind, .openChat)
        XCTAssertTrue(contact.isEnabled)
        XCTAssertEqual(chat.kind, .openChat)
    }

    func testAuthorWithoutAddressOffersOnlyKnownSourceGroup() throws {
        let unknown = individual(jid: nil)
        let groupMember = individual(jid: nil, sourceGroup: sourceGroup())

        XCTAssertNil(ForwardCardActionPolicy.primaryAction(for: unknown,
            hasContact: true, hasChat: true, hasGroup: true))
        let action = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: groupMember,
            hasContact: false, hasChat: false, hasGroup: true))
        XCTAssertEqual(action.kind, .openGroup)
        XCTAssertTrue(action.isEnabled)
        XCTAssertNil(ForwardCardActionPolicy.primaryAction(for: groupMember,
            hasContact: false, hasChat: false, hasGroup: false))
    }

    func testExplicitMemberAddressKeepsPersonActionAheadOfOriginGroupAction() throws {
        let snapshot = individual(sourceGroup: sourceGroup())

        let action = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: snapshot,
            hasContact: false, hasChat: false, hasGroup: true, groupAccess: .open))

        XCTAssertEqual(action.kind, .addContact)
    }

    func testKnownGroupOpensExistingChatEvenWhileAccessIsUnknown() throws {
        let action = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: groupCard(),
            hasContact: false, hasChat: false, hasGroup: true))

        XCTAssertEqual(action.kind, .openGroup)
        XCTAssertTrue(action.isEnabled)
    }

    func testGroupAccessMustBeResolvedBeforeOfferingJoin() throws {
        for access in [ForwardCardGroupAccess.unknown, .loading, .unavailable] {
            XCTAssertNil(ForwardCardActionPolicy.primaryAction(for: groupCard(),
                hasContact: false, hasChat: false, hasGroup: false, groupAccess: access))
        }
        let action = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: groupCard(),
            hasContact: false, hasChat: false, hasGroup: false, groupAccess: .open))

        XCTAssertEqual(action.kind, .joinGroup)
        XCTAssertTrue(action.isEnabled)
    }

    func testRestrictedGroupShowsDisabledRequestToJoin() throws {
        let action = try XCTUnwrap(ForwardCardActionPolicy.primaryAction(for: groupCard(),
            hasContact: false, hasChat: false, hasGroup: false, groupAccess: .restricted))

        XCTAssertEqual(action.kind, .requestToJoin)
        XCTAssertFalse(action.isEnabled)
    }

    func testSheetFactoryUsesCardOwnerForContactAndChatLookup() throws {
        let realm = try WRealm.safe()
        let snapshot = individual()
        let target = try XCTUnwrap(snapshot.jid)
        let foreignOwner = "foreign-owner@example.test"
        let foreignContact = makeRoster(owner: foreignOwner, jid: target)
        let foreignChat = LastChatsStorageItem()
        foreignChat.primary = LastChatsStorageItem.genPrimary(jid: target, owner: foreignOwner,
                                                             conversationType: .regular)
        foreignChat.owner = foreignOwner
        foreignChat.jid = target
        foreignChat.conversationType = .regular
        let controller = ChatViewController()
        controller.owner = foreignOwner
        controller.jid = "recipient@example.test"
        controller.conversationType = .regular
        try realm.write { realm.add(foreignContact); realm.add(foreignChat) }

        let unknown = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(unknown.snapshot.owner, owner)
        XCTAssertEqual(unknown.primaryAction?.kind, .addContact)

        try realm.write { realm.add(makeRoster(owner: owner, jid: target)) }
        let known = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(known.snapshot.owner, owner)
        XCTAssertEqual(known.primaryAction?.kind, .openChat)
    }

    func testSheetFactoryUsesCardOwnerForCanonicalGroupMembership() throws {
        let realm = try WRealm.safe()
        let snapshot = groupCard()
        let target = try XCTUnwrap(snapshot.jid)
        let foreignOwner = "foreign-owner@example.test"
        let controller = ChatViewController()
        controller.owner = foreignOwner
        controller.jid = "recipient@example.test"
        controller.conversationType = .regular
        try realm.write { realm.add(makeMembership(owner: foreignOwner, jid: target)) }

        let unknown = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(unknown.snapshot.owner, owner)
        XCTAssertNil(unknown.primaryAction)

        try realm.write { realm.add(makeMembership(owner: owner, jid: target)) }
        let known = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(known.snapshot.owner, owner)
        XCTAssertEqual(known.primaryAction?.kind, .openGroup)
        XCTAssertEqual(known.primaryAction?.isEnabled, true)
    }

    func testSheetFactoryDoesNotTreatRosterPlaceholderAsSavedContact() throws {
        let realm = try WRealm.safe()
        let snapshot = individual()
        let target = try XCTUnwrap(snapshot.jid)
        let placeholder = makeRoster(owner: owner, jid: target)
        placeholder.isContact = false
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = "recipient@example.test"
        controller.conversationType = .regular
        try realm.write { realm.add(placeholder) }

        let unknown = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(unknown.primaryAction?.kind, .addContact)

        try realm.write { placeholder.isContact = true }
        let known = controller.makeForwardCardInfoController(for: snapshot)

        XCTAssertEqual(known.primaryAction?.kind, .openChat)
    }

    func testSheetFactoryUsesDismissiblePageSheetAndLimitedContactHeader() throws {
        let snapshot = individual(name: "Historical Juliet", badge: "Architect")
        let navigation = ForwardCardInfoViewController.makeNavigationController(
            snapshot: snapshot, primaryAction: .init(kind: .addContact),
            onAction: { _ in }, onOpenGroup: {})
        let controller = try XCTUnwrap(navigation.viewControllers.first as? ForwardCardInfoViewController)

        controller.loadViewIfNeeded()

        XCTAssertEqual(navigation.modalPresentationStyle, .pageSheet)
        XCTAssertEqual(navigation.sheetPresentationController?.selectedDetentIdentifier, .large)
        XCTAssertFalse(navigation.isModalInPresentation)
        XCTAssertEqual(controller.snapshot, snapshot)
        XCTAssertEqual(controller.headerView.titleButton.title(for: .normal), "Historical Juliet")
        XCTAssertEqual(controller.headerView.subtitleLabel.text, "juliet@example.test")
        XCTAssertTrue(controller.headerView.supportButtonsStack.arrangedSubviews.isEmpty)
        XCTAssertFalse(controller.headerView.showButtons)
        let rows = tableRows(in: controller)
        let button = try XCTUnwrap(controller.primaryActionButton)
        let actionRow = try XCTUnwrap(rows.first { button.isDescendant(of: $0.cell.contentView) })
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 2)
        XCTAssertEqual(controller.tableView(controller.tableView,
            numberOfRowsInSection: actionRow.indexPath.section), 1)
        XCTAssertTrue(rows.filter { $0.indexPath.section != actionRow.indexPath.section }
            .contains { $0.cell.accessibilityIdentifier == "forward_card_jid" })
        XCTAssertNotNil(controller.navigationItem.rightBarButtonItem)
        XCTAssertEqual(controller.view.accessibilityIdentifier, "forward_card_sheet")
    }

    func testAuthorTapMakesPresentedCardModalAndHidesOnlyPresentingChat() throws {
        let chat = ChatViewController()
        chat.owner = owner
        chat.jid = "recipient@example.test"
        chat.conversationType = .regular
        let navigation = UINavigationController(rootViewController: chat)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let currentControllerAccess = ModalPresentationCurrentControllerAccess.application
        let previousPresentedController = currentControllerAccess.get()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            (chat.presentedViewController as? UINavigationController)?
                .viewControllers.compactMap { $0 as? ForwardCardInfoViewController }.first?.dismissSheet()
            chat.performTerminalChatResourceTeardownForTesting()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            currentControllerAccess.set(previousPresentedController)
        }
        chat.loadViewIfNeeded()
        navigation.view.layoutIfNeeded()
        settlePresentationLayout()
        chat.archiveWindowState = .authoritativeEmpty(target: .latest,
            freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: "forward-card-fixture-empty"))
        chat.archiveWindowCommittedCoverageGeneration = 0
        chat.setSkeletonVisible(false)
        chat.isInSelectionMode.accept(false)
        let snapshot = individual()
        let attachment = messageAttachment(author: snapshot.name, jid: try XCTUnwrap(snapshot.jid))
        attachment.forwardCard = snapshot
        chat.datasource = [presentationRow(attachment: attachment)]
        XCTAssertFalse(chat.view.accessibilityViewIsModal)
        XCTAssertFalse(chat.view.accessibilityElementsHidden)

        chat.didTapOnForwardAuthor(message: attachment.primary, card: snapshot)
        settlePresentationLayout()

        let modalNavigation = try XCTUnwrap(chat.presentedViewController as? UINavigationController)
        let card = try XCTUnwrap(modalNavigation.viewControllers.first as? ForwardCardInfoViewController)
        XCTAssertEqual(modalNavigation.modalPresentationStyle, .pageSheet)
        XCTAssertEqual(modalNavigation.sheetPresentationController?.selectedDetentIdentifier, .large)
        XCTAssertTrue(card.view.accessibilityViewIsModal)
        XCTAssertTrue(chat.view.accessibilityElementsHidden)
        XCTAssertFalse(chat.view.accessibilityViewIsModal)
    }

    func testEnabledPrimaryButtonRoutesExactlyChosenAction() throws {
        var routed: [ForwardCardAction] = []
        let controller = ForwardCardInfoViewController(snapshot: individual(),
            primaryAction: .init(kind: .openChat), onAction: { routed.append($0) }, onOpenGroup: {})
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(controller.primaryActionButton)
        let rows = tableRows(in: controller)
        XCTAssertEqual(rows.filter { button.isDescendant(of: $0.cell.contentView) }.count, 1)

        button.sendActions(for: .touchUpInside)

        XCTAssertEqual(routed, [.openChat])
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertEqual(button.accessibilityIdentifier, "forward_card_primary_open_chat")
    }

    func testDisabledRequestCannotRouteEvenWhenInvokedProgrammatically() throws {
        var routed: [ForwardCardAction] = []
        let controller = ForwardCardInfoViewController(snapshot: groupCard(),
            primaryAction: .init(kind: .requestToJoin, isEnabled: false),
            onAction: { routed.append($0) }, onOpenGroup: {})
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(controller.primaryActionButton)

        controller.performPrimaryAction()
        button.sendActions(for: .touchUpInside)

        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(routed.isEmpty)
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertEqual(button.accessibilityIdentifier, "forward_card_primary_request_to_join")
    }

    func testSourceGroupPillRoutesSeparateGroupAction() throws {
        var openedGroups = 0
        var actions: [ForwardCardAction] = []
        let controller = ForwardCardInfoViewController(snapshot: individual(sourceGroup: sourceGroup()),
            primaryAction: .init(kind: .addContact), onAction: { actions.append($0) },
            onOpenGroup: { openedGroups += 1 })
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(controller.sourceGroupButton)
        let actionButton = try XCTUnwrap(controller.primaryActionButton)
        let rows = tableRows(in: controller)
        let sourceRow = try XCTUnwrap(rows.first { button.isDescendant(of: $0.cell.contentView) })
        let actionRow = try XCTUnwrap(rows.first { actionButton.isDescendant(of: $0.cell.contentView) })
        let detailRow = try XCTUnwrap(rows.first { $0.cell.accessibilityIdentifier == "forward_card_jid" })
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 3)
        XCTAssertEqual(Set([sourceRow.indexPath.section, actionRow.indexPath.section,
                           detailRow.indexPath.section]).count, 3)
        XCTAssertEqual(controller.tableView(controller.tableView,
            numberOfRowsInSection: actionRow.indexPath.section), 1)

        button.sendActions(for: .touchUpInside)

        XCTAssertEqual(openedGroups, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(button.accessibilityIdentifier, "forward_card_source_group")
    }

    func testSourceGroupPillReparentingDoesNotAccumulateOwnedHeightConstraints() throws {
        let controller = ForwardCardInfoViewController(snapshot: individual(sourceGroup: sourceGroup()),
            primaryAction: nil, onAction: { _ in }, onOpenGroup: {})
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(controller.sourceGroupButton)
        let path = IndexPath(row: 0, section: 0)
        let firstCell = controller.tableView(controller.tableView, cellForRowAt: path)
        let firstCount = button.constraints.filter {
            $0.firstAttribute == .height && ($0.firstItem as? UIView) === button && $0.secondItem == nil
        }.count

        let secondCell = controller.tableView(controller.tableView, cellForRowAt: path)
        let secondCount = button.constraints.filter {
            $0.firstAttribute == .height && ($0.firstItem as? UIView) === button && $0.secondItem == nil
        }.count

        XCTAssertGreaterThan(firstCount, 0)
        XCTAssertEqual(secondCount, firstCount)
        withExtendedLifetime((firstCell, secondCell)) {}
    }

    func testMissingAddressAndOriginOmitControlsInsteadOfInventingTargets() {
        var actions: [ForwardCardAction] = []
        var openedGroups = 0
        let controller = ForwardCardInfoViewController(snapshot: individual(jid: nil),
            primaryAction: nil, onAction: { actions.append($0) },
            onOpenGroup: { openedGroups += 1 })
        controller.loadViewIfNeeded()

        controller.performPrimaryAction()
        controller.openSourceGroup()

        XCTAssertTrue(controller.headerView.subtitleLabel.text?.isEmpty != false)
        XCTAssertNil(controller.primaryActionButton)
        XCTAssertNil(controller.sourceGroupButton)
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 0)
        XCTAssertTrue(controller.headerView.supportButtonsStack.arrangedSubviews.isEmpty)
        XCTAssertFalse(controller.headerView.showButtons)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(openedGroups, 0)
    }

    func testUnavailableMemberHeaderDoesNotDisplayGroupRoutingAddress() {
        let controller = ForwardCardInfoViewController(snapshot: individual(jid: nil, sourceGroup: sourceGroup()),
            primaryAction: nil, onAction: { _ in }, onOpenGroup: {})

        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.headerView.subtitleLabel.text?.isEmpty != false)
        XCTAssertNotNil(controller.sourceGroupButton)
    }

    func testUpdatingActionCannotLeavePreviouslyEnabledJoinActive() throws {
        var actions: [ForwardCardAction] = []
        let controller = ForwardCardInfoViewController(snapshot: groupCard(),
            primaryAction: .init(kind: .joinGroup), onAction: { actions.append($0) }, onOpenGroup: {})
        controller.loadViewIfNeeded()
        let previousJoinButton = try XCTUnwrap(controller.primaryActionButton)
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 2)

        controller.updatePrimaryAction(.init(kind: .requestToJoin, isEnabled: false))
        let disabledButton = try XCTUnwrap(controller.primaryActionButton)
        let disabledRows = tableRows(in: controller)
        XCTAssertEqual(disabledRows.filter { disabledButton.isDescendant(of: $0.cell.contentView) }.count, 1)
        XCTAssertEqual(disabledButton.accessibilityIdentifier, "forward_card_primary_request_to_join")
        XCTAssertFalse(disabledButton.isEnabled)
        controller.performPrimaryAction()
        controller.updatePrimaryAction(.init(kind: .openGroup))
        previousJoinButton.sendActions(for: .touchUpInside)
        disabledButton.sendActions(for: .touchUpInside)
        controller.updatePrimaryAction(nil)
        controller.performPrimaryAction()

        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(controller.primaryActionButton)
        XCTAssertEqual(controller.numberOfSections(in: controller.tableView), 1)
        XCTAssertFalse(tableRows(in: controller).contains { disabledButton.isDescendant(of: $0.cell.contentView) })
        XCTAssertTrue(controller.headerView.supportButtonsStack.arrangedSubviews.isEmpty)
        XCTAssertFalse(controller.headerView.showButtons)
    }

    func testSameTargetSnapshotUpdateClearsUnavailableMetadataAndKeepsOwner() {
        let controller = ForwardCardInfoViewController(snapshot: individual(name: "Old Name", badge: "Old Badge"),
            primaryAction: nil, onAction: { _ in }, onOpenGroup: {})
        controller.loadViewIfNeeded()
        let replacement = individual(name: "Current Name")

        controller.updateSnapshot(replacement)

        XCTAssertEqual(controller.snapshot, replacement)
        XCTAssertEqual(controller.snapshot.owner, owner)
        XCTAssertNil(controller.snapshot.badge)
        XCTAssertEqual(controller.headerView.titleButton.title(for: .normal), "Current Name")
        XCTAssertFalse(allRenderedTexts(in: controller.view).contains("Old Badge"))
    }

    func testSnapshotRefreshCannotChangeCardOwnerOrTarget() {
        let original = individual()
        let controller = ForwardCardInfoViewController(snapshot: original,
            primaryAction: nil, onAction: { _ in }, onOpenGroup: {})
        controller.loadViewIfNeeded()

        controller.updateSnapshot(ForwardCardSnapshot(kind: .individual,
            owner: "foreign-owner@example.test", name: "Foreign", jid: original.jid))
        controller.updateSnapshot(individual(jid: "foreign-target@example.test"))

        XCTAssertEqual(controller.snapshot, original)
    }

    func testSyntheticCardPagesKeepHeaderActionsAndOriginPillReachableAtIPhoneSize() throws {
        let variants: [(String, ForwardCardSnapshot, ForwardCardPrimaryAction, UIContentSizeCategory)] = [
            ("individual", individual(name: "Juliet Capulet", badge: "Architect"),
             .init(kind: .addContact), .large),
            ("incognito-member", individual(name: "Technical Penguin 4", jid: nil, sourceGroup: sourceGroup()),
             .init(kind: .openGroup), .large),
            ("restricted-group", ForwardCardSnapshot(kind: .group, owner: owner,
                name: "Secret Council", jid: "council@example.test", privacy: .incognito),
             .init(kind: .requestToJoin, isEnabled: false), .large),
            ("restricted-group-accessibility", ForwardCardSnapshot(kind: .group, owner: owner,
                name: "Secret Council", jid: "council@example.test", privacy: .incognito),
             .init(kind: .requestToJoin, isEnabled: false), .accessibilityExtraExtraExtraLarge)
        ]

        for (name, snapshot, action, contentSize) in variants {
            XCTAssertNil(snapshot.avatarURL)
            XCTAssertNil(snapshot.sourceGroup?.avatarURL)
            let navigation = ForwardCardInfoViewController.makeNavigationController(
                snapshot: snapshot, primaryAction: action, onAction: { _ in }, onOpenGroup: {})
            let controller = try XCTUnwrap(navigation.viewControllers.first as? ForwardCardInfoViewController)
            navigation.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: contentSize),
                                                  forChild: controller)
            controller.loadViewIfNeeded()
            let button = try XCTUnwrap(controller.primaryActionButton)
            let rows = tableRows(in: controller)
            let actionIndexPath = try XCTUnwrap(rows.first {
                button.isDescendant(of: $0.cell.contentView)
            }?.indexPath)
            let sourceIndexPath = rows.first {
                controller.sourceGroupButton?.isDescendant(of: $0.cell.contentView) == true
            }?.indexPath
            controller.tableView.reloadData()
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
                ?? UIApplication.shared.windows.first { $0.isKeyWindow }
            let window = scene.map(UIWindow.init(windowScene:))
                ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = .light
            let host = UIViewController()
            host.view.backgroundColor = .systemBackground
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKeyAndVisible()
            }
            host.loadViewIfNeeded()
            host.view.layoutIfNeeded()
            settlePresentationLayout()
            host.present(navigation, animated: false)
            settlePresentationLayout()
            XCTAssertTrue(navigation.presentingViewController === host, name)
            XCTAssertTrue(navigation.view.window === window, name)
            navigation.loadViewIfNeeded()
            XCTAssertEqual(navigation.sheetPresentationController?.selectedDetentIdentifier, .large, name)
            window.layoutIfNeeded()
            navigation.view.setNeedsLayout()
            navigation.view.layoutIfNeeded()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            controller.tableView.reloadData()
            controller.tableView.layoutIfNeeded()
            controller.headerView.layoutIfNeeded()

            controller.tableView.scrollToRow(at: actionIndexPath, at: .middle, animated: false)
            settlePresentationLayout()
            window.layoutIfNeeded()
            navigation.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            controller.tableView.layoutIfNeeded()
            controller.headerView.layoutIfNeeded()
            button.setNeedsLayout()
            button.layoutIfNeeded()
            let actionFrame = button.convert(button.bounds, to: navigation.view)
            XCTAssertGreaterThan(controller.tableView.bounds.width, 0, name)
            XCTAssertGreaterThan(controller.headerView.frame.height, 0, name)
            XCTAssertGreaterThan(actionFrame.width, 0, name)
            XCTAssertGreaterThan(actionFrame.height, 0, name)
            XCTAssertTrue(navigation.view.bounds.intersects(actionFrame), "Primary action is outside the viewport: \(name)")
            XCTAssertGreaterThanOrEqual(actionFrame.minX, navigation.view.bounds.minX - 1, name)
            XCTAssertLessThanOrEqual(actionFrame.maxX, navigation.view.bounds.maxX + 1, name)
            XCTAssertEqual(button.isEnabled, action.isEnabled)
            XCTAssertTrue(button.isAccessibilityElement)
            XCTAssertTrue(button.accessibilityTraits.contains(.button))
            XCTAssertFalse(button.isDescendant(of: controller.headerView))
            XCTAssertTrue(controller.headerView.supportButtonsStack.arrangedSubviews.isEmpty)
            XCTAssertFalse(controller.headerView.showButtons)
            XCTAssertTrue(controller.headerView.titleButton.titleLabel?.adjustsFontForContentSizeCategory == true)
            let actionCell = try XCTUnwrap(controller.tableView.cellForRow(at: actionIndexPath))
            XCTAssertTrue(button.isDescendant(of: actionCell.contentView), name)
            let buttonFrame = button.convert(button.bounds, to: actionCell.contentView)
            XCTAssertEqual(buttonFrame.minX, actionCell.contentView.bounds.minX, accuracy: 1, name)
            XCTAssertEqual(buttonFrame.maxX, actionCell.contentView.bounds.maxX, accuracy: 1, name)
            XCTAssertGreaterThanOrEqual(buttonFrame.height, 44, name)
            let titleLabel = try XCTUnwrap(button.titleLabel)
            XCTAssertTrue(titleLabel.text?.isEmpty == false, name)
            XCTAssertTrue(titleLabel.adjustsFontForContentSizeCategory, name)
            XCTAssertEqual(titleLabel.numberOfLines, 0, name)

            if snapshot.sourceGroup != nil {
                let path = try XCTUnwrap(sourceIndexPath)
                controller.tableView.scrollToRow(at: path, at: .middle, animated: false)
                controller.tableView.layoutIfNeeded()
                let pill = try XCTUnwrap(controller.sourceGroupButton)
                let pillFrame = pill.convert(pill.bounds, to: navigation.view)
                XCTAssertGreaterThan(pillFrame.height, 0)
                XCTAssertTrue(navigation.view.bounds.intersects(pillFrame))
                XCTAssertEqual(pill.accessibilityIdentifier, "forward_card_source_group")
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.preferredRange = .standard
            settlePresentationLayout()
            var renderedHierarchy = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                renderedHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(renderedHierarchy, "Window hierarchy could not render: \(name)")
            XCTAssertTrue(hasVisibleSnapshotContent(image), "Snapshot is blank or monochrome: \(name)")
            let attachment = XCTAttachment(image: image)
            attachment.name = "forward-card-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let png = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(png.count, 1_000)
            let directory = URL(fileURLWithPath: "/tmp/xabber-forward-card-20261008", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                try? png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
            }
        }
    }

    private func tableRows(in controller: ForwardCardInfoViewController)
        -> [(indexPath: IndexPath, cell: UITableViewCell)] {
        let table = controller.tableView
        return (0..<controller.numberOfSections(in: table)).flatMap { section in
            (0..<controller.tableView(table, numberOfRowsInSection: section)).map { row in
                let indexPath = IndexPath(row: row, section: section)
                return (indexPath, controller.tableView(table, cellForRowAt: indexPath))
            }
        }
    }

    private func settlePresentationLayout() {
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func hasVisibleSnapshotContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let sampled = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard sampled else { return false }
        var colors = Set<UInt32>()
        var brightPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = UInt32(pixels[index])
            let green = UInt32(pixels[index + 1])
            let blue = UInt32(pixels[index + 2])
            colors.insert((red << 16) | (green << 8) | blue)
            if red + green + blue > 300 { brightPixels += 1 }
        }
        return colors.count > 8 && brightPixels > side
    }

    private func makeInlineView(author: String, jid: String) -> InlineMessageAttachmentView {
        let view = InlineMessageAttachmentView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        view.setupSubviews()
        view.delegate = delegate
        let attachment = messageAttachment(author: author, jid: jid)
        if !author.isEmpty, !jid.isEmpty {
            attachment.forwardCard = individual(name: author, jid: jid)
        }
        view.configure(attachment, palette: .blue)
        return view
    }

    private func messageAttachment(author: String, jid: String) -> MessageAttachment {
        MessageAttachment(
            primary: "forward-author",
            author: author,
            jid: jid,
            outgoing: false,
            textMessage: NSAttributedString(string: "Forwarded body"),
            images: [], videos: [], files: [], audios: [],
            timeMarker: NSAttributedString(string: ""),
            subforwards: []
        )
    }

    private func presentationRow(attachment: MessageAttachment) -> ChatViewController.Datasource {
        ChatViewController.Datasource(primary: "carrier", jid: "recipient@example.test", owner: owner,
            outgoing: false, sender: Sender(id: "relay@example.test", displayName: "Relay"),
            messageId: "carrier", sentDate: Date(timeIntervalSince1970: 1), editDate: nil,
            kind: .attributedText(NSAttributedString(string: "")), withAuthor: false, withAvatar: false,
            error: false, errorType: "", canPinMessage: false, canEditMessage: false,
            canDeleteMessage: false, forwards: [attachment], isOutgoing: false, isEdited: false,
            groupchatAuthorRole: "", groupchatAuthorId: "", groupchatAuthorNickname: "",
            groupchatAuthorBadge: "", isHasAttachedMessages: true, isDownloaded: true,
            state: .none, searchString: nil, burnDate: -1, afterburnInterval: -1,
            archivedId: nil, queryIds: nil, isRead: true,
            images: [], videos: [], files: [], audios: [],
            timeMarkerText: NSAttributedString(string: ""), indicator: .none, avatarUrl: nil)
    }

    private func individual(name: String = "Juliet", jid: String? = "juliet@example.test",
                            badge: String? = nil, sourceGroup: ForwardCardGroupSnapshot? = nil) -> ForwardCardSnapshot {
        ForwardCardSnapshot(kind: .individual, owner: owner, name: name,
                            jid: jid, badge: badge, sourceGroup: sourceGroup)
    }

    private func sourceGroup() -> ForwardCardGroupSnapshot {
        ForwardCardGroupSnapshot(jid: "council@example.test", name: "Council", privacy: .incognito)
    }

    private func groupCard() -> ForwardCardSnapshot {
        ForwardCardSnapshot(kind: .group, owner: owner, name: "Council", jid: "council@example.test")
    }

    private func makeRoster(owner: String, jid: String) -> RosterStorageItem {
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        roster.owner = owner
        roster.jid = jid
        roster.isContact = true
        return roster
    }

    private func makeMembership(owner: String, jid: String) -> GroupSelfMembershipStorageItem {
        let membership = GroupSelfMembershipStorageItem()
        membership.primary = GroupStorageKey.groupPrimary(owner: owner, groupJID: jid)
        membership.owner = owner
        membership.groupJID = jid
        membership.stateRaw = GroupSelfMembershipState.both.rawValue
        return membership
    }

    private func makeForward(jid: String) -> MessageForwardsInlineStorageItem {
        let forward = MessageForwardsInlineStorageItem()
        forward.primary = "forward-\(UUID().uuidString)"
        forward.messageId = "original"
        forward.owner = owner
        forward.jid = "recipient@example.test"
        forward.opponent = "recipient@example.test"
        forward.forwardJid = jid
        forward.body = "Original body"
        return forward
    }

    private func makeGroupForward(memberJID: String?, memberAvatar: String? = "https://example.test/member.png",
                                  privacy: ForwardContactCard.Privacy? = .incognito) -> MessageForwardsInlineStorageItem {
        let forward = makeForward(jid: "council@example.test/server")
        let member = MessageReferenceStorageItem()
        member.kind = .groupchat
        var metadata: [String: Any] = ["id": "member-7", "nickname": "Historical Juliet",
                                       "badge": "Architect", "role": "owner"]
        if let memberJID { metadata["jid"] = memberJID }
        if let memberAvatar { metadata["avatar_uri"] = memberAvatar }
        member.metadata = metadata
        forward.references.append(member)
        forward.references.append(storedCard(jid: "council@example.test", name: "Historical Council",
                                             kind: .group, privacy: privacy,
                                             avatarURI: "https://example.test/group.png"))
        return forward
    }

    private func storedCard(jid: String, name: String, kind: ForwardContactCard.Kind = .individual,
                            privacy: ForwardContactCard.Privacy? = nil,
                            avatarURI: String? = nil) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = "card-\(UUID().uuidString)"
        reference.owner = owner
        reference.kind = .forwardContactData
        reference.metadata = ForwardContactDataCodec.metadata(for: ForwardContactCard(
            jid: jid, name: name, nickname: nil, kind: kind, privacy: privacy, avatarURI: avatarURI))
        return reference
    }

    private func allRenderedTexts(in view: UIView) -> [String] {
        let text = (view as? UILabel)?.text.map { [$0] } ?? []
        return text + view.subviews.flatMap { allRenderedTexts(in: $0) }
    }
}

private final class ForwardInfoCardDelegateSpy: MessageCellDelegate {
    var messagePrimaries: [String] = []
    var cards: [ForwardCardSnapshot] = []
    var contacts: [ContactAttachment] = []
    var inSelection = false
    func didTapOnForwardAuthor(message messagePrimary: String, card: ForwardCardSnapshot) {
        messagePrimaries.append(messagePrimary)
        cards.append(card)
    }
    func didTap(in cell: MessageCollectionViewCell) {}
    func didTapMessage(in cell: MessageCollectionViewCell) {}
    func didTapAvatar(in cell: MessageCollectionViewCell) {}
    func didTapCellTopLabel(in cell: MessageCollectionViewCell) {}
    func didTapMessageTopLabel(in cell: MessageCollectionViewCell) {}
    func didTapMessageBottomLabel(in cell: MessageCollectionViewCell) {}
    func onTapAttachment(cell: MessageCollectionViewCell, inlineItem: Bool, messageId: String?, index: Int, isSubforward: Bool) {}
    func onTapVoiceCall(cell: MessageCollectionViewCell) {}
    func onLongTap(cell: MessageCollectionViewCell) {}
    func onLongTapMessage(cell: MessageCollectionViewCell) {}
    func onSwipe(cell: MessageCollectionViewCell) {}
    func didTapErrorButton(cell: MessageCollectionViewCell) {}
    func didTapOnInitialFooterLabel(in cell: MessageCollectionViewCell) {}
    func isInSelection() -> Bool { inSelection }
    func didTapOnFile(url: URL) {}
    func didTapOnPhoto(message messagePrimary: String, urls: [URL], url: URL, referencePrimary: String, isSensitive: Bool) {}
    func didTapOnVideo(message messagePrimary: String, url: URL?, referencePrimary: String, isSensitive: Bool) {}
    func didTapOnLocation(message messagePrimary: String, referencePrimary: String, coordinate: CLLocationCoordinate2D,
                          address: String?, geoURI: String) {}
    func didTapOnContact(message messagePrimary: String, contact: ContactAttachment) { contacts.append(contact) }
    func didTapOnAudio(_ audioView: InlineAudiosGridView.AudioView?, url: URL?) {}
    func didStopPlayingAudioCell() {}
    func canChangeAudioPosition(for referencePrimary: String) -> Bool { false }
    func didSetAudioPosition(_ audioView: InlineAudiosGridView.AudioView?, percentage: Float) -> TimeInterval { 0 }
    func isSelected(primary: String) -> Bool { false }
}
