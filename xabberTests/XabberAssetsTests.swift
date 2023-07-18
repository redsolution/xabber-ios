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

import Foundation
import XCTest

class XabberAssetsTests: XCTestCase {
    
    struct AssetsError: Error {
        let message: String
    }
    
    var icons: [String] = [
        "archive-remove",
        "palette",
        "email",
        "discover-outline",
        "check",
        "file-table",
        "format-bold",
        "phone-circle",
        "camera-retake",
        "stop",
        "eye-off",
        "bell-1d",
        "bot",
        "bell",
        "format-italic",
        "pin",
        "link-variant",
        "download",
        "group-incognito",
        "group-public",
        "group-private",
        "chat-encrypted",
        "chat",
        "archive",
        "qrcode",
        "settings",
        "trash-filled",
        "key",
        "video-off",
        "link",
        "camera-iris",
        "microphone-off",
        "keyboard",
        "lock",
        "address",
        "chevron-up",
        "file-video",
        "archive-filled",
        "lock-outline",
        "call-outline",
        "file",
        "microphone",
        "chat-alert-outline",
        "bell-mention",
        "file-audio",
        "chevron-down",
        "call-noanswer",
        "alert",
        "fullscreen-exit",
        "format-quote",
        "archive-put",
        "circle",
        "phone-hangup",
        "account",
        "fullscreen",
        "group-incognito",
        "check-all",
        "reply",
        "group-public-add",
        "file-zip",
        "information",
        "flashlight",
        "device-desktop",
        "group-public",
        "lock-open-outline",
        "qrcode-scan",
        "search",
        "moon",
        "xmpp",
        "file-presentation",
        "birthday",
        "file-pdf",
        "bell-sleep",
        "chat-outline",
        "menu",
        "group-private",
        "lock-open",
        "bookmark",
        "forward",
        "pause",
        "description",
        "attach",
        "arrow-expand",
        "bell-15m",
        "bell-off",
        "video",
        "arrow-collapse",
        "alert-circle-outline",
        "web",
        "eye",
        "format-clear",
        "call",
        "format-underliine",
        "clock",
        "group-incognito-add",
        "call-made",
        "pencil",
        "call-received",
        "archive-remove-filled",
        "search-circle",
        "format-strikethrough",
        "flashlight-off",
        "contacts",
        "job",
        "sun",
        "trash",
        "format-list-bulleted",
        "camera",
        "chat",
        "archive-variant",
        "send",
        "contact-add",
        "emoticon",
        "bell-1h",
        "play",
        "check-circle",
        "call-missed",
        "archive-put-filled",
        "format-text",
        "image",
        "phone-circle",
        "invite-circle",
        "information-circle",
        "search-circle",
        "archive-circle",
        "copy",
        "format-list-numbered"
    ]
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testIcons() throws {
//        for icon in icons {
//            if UIImage(named: icon, in: Bundle(for: XabberAssetsTests.self), compatibleWith: nil) == nil {
//                throw AssetsError(message: "Fail to load icon with name: \(icon)")
//            }
//        }
    }

}
