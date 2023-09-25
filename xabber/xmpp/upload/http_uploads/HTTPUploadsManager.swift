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
import RxSwift
import RxCocoa
import Alamofire
import Cache
import Kingfisher

class HTTPUploadsManager: AbstractXMPPManager, UploadManagerProtocol {
    internal var node: String? = nil
    internal var namespace: String = ""
    internal var maxFileSize: Int? = nil
    
    internal var uploads: BehaviorRelay<Set<UploadBatchItem>> = BehaviorRelay(value: Set<UploadBatchItem>())
    internal var bag: DisposeBag = DisposeBag()
        
    static var storage: Storage<String, Data>? = nil
    
    enum UploadError: Error {
        case emptyUploads
    }
    
    static private func configureStorage() {
        do {
            HTTPUploadsManager.storage = try Storage(
                diskConfig: DiskConfig(name: "TemporaryUploadCache",
                                       expiry: Expiry.seconds(TimeInterval(exactly: 30 * 60)!),
                                       directory: nil,
                                       protectionType: nil),
                memoryConfig: MemoryConfig(expiry: Expiry.seconds(10 * 60),
                                           countLimit: 0,
                                           totalCostLimit: 0),
                transformer: Cache.Transformer<Data>(toData: { return $0 },
                                                     fromData: { return $0 })
            )
        } catch {
            DDLogDebug("cant invoke storage")
        }
    }
    
//    static public func storeData(_ data: Data, for key: String) {
//        if HTTPUploadsManager.storage == nil {
//            HTTPUploadsManager.configureStorage()
//        }
//        try? HTTPUploadsManager.storage?.setObject(data, forKey: key)
//    }
//
    internal func loadData(_ key: String) -> Data? {
        do {
            let realm = try WRealm.safe()
            if let url = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: key)?.localFileUrl {
                print("FILE EXISTS:", FileManager.default.fileExists(atPath: url.absoluteString))
                return try? Data(contentsOf: url)
            }
        } catch {
            DDLogDebug("HTTPUploadsManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    internal class UploadBatchItem: Hashable {
        
        static func == (lhs: HTTPUploadsManager.UploadBatchItem, rhs: HTTPUploadsManager.UploadBatchItem) -> Bool {
            return lhs.messageId == rhs.messageId && lhs.date == rhs.date
        }
        
        var sended: Bool = false
        var messageId: String = ""
        
        var attachments: Set<String> = Set<String>()
        
        var hasError: Bool = false
        
        var error: (() -> Void)? = nil
        var success: (() -> Void)? = nil
        
        var completed: Bool = false
        
        var date: Date = Date()
        
        init(_ message: MessageStorageItem, error: @escaping (() -> Void), success: @escaping (() -> Void)) throws  {
            self.messageId = message.messageId
            self.error = error
            self.success = success
//             == .media || $0.kind == .voice
            if message
                .references
                .filter({ [.media, .voice].contains($0.kind) })
                .isEmpty { throw UploadError.emptyUploads }
            message
                .references
                .compactMap({ return [.media, .voice].contains($0.kind) ? $0.primary : nil })
                .forEach { attachments.insert($0) }
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(messageId)
        }
        
        func onComplete(force: Bool = false) {
            if completed { return }
            if force {
                completed = true
                if hasError {
                    error?()
                } else {
                    success?()
                }
            } else {
                if attachments.count == 0 {
                    completed = true
                    if hasError {
                        error?()
                    } else {
                        success?()
                    }
                }
            }
        }
    }
    
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        _ = isAvailable()
//        subscribe()
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        uploads
            .asObservable()
            .debug()
            .debounce(.milliseconds(50), scheduler: SerialDispatchQueueScheduler(qos: .default))
//            .window(timeSpan: .milliseconds(800),
//                    count: 50,
//                    scheduler: SerialDispatchQueueScheduler(qos: .default))
            .subscribe(onNext: { (collection) in
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    let value = self.uploads.value
                    if let batchItem = value.filter({ !$0.sended }).first {
                        value.filter({ $0.sended }).first?.sended = true
                        batchItem.attachments.forEach {
                            self.requestSlot(stream, for: $0)
                        }
                    }
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        if stream.isAuthenticated && self.uploads.value.isNotEmpty {
                            let value = self.uploads.value
                            if let batchItem = value.filter({ !$0.sended }).first {
                                value.filter({ $0.sended }).first?.sended = true
                                autoreleasepool {
                                    batchItem.attachments.forEach {
                                        self.requestSlot(stream, for: $0)
                                    }
                                }
                            }
                        } else {
                            if self.uploads.value.isNotEmpty {
                                self.uploads.accept(self.uploads.value)
                            }
                        }
                    })
                })
                
            }, onError: { (error) in
                print(error.localizedDescription)
            }, onCompleted: {
                print("completed")
            }) {
                print("disposed")
            }
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    open func isAvailable() -> Bool {
        guard let node = SettingManager.shared.getKey(for: owner, scope: .httpUploader, key: "node"),
              let namespace = SettingManager.shared.getKey(for: owner, scope: .httpUploader, key: "namespace") else {
                return false
        }
        self.node = node
        self.namespace = namespace
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .httpUploader, key: "max_file_size") ?? "")
        return node.isNotEmpty
    }
    
    open func upload(_ xmppStream: XMPPStream, message primary: String, error: @escaping (() -> Void), success: @escaping (() -> Void)) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let batchItem = try UploadBatchItem(instance, error: error, success: success)
                var value = uploads.value
                value.insert(batchItem)
                uploads.accept(value)
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    let value = self.uploads.value
                    value.filter({ !$0.sended }).forEach {
                        batchItem in
                        if let index = value.firstIndex(of: batchItem) {
                            value[index].sended = true
                        }
                        
                        batchItem.attachments.forEach {
                            self.requestSlot(stream, for: $0)
                        }
                    }
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        if stream.isDisconnected {
                            value.filter({ !$0.sended }).forEach { $0.error?() }
                        } else {
                            value.filter({ !$0.sended }).forEach {
                                batchItem in
                                if let index = value.firstIndex(of: batchItem) {
                                    value[index].sended = true
                                }
                                
                                batchItem.attachments.forEach {
                                    self.requestSlot(stream, for: $0)
                                }
                            }
                        }
                        
                    })
                })
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        return readResponse(iq)
    }
    
    internal func readResponse(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            let uploadItem = uploads.value.first(where: { $0.attachments.contains(elementId) }) else {
                return false
        }
        func onFail() {
            uploadItem.hasError = true
            uploadItem.attachments.remove(elementId)
            uploadItem.onComplete()
            if uploadItem.attachments.isEmpty {
                var value = self.uploads.value
                value.remove(uploadItem)
                self.uploads.accept(value)
            }
        }
        
        func onSuccess() {
            uploadItem.attachments.remove(elementId)
            uploadItem.onComplete()
            if uploadItem.attachments.isEmpty {
                var value = self.uploads.value
                value.remove(uploadItem)
                self.uploads.accept(value)
            }
        }
        
        if iq.element(forName: "error") != nil {
            onFail()
            return true
        }
        guard let slot = iq.element(forName: "slot"),
            slot.xmlns() == "urn:xmpp:http:upload:0",
            let uri = slot.element(forName: "get")?.attributeStringValue(forName: "url"),
            let putUrlUwnr = slot.element(forName: "put")?.attributeStringValue(forName: "url") else {
                onFail()
                return true
        }
        
        
        let putUrl = URL(string: putUrlUwnr)!
        guard let data = loadData(elementId) else {
            onFail()
            return true
        }
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: elementId) {
                try realm.write {
                    instance.uploadUrl = putUrl
                }
            }
        } catch {
            DDLogDebug("HTTPUploadsManager: \(#function). \(error.localizedDescription)")
        }
        
        var headers: [String: String] = [:]
        slot.element(forName: "put")?.elements(forName: "header").forEach {
            if let name = $0.attributeStringValue(forName: "name"),
                name == "Authorization",
                let authorization = $0.stringValue  {
                headers["Authorization"] = authorization
            }
        }
        
        if let image = Image(data: data) {
            ImageCache.default.storeToDisk(data, forKey: uri)
        }
        
        Alamofire
            .upload(data,
                    to: putUrl,
                    method: .put,
                    headers: headers.isEmpty ? nil : headers)
            .response {
                result in
                if result.error != nil {
                    DDLogDebug("HTTPUploadsManager: \(#function). \(result.error?.localizedDescription ?? "Internal error")")
                    onFail()
                } else if let status = result.response?.statusCode {
                    if status >= 400 {
                        onFail()
                    } else if status >= 200 {
                        DDLogDebug("HTTPUploadsManager: \(#function). File \(uri) uploaded")
                        do {
                            let realm = try  WRealm.safe()
                            if let instance = realm.object(ofType: MessageReferenceStorageItem.self,
                                                           forPrimaryKey: elementId) {
                                try realm.write {
                                    instance.metadata?["uri"] = uri
                                    instance.url = uri
                                }
                            }
                        } catch {
                            onFail()
                        }
                        onSuccess()
                        uploadItem.onComplete()
                    }
                }
                
        }
        return true
    }
    
    internal func requestSlot(_ xmppStream: XMPPStream, for primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary),
                let filename = instance.metadata?["filename"] as? String,
                let size = instance.metadata?["size"] as? Int,
                let contentType = instance.metadata?["media-type"] as? String {
                let request = DDXMLElement(name: "request", xmlns: "urn:xmpp:http:upload:0")
                request.addAttribute(withName: "filename", stringValue: filename)
                request.addAttribute(withName: "content-type", stringValue: contentType)
                request.addAttribute(withName: "size", integerValue: size)
                guard isAvailable(), let node = node else {
                    DDLogDebug("HTTPrUploasManager (\(#function) is unavailable.")
                    return
                }
                xmppStream.send(XMPPIQ(iqType: .get, to: XMPPJID(string: node), elementID: primary, child: request))
                
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    self.requestSlot(xmppStream, for: primary)
                }
            }
        } catch {
            print("dsfgdsfg")
        }
    }
    
    deinit {
        unsubscribe()
    }
}
