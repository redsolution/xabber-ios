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


protocol MessageType {
    var primary: String { get }
    var jid: String { get }
    var owner: String { get }
    var sender: Sender { get }
    var messageId: String { get }
    var sentDate: Date { get }
    var editDate: Date? { get }
    var kind: MessageKind { get }
    var withAuthor: Bool { get }
    var withAvatar: Bool { get }
    var error: Bool { get }
    var errorType: String { get }
    var canPinMessage: Bool { get }
    var canEditMessage: Bool { get }
    var canDeleteMessage: Bool { get }
    var forwards: [MessageForwardsInlineStorageItem.Model] { get }
    var isOutgoing: Bool { get }
    var isEdited: Bool { get }
    var groupchatAuthorNickname: String { get }
    var groupchatAuthorBadge: String { get }
    var isHasAttachedMessages: Bool { get }
    var afterburnInterval: Double { get }
    var references: [MessageReferenceStorageItem.Model] { get }
//    var queryIds: String? { get }
}
