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
    
    struct SizedImage {
        var image: UIImage? = nil
        var url: String?
        var size: ImageSize
        
        func key(jid: String, owner: String) -> String  {
            if let url = self.url {
                return url
            }
            return [jid, owner, "\(size.rawValue)"].prp()
        }
    }
    
    class AvatarItem: Equatable, Hashable {
        static func == (lhs: DefaultAvatarManager.AvatarItem, rhs: DefaultAvatarManager.AvatarItem) -> Bool {
            return lhs.jid == rhs.jid &&
                lhs.owner == rhs.owner
        }
                
        var jid: String
        var owner: String
        var images: [SizedImage] = []
        var imageHash: String? = nil
        var isGroupUser: Bool
        var kind: AvatarStorageItem.Kind = .none
        
        init(jid: String, owner: String, isGroupUser: Bool = false) {
            self.jid = jid
            self.owner = owner
            self.isGroupUser = isGroupUser
            self.update()
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
            hasher.combine(owner)
        }
        
        public final func update() {
            do {
                let realm = try WRealm.safe()

                if let i = realm.object(ofType: AvatarStorageItem.self, forPrimaryKey: AvatarStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                    self.imageHash = i.imageHash
                    self.kind = i.kind
                    if kind == .none {
                        self.images = [self.createDefaultAvatar(checkName: true)]
                    }
                    var requested: Bool = false
                    if let url = i.imageOriginal { requested = insertImage(url: url, size: .original) }
                    if let url = i.image32  { requested = insertImage(url: url, size:  .px32) }
                    if let url = i.image48  { requested = insertImage(url: url, size:  .px48) }
                    if let url = i.image64  { requested = insertImage(url: url, size:  .px64) }
                    if let url = i.image96  { requested = insertImage(url: url, size:  .px96) }
                    if let url = i.image128 { requested = insertImage(url: url, size: .px128) }
                    if let url = i.image192 { requested = insertImage(url: url, size: .px192) }
                    if let url = i.image256 { requested = insertImage(url: url, size: .px256) }
                    if let url = i.image384 { requested = insertImage(url: url, size: .px384) }
                    if let url = i.image512 { requested = insertImage(url: url, size: .px512) }
                    if !requested {
                        self.images = [self.createDefaultAvatar(checkName: true)]
                    }
                } else {
                    self.images = [self.createDefaultAvatar(checkName: true)]
//                    self.createDefaultAvatar(checkName: false)
                }
            } catch {
                DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
//                self.createDefaultAvatar(checkName: false)
            }
            self.images = self.images.sorted(by: { $0.size.rawValue < $1.size.rawValue })
        }
        
        private func insertImage(url urlRaw: String, size: ImageSize) -> Bool {
//            var image = DefaultAvatarManager.SizedImage(url: urlRaw, size: size)
            func download() {
                if let url = URL(string: urlRaw) {
                    ImageDownloader.default.downloadImage(with: url, options: KingfisherParsedOptionsInfo([
                        .backgroundDecode,
                        .downloadPriority(0.2),
                        .lowDataMode(nil),
                        .callbackQueue(.dispatch(DispatchQueue.global(qos: .background)))
                    ])) {
                        result in
                        switch result {
                            case .success(let value):
                                let image = DefaultAvatarManager.SizedImage(image: value.image, url: urlRaw, size: size)
                                self.images.append(image)
                            case .failure(_):
                                if !self.images.contains(where: { $0.size == .original }) {
                                    self.images.append(self.createDefaultAvatar(checkName: true))
                                }
                                
                                break
                        }
                    }
                }
            }
            
            
            ImageCache.default.retrieveImageInDiskCache(forKey: urlRaw) { result in
                switch result {
                    case .success(let value):
                        guard let image = value else {
                            download()
                            return
                        }
                        self.images.append(DefaultAvatarManager.SizedImage(image: image, url: urlRaw, size: size))
                    case .failure(_):
                        download()
                        break
                }
            }
            return true
        }
        
        public final func store(images: [SizedImage], hash: String, kind: AvatarStorageItem.Kind) {
            func update(_ instance: AvatarStorageItem) {
                if images.isEmpty {
                    instance.imageHash = nil
                    instance.image32 = nil
                    instance.image48 = nil
                    instance.image64 = nil
                    instance.image96 = nil
                    instance.image128 = nil
                    instance.image192 = nil
                    instance.image256 = nil
                    instance.image384 = nil
                    instance.image512 = nil
                    instance.imageOriginal = nil
                    instance.kind = .none
                } else {
                    instance.imageHash = hash
                    instance.kind = kind
                    images.forEach {
                        switch $0.size {
                            case .px32 : instance.image32 =  $0.key(jid: jid, owner: owner)
                            case .px48 : instance.image48 =  $0.key(jid: jid, owner: owner)
                            case .px64 : instance.image64 =  $0.key(jid: jid, owner: owner)
                            case .px96 : instance.image96 =  $0.key(jid: jid, owner: owner)
                            case .px128: instance.image128 = $0.key(jid: jid, owner: owner)
                            case .px192: instance.image192 = $0.key(jid: jid, owner: owner)
                            case .px256: instance.image256 = $0.key(jid: jid, owner: owner)
                            case .px384: instance.image384 = $0.key(jid: jid, owner: owner)
                            case .px512: instance.image512 = $0.key(jid: jid, owner: owner)
                            case .original: instance.imageOriginal = $0.key(jid: jid, owner: owner)
                        }
                        if let urlRaw = $0.url, let url = URL(string: urlRaw) {
                            ImageDownloader.default.downloadImage(with: url, options: KingfisherParsedOptionsInfo([
                                .backgroundDecode,
                                .downloadPriority(0.2),
                                .lowDataMode(nil),
                                .callbackQueue(.dispatch(DispatchQueue.global(qos: .background)))
                            ]))
                        }
                        if let image = $0.image {
                            ImageCache.default.store(
                                image,
                                forKey: $0.key(jid: jid, owner: owner),
                                options: KingfisherParsedOptionsInfo([.callbackQueue(.dispatch(DispatchQueue.global(qos: .background)))]),
                                toDisk: true
                            )
                        }
                    }
                }
            }
            
            self.images = images
            
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: AvatarStorageItem.self,
                                               forPrimaryKey: AvatarStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                    try realm.write {
                        update(instance)
                        realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner))?.avatar = instance
                    }
                } else {
                    let instance = AvatarStorageItem()
                    instance.jid = self.jid
                    instance.owner = self.owner
                    instance.primary = AvatarStorageItem.genPrimary(jid: self.jid, owner: self.owner)
                    update(instance)
                    try realm.write {
                        realm.add(instance, update: .modified)
                        realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner))?.avatar = instance
                    }
                }
            } catch {
                DDLogDebug("AvatarItem: \(#function). \(error.localizedDescription)")
            }
        }

        
        private final func createDefaultAvatar(checkName: Bool) -> SizedImage {
            let conf = LetterAvatarBuilderConfiguration()
            conf.useSingleLetter = true
            if checkName {
                do {
                    let realm = try WRealm.safe()
                    if isGroupUser {
                        if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                            if instance.nickname.isNotEmpty {
                                conf.username = instance
                                    .nickname
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .uppercased()
                            } else {
                                conf.username = instance
                                    .jid
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .uppercased()
                            }
                        }
                    } else {
                        if let instance = realm.object(ofType: RosterDisplayNameStorageItem.self, forPrimaryKey: [self.jid, self.owner].prp()) {
                            conf.username = instance
                                .displayName
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .uppercased()
                        } else {
                            conf.username = self.jid
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .uppercased()
                        }
                    }
                } catch {
                    DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                    conf.username = self.jid
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased()
                }
            } else {
                conf.username = self.jid
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
            }
            let color = AccountColorManager.shared.palette(for: self.owner)
            conf.backgroundColors = [color.tint700, color.tint600, color.tint500, color.tint400, color.tint300]
            conf.size = CGSize(square: 128)
            let image = UIImage.makeLetterAvatar(withConfiguration: conf)
            
            return SizedImage(image: image, size: .original)
        }
        
        func retrieveDefaultAvatar(size: ImageSize, callback: ((UIImage?) -> Void)?) {
            ImageCache.default.retrieveImage(forKey: [self.owner, self.jid, "\(ImageSize.original.rawValue)"].prp()) { result in
                switch result {
                case .success(let value): callback?(value.image)
                case .failure(_): callback?(nil)
                }
            }
        }
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
    internal var imageCache: Set<AvatarItem> = Set<AvatarItem>()
    
    internal var dumbAvatar: UIImage
    
    override init() {
        let conf = LetterAvatarBuilderConfiguration()
        conf.backgroundColors = [AccountColorManager.shared.randomPalette().tint500]
        conf.size = DefaultAvatarManager.defaultSize
        
        conf.username = ["💡","😃","👽","👻","🎃","🤖","👾","🦷","🧦","🍺"].randomElement() ?? "💡"
        
        dumbAvatar = UIImage.makeLetterAvatar(withConfiguration: conf)!
        super.init()
        ImageCache.default.memoryStorage.config.expiration = .seconds(60*60*12)
        ImageCache.default.memoryStorage.config.countLimit = 10000
        ImageCache.default.diskStorage.config.expiration = .never
        ImageCache.default.diskStorage.config.sizeLimit = 0
//        DispatchQueue.main.async {
//            self.subscribe()
//        }
    }
    
    public final func preheat() {
        do {
            let realm = try WRealm.safe()
            let activeAccounts = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { return $0.jid }
            activeAccounts.forEach {
                self.updateAvatar(jid: $0, owner: $0)
            }
            realm.objects(LastChatsStorageItem.self).filter("owner IN %@", activeAccounts).toArray().forEach {
                self.updateAvatar(jid: $0.jid, owner: $0.owner)
            }
        } catch {
            DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            let asitems =  realm.objects(AvatarStorageItem.self)
            print(asitems.toArray())
            Observable
                .changeset(from: realm.objects(AvatarStorageItem.self))
                .subscribe { changes in
                    let collection = changes.0
                    guard !collection.isEmpty else {
                        return
                    }
                    if let changeset = changes.1 {
                        if changeset.deleted.isNotEmpty {
                            changeset.deleted.forEach { index in
                                let item = collection[index]
                                self.imageCache.remove(AvatarItem(jid: item.jid,
                                                                  owner: item.owner))
                            }
                        }
                        if changeset.inserted.isNotEmpty {
                            changeset.inserted.forEach { index in
                                let item = collection[index]
                                let avatarItem = AvatarItem(jid: item.jid, owner: item.owner)
                                avatarItem.update()
                                self.imageCache.insert(avatarItem)
                            }
                        }
                        if changeset.updated.isNotEmpty {
                            changeset.updated.forEach { index in
                                let item = collection[index]
                                self.imageCache
                                    .first(where: { $0.jid == item.jid && $0.owner == item.owner })?
                                    .update()
                            }
                        }
                    } else {
                        collection.forEach {
                            let item = AvatarItem(jid: $0.jid, owner: $0.owner)
                            item.update()
                            self.imageCache.insert(item)
                        }
                    }
                } onError: { error in
                    DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: bag)

        } catch {
            DDLogDebug("DefaultAvatarManager: \(#function)")
        }
    }
    
    private final func unsubscribe() {
        bag = DisposeBag()
    }
    
    public final func getGroupAvatar(user: String, jid: String, owner: String, size: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        getAvatar(jid: [user, jid].prp(), owner: owner, size: size, callback: callback)
    }
    
    public final func updateGroupAvatar(user: String, jid: String, owner: String) {
        updateAvatar(jid: [user, jid].prp(), owner: owner)
    }
    
    public final func storeGroupAvatar(user: String, jid: String, owner: String, hash: String, images: [SizedImage], kind: AvatarStorageItem.Kind) {
        storeAvatar(jid: [user, jid].prp(), owner: owner, hash: hash, images: images, kind: kind)
    }
        
    public final func deleteGroupAvatar(user: String, jid: String, owner: String) {
        deleteAvatar(jid: [user, jid].prp(), owner: owner)
    }
    
    public final func isImageCachedGroup(user: String, jid: String, owner: String, imageHash: String) -> Bool {
        return isImageCached(jid: [user, jid].prp(), owner: owner, imageHash: imageHash)
    }
    
    public final func getAvatar(jid: String, owner: String, size requiredSize: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        var size: ImageSize = .original
        let options: KingfisherOptionsInfo = [.alsoPrefetchToMemory]
        switch requiredSize {
        case 32, 44, 48: size = .px96
        case 56: size = .px192
        case 128: size = .px384
        case 144, 256: size = .px512
        default: size = .original
        }
        func completionHandler(result: Result<KFCrossPlatformImage?, KingfisherError>) {
            switch result {
            case .success(let value):
                    if let image = value?.images?.first {
                    callback?(image)
                } else {
                    if let item = self.imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
                        item.retrieveDefaultAvatar(size: size, callback: callback)
                    } else {
                        let item = AvatarItem(jid: jid, owner: owner)
                        item.retrieveDefaultAvatar(size: size, callback: callback)
                    }
                }
            case .failure(_):
                callback?(self.dumbAvatar)
            }
        }
        func getFrom(_ item: AvatarItem) {
            if let index = item.images.firstIndex(where: { $0.size == size }) {
                if let image = item.images[index].image {
                    callback?(image)
                } else {
                    ImageCache
                        .default
                        .retrieveImageInDiskCache(
                            forKey: item.images[index].key(jid: item.jid, owner: item.owner),
                            options: options,
                            callbackQueue: .mainAsync,
                            completionHandler: completionHandler
                        )
                }
            } else {
                if let image = item.images.first?.image {
                    callback?(image)
                } else {
                    ImageCache
                        .default
                        .retrieveImageInDiskCache(
                            forKey: item.images.first?.key(jid: item.jid, owner: item.owner) ?? "dumb_avatar",
                            options: options,
                            callbackQueue: .mainAsync,
                            completionHandler: completionHandler
                        )
                }
            }
        }
                
        if let item = self.imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
            getFrom(item)
        } else {
            let item = AvatarItem(jid: jid, owner: owner)
            self.imageCache.update(with: item)
            getFrom(item)
        }
    }
    
    public final func updateAvatar(jid: String, owner: String) {
//        DefaultAvatarManager.queue.sync {
            if let item = self.imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
                item.update()
            } else {
                let item = AvatarItem(jid: jid, owner: owner)
                self.imageCache.insert(item)
            }
//        }
    }
    
    public final func storeAvatar(jid: String, owner: String, hash: String, images: [SizedImage], kind: AvatarStorageItem.Kind) {
        if let item = imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
            item.store(images: images, hash: hash, kind: kind)
        } else {
            let item = AvatarItem(jid: jid, owner: owner)
            item.store(images: images, hash: hash, kind: kind)
            imageCache.update(with: item)
        }
    }
    
    public func removeFromCache(jid: String, owner: String, url: String) {
        ImageCache.default.removeImage(forKey: url)
        if let index = imageCache.firstIndex(where: { $0.jid == jid && $0.owner == owner }) {
            imageCache.remove(at: index)
        }
    }
    
    public final func deleteAvatar(jid: String, owner: String) {
        if let item = imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
            item.store(images: [], hash: "", kind: .none)
        } else {
            let item = AvatarItem(jid: jid, owner: owner)
            item.store(images: [], hash: "", kind: .none)
            imageCache.insert(item)
        }
    }
    
    public final func isImageCached(jid: String, owner: String, imageHash: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: AvatarStorageItem.self,
                forPrimaryKey: AvatarStorageItem.genPrimary(jid: jid, owner: owner)
            ) {
                return instance.imageHash == imageHash
            }
        } catch {
            DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
        }
        return false
        
//        if let item = imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
//            return item.imageHash == imageHash
//        } else {
//            let item = AvatarItem(jid: jid, owner: owner)
//            imageCache.insert(item)
//            return item.imageHash == imageHash
//        }
    }
    
    public final func getAvatarItem(jid: String, owner: String) -> AvatarItem {
        if let item = imageCache.first(where: { $0.jid == jid && $0.owner == owner }) {
            return item
        } else {
            let item = AvatarItem(jid: jid, owner: owner)
            imageCache.insert(item)
            return item
        }
    }
    
    public final func deleteAllAvatars() {
        do {
            let realm = try WRealm.safe()
            let avatars =  realm.objects(AvatarStorageItem.self)
            try realm.write {
                realm.delete(avatars)
            }
        } catch {
            print("Error while deleting AvatarStorageItems")
        }
    }
}
