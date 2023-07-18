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

/// An object that groups the metadata of a messages sender.
public struct Sender {

    /// MARK: - Properties

    /// The unique String identifier for the sender.
    ///
    /// Note: This value must be unique across all senders.
    public let id: String

    /// The display name of a sender.
    public let displayName: String

    // MARK: - Intializers

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

// MARK: - Equatable Conformance

extension Sender: Equatable {

    /// Two senders are considered equal if they have the same id.
    public static func == (left: Sender, right: Sender) -> Bool {
        return left.id == right.id
    }

}


public struct MessageAvatarMetadata: Equatable, Hashable {
    let jid: String
    let owner: String
    let userId: String?
    
    public static func ==(left: MessageAvatarMetadata, right: MessageAvatarMetadata) -> Bool {
        return left.owner == right.owner
            && left.jid == right.jid
            && left.userId == right.userId
    }
}
