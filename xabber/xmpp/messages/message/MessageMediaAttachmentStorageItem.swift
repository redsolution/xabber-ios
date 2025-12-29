//
//  MessageMediaAttachmentStorageItem.swift
//  xabber
//
//  Created by Игорь Болдин on 12.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack
import UIKit

class MessageMediaAttachmentStorageItem: Object {
    
    public static func genPrimary(jid: String, owner: String, url: String, messagePrimary: String) -> String {
        return [jid, owner, url, messagePrimary].prp()
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    override static func indexedProperties() -> [String] {
        return ["jid", "owner", "date", "conversationType_", "kind_"]
    }
    
    enum Kind: String {
        case none = ""
        case image = "image"
        case file = "file"
        case video = "video"
        case voice = "voice"
        case audio = "audio"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ""
    @objc dynamic var messagePrimary: String = ""
    @objc dynamic var archiveId: String = ""
    @objc dynamic var kind_ = ""
    @objc dynamic var filename: String = ""
    @objc dynamic var isEncrypted: Bool = false
    @objc dynamic var outgoing: Bool = false
    @objc dynamic var date: Date = Date()
    @objc dynamic var url_: String = ""
    @objc dynamic var isDownloaded: Bool = false
    @objc dynamic var verySmallThumb: String? = nil
    
    @objc dynamic var metadata_: String = ""
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var kind: Kind {
        get {
            return Kind(rawValue: self.kind_) ?? .none
        } set {
            self.kind_ = newValue.rawValue
        }
    }
    
    var url: URL? {
        get {
            return URL(string: self.url_)
        } set {
            self.url_ = newValue?.absoluteString ?? ""
        }
    }
    
    func subtitle() -> String {
        return ""
    }
    
    var thumb: UIImage? {
        get {
            guard let b64 = self.verySmallThumb,
                  let data = Data(base64Encoded: b64),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image
        } set {
            self.verySmallThumb = newValue?.jpegData(compressionQuality: 0.5)?.base64EncodedString()
        }
    }
}
