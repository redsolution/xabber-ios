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
import CoreLocation
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
    var reservesAvatarSpace: Bool { get }
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
    var locations: [LocationAttachment] { get }
    var contacts: [ContactAttachment] { get }
    var files: [FileAttachment] { get }
    var audios: [AudioAttachment] { get }
    var messageWarningText: String? { get }
    var timeMarkerText: NSAttributedString { get }
    var indicator: IndicatorType { get }
    var avatarUrl: String? { get }
    var attributedAuthor: NSAttributedString? { get }
    
//    var queryIds: String? { get }
}

extension MessageType {
    var reservesAvatarSpace: Bool {
        withAvatar
    }
}

class CallAttachment {
    var primary: String
    var incoming: Bool
    var missed: Bool
    
    init(primary: String, incoming: Bool, missed: Bool) {
        self.primary = primary
        self.incoming = incoming
        self.missed = missed
    }
}

class ImageAttachment {
    var primary: String
    var url: URL?
    var size: CGSize
    var isSensitive: Bool
    var isSensitiveRevealed: Bool
    
    init(primary: String, url: URL? = nil, size: CGSize, isSensitive: Bool = false, isSensitiveRevealed: Bool = false) {
        self.primary = primary
        self.url = url
        self.size = size
        self.isSensitive = isSensitive
        self.isSensitiveRevealed = isSensitiveRevealed
    }
    
}

class VideoAttachment {
    var primary: String
    var url: URL?
    var size: CGSize
    var previewUrl: URL?
    var duration: Double
    var downloaded: Bool
    var isSensitive: Bool
    var isSensitiveRevealed: Bool
    
    init(primary: String, url: URL?, size: CGSize, previewUrl: URL? = nil, duration: Double, downloaded: Bool, isSensitive: Bool = false, isSensitiveRevealed: Bool = false) {
        self.primary = primary
        self.url = url
        self.size = size
        self.previewUrl = previewUrl
        self.duration = duration
        self.downloaded = downloaded
        self.isSensitive = isSensitive
        self.isSensitiveRevealed = isSensitiveRevealed
    }
}

class LocationAttachment {
    var primary: String
    var coordinate: CLLocationCoordinate2D
    var address: String?
    var geoURI: String
    var snapshotURL: URL?

    init(
        primary: String,
        coordinate: CLLocationCoordinate2D,
        address: String?,
        geoURI: String,
        snapshotURL: URL?
    ) {
        self.primary = primary
        self.coordinate = coordinate
        self.address = address
        self.geoURI = geoURI
        self.snapshotURL = snapshotURL
    }
}

class ContactAttachment {
    var primary: String
    var owner: String
    var jid: String
    var entity: MessageContactEntityKind
    var title: String
    var nickname: String?
    var given: String?
    var family: String?
    var avatarURL: String?
    var avatarMetadata: [String: String]

    init(
        primary: String,
        owner: String = "",
        jid: String,
        entity: MessageContactEntityKind = .contact,
        title: String,
        nickname: String?,
        given: String?,
        family: String?,
        avatarURL: String?,
        avatarMetadata: [String: String]
    ) {
        self.primary = primary
        self.owner = owner
        self.jid = jid
        self.entity = entity
        self.title = title
        self.nickname = nickname
        self.given = given
        self.family = family
        self.avatarURL = avatarURL
        self.avatarMetadata = avatarMetadata
    }

    var subtitle: String {
        switch entity {
        case .contact:
            return "Contact"
        case .groupchat:
            return "Group"
        case .incognito:
            return "Incognito group"
        }
    }
}

struct ChatFileAttachmentPresentation: Hashable {
    let displayName: String
    let formattedSize: String
    let mimeType: String
    let icon: MimeIconTypes

    init(name: String, size: Double, mimeType: String?) {
        let resolvedMimeType = mimeType ?? MimeType(path: name).value
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        self.displayName = name
        self.formattedSize = formatter.string(fromByteCount: Int64(max(0, size)))
        self.mimeType = resolvedMimeType
        self.icon = MimeIcon(resolvedMimeType).value
    }

    var revision: String {
        [displayName, formattedSize, mimeType, icon.rawValue].joined(separator: "|")
    }
}

final class FileAttachment {
    let primary: String
    let url: URL?
    let size: Double
    let name: String
    let downloaded: Bool
    let presentation: ChatFileAttachmentPresentation

    init(
        primary: String,
        url: URL?,
        size: Double,
        name: String,
        mimeType: String? = nil,
        downloaded: Bool
    ) {
        self.primary = primary
        self.url = url
        self.size = size
        self.name = name
        self.downloaded = downloaded
        self.presentation = ChatFileAttachmentPresentation(
            name: name,
            size: size,
            mimeType: mimeType
        )
    }

    var prettySize: String {
        presentation.formattedSize
    }

    var transferState: ChatFileTransferState {
        downloaded ? .available : .idle
    }

    func representedRequest(containerPrimary: String) -> ChatFileAttachmentRequest {
        ChatFileAttachmentRequest(
            containerPrimary: containerPrimary,
            referencePrimary: primary,
            resourceIdentity: url?.absoluteString ?? "",
            presentationRevision: presentation.revision
        )
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
    var locations: [LocationAttachment]
    var contacts: [ContactAttachment]
    var files: [FileAttachment]
    var audios: [AudioAttachment]
    var timeMarker: NSAttributedString
    var subforwards: [MessageAttachment]
    
    init(primary: String, author: String, jid: String, outgoing: Bool, textMessage: NSAttributedString?, images: [ImageAttachment], videos: [VideoAttachment], locations: [LocationAttachment] = [], contacts: [ContactAttachment] = [], files: [FileAttachment], audios: [AudioAttachment], timeMarker: NSAttributedString, subforwards: [MessageAttachment]) {
        self.primary = primary
        self.author = author
        self.jid = jid
        self.outgoing = outgoing
        self.textMessage = textMessage
        self.images = images
        self.videos = videos
        self.locations = locations
        self.contacts = contacts
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
