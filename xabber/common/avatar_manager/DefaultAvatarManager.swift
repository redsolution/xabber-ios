//
//  DefaultAvatarManager.swift
//  xabber_test_xmpp
//
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
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import Kingfisher
import LetterAvatarKit
import CocoaLumberjack
import MaterialComponents.MDCPalettes

class DefaultAvatarManager: NSObject {
    
    enum ImageSize: CGFloat, CaseIterable {
        case px32 = 32
        case px48 = 48
        case px64 = 64
        case px96 = 96
        case px128 = 128
        case px192 = 192
        case px256 = 256
        case px384 = 384
        case px512 = 512
        case original = 0
    }
    
    open class var shared: DefaultAvatarManager {
        struct DefaultAvatarManagerSingleton {
            static let instance = DefaultAvatarManager()
        }
        return DefaultAvatarManagerSingleton.instance
    }
    
    static let defaultSize: CGSize = CGSize(square: 140)
    
    static let queue: DispatchQueue = DispatchQueue(
        label: "com.xabber.avatarManager.default",
        qos: .utility,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem,
        target: nil
    )
    
    internal var bag: DisposeBag = DisposeBag()
        
    override init() {
        super.init()
        ImageCache.default.memoryStorage.config.expiration = .seconds(60*60*1)
        ImageCache.default.memoryStorage.config.countLimit = 1000
        ImageCache.default.diskStorage.config.expiration = .never
        ImageCache.default.diskStorage.config.sizeLimit = 0
    }
    
    public final func preheat() {

    }
    
    
    public final func getGroupAvatar(user: String, jid: String, owner: String, size: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        callback?(nil)
    }
    
    public final func storeImage(for key: String, image: UIImage) {
        ImageCache.default.store(image, forKey: key, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
    }
    
    public final func getGroupAvatar(url: String?, userId: String, jid: String, owner: String, size requiredSize: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        if let url = url {
            if ImageCache.default.isCached(forKey: url) {
                ImageCache.default.retrieveImage(forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]), callbackQueue: .mainAsync) { result in
                    switch result {
                        case .success(let image):
//                            print("rgthio", image.image == nil)
                            callback?(image.image)
                        default:
                            callback?(nil)
                    }
                }
            } else {
                callback?(nil)
                guard let urlUnwr = URL(string: url) else {
                    return
                }
                ImageDownloader.default.downloadImage(with: urlUnwr, options: KingfisherParsedOptionsInfo([.cacheOriginalImage, .alsoPrefetchToMemory, .callbackQueue(.untouch)])) { result in
                    switch result {
                        case .success(let image):
                            ImageCache.default.store(image.image, forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                do {
                                    let realm = try WRealm.safe()
                                    let collectionChats = realm.objects(LastChatsStorageItem.self).filter("jid == %@ AND owner == %@", jid, owner)
                                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                                        try realm.write {
                                            instance.updatedTS = Date().timeIntervalSince1970
                                            collectionChats.forEach { $0.updateTS = Date().timeIntervalSince1970 }
                                        }
                                    }
                                    if jid == owner {
                                        if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                                            try realm.write {
                                                instance.avatarUpdatedTS = Double(Date().timeIntervalSince1970)
                                            }
                                        }
                                    }
                                    
                                } catch {
                                    DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                                }
                            }
                        default:
                            break
                    }
                }
            }
        }
        callback?(nil)
    }
    
    public final func getAvatar(url: String?, jid: String, owner: String, size requiredSize: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        if let url = url {
            if ImageCache.default.isCached(forKey: url) {
                ImageCache.default.retrieveImage(forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]), callbackQueue: .mainAsync) { result in
                    switch result {
                        case .success(let image):
//                            print("rgthio", image.image == nil)
                            callback?(image.image)
                        default:
                            callback?(nil)
                    }
                }
            } else {
                callback?(nil)
                guard let urlUnwr = URL(string: url) else {
                    return
                }
                ImageDownloader.default.downloadImage(with: urlUnwr, options: KingfisherParsedOptionsInfo([.cacheOriginalImage, .alsoPrefetchToMemory, .callbackQueue(.untouch)])) { result in
                    switch result {
                        case .success(let image):
                            ImageCache.default.store(image.image, forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                do {
                                    let realm = try WRealm.safe()
                                    let collectionChats = realm.objects(LastChatsStorageItem.self).filter("jid == %@ AND owner == %@", jid, owner)
                                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                                        try realm.write {
                                            instance.updatedTS = Date().timeIntervalSince1970
                                            collectionChats.forEach { $0.updateTS = Date().timeIntervalSince1970 }
                                        }
                                    }
                                    if jid == owner {
                                        if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                                            try realm.write {
                                                instance.avatarUpdatedTS = Double(Date().timeIntervalSince1970)
                                            }
                                        }
                                    }
                                    
                                } catch {
                                    DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                                }
                            }
                        default:
                            break
                    }
                }
            }
        }
        callback?(nil)
    }
    
    public final func deleteAvatar(jid: String, owner: String) {
        
    }
    
    public final func deleteAllAvatars() {
        do {
            try ImageCache.default.diskStorage.removeAll()
            ImageCache.default.memoryStorage.removeAll()
            let realm = try WRealm.safe()
            let avatars =  realm.objects(AvatarStorageItem.self)
            try realm.write {
                realm.delete(avatars)
            }
        } catch {
//            print("Error while deleting AvatarStorageItems")
        }
    }
}
