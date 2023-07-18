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
import XMPPFramework
import RealmSwift
import RxCocoa
import RxSwift



class RosterUtils {
    
    open class var shared: RosterUtils {
        struct SharedRosterSingleton {
            static let instance = RosterUtils()
        }
        return SharedRosterSingleton.instance
    }
    
    static let ungroupped: String = "Ungroupped".localizeString(id: "chat_message_ungroupped", arguments: [])
    static let invitesGroup: String = "Chat invites".localizeString(id: "chat_message_chat_invites", arguments: [])
    static let subscribersGroup: String = "Subscribers".localizeString(id: "chat_message_subscribers", arguments: [])
    
    open func convertStatus(_ status: ResourceStatus, customOfflineStatus: String? = nil) -> String {
        switch status {
        case .offline:
            return customOfflineStatus ?? "Offline".localizeString(id: "groupchat_status_offline", arguments: [])
        case .xa:
            return "Away for long time".localizeString(id: "groupchat_status_away_long", arguments: [])
        case .away:
            return "Away".localizeString(id: "groupchat_status_away", arguments: [])
        case .dnd:
            return "Busy".localizeString(id: "groupchat_status_busy", arguments: [])
        case .online:
            return "Online".localizeString(id: "groupchat_status_online", arguments: [])
        case .chat:
            return "Ready to chat".localizeString(id: "groupchat_status_ready_to_chat", arguments: [])
        }
        
    }
    
    open func convertResourceTypeToString(_ type: ResourceStorageItem.ClientType) -> String {
        switch type {
        case .bot: return "Bot".localizeString(id: "chat_resource_bot", arguments: [])
        case .console: return "Console".localizeString(id: "chat_resource_console", arguments: [])
        case .game: return "Game".localizeString(id: "chat_resource_game", arguments: [])
        case .handheld: return "Handheld".localizeString(id: "chat_resource_handheld", arguments: [])
        case .pc: return "PC".localizeString(id: "chat_resource_pc", arguments: [])
        case .phone: return "Phone".localizeString(id: "chat_resource_phone", arguments: [])
        case .sms: return "SMS".localizeString(id: "chat_resource_sms", arguments: [])
        case .web: return "Web"
        case .unknown: return ""
        case .groupchat: return "Groupchat".localizeString(id: "chat_resource_groupchat", arguments: [])
        }
    }
    
    open func convertResourceTypeFromString(_ type: String) -> ResourceStorageItem.ClientType {
        switch type {
        case "bot": return .bot
        case "console": return .console
        case "game": return .game
        case "handheld": return .handheld
        case "pc": return .pc
        case "phone": return .phone
        case "sms": return .sms
        case "web": return .web
        default: return .unknown
        }
    }
    
    open func convertShowStatus(_ status: String) -> ResourceStatus {
        switch status {
        case "unavailable", "inactive": return .offline
        case "available", "active": return .online
        case "chat": return .chat
        case "away": return .away
        case "dnd": return .dnd
        case "xa": return .xa
        default: return .online
        }
    }
}
