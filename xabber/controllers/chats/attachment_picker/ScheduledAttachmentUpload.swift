import CryptoKit
import Foundation

enum ScheduledAttachmentUploadError: Error, Equatable {
    case invalidSelection
    case cloudUnavailable
    case cloudPending
    case quotaExceeded
    case routeUnavailable
    case localFileUnavailable
    case invalidResponse
    case uploadFailed
}

protocol ScheduledAttachmentFileUploading {
    func upload(
        file: AttachmentPreparedFile,
        owner: String,
        encrypted: Bool,
        completion: @escaping (Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>) -> Void
    )
}

struct ScheduledAttachmentUploadPayload {
    let data: Data
    let filename: String
    let mimeType: String
    let privateMetadata: [String: String]?

    static func make(data: Data, filename: String, mimeType: String, encrypted: Bool) throws -> Self {
        guard encrypted else {
            return Self(data: data, filename: filename, mimeType: mimeType, privateMetadata: nil)
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let iv = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        guard let ciphertext = try data.encrypt(key: Array(key), iv: Array(iv)) else {
            throw ScheduledAttachmentUploadError.uploadFailed
        }
        let encryptedFilename = UUID().uuidString + ".bin"
        return Self(
            data: ciphertext,
            filename: encryptedFilename,
            mimeType: "application/octet-stream",
            privateMetadata: [
                "encryption-key": key.base64EncodedString(),
                "iv": iv.base64EncodedString(),
                "hash": ciphertext.sha256Data.hexEncodedString(),
                "size": String(data.count)
            ]
        )
    }
}

/// Prepares the ordinary file-sharing references without admitting an outgoing message.
final class ScheduledAttachmentUpload {
    private struct CachedFile {
        let local: AttachmentPreparedFile
        let remote: AttachmentUploadedRemoteFile
    }

    private struct Scope: Equatable {
        let owner: String
        let jid: String
        let type: ClientSynchronizationManager.ConversationType
        let gallery: String?
    }

    private let fileUploader: ScheduledAttachmentFileUploading
    private let cloudAvailability: ChatAttachmentCloudStorageAvailabilityProviding
    private let quotaAccess: ChatAttachmentQuotaAccessProviding
    private let galleryScope: (String) -> String?
    private let referenceBuilder = ChatAttachmentReferenceBuilder()
    private var cachedScope: Scope?
    private var cachedFiles: [String: CachedFile] = [:]
    private var isPreparing = false

    init(
        fileUploader: ScheduledAttachmentFileUploading = AccountScheduledAttachmentFileUploader(),
        cloudAvailability: ChatAttachmentCloudStorageAvailabilityProviding = AccountChatAttachmentCloudStorageAvailabilityProvider(),
        quotaAccess: ChatAttachmentQuotaAccessProviding = MediaUploadQuotaAccessProvider(),
        galleryScope: @escaping (String) -> String? = { AccountGalleryConfiguration(owner: $0).currentGalleryIdentity }
    ) {
        self.fileUploader = fileUploader
        self.cloudAvailability = cloudAvailability
        self.quotaAccess = quotaAccess
        self.galleryScope = galleryScope
    }

    static func supports(_ drafts: [AttachmentDraft], context: ChatAttachmentFlowContext) -> Bool {
        [.regular, .group, .saved, .omemo].contains(context.conversationType)
            && !drafts.isEmpty
            && drafts.allSatisfy { draft in
                guard draft.mediaKind != .location, draft.mediaKind != .contact,
                      case .prepared(let file) = draft.preparationState else { return false }
                guard file.byteSize >= 0, !file.filename.isEmpty, !file.mediaType.isEmpty else { return false }
                return file.uploadedRemoteFile.map { matchesProtection($0, owner: context.owner, type: context.conversationType) } ?? true
            }
    }

    func prepare(
        drafts: [AttachmentDraft],
        context: ChatAttachmentFlowContext,
        canContinue: @escaping () -> Bool = { true },
        progress: @escaping (_ completed: Int, _ total: Int) -> Void,
        completion: @escaping (Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>) -> Void
    ) {
        guard !isPreparing, Self.supports(drafts, context: context) else {
            completion(.failure(.invalidSelection))
            return
        }
        guard canContinue() else {
            completion(.failure(.routeUnavailable))
            return
        }
        let scope = Scope(owner: context.owner, jid: context.jid, type: context.conversationType,
                          gallery: galleryScope(context.owner))
        if cachedScope != scope {
            cachedScope = scope
            cachedFiles.removeAll()
        }
        let candidates = drafts.map { draft in
            Self.applyingCachedUpload(to: draft, cached: cachedFiles[draft.id])
        }
        let keptIDs = Set(drafts.map(\.id))
        cachedFiles = cachedFiles.filter { keptIDs.contains($0.key) }

        if candidates.contains(where: \.requiresUpload),
           let error = uploadBlock(for: context.owner) {
            completion(.failure(error))
            return
        }

        isPreparing = true
        progress(0, drafts.count)
        var prepared: [AttachmentDraft] = []

        func finish(_ result: Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>) {
            isPreparing = false
            completion(result)
        }

        func prepareNext() {
            guard canContinue(), galleryScope(context.owner) == scope.gallery else {
                finish(.failure(.routeUnavailable))
                return
            }
            // Skip already-hosted selections without using stack space per file.
            while prepared.count < candidates.count {
                let index = prepared.count
                let draft = candidates[index]
                guard case .prepared(let file) = draft.preparationState else {
                    finish(.failure(.invalidSelection))
                    return
                }
                if let remote = file.uploadedRemoteFile {
                    guard Self.matchesProtection(remote, owner: context.owner, type: context.conversationType) else {
                        finish(.failure(.invalidResponse))
                        return
                    }
                    prepared.append(draft)
                    progress(prepared.count, drafts.count)
                    continue
                }
                guard file.localFileURL.isFileURL else {
                    finish(.failure(.localFileUnavailable))
                    return
                }
                fileUploader.upload(file: file, owner: context.owner, encrypted: context.conversationType == .omemo) { result in
                    let receive = {
                        switch result {
                        case .failure(let error):
                            finish(.failure(error))
                        case .success(let remote):
                            guard Self.matchesProtection(remote, owner: context.owner, type: context.conversationType) else {
                                finish(.failure(.invalidResponse))
                                return
                            }
                            let cached = CachedFile(local: file, remote: remote)
                            self.cachedFiles[draft.id] = cached
                            prepared.append(Self.applyingCachedUpload(to: draft, cached: cached))
                            progress(prepared.count, drafts.count)
                            prepareNext()
                        }
                    }
                    if Thread.isMainThread { receive() }
                    else { DispatchQueue.main.async(execute: receive) }
                }
                return
            }

            do {
                let references = try referenceBuilder.makeReferences(from: prepared, context: context)
                for reference in references {
                    reference.temporaryData = nil
                    if reference.metadata?["thumbnail-uri"] == nil,
                       let url = reference.videoPreviewUrl, Self.isRemoteURL(url) {
                        reference.metadata?["thumbnail-uri"] = url.absoluteString
                    }
                }
                finish(.success(references))
            } catch {
                finish(.failure(.invalidSelection))
            }
        }

        prepareNext()
    }

    private func uploadBlock(for owner: String) -> ScheduledAttachmentUploadError? {
        guard cloudAvailability.isCloudStorageAvailable(owner: owner) else {
            if let provider = cloudAvailability as? ChatAttachmentCloudStorageStateProviding,
               case .unsupported = provider.cloudStorageAvailabilityState(owner: owner) {
                return .cloudUnavailable
            }
            return .cloudPending
        }
        return quotaAccess.currentAccess(owner: owner) == .premiumRequired ? .quotaExceeded : nil
    }

    private static func applyingCachedUpload(to draft: AttachmentDraft, cached: CachedFile?) -> AttachmentDraft {
        guard let cached, case .prepared(var file) = draft.preparationState,
              file.uploadedRemoteFile == nil, file == cached.local else { return draft }
        file.uploadedRemoteFile = cached.remote
        var result = draft
        result.preparationState = .prepared(file)
        return result
    }

    static func isRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    private static func matchesProtection(
        _ remote: AttachmentUploadedRemoteFile, owner: String, type: ClientSynchronizationManager.ConversationType
    ) -> Bool {
        guard isRemoteURL(remote.remoteURL) else { return false }
        let descriptor = ChatEncryptedAttachmentDescriptor(
            metadata: remote.metadata, url: remote.remoteURL, owner: owner, referenceIdentity: String(remote.fileID)
        )
        return type == .omemo
            ? descriptor.state == .encrypted && remote.metadata?["hash"] != nil
            : descriptor.state == .plaintext
    }
}

private final class AccountScheduledAttachmentFileUploader: ScheduledAttachmentFileUploading {
    private static let readQueue = DispatchQueue(label: "com.xabber.scheduled-attachment-file", qos: .userInitiated)

    func upload(
        file: AttachmentPreparedFile,
        owner: String,
        encrypted: Bool,
        completion: @escaping (Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>) -> Void
    ) {
        guard let account = AccountManager.shared.find(for: owner), account.jid == owner else {
            completion(.failure(.routeUnavailable))
            return
        }
        Self.readQueue.async {
            let upload: ScheduledAttachmentUploadPayload
            do {
                let data = try Data(contentsOf: file.localFileURL, options: .mappedIfSafe)
                upload = try ScheduledAttachmentUploadPayload.make(
                    data: data, filename: file.filename, mimeType: file.mediaType, encrypted: encrypted
                )
            } catch let error as ScheduledAttachmentUploadError {
                completion(.failure(error))
                return
            } catch {
                completion(.failure(.localFileUnavailable))
                return
            }
            account.action { account, _ in
                guard AccountManager.shared.find(for: owner) === account else {
                    completion(.failure(.routeUnavailable))
                    return
                }

                var metadata: [String: String] = [:]
                if !encrypted {
                    if let preview = file.videoPreviewKey { metadata["video_preview_key"] = preview }
                    if let duration = file.duration { metadata["duration"] = String(duration) }
                }
                account.cloudStorage.uploadMedia(
                    data: upload.data,
                    filename: upload.filename,
                    mimeType: upload.mimeType,
                    metadata: metadata.isEmpty ? nil : metadata
                ) { response in
                    guard AccountManager.shared.find(for: owner) === account else {
                        completion(.failure(.routeUnavailable))
                        return
                    }
                    completion(Self.parse(response, privateMetadata: upload.privateMetadata))
                }
            }
        }
    }

    private static func parse(_ response: CloudStorageQuotaAPIResponse, privateMetadata: [String: String]?)
        -> Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>
    {
        if case .failure(let status, _, _) = response {
            return .failure(status == 403 ? .quotaExceeded : .uploadFailed)
        }
        guard case .response(let status, let value, _) = response,
              let status else { return .failure(.uploadFailed) }
        if status == 403 { return .failure(.quotaExceeded) }
        guard (200..<300).contains(status) else { return .failure(.uploadFailed) }
        guard let json = value as? [String: Any],
              let rawURL = json["file"] as? String,
              let url = URL(string: rawURL), ScheduledAttachmentUpload.isRemoteURL(url),
              let fileID = (json["id"] as? NSNumber)?.intValue ?? (json["id"] as? String).flatMap(Int.init),
              fileID > 0 else { return .failure(.invalidResponse) }
        let thumbnail = (json["thumbnail"] as? [String: Any])?["url"] as? String
        let metadata: [String: String]? = privateMetadata ?? thumbnail.flatMap { raw in
            guard let thumbnailURL = URL(string: raw), ScheduledAttachmentUpload.isRemoteURL(thumbnailURL) else { return nil }
            return ["thumbnail": thumbnailURL.absoluteString, "thumbnail-uri": thumbnailURL.absoluteString]
        }
        return .success(AttachmentUploadedRemoteFile(remoteURL: url, fileID: fileID,
                                                       hash: privateMetadata?["hash"] ?? json["hash"] as? String,
                                                       createdAt: nil, metadata: metadata))
    }
}
