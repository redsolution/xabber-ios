import AVFoundation
import UniformTypeIdentifiers
import UIKit

enum ChatAttachmentCameraAuthorizationStatus: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

enum ChatAttachmentCameraBlockReason: Equatable {
    case cameraUnavailable
    case permissionDenied
    case permissionRestricted
    case unsupportedMediaTypes
    case unavailable
}

enum ChatAttachmentCameraPermissionState: Equatable {
    case ready
    case requestAuthorization
    case blocked(reason: ChatAttachmentCameraBlockReason)
}

enum ChatAttachmentCameraPermissionPolicy {
    static func state(
        isCameraAvailable: Bool,
        authorizationStatus: ChatAttachmentCameraAuthorizationStatus,
        availableMediaTypes: [String]
    ) -> ChatAttachmentCameraPermissionState {
        guard isCameraAvailable else {
            return .blocked(reason: .cameraUnavailable)
        }

        guard ChatAttachmentCameraMediaTypePolicy.hasSupportedMediaType(availableMediaTypes) else {
            return .blocked(reason: .unsupportedMediaTypes)
        }

        switch authorizationStatus {
        case .authorized:
            return .ready
        case .notDetermined:
            return .requestAuthorization
        case .denied:
            return .blocked(reason: .permissionDenied)
        case .restricted:
            return .blocked(reason: .permissionRestricted)
        case .unavailable:
            return .blocked(reason: .unavailable)
        }
    }
}

enum ChatAttachmentCameraMediaTypePolicy {
    static var supportedMediaTypeIdentifiers: Set<String> {
        [UTType.image.identifier, UTType.movie.identifier]
    }

    static func hasSupportedMediaType(_ mediaTypes: [String]) -> Bool {
        !supportedMediaTypes(from: mediaTypes).isEmpty
    }

    static func supportedMediaTypes(from mediaTypes: [String]) -> [String] {
        mediaTypes.filter { supportedMediaTypeIdentifiers.contains($0) }
    }
}

protocol ChatAttachmentCameraAuthorizing: AnyObject {
    var authorizationStatus: ChatAttachmentCameraAuthorizationStatus { get }
    func requestAuthorization(completion: @escaping (ChatAttachmentCameraAuthorizationStatus) -> Void)
}

final class AVFoundationChatAttachmentCameraAuthorizer: ChatAttachmentCameraAuthorizing {
    var authorizationStatus: ChatAttachmentCameraAuthorizationStatus {
        Self.map(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentCameraAuthorizationStatus) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            completion(self.authorizationStatus)
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> ChatAttachmentCameraAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }
}

enum ChatAttachmentCameraCapture {
    case image(UIImage)
    case video(URL)
}

enum ChatAttachmentCameraPresentingResult {
    case captured(ChatAttachmentCameraCapture)
    case cancelled
    case failed
}

protocol ChatAttachmentCameraPresenting: AnyObject {
    var isCameraAvailable: Bool { get }
    var availableMediaTypes: [String] { get }

    func presentCamera(
        from viewController: UIViewController,
        completion: @escaping (ChatAttachmentCameraPresentingResult) -> Void
    )
}

protocol ChatAttachmentCameraPreviewProviding: AnyObject {
    var isPreviewRunning: Bool { get }
    func startPreview(
        in view: UIView,
        completion: @escaping (ChatAttachmentCameraPreviewStartResult) -> Void
    )
    func detachPreview(from view: UIView)
    func stopPreview()
}

enum ChatAttachmentCameraPreviewStartResult: Equatable {
    case started
    case failed
}

final class AVCaptureChatAttachmentCameraPreviewProvider: ChatAttachmentCameraPreviewProviding {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.xabber.chatAttachment.cameraPreview")
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var isConfigured = false
    private weak var previewView: UIView?

    private(set) var isPreviewRunning = false

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func startPreview(
        in view: UIView,
        completion: @escaping (ChatAttachmentCameraPreviewStartResult) -> Void
    ) {
        previewView = view

        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.configureIfNeeded() else {
                DispatchQueue.main.async {
                    if self.previewView === view {
                        self.previewView = nil
                        self.removePreviewLayer(from: view)
                        self.isPreviewRunning = false
                    }
                    completion(.failed)
                }
                return
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                guard self.previewView === view,
                      self.session.isRunning else {
                    if self.previewView === view {
                        self.previewView = nil
                        self.removePreviewLayer(from: view)
                        self.isPreviewRunning = false
                    }
                    completion(.failed)
                    return
                }

                if self.previewLayer.superlayer !== view.layer {
                    self.previewLayer.removeFromSuperlayer()
                    self.previewLayer.frame = view.bounds
                    view.layer.insertSublayer(self.previewLayer, at: 0)
                }
                self.previewLayer.frame = view.bounds
                self.isPreviewRunning = true
                completion(.started)
            }
        }
    }

    func detachPreview(from view: UIView) {
        if previewView === view {
            previewView = nil
        }
        removePreviewLayer(from: view)
    }

    func stopPreview() {
        previewView = nil
        previewLayer.removeFromSuperlayer()
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isPreviewRunning = false
            }
        }
    }

    private func configureIfNeeded() -> Bool {
        guard !isConfigured else {
            return true
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.commitConfiguration()
        isConfigured = true
        return true
    }

    private func removePreviewLayer(from view: UIView) {
        guard previewLayer.superlayer === view.layer else {
            return
        }

        previewLayer.removeFromSuperlayer()
    }
}

final class UIImagePickerChatAttachmentCameraPresenter: NSObject, ChatAttachmentCameraPresenting {
    var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var availableMediaTypes: [String] {
        UIImagePickerController.availableMediaTypes(for: .camera) ?? []
    }

    private var activeDelegates: [ObjectIdentifier: CameraPickerDelegateBridge] = [:]

    func presentCamera(
        from viewController: UIViewController,
        completion: @escaping (ChatAttachmentCameraPresentingResult) -> Void
    ) {
        guard isCameraAvailable else {
            completion(.failed)
            return
        }

        let mediaTypes = ChatAttachmentCameraMediaTypePolicy.supportedMediaTypes(from: availableMediaTypes)
        guard !mediaTypes.isEmpty else {
            completion(.failed)
            return
        }

        let picker = UIImagePickerController()
        let key = ObjectIdentifier(picker)
        let delegate = CameraPickerDelegateBridge { [weak self, weak picker] result in
            let finish = {
                completion(result)
                self?.activeDelegates.removeValue(forKey: key)
            }

            guard let picker else {
                finish()
                return
            }

            picker.dismiss(animated: true, completion: finish)
        }

        activeDelegates[key] = delegate
        picker.delegate = delegate
        picker.sourceType = .camera
        picker.mediaTypes = mediaTypes
        picker.allowsEditing = false
        viewController.present(picker, animated: true)
    }
}

private final class CameraPickerDelegateBridge: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let completion: (ChatAttachmentCameraPresentingResult) -> Void

    init(completion: @escaping (ChatAttachmentCameraPresentingResult) -> Void) {
        self.completion = completion
        super.init()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        completion(.cancelled)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
            completion(.captured(.image(image)))
            return
        }

        if let url = info[.mediaURL] as? URL {
            completion(.captured(.video(url)))
            return
        }

        completion(.failed)
    }
}

struct AttachmentCapturedDraft: Equatable, Hashable {
    private static let idPrefix = "captured:"

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

struct ChatAttachmentCameraVideoMetadata {
    let duration: Int?
    let dimensions: CGSize?
    let thumbnailImage: UIImage?
}

protocol ChatAttachmentCameraVideoMetadataProviding {
    func metadata(forVideoAt url: URL) throws -> ChatAttachmentCameraVideoMetadata
}

final class AVAssetChatAttachmentCameraVideoMetadataProvider: ChatAttachmentCameraVideoMetadataProviding {
    func metadata(forVideoAt url: URL) throws -> ChatAttachmentCameraVideoMetadata {
        let asset = AVAsset(url: url)
        let duration = Self.duration(from: asset)
        let dimensions = Self.dimensions(from: asset)
        let thumbnailImage = Self.thumbnailImage(from: asset)

        return ChatAttachmentCameraVideoMetadata(
            duration: duration,
            dimensions: dimensions,
            thumbnailImage: thumbnailImage
        )
    }

    private static func duration(from asset: AVAsset) -> Int? {
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }

        return Int(seconds.rounded())
    }

    private static func dimensions(from asset: AVAsset) -> CGSize? {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return nil
        }

        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        return CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )
    }

    private static func thumbnailImage(from asset: AVAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

protocol ChatAttachmentCameraCaptureDraftBuilding: AnyObject {
    func makeDraft(from capture: ChatAttachmentCameraCapture) throws -> AttachmentDraft
    func removeTemporaryFiles(for draft: AttachmentDraft)
}

enum ChatAttachmentCameraCaptureDraftBuilderError: Error, Equatable {
    case imageEncodingFailed
    case sourceFileUnreadable
    case unableToCreateOutputDirectory
    case unableToWriteOutput
}

final class ChatAttachmentCameraCaptureDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding {
    private let outputDirectory: URL
    private let uuidProvider: () -> UUID
    private let fileManager: FileManager
    private let videoMetadataProvider: ChatAttachmentCameraVideoMetadataProviding

    init(
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-attachment-camera-\(UUID().uuidString)", isDirectory: true),
        uuidProvider: @escaping () -> UUID = UUID.init,
        fileManager: FileManager = .default,
        videoMetadataProvider: ChatAttachmentCameraVideoMetadataProviding = AVAssetChatAttachmentCameraVideoMetadataProvider()
    ) {
        self.outputDirectory = outputDirectory
        self.uuidProvider = uuidProvider
        self.fileManager = fileManager
        self.videoMetadataProvider = videoMetadataProvider
    }

    func makeDraft(from capture: ChatAttachmentCameraCapture) throws -> AttachmentDraft {
        try createOutputDirectoryIfNeeded()

        switch capture {
        case .image(let image):
            return try makeImageDraft(from: image)
        case .video(let url):
            return try makeVideoDraft(from: url)
        }
    }

    func removeTemporaryFiles(for draft: AttachmentDraft) {
        guard let fileURL = AttachmentCapturedDraft.url(from: draft.id) else {
            return
        }

        try? fileManager.removeItem(at: fileURL)

        if case .available(let key) = draft.thumbnailState,
           let thumbnailURL = URL(string: key),
           thumbnailURL != fileURL {
            try? fileManager.removeItem(at: thumbnailURL)
        }
    }

    private func makeImageDraft(from image: UIImage) throws -> AttachmentDraft {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw ChatAttachmentCameraCaptureDraftBuilderError.imageEncodingFailed
        }

        let uuid = uuidProvider().uuidString
        let filename = "captured-image-\(uuid).jpg"
        let fileURL = outputDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ChatAttachmentCameraCaptureDraftBuilderError.unableToWriteOutput
        }

        return AttachmentDraft(
            id: AttachmentCapturedDraft(url: fileURL).id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .available(key: fileURL.absoluteString),
            filename: filename,
            byteSize: data.count,
            duration: nil,
            dimensions: image.size,
            preparationState: .pending
        )
    }

    private func makeVideoDraft(from sourceURL: URL) throws -> AttachmentDraft {
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw ChatAttachmentCameraCaptureDraftBuilderError.sourceFileUnreadable
        }

        let uuid = uuidProvider().uuidString
        let pathExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let filename = "captured-video-\(uuid).\(pathExtension)"
        let fileURL = outputDirectory.appendingPathComponent(filename)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try fileManager.copyItem(at: sourceURL, to: fileURL)
        } catch {
            throw ChatAttachmentCameraCaptureDraftBuilderError.unableToWriteOutput
        }

        let metadata = try videoMetadataProvider.metadata(forVideoAt: fileURL)
        let thumbnailURL = try writeThumbnailIfNeeded(metadata.thumbnailImage, uuid: uuid)
        let byteSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0

        return AttachmentDraft(
            id: AttachmentCapturedDraft(url: fileURL).id,
            source: .gallery,
            mediaKind: .video,
            thumbnailState: thumbnailURL.map { .available(key: $0.absoluteString) } ?? .none,
            filename: filename,
            byteSize: byteSize,
            duration: metadata.duration,
            dimensions: metadata.dimensions,
            preparationState: .pending
        )
    }

    private func createOutputDirectoryIfNeeded() throws {
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw ChatAttachmentCameraCaptureDraftBuilderError.unableToCreateOutputDirectory
        }
    }

    private func writeThumbnailIfNeeded(_ image: UIImage?, uuid: String) throws -> URL? {
        guard let image,
              let data = image.jpegData(compressionQuality: 0.75) else {
            return nil
        }

        let thumbnailURL = outputDirectory.appendingPathComponent("captured-video-thumbnail-\(uuid).jpg")
        do {
            try data.write(to: thumbnailURL, options: .atomic)
            return thumbnailURL
        } catch {
            throw ChatAttachmentCameraCaptureDraftBuilderError.unableToWriteOutput
        }
    }
}
