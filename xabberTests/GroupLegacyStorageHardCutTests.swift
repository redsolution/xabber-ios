import XCTest
@testable import xabber

final class GroupLegacyStorageHardCutTests: XCTestCase {
    private struct SourceFile {
        let relativePath: String
        let contents: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func productionSources() throws -> [SourceFile] {
        try swiftSources(in: [
            repositoryRoot.appendingPathComponent("xabber", isDirectory: true),
            repositoryRoot.appendingPathComponent("xabber-push-extension", isDirectory: true)
        ])
    }

    private func swiftSources(in roots: [URL]) throws -> [SourceFile] {
        var result: [SourceFile] = []
        for root in roots {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift",
                      let source = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                result.append(
                    SourceFile(
                        relativePath: url.path.replacingOccurrences(
                            of: repositoryRoot.path + "/",
                            with: ""
                        ),
                        contents: source
                    )
                )
            }
        }
        return result
    }

    private func violations(
        in sources: [SourceFile],
        tokens: [String]
    ) -> [String] {
        sources.flatMap { source in
            tokens.compactMap { token in
                guard source.contents.contains(token) else {
                    return nil
                }
                return "\(source.relativePath): \(token)"
            }
        }.sorted()
    }

    func testAllProductionTargetsContainNoLegacyGroupTypesOrManager() throws {
        let forbidden = [
            "GroupchatManager",
            "GroupChatStorageItem",
            "GroupchatUserStorageItem",
            "GroupchatInvitesStorageItem",
            "GroupchatInvitedUsersStorageItem",
            "GroupchatPermission",
            "GroupchatInvitePersistenceService",
            "GroupchatInviteV3Parser",
            "GroupchatRightsDelegateProtocol"
        ]
        let found = violations(in: try productionSources(), tokens: forbidden)
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    func testAllProductionTargetsContainNoLegacyGroupVocabularyOrNamespaces() throws {
        let groupsFragmentNamespace = "https://xabber.com/protocol/groups#"
        let permissionsFragmentNamespace = "https://xabber.com/protocol/permissions#"
        let forbidden = [
            groupsFragmentNamespace,
            permissionsFragmentNamespace,
            "member-only",
            "role_ == \"custom\"",
            "X-PRIVACY",
            "X-INDEX",
            "X-STATUS",
            "X-MEMBERSHIP",
            "X-MEMBERS"
        ]
        let found = violations(in: try productionSources(), tokens: forbidden)
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    func testGroupUIKitContainsNoRawDataFormCompatibilitySurface() throws {
        let groupUIRoots = [
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_info",
                isDirectory: true
            ),
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_contact_info",
                isDirectory: true
            )
        ]
        let forbidden = [
            "GroupchatContactInfoPermissionDelegate",
            "FormDatasource",
            "formDatasource",
            "formId",
            "updateFormId",
            "formSectionTitles",
            "groupEditFormValues",
            "onChatSettingsFormResponse",
            "onChangePermission",
            "changeItem(",
            "changedValues",
            "[[String: Any]]"
        ]
        let found = violations(in: try swiftSources(in: groupUIRoots), tokens: forbidden)
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    func testGroupFeatureContainsNoLegacyCustomRoleCase() throws {
        let groupFeatureRoots = [
            repositoryRoot.appendingPathComponent(
                "xabber/xmpp/groupchat",
                isDirectory: true
            ),
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/groupchats",
                isDirectory: true
            ),
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_info",
                isDirectory: true
            ),
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_contact_info",
                isDirectory: true
            ),
            repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/create_new_entity/new_group",
                isDirectory: true
            )
        ]
        let found = violations(
            in: try swiftSources(in: groupFeatureRoots),
            tokens: ["case custom"]
        )
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    func testContactInfoTableMapsOnlyCanonicalTypedSections() throws {
        let dataSourceURL = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/info_screens/groupchat_contact_info/"
                + "GroupchatContactInfoViewController+UITableViewDataSource.swift"
        )
        let delegateURL = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/info_screens/groupchat_contact_info/"
                + "GroupchatContactInfoViewController+UITableViewDelegate.swift"
        )
        let dataSource = try String(contentsOf: dataSourceURL, encoding: .utf8)
        let delegate = try String(contentsOf: delegateURL, encoding: .utf8)

        XCTAssertTrue(dataSource.contains("return datasource.count"))
        XCTAssertTrue(dataSource.contains("return datasource[section].childs.count"))
        XCTAssertFalse(dataSource.contains("section - datasource.count"))
        XCTAssertFalse(delegate.contains("section - datasource.count"))
        XCTAssertFalse(dataSource.contains("cell.delegate = self"))
    }

    func testContactInfoCanonicalSectionProjectionDropsEmptySectionsAndPreservesRows() {
        let firstRow = GroupchatContactInfoViewController.Datasource(
            .text,
            title: "Role",
            key: "role"
        )
        let secondRow = GroupchatContactInfoViewController.Datasource(
            .button,
            title: "Report",
            key: "report"
        )
        let sections = [
            GroupchatContactInfoViewController.Datasource(
                .text,
                title: "Empty",
                childs: []
            ),
            GroupchatContactInfoViewController.Datasource(
                .text,
                title: "Details",
                childs: [firstRow]
            ),
            GroupchatContactInfoViewController.Datasource(
                .text,
                title: "Safety",
                childs: [secondRow]
            )
        ]

        let result = GroupchatContactInfoViewController.canonicalSections(sections)

        XCTAssertEqual(result.map(\.title), ["Details", "Safety"])
        XCTAssertEqual(result.map { $0.childs.compactMap(\.key) }, [["role"], ["report"]])
    }

    func testControllersDoNotIntroduceNewDirectCanonicalGroupRealmAccess() throws {
        let controllers = try swiftSources(in: [
            repositoryRoot.appendingPathComponent("xabber/controllers", isDirectory: true)
        ])
        let fixtureAllowlist: Set<String> = [
            "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
        ]
        let canonicalStorageTokens = [
            "GroupSnapshotStorageItem",
            "GroupSelfMembershipStorageItem",
            "GroupMemberStorageItem",
            "GroupPermissionSetStorageItem",
            "GroupPermissionStorageItem",
            "GroupInviteStorageItem"
        ]
        let found = controllers
            .filter { !fixtureAllowlist.contains($0.relativePath) }
            .flatMap { source in
                canonicalStorageTokens.compactMap { token in
                    source.contents.contains(token)
                        ? "\(source.relativePath): \(token)"
                        : nil
                }
            }
            .sorted()
        XCTAssertEqual(found, [], found.joined(separator: "\n"))

        let fixture = try XCTUnwrap(
            controllers.first {
                $0.relativePath
                    == "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
            }
        )
        XCTAssertTrue(fixture.contents.contains("#if DEBUG || CHAT_PERFORMANCE_LAB"))
    }

    func testProjectContainsNoDeletedLegacyGroupFormSources() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let forbidden = [
            "GroupchatContactInfoViewController+Delegate.swift",
            "GroupchatContactInfoViewController+InfoCell.swift",
            "GroupchatContactInfoViewController+ItemCell.swift"
        ]
        let found = forbidden.filter { project.contains($0) }
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }
}
