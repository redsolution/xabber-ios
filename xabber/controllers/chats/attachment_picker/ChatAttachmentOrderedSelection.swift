import CoreGraphics
import Foundation

enum ChatAttachmentSelectionBlockReason: Equatable {
    case maximumSelectionCountReached
}

enum ChatAttachmentSelectionToggleResult: Equatable {
    case selected([AttachmentDraft])
    case deselected([AttachmentDraft])
    case blocked(reason: ChatAttachmentSelectionBlockReason, drafts: [AttachmentDraft])

    var drafts: [AttachmentDraft] {
        switch self {
        case .selected(let drafts), .deselected(let drafts):
            return drafts
        case .blocked(_, let drafts):
            return drafts
        }
    }
}

struct ChatAttachmentSelectionPolicy {
    let maximumSelectedCount: Int

    init(maximumSelectedCount: Int = 10) {
        self.maximumSelectedCount = maximumSelectedCount
    }

    func toggle(
        draft: AttachmentDraft,
        in selectedDrafts: [AttachmentDraft]
    ) -> ChatAttachmentSelectionToggleResult {
        if let existingIndex = selectedDrafts.firstIndex(where: { $0.id == draft.id }) {
            var updatedDrafts = selectedDrafts
            updatedDrafts.remove(at: existingIndex)
            return .deselected(updatedDrafts)
        }

        guard selectedDrafts.count < maximumSelectedCount else {
            return .blocked(reason: .maximumSelectionCountReached, drafts: selectedDrafts)
        }

        return .selected(selectedDrafts + [draft])
    }
}

struct ChatAttachmentGalleryDraftBuilder {
    func makeDraft(from asset: ChatAttachmentGalleryAsset) -> AttachmentDraft {
        AttachmentDraft(
            id: AttachmentAssetDraft(assetLocalIdentifier: asset.localIdentifier).id,
            source: .gallery,
            mediaKind: asset.mediaKind,
            thumbnailState: .none,
            filename: filename(for: asset),
            byteSize: 0,
            duration: asset.duration.map { Int($0.rounded()) },
            dimensions: asset.pixelSize,
            preparationState: .pending
        )
    }

    private func filename(for asset: ChatAttachmentGalleryAsset) -> String {
        "\(sanitizedFilenameStem(from: asset.localIdentifier)).\(fileExtension(for: asset.mediaKind))"
    }

    private func sanitizedFilenameStem(from localIdentifier: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = localIdentifier.unicodeScalars
            .map { scalar in allowedCharacters.contains(scalar) ? String(scalar) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stem.isEmpty ? "asset" : stem
    }

    private func fileExtension(for mediaKind: AttachmentMediaKind) -> String {
        switch mediaKind {
        case .video:
            return "mov"
        case .animatedImage:
            return "gif"
        case .image:
            return "jpg"
        case .audio:
            return "m4a"
        case .file:
            return "dat"
        case .location:
            return "geo"
        }
    }
}
