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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest

final class ChatSearchLiveSmokeTests: XCTestCase {
    func testTelegramStyleInChatSearchLiveSmoke() throws {
        // Safety gate is deliberately evaluated before XCUIApplication exists.
        // Task 23 is compile-only: even an opted-in run must not launch the app.
        _ = try ChatSearchLiveQASafetyGate.requireAuthorization()
        throw XCTSkip("Live scenario is implemented and first executed in Task 24.")
    }

    override func tearDown() {
        // Future teardown may only cancel search and terminate the process.
        // Never reset, erase, logout, remove accounts, delete data, clean Realm,
        // uninstall the app, remove its container, or mutate credentials here.
        super.tearDown()
    }
}
