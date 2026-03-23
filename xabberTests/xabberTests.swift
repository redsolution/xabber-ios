//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import XCTest
import Security
import RealmSwift
@testable import xabber

class xabberTests: XCTestCase {

    override func setUpWithError() throws {}
    override func tearDownWithError() throws {}

    func testExample() throws {}

    func testPerformanceExample() throws {
        measure {}
    }

    /// Snapshot the InfoScreenHeaderView in different contexts
    func testSnapshotInfoHeaderView() throws {
        let expectation = self.expectation(description: "UI rendering")

        DispatchQueue.main.async {
            defer { expectation.fulfill() }

            func snapshotHeader(width: CGFloat, title: String, subtitle: String, thirdLine: String?, hasButtons: Bool, filename: String) {
                let header = InfoScreenHeaderView(frame: .zero)
                header.additionalTopOffset = 56

                // Add some buttons if needed
                if hasButtons {
                    let b1 = InfoHeaderButton()
                    b1.configure(icon: "message.fill", title: "message")
                    let b2 = InfoHeaderButton()
                    b2.configure(icon: "phone.fill", title: "call")
                    let b3 = InfoHeaderButton()
                    b3.configure(icon: "bell.fill", title: "mute")
                    let b4 = InfoHeaderButton()
                    b4.configure(icon: "ellipsis", title: "more")
                    header.configureButtons { [b1, b2, b3, b4] }
                }

                header.configure(avatarUrl: nil, owner: "", jid: title,
                                  titleColor: .label, title: title,
                                  subtitle: subtitle, thirdLine: thirdLine)

                let h = header.preferredHeight
                header.frame = CGRect(x: 0, y: 0, width: width, height: h)
                header.updateSubviews()
                header.backgroundColor = .systemGroupedBackground
                header.layoutIfNeeded()

                let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: h))
                let img = renderer.image { _ in
                    header.drawHierarchy(in: header.bounds, afterScreenUpdates: true)
                }
                let path = "/tmp/\(filename).png"
                try? img.pngData()?.write(to: URL(fileURLWithPath: path))
                print("✓ Saved \(filename): w=\(Int(width)) h=\(Int(h))")
            }

            // iPhone 16e width (390pt)
            snapshotHeader(width: 390, title: "igor.boldin@redsolution.com", subtitle: "redsolution.com", thirdLine: nil, hasButtons: true, filename: "header_account_iphone")
            snapshotHeader(width: 390, title: "Andrew Nenakhov", subtitle: "andrew.nenakhov@redsolution.com", thirdLine: "redsolution.com", hasButtons: true, filename: "header_contact_iphone")
            snapshotHeader(width: 390, title: "xabber developers", subtitle: "groupchat@conference.redsolution.com", thirdLine: "5 members", hasButtons: true, filename: "header_groupchat_iphone")
            snapshotHeader(width: 390, title: "igor.boldin@redsolution.com", subtitle: "redsolution.com", thirdLine: nil, hasButtons: false, filename: "header_settings_iphone")

            // iPad width (1024pt)
            snapshotHeader(width: 1024, title: "igor.boldin@redsolution.com", subtitle: "redsolution.com", thirdLine: nil, hasButtons: true, filename: "header_account_ipad")
            snapshotHeader(width: 1024, title: "xabber developers", subtitle: "groupchat@conference.redsolution.com", thirdLine: "5 members", hasButtons: true, filename: "header_groupchat_ipad")
        }

        waitForExpectations(timeout: 5)
    }

    /// Injects XMPP account into Realm and credentials into keychain using the app's CredentialsManager.
    func testInjectXMPPCredentials() throws {
        let jid = ""
        let password = ""

        // Use the app's CredentialsManager to store the password (correct service/access group)
        CredentialsManager.shared.setItem(for: jid, password: password)

        // Verify via CredentialsManager read
        let stored = CredentialsManager.shared.getItem(for: jid)
        let readPass = stored.creditionalString
        print("Keychain read back: \(readPass != nil ? "OK" : "FAILED")")
        XCTAssertNotNil(readPass, "Password not readable via CredentialsManager")
        if let p = readPass { XCTAssertEqual(p, password) }
        print("✓ Credentials injected for \(jid)")

        // Add account to Realm
        let realm = try WRealm.safe()
        try realm.write {
            if realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) == nil {
                let account = AccountStorageItem()
                account.jid = jid
                account.node = String(jid.split(separator: "@").first ?? "")
                account.service = String(jid.split(separator: "@").last ?? "")
                account.host = account.service
                account.savePassword = true
                account.enabled = true
                account.order = 0
                realm.add(account)
                print("✓ Account added to Realm: \(jid)")
            } else {
                print("ℹ Account already in Realm: \(jid)")
            }
        }
    }

}
