//
//  AccountEditProfileTests.swift
//  xabberTests
//
//  Created by Codex on 28.08.2026.
//

import UIKit
import XCTest
import XMPPFramework

@testable import xabber

@MainActor
final class AccountEditProfileTests: XCTestCase {

    func testControllerUsesInsetGroupedTableAndCheckmarkSaveAction() {
        let controller = AccountEditViewController()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertNil(controller.doneButton.title)
        XCTAssertNotNil(controller.doneButton.image)
        XCTAssertEqual(controller.doneButton.accessibilityIdentifier, "account.edit_profile.save")
        XCTAssertFalse(controller.doneButton.accessibilityLabel?.isEmpty ?? true)
    }

    func testVCardFieldsUseSemanticKeyboardsAndContentTypes() {
        let cell = AccountEditViewController.VcardEditedItem(style: .default, reuseIdentifier: nil)

        cell.configure("desc_email_work", for: "Email", value: "")
        XCTAssertEqual(cell.field.keyboardType, .emailAddress)
        XCTAssertEqual(cell.field.textContentType, .emailAddress)
        XCTAssertEqual(cell.field.autocapitalizationType, .none)
        XCTAssertEqual(cell.field.autocorrectionType, .no)

        cell.configure("desc_url", for: "Website", value: "")
        XCTAssertEqual(cell.field.keyboardType, .URL)
        XCTAssertEqual(cell.field.textContentType, .URL)
        XCTAssertEqual(cell.field.autocapitalizationType, .none)
        XCTAssertEqual(cell.field.autocorrectionType, .no)

        cell.configure("ph_homePhone", for: "Phone", value: "")
        XCTAssertEqual(cell.field.keyboardType, .phonePad)
        XCTAssertEqual(cell.field.textContentType, .telephoneNumber)

        cell.configure("ha_pcode", for: "Postal code", value: "")
        XCTAssertEqual(cell.field.keyboardType, .asciiCapable)
        XCTAssertEqual(cell.field.textContentType, .postalCode)

        cell.configure("wp_orgunit", for: "Department", value: "")
        XCTAssertEqual(cell.field.textContentType, .organizationName)
        XCTAssertEqual(cell.field.autocapitalizationType, .words)

        cell.configure("wa_pobox", for: "PO box", value: "")
        XCTAssertEqual(cell.field.keyboardType, .asciiCapable)
        XCTAssertEqual(cell.field.autocapitalizationType, .allCharacters)
        XCTAssertEqual(cell.field.autocorrectionType, .no)
    }

    func testProfileNameFieldsUseNameKeyboardsAndContentTypes() {
        let cell = AccountEditViewController.ProfileCell(style: .default, reuseIdentifier: nil)

        XCTAssertEqual(cell.givenNameField.keyboardType, .namePhonePad)
        XCTAssertEqual(cell.givenNameField.textContentType, .givenName)
        XCTAssertEqual(cell.middleNameField.keyboardType, .namePhonePad)
        XCTAssertEqual(cell.middleNameField.textContentType, .middleName)
        XCTAssertEqual(cell.familyNameField.keyboardType, .namePhonePad)
        XCTAssertEqual(cell.familyNameField.textContentType, .familyName)
        XCTAssertEqual(cell.fullnameField.keyboardType, .namePhonePad)
        XCTAssertEqual(cell.fullnameField.textContentType, .name)
    }

    func testBirthdayUsesWheelDatePickerAndCanonicalDateSerialization() throws {
        let cell = AccountEditViewController.VcardEditedItem(style: .default, reuseIdentifier: nil)
        var receivedValue: String?
        cell.callback = { field in
            receivedValue = field.text
            return true
        }

        cell.configure("ci_birthday", for: "Birthday", value: "2001-02-03")

        XCTAssertTrue(cell.field.inputView === cell.datePicker)
        XCTAssertEqual(cell.datePicker.datePickerMode, .date)
        XCTAssertEqual(cell.datePicker.preferredDatePickerStyle, .wheels)
        XCTAssertNotNil(cell.field.inputAccessoryView)
        XCTAssertNotNil(cell.datePicker.maximumDate)

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = 1992
        components.month = 6
        components.day = 15
        cell.datePicker.date = try XCTUnwrap(components.date)
        cell.datePicker.sendActions(for: .valueChanged)

        XCTAssertEqual(cell.field.text, "1992-06-15")
        XCTAssertEqual(receivedValue, "1992-06-15")
    }

    func testProfileAvatarAffordanceAndLayoutAdaptAcrossRotationWidths() throws {
        let cell = AccountEditViewController.ProfileCell(style: .default, reuseIdentifier: nil)

        XCTAssertTrue(cell.avatarActionOverlay.isDescendant(of: cell.avatarButton))
        XCTAssertNotNil(cell.avatarActionOverlay.cameraImageView.image)
        XCTAssertGreaterThanOrEqual(cell.avatarActionOverlay.gradientLayer.colors?.count ?? 0, 2)
        XCTAssertFalse(cell.avatarButton.accessibilityLabel?.isEmpty ?? true)
        XCTAssertFalse(cell.avatarButton.accessibilityHint?.isEmpty ?? true)

        layout(cell, width: 320)
        let compactFieldFrame = cell.fieldStack.convert(cell.fieldStack.bounds, to: cell.contentView)
        XCTAssertGreaterThan(compactFieldFrame.width, 0)
        XCTAssertGreaterThanOrEqual(compactFieldFrame.minX, cell.contentView.bounds.minX)
        XCTAssertLessThanOrEqual(compactFieldFrame.maxX, cell.contentView.bounds.maxX + 0.5)
        XCTAssertEqual(cell.avatarActionOverlay.frame.maxY, cell.avatarButton.bounds.maxY, accuracy: 0.5)

        layout(cell, width: 700)
        let landscapeFieldFrame = cell.fieldStack.convert(cell.fieldStack.bounds, to: cell.contentView)
        XCTAssertGreaterThan(landscapeFieldFrame.width, compactFieldFrame.width)
        XCTAssertLessThanOrEqual(landscapeFieldFrame.maxX, cell.contentView.bounds.maxX + 0.5)
        XCTAssertEqual(cell.avatarActionOverlay.frame.maxY, cell.avatarButton.bounds.maxY, accuracy: 0.5)
    }

    func testAvatarMetadataPublishesCloudThumbnailURIsWithoutRawDataNode() throws {
        let manager = AvatarUploadManager(withOwner: "alice@example.com")
        let responseData = try XCTUnwrap(
            """
            {
              "file": "https://storage.example/avatar/original.png",
              "hash": "avatar-hash",
              "name": "avatar.png",
              "quota": 100000,
              "used": 1000,
              "size": 1000,
              "thumbnails": [
                {"height": 128, "url": "https://storage.example/avatar/128.png", "width": 128},
                {"height": 512, "url": "https://storage.example/avatar/512.png", "width": 512}
              ]
            }
            """.data(using: .utf8)
        )
        let response = try JSONDecoder().decode(AvatarUploadManager.AvatarResponse.self, from: responseData)

        let iq = manager.makeImageMetadataIQ(
            avatar: response,
            to: nil,
            elementID: "avatar-test"
        )
        let pubsub = try XCTUnwrap(
            iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        )
        let publish = try XCTUnwrap(pubsub.element(forName: "publish"))
        XCTAssertEqual(publish.attributeStringValue(forName: "node"), "urn:xmpp:avatar:metadata")
        let metadata = try XCTUnwrap(
            publish.element(forName: "item")?
                .element(forName: "metadata", xmlns: "urn:xmpp:avatar:metadata")
        )
        let info = try XCTUnwrap(metadata.element(forName: "info"))
        let thumbnails = info.elements(forName: "thumbnail")

        XCTAssertEqual(thumbnails.count, 2)
        XCTAssertEqual(thumbnails[0].attributeStringValue(forName: "uri"), "https://storage.example/avatar/128.png")
        XCTAssertNil(thumbnails[0].attributeStringValue(forName: "url"))
        XCTAssertEqual(thumbnails[0].attributeIntegerValue(forName: "width"), 128)
        XCTAssertEqual(thumbnails[0].attributeIntegerValue(forName: "height"), 128)
        XCTAssertFalse(thumbnails[0].attributeStringValue(forName: "media-type")?.isEmpty ?? true)
        XCTAssertNil(pubsub.element(forName: "data", xmlns: "urn:xmpp:avatar:data"))
        XCTAssertFalse(iq.xmlString.contains("urn:xmpp:avatar:data"))
    }

    func testAvatarMetadataReceiverReadsThumbnailURIAndWidth() throws {
        let owner = "owner-\(UUID().uuidString)@example.com"
        let jid = "contact-\(UUID().uuidString)@example.com"
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        roster.owner = owner
        roster.jid = jid
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(roster, update: .modified)
        }

        let document = try DDXMLDocument(
            xmlString: """
            <item id="avatar-hash">
              <metadata xmlns="urn:xmpp:avatar:metadata">
                <info url="https://storage.example/avatar/original.png" type="image/png" id="avatar-hash" bytes="1000">
                  <thumbnail xmlns="urn:xmpp:thumbs:1" uri="https://storage.example/avatar/128.png" media-type="image/png" width="128" height="128"/>
                  <thumbnail xmlns="urn:xmpp:thumbs:1" uri="https://storage.example/avatar/512.png" media-type="image/png" width="512" height="512"/>
                </info>
              </metadata>
            </item>
            """,
            options: 0
        )
        let item = try XCTUnwrap(document.rootElement())
        let manager = XmppAvatarManager(withOwner: owner)

        XCTAssertTrue(manager.readFromPubSubMetadata(jid: jid, pubsub: item))

        let stored = try XCTUnwrap(
            realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
            )
        )
        XCTAssertEqual(stored.avatarMaxUrl, "https://storage.example/avatar/512.png")
        XCTAssertEqual(stored.avatarMinUrl, "https://storage.example/avatar/128.png")
    }

    func testEditProfileAvatarSelectionUsesOnlyAvatarUploadManager() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let flow = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/account_info/edit/AccountEditViewController+Flow.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(flow.contains("user.avatarUploader.setAvatar(image: image"))
        XCTAssertFalse(flow.contains("urn:xmpp:avatar:data"))
        XCTAssertFalse(flow.contains("PHOTO"))
    }

    private func layout(_ cell: UITableViewCell, width: CGFloat) {
        cell.frame = CGRect(x: 0, y: 0, width: width, height: 188)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }
}
