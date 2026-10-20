import CoreFoundation
import CryptoKit
import Foundation

/// Protected file metadata stays attached to its authenticated message reference.
/// Invalid protected metadata retains its protected state and cannot become a raw URL fallback.
struct ChatEncryptedAttachmentDescriptor: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    enum State: Hashable { case plaintext, encrypted, invalid }
    let sourceURL: URL?
    let owner: String
    let referenceIdentity: String
    let state: State
    let cacheIdentity: String
    fileprivate let key: Data?
    fileprivate let iv: Data?
    fileprivate let ciphertextHash: Data?
    fileprivate let originalSize: Int?
    fileprivate let fileExtension: String

    var requiresAuthentication: Bool { state != .plaintext }
    var description: String { "ChatEncryptedAttachmentDescriptor(\(state))" }
    var debugDescription: String { description }

    init(metadata: [String: Any]?, url: URL?, owner: String, referenceIdentity: String) {
        sourceURL = url; self.owner = owner; self.referenceIdentity = referenceIdentity
        let protected = metadata?.keys.contains("encryption-key") == true || metadata?.keys.contains("iv") == true
        let encodedKey = metadata?["encryption-key"] as? String
        let encodedIV = metadata?["iv"] as? String
        key = Self.base64(encodedKey, lengths: [16, 32])
        iv = Self.base64(encodedIV, lengths: [16])
        ciphertextHash = Self.hex(metadata?["hash"] as? String)
        originalSize = Self.size(metadata?["size"])
        let name = (metadata?["name"] as? String) ?? (metadata?["filename"] as? String) ?? ""
        let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
        let mime = (metadata?["media-type"] as? String)?.lowercased() ?? ""
        let fallback = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "video/mp4": "mp4", "video/quicktime": "mov", "audio/ogg": "ogg", "audio/opus": "ogg", "audio/wav": "wav", "audio/x-wav": "wav", "audio/mpeg": "mp3", "application/pdf": "pdf", "text/plain": "txt"][mime] ?? "bin"
        fileExtension = !suffix.isEmpty && suffix.count <= 12 && suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) ? suffix : fallback
        let validURL = url.map { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false && $0.user == nil && $0.password == nil && $0.fragment == nil } ?? false
        let validOwner = !owner.isEmpty && owner.contains("@") && !owner.contains("/") && !owner.contains(where: { $0.isWhitespace })
        state = !protected ? .plaintext : (key != nil && iv != nil && ciphertextHash != nil && originalSize != nil && validURL && validOwner && !referenceIdentity.isEmpty ? .encrypted : .invalid)
        if !protected {
            cacheIdentity = url?.absoluteString ?? ""
        } else {
            let material = Self.framed([Data("xabber-authenticated-file-v1".utf8), Data(owner.utf8), Data((url?.absoluteString ?? "").utf8), Data((encodedKey ?? "invalid-key").utf8), Data((encodedIV ?? "invalid-iv").utf8), Data(((metadata?["hash"] as? String) ?? "invalid-hash").lowercased().utf8), Data(String(originalSize ?? -1).utf8)])
            cacheIdentity = Self.sha256(material)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state && lhs.cacheIdentity == rhs.cacheIdentity }
    func hash(into hasher: inout Hasher) { hasher.combine(state); hasher.combine(cacheIdentity) }

    private static func base64(_ text: String?, lengths: [Int]) -> Data? {
        guard let text, let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text, lengths.contains(bytes.count) else { return nil }
        return bytes
    }
    private static func hex(_ text: String?) -> Data? {
        guard let text, text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var result = Data(); var position = text.startIndex
        while position < text.endIndex { let end = text.index(position, offsetBy: 2); result.append(UInt8(text[position..<end], radix: 16)!); position = end }
        return result
    }
    private static func size(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let value = number.doubleValue
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), value.isFinite, value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        if let text = value as? String, let value = Int(text), value >= 0, String(value) == text { return value }
        return nil
    }
    fileprivate static func framed(_ values: [Data]) -> Data {
        var result = Data()
        for value in values { var length = UInt64(value.count).bigEndian; withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }; result.append(value) }
        return result
    }
    fileprivate static func sha256(_ data: Data) -> String { CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum ChatEncryptedAttachmentReceiveError: Error, Equatable {
    case invalidMetadata, downloadFailed, ciphertextHashMismatch, authenticationFailed, plaintextSizeMismatch, cacheFailure, tooLarge
}
struct ChatAuthenticatedAttachmentFile {
    let fileURL: URL
    let byteCount: Int
    let plaintextSHA256: String
    let cacheIdentity: String
}
protocol ChatEncryptedAttachmentReceiveTask: AnyObject { func cancel() }
private final class ChatEncryptedAttachmentToken: ChatEncryptedAttachmentReceiveTask {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandler: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancelHandler = cancel }
    func cancel() {
        lock.lock(); guard !cancelled else { lock.unlock(); return }; cancelled = true
        let handler = cancelHandler; cancelHandler = nil; lock.unlock(); handler?()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Enforces the receive bound while data arrives, including a response which
/// never finishes. Per-task delegation retains the injected session's policy.
private final class ChatBoundedAttachmentTransfer: NSObject, URLSessionDataDelegate {
    private let maximumBytes: Int
    private let completion: (Result<Data, ChatEncryptedAttachmentReceiveError>) -> Void
    private let lock = NSLock()
    private var data = Data()
    private var acceptedResponse = false
    private var finished = false

    init(maximumBytes: Int, completion: @escaping (Result<Data, ChatEncryptedAttachmentReceiveError>) -> Void) {
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            reject(dataTask, error: .downloadFailed); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            reject(dataTask, error: .tooLarge); completionHandler(.cancel); return
        }
        lock.lock()
        let allow = !finished
        if allow { acceptedResponse = true }
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard acceptedResponse, chunk.count <= maximumBytes - data.count else {
            let error: ChatEncryptedAttachmentReceiveError = acceptedResponse ? .tooLarge : .downloadFailed
            finished = true; data = Data(); lock.unlock()
            dataTask.cancel(); completion(.failure(error)); return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result: Result<Data, ChatEncryptedAttachmentReceiveError> = error == nil && acceptedResponse ? .success(data) : .failure(.downloadFailed)
        data = Data()
        lock.unlock()
        completion(result)
    }

    private func reject(_ task: URLSessionTask, error: ChatEncryptedAttachmentReceiveError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; data = Data(); lock.unlock()
        task.cancel(); completion(.failure(error))
    }
}

/// The sole encrypted-file receive path for thumbnails, opening, playback and saving.
/// It never returns a remote ciphertext URL or unauthenticated bytes.
final class ChatEncryptedAttachmentReceiver {
    static let shared = ChatEncryptedAttachmentReceiver()
    private struct Delivery {
        let token: ChatEncryptedAttachmentToken
        let completion: (Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) -> Void
    }
    private final class Work {
        let descriptor: ChatEncryptedAttachmentDescriptor
        var subscribers: [UUID: Delivery]
        var task: URLSessionDataTask?
        init(descriptor: ChatEncryptedAttachmentDescriptor, subscriber: UUID, delivery: Delivery) { self.descriptor = descriptor; subscribers = [subscriber: delivery] }
        var hasActiveSubscribers: Bool { subscribers.values.contains { !$0.token.isCancelled } }
    }
    private struct CacheRecord: Codable {
        let version: Int
        let identity: String
        let bytes: Int
        let plaintextSHA256: String
        let authentication: String
    }
    private let session: URLSession
    private let cacheDirectory: URL
    private let maximumCiphertextBytes: Int
    private let queue = DispatchQueue(label: "com.xabber.authenticated-attachment-receiver", qos: .userInitiated)
    private var workByIdentity: [String: Work] = [:]

    init(session: URLSession? = nil, cacheDirectory: URL? = nil, maximumCiphertextBytes: Int = 512 * 1_024 * 1_024) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData; configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ChatAuthenticatedMedia-v1", isDirectory: true)
        self.maximumCiphertextBytes = max(16, maximumCiphertextBytes)
    }

    @discardableResult
    func receive(_ descriptor: ChatEncryptedAttachmentDescriptor, completion: @escaping (Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) -> Void) -> ChatEncryptedAttachmentReceiveTask {
        let subscriber = UUID()
        let token = ChatEncryptedAttachmentToken { [weak self] in self?.queue.async { [weak self] in self?.cancel(identity: descriptor.cacheIdentity, subscriber: subscriber) } }
        let delivery = Delivery(token: token, completion: completion)
        queue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            guard descriptor.state == .encrypted, let url = descriptor.sourceURL, let size = descriptor.originalSize else { return self.deliver(.failure(.invalidMetadata), to: delivery) }
            guard size <= self.maximumCiphertextBytes - 16 else { return self.deliver(.failure(.tooLarge), to: delivery) }
            if let existing = self.workByIdentity[descriptor.cacheIdentity] { existing.subscribers[subscriber] = delivery; return }
            let work = Work(descriptor: descriptor, subscriber: subscriber, delivery: delivery)
            self.workByIdentity[descriptor.cacheIdentity] = work
            if let file = self.readCache(descriptor) { self.finish(work, result: .success(file)); return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpShouldHandleCookies = false
            let transfer = ChatBoundedAttachmentTransfer(maximumBytes: self.maximumCiphertextBytes) { [weak self, weak work] result in
                guard let self, let work else { return }
                self.queue.async {
                    guard self.workByIdentity[descriptor.cacheIdentity] === work else { return }
                    guard work.hasActiveSubscribers else { self.workByIdentity.removeValue(forKey: descriptor.cacheIdentity); return }
                    let data: Data
                    switch result {
                    case .success(let value): data = value
                    case .failure(let error): self.finish(work, result: .failure(error)); return
                    }
                    do {
                        let plaintext = try self.authenticate(data, descriptor: descriptor)
                        guard work.hasActiveSubscribers else { self.workByIdentity.removeValue(forKey: descriptor.cacheIdentity); return }
                        let file = try self.writeCache(plaintext, descriptor: descriptor)
                        guard work.hasActiveSubscribers else { self.removeCache(descriptor); self.workByIdentity.removeValue(forKey: descriptor.cacheIdentity); return }
                        self.finish(work, result: .success(file))
                    } catch let error as ChatEncryptedAttachmentReceiveError { self.finish(work, result: .failure(error)) }
                    catch { self.finish(work, result: .failure(.cacheFailure)) }
                }
            }
            work.task = self.session.dataTask(with: request)
            work.task?.delegate = transfer
            work.task?.resume()
        }
        return token
    }

    private func authenticate(_ ciphertext: Data, descriptor: ChatEncryptedAttachmentDescriptor) throws -> Data {
        guard let key = descriptor.key, let iv = descriptor.iv, let expectedHash = descriptor.ciphertextHash, let originalSize = descriptor.originalSize else { throw ChatEncryptedAttachmentReceiveError.invalidMetadata }
        guard Data(CryptoKit.SHA256.hash(data: ciphertext)) == expectedHash else { throw ChatEncryptedAttachmentReceiveError.ciphertextHashMismatch }
        let plaintext: Data
        do { guard ciphertext.count >= 16, let value = try Data.decrypt(ciphertext, key: Array(key), iv: Array(iv)) else { throw ChatEncryptedAttachmentReceiveError.authenticationFailed }; plaintext = value }
        catch { throw ChatEncryptedAttachmentReceiveError.authenticationFailed }
        guard plaintext.count == originalSize else { throw ChatEncryptedAttachmentReceiveError.plaintextSizeMismatch }
        return plaintext
    }
    private func cancel(identity: String, subscriber: UUID) {
        guard let work = workByIdentity[identity] else { return }
        work.subscribers.removeValue(forKey: subscriber)
        if !work.hasActiveSubscribers { work.task?.cancel(); workByIdentity.removeValue(forKey: identity) }
    }
    private func deliver(_ result: Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>, to delivery: Delivery) {
        DispatchQueue.main.async { guard !delivery.token.isCancelled else { return }; delivery.completion(result) }
    }
    private func finish(_ work: Work, result: Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) {
        guard workByIdentity[work.descriptor.cacheIdentity] === work else { return }
        workByIdentity.removeValue(forKey: work.descriptor.cacheIdentity)
        work.subscribers.values.forEach { deliver(result, to: $0) }
    }
    private func paths(_ descriptor: ChatEncryptedAttachmentDescriptor) -> (file: URL, record: URL) {
        (cacheDirectory.appendingPathComponent(descriptor.cacheIdentity + "." + descriptor.fileExtension), cacheDirectory.appendingPathComponent(descriptor.cacheIdentity + ".json"))
    }
    private func cacheAuthentication(_ descriptor: ChatEncryptedAttachmentDescriptor, bytes: Int, digest: String) -> Data {
        let material = ChatEncryptedAttachmentDescriptor.framed([Data("xabber-authenticated-file-cache-v1".utf8), Data(descriptor.cacheIdentity.utf8), Data(String(bytes).utf8), Data(digest.utf8)])
        let key = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: descriptor.key!), salt: Data(), info: Data("xabber-authenticated-file-cache-key-v1".utf8), outputByteCount: 32)
        return Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: material, using: key))
    }
    private func readCache(_ descriptor: ChatEncryptedAttachmentDescriptor) -> ChatAuthenticatedAttachmentFile? {
        let path = paths(descriptor)
        guard FileManager.default.fileExists(atPath: path.file.path) || FileManager.default.fileExists(atPath: path.record.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: path.record))
            let attributes = try FileManager.default.attributesOfItem(atPath: path.file.path)
            guard record.version == 1, record.identity == descriptor.cacheIdentity, record.bytes == descriptor.originalSize, record.bytes <= maximumCiphertextBytes, (attributes[.size] as? NSNumber)?.intValue == record.bytes else { removeCache(descriptor); return nil }
            let plaintext = try Data(contentsOf: path.file, options: .mappedIfSafe)
            let digest = ChatEncryptedAttachmentDescriptor.sha256(plaintext)
            guard digest == record.plaintextSHA256, let authentication = Data(base64Encoded: record.authentication), authentication == cacheAuthentication(descriptor, bytes: record.bytes, digest: digest) else { removeCache(descriptor); return nil }
            return ChatAuthenticatedAttachmentFile(fileURL: path.file, byteCount: record.bytes, plaintextSHA256: digest, cacheIdentity: descriptor.cacheIdentity)
        } catch { removeCache(descriptor); return nil }
    }
    private func writeCache(_ plaintext: Data, descriptor: ChatEncryptedAttachmentDescriptor) throws -> ChatAuthenticatedAttachmentFile {
        let path = paths(descriptor)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var directory = cacheDirectory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            let digest = ChatEncryptedAttachmentDescriptor.sha256(plaintext)
            let record = CacheRecord(version: 1, identity: descriptor.cacheIdentity, bytes: plaintext.count, plaintextSHA256: digest, authentication: cacheAuthentication(descriptor, bytes: plaintext.count, digest: digest).base64EncodedString())
            try plaintext.write(to: path.file, options: .atomic)
            try JSONEncoder().encode(record).write(to: path.record, options: .atomic)
            for url in [path.file, path.record] { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path) }
            return ChatAuthenticatedAttachmentFile(fileURL: path.file, byteCount: plaintext.count, plaintextSHA256: digest, cacheIdentity: descriptor.cacheIdentity)
        } catch { removeCache(descriptor); throw ChatEncryptedAttachmentReceiveError.cacheFailure }
    }
    private func removeCache(_ descriptor: ChatEncryptedAttachmentDescriptor) { let path = paths(descriptor); try? FileManager.default.removeItem(at: path.file); try? FileManager.default.removeItem(at: path.record) }
}
