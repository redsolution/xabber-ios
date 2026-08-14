import XCTest
import XMPPFramework
import RealmSwift
@testable import xabber

final class GroupLegacyXMLHardCutTests: XCTestCase {
    func testComposerMentionAllCandidateProducesExplicitIntentWithoutMemberReference() {
        let candidate = ComposerMentionCandidate.mentionAll(groupJID: "stage@example.com")
        let attributed = NSMutableAttributedString(string: "Ping ")
        attributed.append(NSAttributedString(
            string: "@all",
            attributes: [.composerMention: candidate.mentionEntity]
        ))

        let payload = ComposerMentionSerializer.payload(from: attributed)

        XCTAssertEqual(payload.body, "Ping @all")
        XCTAssertEqual(payload.groupMentionIntent, .all)
        XCTAssertTrue(payload.references.isEmpty)
        XCTAssertTrue(candidate.isMentionAll)
        XCTAssertEqual(candidate.uri, "xmpp:stage@example.com?members")
    }

    func testComposerMemberMentionProducesStableMemberIntentAndReference() throws {
        let candidate = ComposerMentionCandidate(
            memberId: "member-7",
            nickname: "Mercutio",
            uri: "xmpp:stage@example.com?members;id=member-7",
            node: nil,
            jid: nil,
            secondaryText: "member-7"
        )
        let attributed = NSMutableAttributedString(string: "Ping ")
        attributed.append(NSAttributedString(
            string: "@Mercutio",
            attributes: [.composerMention: candidate.mentionEntity]
        ))

        let payload = ComposerMentionSerializer.payload(from: attributed)
        let reference = try XCTUnwrap(payload.references.first)

        XCTAssertEqual(payload.groupMentionIntent, .members(["member-7"]))
        XCTAssertEqual(payload.references.count, 1)
        XCTAssertEqual(
            reference.metadata?["memberId"] as? String,
            "member-7"
        )
    }

    func testPlainComposerTextKeepsGroupMentionIntentAbsent() {
        let payload = ComposerMentionSerializer.payload(
            from: NSAttributedString(string: "Ping everyone")
        )

        XCTAssertEqual(payload.groupMentionIntent, .absent)
        XCTAssertTrue(payload.references.isEmpty)
    }

    func testComposerMentionAllSuggestionIsVisibleOnlyToAdminOrOwner() {
        XCTAssertFalse(ComposerMentionAllPolicy.canPresent(senderRole: nil))
        XCTAssertFalse(ComposerMentionAllPolicy.canPresent(senderRole: .member))
        XCTAssertTrue(ComposerMentionAllPolicy.canPresent(senderRole: .admin))
        XCTAssertTrue(ComposerMentionAllPolicy.canPresent(senderRole: .owner))
    }

    func testCanonicalMentionsCodecDistinguishesAbsenceMembersAndMentionAll() throws {
        let absent = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <body>Hello</body>
        </message>
        """)
        let members = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <mentions xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'/>
            <user id='member-8'/>
          </mentions>
          <body>Hello</body>
        </message>
        """)
        let all = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <mentions xmlns='https://xabber.com/protocol/groups'/>
          <body>Hello everyone</body>
        </message>
        """)

        XCTAssertEqual(GroupMessageMentionsCodec.decode(from: absent), .absent)
        XCTAssertEqual(
            GroupMessageMentionsCodec.decode(from: members),
            .members(["member-7", "member-8"])
        )
        XCTAssertEqual(GroupMessageMentionsCodec.decode(from: all), .all)
    }

    func testCanonicalMentionsCodecRejectsAmbiguousOrNonCanonicalContainers() throws {
        let malformedXML = [
            """
            <message type='chat' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='https://xabber.com/protocol/groups'><user id='member-7'/></mentions>
              <mentions xmlns='https://xabber.com/protocol/groups'><user id='member-8'/></mentions>
            </message>
            """,
            """
            <message type='chat' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='https://xabber.com/protocol/groups'><user id='member-7'/><user id='member-7'/></mentions>
            </message>
            """,
            """
            <message type='chat' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='https://xabber.com/protocol/groups'><user id=' '/></mentions>
            </message>
            """,
            """
            <message type='chat' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='https://xabber.com/protocol/groups'><member id='member-7'/></mentions>
            </message>
            """,
            """
            <message type='headline' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='https://xabber.com/protocol/groups'/>
            </message>
            """,
            """
            <message type='chat' from='stage@example.com' to='romeo@example.com'>
              <mentions xmlns='http://xabber.com/protocol/groupchat'><user id='member-7'/></mentions>
            </message>
            """
        ]
        let malformed = try malformedXML.map { try makeMessage($0) }

        for message in malformed {
            XCTAssertEqual(GroupMessageMentionsCodec.decode(from: message), .invalid, message.xmlString)
        }

        let nested = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <mentions><user id='forged-member'/></mentions>
          </x>
        </message>
        """)
        XCTAssertEqual(GroupMessageMentionsCodec.decode(from: nested), .absent)
    }

    func testOutgoingMentionAllRequiresPrivilegedRoleAndCapabilityCannotBypassIt() throws {
        let item = MessageStorageItem()

        XCTAssertNil(item.createMentionsElement(), "Absence must not serialize a mentions element")

        item.groupMentionIntent = .all
        item.groupMentionSenderRole = .member
        XCTAssertNil(item.createMentionsElement())

        item.groupMentionAllCapabilityGranted = true
        XCTAssertNil(item.createMentionsElement())

        item.groupMentionAllCapabilityGranted = false
        item.groupMentionSenderRole = .admin
        XCTAssertNotNil(item.createMentionsElement())

        item.groupMentionSenderRole = .owner
        XCTAssertNotNil(item.createMentionsElement())
    }

    func testMentionAllIntentRoleAndCapabilitySurviveRealmPersistenceForRetry() throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.schemaVersion = XabberRealmSchema.current
        let realm = try Realm(configuration: configuration)
        let item = MessageStorageItem()
        item.primary = "message-primary"
        item.groupMentionIntent = .all
        item.groupMentionSenderRole = .admin
        item.groupMentionAllCapabilityGranted = true

        try realm.write {
            realm.add(item)
        }
        let stored = try XCTUnwrap(
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "message-primary")
        )

        XCTAssertEqual(stored.groupMentionIntent, .all)
        XCTAssertEqual(stored.groupMentionSenderRole, .admin)
        XCTAssertTrue(stored.groupMentionAllCapabilityGranted)
        let mentions = try XCTUnwrap(stored.createMentionsElement())
        XCTAssertEqual(mentions.name, "mentions")
        XCTAssertEqual(mentions.xmlns(), "https://xabber.com/protocol/groups")
        XCTAssertTrue(mentions.elements(forName: "user").isEmpty)
    }

    func testRetrySenderForwardsPersistedMentionAuthorizationSnapshot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sender = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/messages_manager/MessageManager+CommonSender.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(sender.contains("groupMentionIntent: instance.groupMentionIntent"))
        XCTAssertTrue(sender.contains("groupMentionSenderRole: instance.groupMentionSenderRole"))
        XCTAssertTrue(sender.contains("groupMentionAllCapabilityGranted: instance.groupMentionAllCapabilityGranted"))
    }

    func testOutgoingMemberMentionsUseStableMemberIDsAndNeverImplyMentionAll() throws {
        let explicit = MessageReferenceStorageItem()
        explicit.kind = .mention
        explicit.metadata = [
            "memberId": "member-7",
            "uri": "xmpp:stage@example.com?members;id=member-7"
        ]
        let canonicalURI = MessageReferenceStorageItem()
        canonicalURI.kind = .mention
        canonicalURI.metadata = [
            "uri": "xmpp:stage@example.com?members;id=member-8"
        ]
        let duplicate = MessageReferenceStorageItem()
        duplicate.kind = .mention
        duplicate.metadata = ["memberId": "member-7"]
        let legacyURI = MessageReferenceStorageItem()
        legacyURI.kind = .mention
        legacyURI.metadata = ["uri": "xmpp:stage@example.com?id=legacy-jid-shaped-value"]
        let legacyURIWithMemberID = MessageReferenceStorageItem()
        legacyURIWithMemberID.kind = .mention
        legacyURIWithMemberID.metadata = [
            "memberId": "member-9",
            "uri": "xmpp:stage@example.com?id=member-9"
        ]
        let resourceURI = MessageReferenceStorageItem()
        resourceURI.kind = .mention
        resourceURI.metadata = [
            "memberId": "member-10",
            "uri": "xmpp:stage@example.com/Group?members;id=member-10"
        ]

        let item = MessageStorageItem()
        item.references.append(objectsIn: [
            explicit,
            canonicalURI,
            duplicate,
            legacyURI,
            legacyURIWithMemberID,
            resourceURI
        ])

        let mentions = try XCTUnwrap(item.createMentionsElement())
        XCTAssertEqual(
            mentions.elements(forName: "user").compactMap {
                $0.attributeStringValue(forName: "id")
            },
            ["member-7", "member-8"]
        )

        item.groupMentionIntent = .members([])
        XCTAssertNil(item.createMentionsElement(), "An empty member set must not become mention-all")
    }

    func testCanonicalDirectAuthorIsAccepted() throws {
        let message = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <body>Hello</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'>
              <nickname>Mercutio</nickname>
            </user>
          </x>
        </message>
        """)

        let user = try XCTUnwrap(groupchatUserElement(from: message))

        XCTAssertEqual(user.attributeStringValue(forName: "id"), "member-7")
        XCTAssertEqual(user.element(forName: "nickname")?.stringValue, "Mercutio")
        XCTAssertEqual(conversationTypeByMessage(message), .group)
    }

    func testAuthorShapeRejectsAdditionalSiblingAndDuplicateGroupWrappers() throws {
        let additionalSibling = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Mercutio</nickname></user>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable'/>
          </x>
          <body>Hello</body>
        </message>
        """)
        let duplicateWrappers = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Mercutio</nickname></user>
          </x>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-8'><nickname>Benvolio</nickname></user>
          </x>
          <body>Hello</body>
        </message>
        """)

        XCTAssertNil(groupchatUserElement(from: additionalSibling))
        XCTAssertNil(groupchatUserElement(from: duplicateWrappers))
        XCTAssertEqual(conversationTypeByMessage(additionalSibling), .regular)
        XCTAssertEqual(conversationTypeByMessage(duplicateWrappers), .regular)
    }

    func testNestedMutableReferenceUserIsNeverUsedAsAuthorIdentity() throws {
        let message = try makeMessage("""
        <message type='chat' from='juliet@example.com' to='romeo@example.com'>
          <body>Forged author</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='13'>
              <user xmlns='https://xabber.com/protocol/groups' id='forged-member'>
                <nickname>Forged</nickname>
              </user>
            </reference>
          </x>
        </message>
        """)

        XCTAssertNil(groupchatUserElement(from: message))
        XCTAssertFalse(parseReferences(
            message,
            primary: "message-primary",
            jid: "juliet@example.com",
            owner: "romeo@example.com"
        ).contains(where: { $0.kind == .groupchat }))
    }

    func testCanonicalSystemEventAndNestedActorAreAccepted() throws {
        let message = try makeMessage("""
        <message type='headline' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='leave'>
              <user id='member-7'><nickname>Mercutio</nickname></user>
            </system-message>
          </x>
        </message>
        """)

        let metadata = try XCTUnwrap(parseSystemMessageMetadata(message))
        let actor = try XCTUnwrap(metadata["user"] as? [String: Any])

        XCTAssertEqual(metadata["type"] as? String, "leave")
        XCTAssertEqual(actor["id"] as? String, "member-7")
        XCTAssertEqual(actor["nickname"] as? String, "Mercutio")
    }

    func testCurrentServerChatSystemEventWithBodyIsAccepted() throws {
        let message = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <body>Mercutio left the group</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='leave'>
              <user id='member-7'><nickname>Mercutio</nickname></user>
            </system-message>
          </x>
        </message>
        """)

        let metadata = try XCTUnwrap(parseSystemMessageMetadata(message))

        XCTAssertEqual(metadata["type"] as? String, "leave")
    }

    func testSystemEventShapeIsExactAndCreateRequiresMAMSource() throws {
        let extraSibling = try makeMessage("""
        <message type='headline' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='join'/>
            <user id='member-7'/>
          </x>
        </message>
        """)
        let create = try makeMessage("""
        <message type='headline' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='create'/>
          </x>
        </message>
        """)

        XCTAssertNil(parseSystemMessageMetadata(extraSibling))
        XCTAssertNil(parseSystemMessageMetadata(create))
        XCTAssertEqual(
            parseSystemMessageMetadata(create, source: .mam)?["type"] as? String,
            "create"
        )
    }

    func testLegacyAndUnknownSystemEventsAreRejected() throws {
        let fragmentMessage = try makeMessage("""
        <message type='headline' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups#system-message' type='join'/>
        </message>
        """)
        let obsoleteShape = try makeMessage("""
        <message type='headline' from='stage@example.com' to='romeo@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <system-message type='kick'/>
          </x>
        </message>
        """)

        XCTAssertNil(parseSystemMessageMetadata(fragmentMessage))
        XCTAssertNil(parseSystemMessageMetadata(obsoleteShape))
        XCTAssertEqual(conversationTypeByMessage(fragmentMessage), .regular)
    }

    func testMUCTypeIsNotClassifiedAsXabberGroupEvenWithCanonicalDecoration() throws {
        let message = try makeMessage("""
        <message type='groupchat' from='stage@example.com/member-7' to='romeo@example.com'>
          <body>MUC-shaped</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Mercutio</nickname></user>
          </x>
        </message>
        """)

        XCTAssertEqual(conversationTypeByMessage(message), .regular)
        XCTAssertNil(PushNotificationArchiveParser.parseArchivedMessage(message, owner: "romeo@example.com")?.route.groupchat)
    }

    func testDisplayedGroupMarkerUsesOriginAndOnlyGroupStanzaID() throws {
        let displayed = try XCTUnwrap(
            GroupDisplayedMarkerCodec.make(
                originID: "origin-1",
                groupStanzaID: "1770000000000001",
                groupJID: "Stage@Example.com/Group"
            )
        )

        XCTAssertEqual(displayed.xmlns(), "urn:xmpp:chat-markers:0")
        XCTAssertEqual(displayed.attributeStringValue(forName: "id"), "origin-1")
        let stanzaID = try XCTUnwrap(displayed.element(forName: "stanza-id"))
        XCTAssertEqual(stanzaID.xmlns(), "urn:xmpp:sid:0")
        XCTAssertEqual(stanzaID.attributeStringValue(forName: "by"), "stage@example.com")
        XCTAssertEqual(stanzaID.attributeStringValue(forName: "id"), "1770000000000001")
    }

    func testPinnedPanelNeverUsesLegacyZeroIDUnpin() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+AdditionalNavbarPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("groupchatService.unpin"))
        XCTAssertTrue(source.contains("groupStanzaID: groupStanzaID"))
        XCTAssertFalse(source.contains("groupchats.unpinMessage"))
    }

    func testPushPreviewUsesOnlyCanonicalDirectAuthor() throws {
        let canonical = try makeMessage("""
        <message type='chat' from='stage@example.com' to='romeo@example.com'>
          <body>Hello</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><nickname>Mercutio</nickname></user>
          </x>
        </message>
        """)
        let nestedLegacyIdentity = try makeMessage("""
        <message type='chat' from='juliet@example.com' to='romeo@example.com'>
          <body>Hello</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'>
              <user xmlns='https://xabber.com/protocol/groups' id='forged-member'>
                <nickname>Forged</nickname>
              </user>
            </reference>
          </x>
        </message>
        """)

        let canonicalPreview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(canonical, owner: "romeo@example.com")
        )
        let regularPreview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(nestedLegacyIdentity, owner: "romeo@example.com")
        )

        XCTAssertEqual(canonicalPreview.route.conversationType, "group")
        XCTAssertEqual(canonicalPreview.route.groupchat, "stage@example.com")
        XCTAssertEqual(canonicalPreview.route.senderUserId, "member-7")
        XCTAssertEqual(canonicalPreview.route.senderNickname, "Mercutio")
        XCTAssertEqual(regularPreview.route.conversationType, "regular")
        XCTAssertNil(regularPreview.route.groupchat)
        XCTAssertNil(regularPreview.route.senderUserId)
        XCTAssertNil(regularPreview.route.senderNickname)
    }

    func testProductionHasNoLegacyGroupNamespaceLiteralsOrRejectionHelpers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = repositoryRoot.appendingPathComponent("xabber", isDirectory: true)
        let forbidden = [
            "https://xabber.com/protocol/groups#",
            "http://xabber.com/protocol/groups",
            "http://xabber.com/protocol/groupchat",
            "https://xabber.com/protocol/groupchat",
            "#system-message",
            "containsLegacyGroupNamespace",
            "isLegacyGroupNamespace"
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: productionRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var violations: [String] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift",
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            for needle in forbidden where contents.contains(needle) {
                violations.append("\(fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")): \(needle)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testRemovedLegacyGroupUIKitControllersDoNotReturnToProductionSources() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = repositoryRoot.appendingPathComponent("xabber", isDirectory: true)
        let removedControllerNames = [
            "GroupchatEditContactViewController",
            "GroupchatSettingsUserPermissionsViewController",
            "GroupchatInfoViewControllerSecondary",
            "GroupchatDefaultRightsViewController"
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: productionRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var violations: [String] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift",
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            for controllerName in removedControllerNames where contents.contains(controllerName) {
                violations.append(
                    "\(fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")): \(controllerName)"
                )
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testCanonicalGroupInfoAndModerationUIKitUsesTypedBoundaryOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController.swift",
            "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift",
            "xabber/controllers/chats/info_screens/groupchat_contact_info/GroupchatContactInfoViewController.swift",
            "xabber/controllers/chats/info_screens/groupchat_contact_info/GroupchatContactInfoViewController+InfoScreenHeaderButtonDelegate.swift",
            "xabber/controllers/chats/groupchats/blocked_list/GroupchatBlockedViewController.swift",
            "xabber/controllers/chats/groupchats/blocked_list/GroupchatBlockAddViewController.swift",
            "xabber/controllers/chats/groupchats/info/GroupchatMembersListViewController.swift"
        ]
        let forbidden = [
            ".groupchats",
            "session.groupchat",
            "XMPPUIActionManager.shared.groupchat",
            "GroupChatStorageItem",
            "GroupchatUserStorageItem",
            "try realm.write",
            "user: \"0\"",
            "userId: \"\"",
            "GroupchatInfoViewControllerSecondary",
            "GroupchatDefaultRightsViewController",
            "Clear avatar"
        ]
        var violations: [String] = []

        for path in paths {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            for needle in forbidden where contents.contains(needle) {
                violations.append("\(path): \(needle)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testCanonicalGroupInfoRoutesToRetainedTypedScreens() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/groupchats/groupchat_settings/GroupchatSettingsViewControllerT.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(headerSource.contains("GroupchatSettingsViewControllerT"))
        XCTAssertTrue(settingsSource.contains("GroupchatSettingsPermissionsViewController"))
        XCTAssertFalse(headerSource.contains("GroupchatInfoViewControllerSecondary"))
        XCTAssertFalse(headerSource.contains("GroupchatDefaultRightsViewController"))
    }

    private func makeMessage(_ xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }
}
