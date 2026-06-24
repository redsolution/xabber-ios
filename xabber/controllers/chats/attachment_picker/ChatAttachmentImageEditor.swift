import Photos
import UIKit

struct AttachmentEditedDraft: Equatable, Hashable {
    private static let idPrefix = "edited:"

    let url: URL

    var id: String {
        Self.idPrefix + url.absoluteString
    }

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    static func url(from id: String) -> URL? {
        guard id.hasPrefix(idPrefix) else {
            return nil
        }

        let urlString = String(id.dropFirst(idPrefix.count))
        return URL(string: urlString)?.standardizedFileURL
    }
}

enum ChatAttachmentImageEditAvailabilityPolicy {
    static func isEditable(_ draft: AttachmentDraft) -> Bool {
        draft.mediaKind == .image
    }
}

enum ChatAttachmentImageEditSourceError: Error, Equatable {
    case assetUnavailable
    case unreadableFile
    case unavailable
}

protocol ChatAttachmentImageEditSourceProviding: AnyObject {
    @discardableResult
    func requestEditableImage(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (Result<UIImage, ChatAttachmentImageEditSourceError>) -> Void
    ) -> Int

    func cancelEditableImageRequest(_ requestID: Int)
}

final class DefaultChatAttachmentImageEditSourceProvider: ChatAttachmentImageEditSourceProviding {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = PHImageManager.default()) {
        self.imageManager = imageManager
    }

    @discardableResult
    func requestEditableImage(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (Result<UIImage, ChatAttachmentImageEditSourceError>) -> Void
    ) -> Int {
        guard ChatAttachmentImageEditAvailabilityPolicy.isEditable(draft) else {
            completion(.failure(.unavailable))
            return Int(PHInvalidImageRequestID)
        }

        if let localURL = draft.editedLocalFileURL ?? draft.capturedLocalFileURL {
            guard let image = UIImage(contentsOfFile: localURL.path) else {
                completion(.failure(.unreadableFile))
                return Int(PHInvalidImageRequestID)
            }

            completion(.success(image))
            return Int(PHInvalidImageRequestID)
        }

        if draft.source == .file,
           case .prepared(let file) = draft.preparationState {
            guard let image = UIImage(contentsOfFile: file.localFileURL.path) else {
                completion(.failure(.unreadableFile))
                return Int(PHInvalidImageRequestID)
            }

            completion(.success(image))
            return Int(PHInvalidImageRequestID)
        }

        guard let assetLocalIdentifier = draft.galleryAssetLocalIdentifier else {
            completion(.failure(.unavailable))
            return Int(PHInvalidImageRequestID)
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil).firstObject else {
            completion(.failure(.assetUnavailable))
            return Int(PHInvalidImageRequestID)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = false

        let targetSize = targetSize == .zero
            ? PHImageManagerMaximumSize
            : targetSize

        return Int(
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    return
                }

                guard let image else {
                    completion(.failure(.assetUnavailable))
                    return
                }

                completion(.success(image))
            }
        )
    }

    func cancelEditableImageRequest(_ requestID: Int) {
        guard requestID != Int(PHInvalidImageRequestID) else {
            return
        }

        imageManager.cancelImageRequest(PHImageRequestID(requestID))
    }
}

enum ChatAttachmentImageRotation: Int, Equatable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    var nextClockwise: ChatAttachmentImageRotation {
        switch self {
        case .degrees0:
            return .degrees90
        case .degrees90:
            return .degrees180
        case .degrees180:
            return .degrees270
        case .degrees270:
            return .degrees0
        }
    }

    var radians: CGFloat {
        CGFloat(rawValue) * .pi / 180
    }
}

struct ChatAttachmentImageCropState: Equatable {
    let rotation: ChatAttachmentImageRotation
    let rotatedImageSize: CGSize
    let cropRect: CGRect
}

enum ChatAttachmentImageCropGeometryPolicy {
    static func cropRect(
        imageSize: CGSize,
        viewportSize: CGSize,
        zoomScale: CGFloat,
        contentOffset: CGPoint
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }

        let safeZoomScale = max(zoomScale, 0.0001)
        let width = min(imageSize.width, viewportSize.width / safeZoomScale)
        let height = min(imageSize.height, viewportSize.height / safeZoomScale)
        let maxX = max(0, imageSize.width - width)
        let maxY = max(0, imageSize.height - height)
        let originX = min(max(contentOffset.x / safeZoomScale, 0), maxX)
        let originY = min(max(contentOffset.y / safeZoomScale, 0), maxY)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func stateAfterRotatingClockwise(
        imageSize: CGSize,
        viewportSize: CGSize,
        currentRotation: ChatAttachmentImageRotation
    ) -> ChatAttachmentImageCropState {
        let rotation = currentRotation.nextClockwise
        let rotatedImageSize = rotatedSize(for: imageSize, rotation: rotation)
        let cropRect = cropRect(
            imageSize: rotatedImageSize,
            viewportSize: viewportSize,
            zoomScale: 1,
            contentOffset: .zero
        )

        return ChatAttachmentImageCropState(
            rotation: rotation,
            rotatedImageSize: rotatedImageSize,
            cropRect: cropRect
        )
    }

    static func rotatedSize(
        for imageSize: CGSize,
        rotation: ChatAttachmentImageRotation
    ) -> CGSize {
        switch rotation {
        case .degrees0, .degrees180:
            return imageSize
        case .degrees90, .degrees270:
            return CGSize(width: imageSize.height, height: imageSize.width)
        }
    }
}

protocol ChatAttachmentImageEditOutputBuilding: AnyObject {
    func makeEditedDraft(
        sourceDraft: AttachmentDraft,
        sourceImage: UIImage,
        cropRect: CGRect,
        rotation: ChatAttachmentImageRotation
    ) throws -> AttachmentDraft

    func removeTemporaryFiles(for draft: AttachmentDraft)
}

enum ChatAttachmentImageEditOutputBuilderError: Error, Equatable {
    case invalidCropRect
    case imageEncodingFailed
    case unableToCreateOutputDirectory
    case unableToWriteOutput
}

final class ChatAttachmentImageEditOutputBuilder: ChatAttachmentImageEditOutputBuilding {
    private let outputDirectory: URL
    private let uuidProvider: () -> UUID
    private let fileManager: FileManager
    private let jpegCompressionQuality: CGFloat

    init(
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-attachment-edits-\(UUID().uuidString)", isDirectory: true),
        uuidProvider: @escaping () -> UUID = UUID.init,
        fileManager: FileManager = .default,
        jpegCompressionQuality: CGFloat = 0.9
    ) {
        self.outputDirectory = outputDirectory
        self.uuidProvider = uuidProvider
        self.fileManager = fileManager
        self.jpegCompressionQuality = jpegCompressionQuality
    }

    func makeEditedDraft(
        sourceDraft: AttachmentDraft,
        sourceImage: UIImage,
        cropRect: CGRect,
        rotation: ChatAttachmentImageRotation
    ) throws -> AttachmentDraft {
        try createOutputDirectoryIfNeeded()

        let outputImage = try ChatAttachmentImageEditRenderer.editedImage(
            sourceImage: sourceImage,
            cropRect: cropRect,
            rotation: rotation
        )

        guard let data = outputImage.jpegData(compressionQuality: jpegCompressionQuality) else {
            throw ChatAttachmentImageEditOutputBuilderError.imageEncodingFailed
        }

        let uuid = uuidProvider().uuidString
        let filename = "edited-image-\(uuid).jpg"
        let fileURL = outputDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ChatAttachmentImageEditOutputBuilderError.unableToWriteOutput
        }

        let preparedFile = AttachmentPreparedFile(
            localFileURL: fileURL,
            referenceURL: fileURL,
            filename: filename,
            byteSize: data.count,
            mediaType: "image/jpeg",
            dimensions: outputImage.size,
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )

        return AttachmentDraft(
            id: AttachmentEditedDraft(url: fileURL).id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .available(key: fileURL.absoluteString),
            filename: filename,
            byteSize: data.count,
            duration: nil,
            dimensions: outputImage.size,
            preparationState: .prepared(preparedFile),
            originalDraftID: sourceDraft.originalDraftID ?? sourceDraft.id
        )
    }

    func removeTemporaryFiles(for draft: AttachmentDraft) {
        guard let fileURL = AttachmentEditedDraft.url(from: draft.id) else {
            return
        }

        try? fileManager.removeItem(at: fileURL)
    }

    private func createOutputDirectoryIfNeeded() throws {
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw ChatAttachmentImageEditOutputBuilderError.unableToCreateOutputDirectory
        }
    }
}

enum ChatAttachmentImageEditRenderer {
    static func editedImage(
        sourceImage: UIImage,
        cropRect: CGRect,
        rotation: ChatAttachmentImageRotation
    ) throws -> UIImage {
        let rotatedImage = rotated(sourceImage, rotation: rotation)
        let imageBounds = CGRect(origin: .zero, size: rotatedImage.size)
        let cropRect = cropRect.integral.intersection(imageBounds)

        guard cropRect.width > 0,
              cropRect.height > 0 else {
            throw ChatAttachmentImageEditOutputBuilderError.invalidCropRect
        }

        return UIGraphicsImageRenderer(size: cropRect.size).image { _ in
            rotatedImage.draw(at: CGPoint(x: -cropRect.minX, y: -cropRect.minY))
        }
    }

    static func rotated(
        _ image: UIImage,
        rotation: ChatAttachmentImageRotation
    ) -> UIImage {
        let normalized = normalized(image)
        guard rotation != .degrees0 else {
            return normalized
        }

        let outputSize = ChatAttachmentImageCropGeometryPolicy.rotatedSize(
            for: normalized.size,
            rotation: rotation
        )

        return UIGraphicsImageRenderer(size: outputSize).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cgContext.rotate(by: rotation.radians)
            normalized.draw(
                in: CGRect(
                    x: -normalized.size.width / 2,
                    y: -normalized.size.height / 2,
                    width: normalized.size.width,
                    height: normalized.size.height
                )
            )
        }
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else {
            return image
        }

        return UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

protocol ChatAttachmentImageEditorViewControllerDelegate: AnyObject {
    func chatAttachmentImageEditorViewControllerDidCancel(_ editor: ChatAttachmentImageEditorViewController)
    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFinishWith editedDraft: AttachmentDraft
    )
    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFailWith error: ChatAttachmentImageEditOutputBuilderError
    )
}

final class ChatAttachmentImageEditorViewController: UIViewController {
    weak var delegate: ChatAttachmentImageEditorViewControllerDelegate?

    let draft: AttachmentDraft
    let cancelButton = UIButton(type: .system)
    let rotateButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)
    let scrollView = UIScrollView()
    let imageView = UIImageView()

    private let sourceImage: UIImage
    private let outputBuilder: ChatAttachmentImageEditOutputBuilding
    private var currentRotation: ChatAttachmentImageRotation = .degrees0
    private var displayedImage: UIImage
    private var didConfigureInitialZoom = false

    init(
        draft: AttachmentDraft,
        image: UIImage,
        outputBuilder: ChatAttachmentImageEditOutputBuilding = ChatAttachmentImageEditOutputBuilder()
    ) {
        self.draft = draft
        self.sourceImage = image
        self.displayedImage = image
        self.outputBuilder = outputBuilder
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black

        configureButton(
            cancelButton,
            title: ChatAttachmentLocalization.string(.actionCancel),
            systemImageName: "xmark",
            accessibilityIdentifier: "chatAttachmentImageEditor.cancelButton"
        )
        cancelButton.addTarget(self, action: #selector(cancelButtonTapped), for: .touchUpInside)

        configureButton(
            rotateButton,
            title: ChatAttachmentLocalization.string(.editorRotateAction),
            systemImageName: "rotate.right",
            accessibilityIdentifier: "chatAttachmentImageEditor.rotateButton"
        )
        rotateButton.addTarget(self, action: #selector(rotateButtonTapped), for: .touchUpInside)

        configureButton(
            doneButton,
            title: ChatAttachmentLocalization.string(.actionDone),
            systemImageName: "checkmark",
            accessibilityIdentifier: "chatAttachmentImageEditor.doneButton"
        )
        doneButton.addTarget(self, action: #selector(doneButtonTapped), for: .touchUpInside)

        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "chatAttachmentImageEditor.scrollView"

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.image = displayedImage
        imageView.isAccessibilityElement = false
        imageView.accessibilityIdentifier = "chatAttachmentImageEditor.imageView"

        let toolbar = UIStackView(arrangedSubviews: [cancelButton, rotateButton, doneButton])
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.distribution = .equalSpacing
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.accessibilityIdentifier = "chatAttachmentImageEditor.toolbar"

        rootView.addSubview(toolbar)
        rootView.addSubview(scrollView)
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didConfigureInitialZoom {
            resetZoomForDisplayedImage()
            didConfigureInitialZoom = true
        }
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        systemImageName: String,
        accessibilityIdentifier: String
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImageName)
        configuration.title = title
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityIdentifier = accessibilityIdentifier
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func resetZoomForDisplayedImage() {
        imageView.image = displayedImage
        imageView.frame = CGRect(origin: .zero, size: displayedImage.size)
        scrollView.contentSize = displayedImage.size

        guard displayedImage.size.width > 0,
              displayedImage.size.height > 0,
              scrollView.bounds.width > 0,
              scrollView.bounds.height > 0 else {
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 6
            scrollView.zoomScale = 1
            return
        }

        let widthScale = scrollView.bounds.width / displayedImage.size.width
        let heightScale = scrollView.bounds.height / displayedImage.size.height
        let minimumZoomScale = min(widthScale, heightScale)
        scrollView.minimumZoomScale = max(minimumZoomScale, 0.01)
        scrollView.maximumZoomScale = max(scrollView.minimumZoomScale * 6, 1)
        scrollView.zoomScale = scrollView.minimumZoomScale
        scrollView.contentOffset = .zero
        centerImageIfNeeded()
    }

    private func centerImageIfNeeded() {
        let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    private func currentCropRect() -> CGRect {
        ChatAttachmentImageCropGeometryPolicy.cropRect(
            imageSize: displayedImage.size,
            viewportSize: scrollView.bounds.size == .zero ? displayedImage.size : scrollView.bounds.size,
            zoomScale: scrollView.zoomScale == 0 ? 1 : scrollView.zoomScale,
            contentOffset: scrollView.contentOffset
        )
    }

    @objc
    private func cancelButtonTapped() {
        delegate?.chatAttachmentImageEditorViewControllerDidCancel(self)
    }

    @objc
    private func rotateButtonTapped() {
        currentRotation = currentRotation.nextClockwise
        displayedImage = ChatAttachmentImageEditRenderer.rotated(sourceImage, rotation: currentRotation)
        resetZoomForDisplayedImage()
    }

    @objc
    private func doneButtonTapped() {
        do {
            let editedDraft = try outputBuilder.makeEditedDraft(
                sourceDraft: draft,
                sourceImage: sourceImage,
                cropRect: currentCropRect(),
                rotation: currentRotation
            )
            delegate?.chatAttachmentImageEditorViewController(self, didFinishWith: editedDraft)
        } catch let error as ChatAttachmentImageEditOutputBuilderError {
            delegate?.chatAttachmentImageEditorViewController(self, didFailWith: error)
        } catch {
            delegate?.chatAttachmentImageEditorViewController(self, didFailWith: .unableToWriteOutput)
        }
    }
}

extension ChatAttachmentImageEditorViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }
}

extension AttachmentDraft {
    var editedLocalFileURL: URL? {
        AttachmentEditedDraft.url(from: id)
    }
}
