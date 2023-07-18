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
import RealmSwift

class LastChatsStorageItem: Object {
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    
//    @objc dynamic var messageText: String = ""
    
    @objc dynamic var messageDate: Date = Date(timeIntervalSince1970: 0)
    @objc dynamic var lastReadMessageDate: Date = Date()
    
    @objc dynamic var rosterItem: RosterStorageItem? = nil
//    var rosterItem: RosterStorageItem {
//        get {
//            return self.rosterItem_ ?? RosterStorageItem()
//        } set {
//            self.rosterItem_ = newValue
//        }
//    }
    
    @objc dynamic var lastMessage: MessageStorageItem?
    
    @objc dynamic var lastMessageId: String = ""
    @objc dynamic var isSynced: Bool = true
    @objc dynamic var isHistoryGapFixedForSession: Bool = false
    @objc dynamic var isArchived: Bool = false
    
    @objc dynamic var messagesCount: Int = -1

//  XEP-0CCC
    @objc dynamic var retractVersion: String? = nil
    @objc dynamic var mentionId: String? = nil
    @objc dynamic var lastReadId: String? = nil
    @objc dynamic var displayedId: String? = nil
    @objc dynamic var deliveredId: String? = nil
    @objc dynamic var unread: Int = 0
//    @objc dynamic var isMuted: Bool = false
    @objc dynamic var isBlocked: Bool = false // TODO: make deprecated
    
    @objc dynamic var draftMessage: String? = nil
    
//    @objc dynamic var groupchatRef: GroupChatStorageItem? = nil
//    @objc dynamic var isGroupchat: Bool = false
    @objc dynamic var groupchatMyId: String? = nil
    
    @objc dynamic var isPrereaded: Bool = false
    
    @objc dynamic var pinnedPosition: Double = 0
    @objc dynamic var isPinned: Bool = false
    
    @objc dynamic var muteExpired: Double = -1
    
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.omemo.rawValue
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager
                .ConversationType(rawValue: self.conversationType_) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var isMuted: Bool {
        get {
            return Date().timeIntervalSince1970 < self.muteExpired //self.muteExpired >= 0
        }
    }
    
    override static func indexedProperties() -> [String] {
        return ["owner", "jid", "messageDate", "isArchived"]
    }
    
    @objc dynamic var chatState_: Int = 0
    var chatState: ChatStatesManager.ComposingType {
        get {
            switch self.chatState_ {
            case ChatStatesManager.ComposingType.none.rawValue: return .none
            case ChatStatesManager.ComposingType.typing.rawValue: return .typing
            case ChatStatesManager.ComposingType.voice.rawValue: return .voice
            case ChatStatesManager.ComposingType.video.rawValue: return .video
            case ChatStatesManager.ComposingType.uploadFile.rawValue: return .uploadFile
            case ChatStatesManager.ComposingType.uploadImage.rawValue: return .uploadImage
            case ChatStatesManager.ComposingType.uploadAudio.rawValue: return .uploadAudio
            default: return .none
            }
        } set {
            self.chatState_ = newValue.rawValue
        }
    }
    
    @objc dynamic var chatMarkersSupport: Bool = false
    
    static public func genPrimary(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) -> String {
        return [jid, owner, conversationType.rawValue].prp()
    }
    
    func setPrimary(withOwner owner: String) {
        self.primary = [jid, owner, conversationType.rawValue].prp()
        self.owner = owner
    }
}
