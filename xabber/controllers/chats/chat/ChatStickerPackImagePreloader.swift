import Foundation

@MainActor
protocol ChatStickerPackImagePreloading {
    func preload(_ pack: ChatStickerPack, owner: String, profile: ChatStickerImageProfile)
    func cancel(manifestURL: URL, owner: String)
    func cancel(owner: String)
}

@MainActor
final class ChatStickerPackImagePreloader: ChatStickerPackImagePreloading {
    private struct BatchKey: Hashable {
        let owner: String
        let manifestURL: URL
    }

    private struct Batch {
        let version: Int
        let requests: [ChatThumbnailRequest]
        var nextRequestIndex = 0
    }

    private struct ActiveLoad {
        let batch: BatchKey
        let task: ChatThumbnailLoadTask
    }

    private let loader: ChatThumbnailLoading
    private let maxConcurrentLoads: Int
    private var batches: [BatchKey: Batch] = [:]
    private var pendingBatches: [BatchKey] = []
    private var activeLoads: [UUID: ActiveLoad] = [:]

    init(loader: ChatThumbnailLoading = KingfisherChatThumbnailLoader(), maxConcurrentLoads: Int = 3) {
        self.loader = loader
        self.maxConcurrentLoads = max(1, maxConcurrentLoads)
    }

    deinit {
        for load in activeLoads.values {
            load.task.cancel()
        }
    }

    func preload(_ pack: ChatStickerPack, owner: String, profile: ChatStickerImageProfile) {
        let key = BatchKey(owner: owner, manifestURL: pack.manifestURL)
        var gridURLs: Set<URL> = []
        var requests: [ChatThumbnailRequest] = []
        for sticker in pack.stickers where gridURLs.insert(sticker.imageURL).inserted {
            requests.append(profile.request(url: sticker.imageURL, owner: owner, size: ChatStickerImageProfile.gridSize))
        }
        if let cover = pack.coverURL ?? pack.stickers.first?.imageURL {
            requests.append(profile.request(url: cover, owner: owner, size: ChatStickerImageProfile.packCoverSize))
        }
        guard !requests.isEmpty else { return }
        if let existing = batches[key], existing.version == pack.version, existing.requests == requests {
            return
        }
        cancelBatch(key)
        batches[key] = Batch(version: pack.version, requests: requests)
        pendingBatches.append(key)
        startPendingLoads()
    }

    func cancel(manifestURL: URL, owner: String) {
        cancelBatch(BatchKey(owner: owner, manifestURL: manifestURL))
        startPendingLoads()
    }

    func cancel(owner: String) {
        for key in batches.keys.filter({ $0.owner == owner }) {
            cancelBatch(key)
        }
        startPendingLoads()
    }

    private func cancelBatch(_ key: BatchKey) {
        guard batches.removeValue(forKey: key) != nil else { return }
        pendingBatches.removeAll { $0 == key }
        let cancelledLoads = activeLoads.filter { $0.value.batch == key }
        for (identifier, load) in cancelledLoads {
            activeLoads.removeValue(forKey: identifier)
            load.task.cancel()
        }
    }

    private func startPendingLoads() {
        while activeLoads.count < maxConcurrentLoads, let key = pendingBatches.first, var batch = batches[key] {
            pendingBatches.removeFirst()
            let request = batch.requests[batch.nextRequestIndex]
            batch.nextRequestIndex += 1
            batches[key] = batch
            if batch.nextRequestIndex < batch.requests.count {
                pendingBatches.append(key)
            }

            let identifier = UUID()
            let task = loader.load(request) { [weak self] _ in
                // A processed cache hit can call back before load() returns its token.
                Task { @MainActor [weak self] in
                    self?.finish(identifier)
                }
            }
            activeLoads[identifier] = ActiveLoad(batch: key, task: task)
        }
    }

    private func finish(_ identifier: UUID) {
        guard let load = activeLoads.removeValue(forKey: identifier), let batch = batches[load.batch] else { return }
        if batch.nextRequestIndex == batch.requests.count,
           !activeLoads.values.contains(where: { $0.batch == load.batch }) {
            batches.removeValue(forKey: load.batch)
        }
        startPendingLoads()
    }
}
