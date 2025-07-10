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
import MaterialComponents.MDCPalettes

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
    var forwards: [MessageAttachment] { get }
    var isOutgoing: Bool { get }
    var isEdited: Bool { get }
    var groupchatAuthorNickname: String { get }
    var groupchatAuthorBadge: String { get }
    var groupchatAuthorId: String { get }
    var isHasAttachedMessages: Bool { get }
    var afterburnInterval: Double { get }
    var tailed: Bool { get }
    var images: [ImageAttachment] { get }
    var videos: [VideoAttachment] { get }
    var files: [FileAttachment] { get }
    var audios: [AudioAttachment] { get }
    var timeMarkerText: NSAttributedString { get }
    var indicator: IndicatorType { get }
    var avatarUrl: String? { get }
    var attributedAuthor: NSAttributedString? { get }
    
//    var queryIds: String? { get }
}

class CallAttachment {
    var primary: String
    
    init(primary: String) {
        self.primary = primary
    }
}

class ImageAttachment {
    var primary: String
    var url: URL?
    var size: CGSize
    
    init(primary: String, url: URL?, size: CGSize) {
        self.primary = primary
        self.url = url
        self.size = size
    }
    
}

class VideoAttachment {
    var primary: String
    var url: URL?
    var size: CGSize
    var previewUrl: URL?
    var duration: Double
    var downloaded: Bool
    
    init(primary: String, url: URL?, size: CGSize, previewUrl: URL? = nil, duration: Double, downloaded: Bool) {
        self.primary = primary
        self.url = url
        self.size = size
        self.previewUrl = previewUrl
        self.duration = duration
        self.downloaded = downloaded
    }
}

class FileAttachment {
    var primary: String
    var url: URL?
    var size: Double
    var name: String
    var downloaded: Bool
    
    init(primary: String, url: URL?, size: Double, name: String, downloaded: Bool) {
        self.primary = primary
        self.url = url
        self.size = size
        self.name = name
        self.downloaded = downloaded
    }
    
    var prettySize: String {
        get {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .binary
            return formatter.string(fromByteCount: Int64(size))
        }
    }
}

class AudioAttachment {
    var primary: String
    var url: URL?
    var size: Double
    var name: String
    var duration: Double
    var downloaded: Bool
    var pcm: [Float]
    
    
    init(primary: String, url: URL?, size: Double, name: String, duration: Double, downloaded: Bool, pcm: [Float]) {
        self.primary = primary
        self.url = url
        self.size = size
        self.name = name
        self.duration = duration
        self.downloaded = downloaded
        self.pcm = pcm
    }
    
    var prettySize: String {
        get {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .binary
            return formatter.string(fromByteCount: Int64(size))
        }
    }
}

class MessageAttachment {
    var primary: String
    var author: String
    var jid: String
    var outgoing: Bool
    var textMessage: NSAttributedString?
    var images: [ImageAttachment]
    var videos: [VideoAttachment]
    var files: [FileAttachment]
    var audios: [AudioAttachment]
    var timeMarker: NSAttributedString
    var subforwards: [MessageAttachment]
    
    init(primary: String, author: String, jid: String, outgoing: Bool, textMessage: NSAttributedString?, images: [ImageAttachment], videos: [VideoAttachment], files: [FileAttachment], audios: [AudioAttachment], timeMarker: NSAttributedString, subforwards: [MessageAttachment]) {
        self.primary = primary
        self.author = author
        self.jid = jid
        self.outgoing = outgoing
        self.textMessage = textMessage
        self.images = images
        self.videos = videos
        self.files = files
        self.audios = audios
        self.timeMarker = timeMarker
        self.subforwards = subforwards
    }
    
    var attributedAuthor: NSAttributedString {
        get {
            return NSAttributedString(string: self.author, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14, weight: .medium),
                NSAttributedString.Key.foregroundColor: ChatViewController.getUsernamePalette(for: self.jid).tint500
            ])
        }
    }
}

public enum IndicatorType {
    case none
    case sending
    case sended
    case received
    case read
    case error
}
