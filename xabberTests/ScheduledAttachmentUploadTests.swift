import XCTest
import RealmSwift
import UIKit
@testable import xabber

@MainActor
final class ScheduledAttachmentUploadTests: XCTestCase {
    func testPreparationUploadsOnlyLocalFilesInDisplayOrderWithoutAdmittingAMessage() throws {
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = makePreparation(uploader)
        let context = makeContext()
        let drafts = [
            makeDraft(id: "remote", remote: remote(named: "already-hosted", id: 7)),
            makeDraft(id: "photo"),
            makeDraft(id: "report")
        ]
        var progress: [Int] = []
        var result: Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>?
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: UUID().uuidString)
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }
        let realm = try WRealm.safe()
        let before = realm.objects(MessageStorageItem.self).count

        preparation.prepare(drafts: drafts, context: context, progress: { done, _ in
            progress.append(done)
        }, completion: { result = $0 })

        XCTAssertEqual(uploader.requests.map(\.filename), ["photo.pdf"])
        XCTAssertNil(result)
        uploader.finish(with: .success(remote(named: "photo", id: 8)))
        XCTAssertEqual(uploader.requests.map(\.filename), ["photo.pdf", "report.pdf"])
        uploader.finish(with: .success(remote(named: "report", id: 9)))

        let references = try XCTUnwrap(result).get()
        XCTAssertEqual(references.map(\.fileSharingURI), [
            "https://gallery.example.test/already-hosted.pdf",
            "https://gallery.example.test/photo.pdf",
            "https://gallery.example.test/report.pdf"
        ])
        XCTAssertTrue(references.allSatisfy { $0.isUploaded && $0.realm == nil && $0.localFileUrl == nil })
        XCTAssertEqual(progress, [0, 1, 2, 3])
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, before)
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).count, 0)
    }

    func testRetryReusesUploadedPrefixButReplacementUploadsNewFile() throws {
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = makePreparation(uploader)
        let context = makeContext()
        let first = makeDraft(id: "photo")
        let second = makeDraft(id: "report")
        var errors: [ScheduledAttachmentUploadError] = []

        preparation.prepare(drafts: [first, second], context: context, progress: { _, _ in }) {
            if case .failure(let error) = $0 { errors.append(error) }
        }
        uploader.finish(with: .success(remote(named: "photo", id: 8)))
        uploader.finish(with: .failure(.uploadFailed))
        XCTAssertEqual(errors, [.uploadFailed])

        preparation.prepare(drafts: [first, second], context: context, progress: { _, _ in }) { _ in }
        XCTAssertEqual(uploader.requests.map(\.filename), ["photo.pdf", "report.pdf", "report.pdf"])
        uploader.finish(with: .success(remote(named: "report", id: 9)))

        preparation.prepare(drafts: [makeDraft(id: "photo", filename: "edited.pdf")], context: context,
                            progress: { _, _ in }) { _ in }
        XCTAssertEqual(uploader.requests.last?.filename, "edited.pdf")
        uploader.finish(with: .success(remote(named: "edited", id: 10)))
    }

    func testRemoteOnlyPreparationDoesNotRequireAvailableUploadOrQuota() throws {
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = ScheduledAttachmentUpload(
            fileUploader: uploader,
            cloudAvailability: ScheduledAttachmentCloudStub(available: false),
            quotaAccess: ScheduledAttachmentQuotaStub(access: .premiumRequired)
        )
        var result: Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>?

        preparation.prepare(drafts: [makeDraft(id: "report", remote: remote(named: "report", id: 9))],
                            context: makeContext(), progress: { _, _ in }, completion: { result = $0 })

        XCTAssertEqual(try XCTUnwrap(result).get().first?.fileSharingURI, "https://gallery.example.test/report.pdf")
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testRouteLossBetweenUploadsStopsAndPreservesUploadedPrefix() {
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = makePreparation(uploader)
        var valid = true
        var error: ScheduledAttachmentUploadError?
        preparation.prepare(drafts: [makeDraft(id: "photo"), makeDraft(id: "report")],
                            context: makeContext(), canContinue: { valid }, progress: { _, _ in }) {
            if case .failure(let failure) = $0 { error = failure }
        }

        valid = false
        uploader.finish(with: .success(remote(named: "photo", id: 8)))

        XCTAssertEqual(uploader.requests.map(\.filename), ["photo.pdf"])
        XCTAssertEqual(error, .routeUnavailable)
    }

    func testPlainHostedFileAndNonFileSelectionNeverUploadsInProtectedSchedule() {
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = makePreparation(uploader)
        var errors: [ScheduledAttachmentUploadError] = []
        func record(_ result: Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>) {
            if case .failure(let error) = result { errors.append(error) }
        }

        preparation.prepare(drafts: [makeDraft(id: "file", remote: remote(named: "plain", id: 4))],
                            context: makeContext(type: .omemo),
                            progress: { _, _ in }, completion: record)
        preparation.prepare(drafts: [makeDraft(id: "contact", mediaKind: .contact)], context: makeContext(),
                            progress: { _, _ in }, completion: record)

        XCTAssertEqual(errors, [.invalidSelection, .invalidSelection])
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testEncryptedUploadPlanHasOpaqueTransportAndRoundTripsOnlyWithPrivateMetadata() throws {
        let data = Data("sensitive document bytes".utf8)
        let upload = try ScheduledAttachmentUploadPayload.make(
            data: data, filename: "payroll.txt", mimeType: "text/plain", encrypted: true
        )

        XCTAssertNotEqual(upload.data, data)
        XCTAssertNotEqual(upload.filename, "payroll.txt")
        XCTAssertEqual(upload.mimeType, "application/octet-stream")
        XCTAssertEqual(upload.privateMetadata?["size"], String(data.count))
        XCTAssertEqual(upload.privateMetadata?["hash"], upload.data.sha256Data.hexEncodedString())
        let key = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(upload.privateMetadata?["encryption-key"])))
        let iv = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(upload.privateMetadata?["iv"])))
        XCTAssertEqual(try Data.decrypt(upload.data, key: Array(key), iv: Array(iv)), data)
    }

    func testOnlyProtectedUploadedReferencesCanBeScheduledAsOMEMO2Files() throws {
        let context = makeContext(type: .omemo)
        let uploader = ScheduledAttachmentUploaderSpy()
        let preparation = makePreparation(uploader)
        let opaque = try ScheduledAttachmentUploadPayload.make(
            data: Data("file".utf8), filename: "original.txt", mimeType: "text/plain", encrypted: true
        )
        var result: Result<[MessageReferenceStorageItem], ScheduledAttachmentUploadError>?
        preparation.prepare(drafts: [makeDraft(id: "report")], context: context,
                            progress: { _, _ in }, completion: { result = $0 })
        uploader.finish(with: .success(.init(
            remoteURL: URL(string: "https://gallery.example.test/cipher.bin")!, fileID: 9,
            hash: opaque.privateMetadata?["hash"], createdAt: nil, metadata: opaque.privateMetadata
        )))

        let references = try XCTUnwrap(result).get()
        let payload = try XCTUnwrap(ScheduledMessageContent.makeMessage(
            owner: context.owner, conversation: context.jid, conversationType: .omemo, body: "", references: references
        ))
        XCTAssertTrue(ScheduledOMEMO2.permitsEncryptedFiles(in: payload, owner: context.owner))
        XCTAssertTrue(payload.xmlString.contains("urn:xmpp:esfs:0"))
        XCTAssertNil(ScheduledMessageContent.makeMessage(
            owner: context.owner, conversation: context.jid, conversationType: .regular, body: "", references: references
        ))
    }

    func testEditorPickerReturnsHostedFilesAfterDismissalWithoutOrdinarySending() throws {
        let presenter = UIViewController()
        let uploader = ScheduledAttachmentUploaderSpy()
        let ordinarySender = ScheduledAttachmentOrdinarySenderSpy()
        let delegate = ScheduledAttachmentFlowDelegateSpy()
        let flow = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: makeContext(),
            scheduledMode: .addToScheduledMessage { references in
                XCTAssertEqual(delegate.dismissals, 1)
                XCTAssertEqual(references.map(\.fileSharingURI), ["https://gallery.example.test/report.pdf"])
                delegate.accepted = true
            },
            sourceControllerFactory: ScheduledAttachmentSourceFactoryStub(),
            sendCoordinator: ordinarySender,
            scheduledUpload: makePreparation(uploader),
            quotaRefresher: ScheduledAttachmentQuotaRefresherStub(),
            presentationHandler: { _, _, _, completion in completion?() },
            dismissalHandler: { _, _, completion in completion?() }
        )
        flow.delegate = delegate
        flow.start()
        let picker = try XCTUnwrap(flow.pickerViewController)
        XCTAssertEqual(picker.sourceBarView.visibleSources, [.gallery, .file])
        let report = makeDraft(id: "remote", remote: remote(named: "report", id: 9))

        flow.chatAttachmentSheetViewController(picker, didRequestSend: [report], captionState: .init())

        XCTAssertTrue(delegate.accepted)
        XCTAssertNil(flow.pickerViewController)
        XCTAssertEqual(ordinarySender.calls, 0)
        XCTAssertEqual(delegate.sends, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testEditorPickerKeepsSheetOpenAfterUploadFailure() throws {
        let presenter = UIViewController()
        let uploader = ScheduledAttachmentUploaderSpy()
        let delegate = ScheduledAttachmentFlowDelegateSpy()
        let flow = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: makeContext(),
            scheduledMode: .addToScheduledMessage { _ in XCTFail("Upload failed") },
            sourceControllerFactory: ScheduledAttachmentSourceFactoryStub(),
            scheduledUpload: makePreparation(uploader),
            quotaRefresher: ScheduledAttachmentQuotaRefresherStub(),
            presentationHandler: { _, _, _, completion in completion?() },
            dismissalHandler: { _, _, _ in XCTFail("The picker should retain the selection") }
        )
        flow.delegate = delegate
        flow.start()
        let picker = try XCTUnwrap(flow.pickerViewController)
        flow.chatAttachmentSheetViewController(picker, didRequestSend: [makeDraft(id: "file")], captionState: .init())
        XCTAssertTrue(flow.pickerNavigationController?.isModalInPresentation == true)

        uploader.finish(with: .failure(.uploadFailed))

        XCTAssertIdentical(flow.pickerViewController, picker)
        XCTAssertFalse(picker.statusBannerView.isHidden)
        XCTAssertFalse(flow.pickerNavigationController?.isModalInPresentation == true)
        XCTAssertEqual(delegate.dismissals, 0)
    }

    private func makePreparation(_ uploader: ScheduledAttachmentUploaderSpy) -> ScheduledAttachmentUpload {
        ScheduledAttachmentUpload(fileUploader: uploader,
                                  cloudAvailability: ScheduledAttachmentCloudStub(available: true),
                                  quotaAccess: ScheduledAttachmentQuotaStub(access: .available))
    }

    private func makeContext(
        type: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(owner: "owner@example.test", jid: "peer@example.test",
                                  conversationType: type, forwardedMessageIds: [])
    }

    private func makeDraft(
        id: String,
        filename: String? = nil,
        mediaKind: AttachmentMediaKind = .file,
        remote: AttachmentUploadedRemoteFile? = nil
    ) -> AttachmentDraft {
        let name = filename ?? "\(id).pdf"
        let local = URL(fileURLWithPath: "/tmp/\(name)")
        let file = AttachmentPreparedFile(
            localFileURL: local, referenceURL: local, filename: name, byteSize: 64,
            mediaType: "application/pdf", dimensions: nil, duration: nil, videoPreviewKey: nil,
            videoOrientation: nil, videoDurationLabel: nil, videoPreviewLocalURL: nil,
            temporaryData: nil, uploadedRemoteFile: remote
        )
        return AttachmentDraft(id: id, source: .file, mediaKind: mediaKind, thumbnailState: .none,
                               filename: name, byteSize: 64, duration: nil, dimensions: nil,
                               preparationState: .prepared(file))
    }

    private func remote(named name: String, id: Int) -> AttachmentUploadedRemoteFile {
        AttachmentUploadedRemoteFile(remoteURL: URL(string: "https://gallery.example.test/\(name).pdf")!,
                                     fileID: id, hash: nil, createdAt: nil, metadata: nil)
    }
}

private struct ScheduledAttachmentSourceFactoryStub: ChatAttachmentSourceControllerFactory {
    func makeController(for source: ChatAttachmentSource, context: ChatAttachmentFlowContext) -> ChatAttachmentSourceControlling {
        ChatAttachmentPlaceholderSourceViewController(source: source)
    }
}

private final class ScheduledAttachmentQuotaRefresherStub: ChatAttachmentQuotaRefreshing {
    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    ) {}
}

private final class ScheduledAttachmentOrdinarySenderSpy: ChatAttachmentSendCoordinating {
    private(set) var calls = 0

    func send(
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        completion: @escaping (ChatAttachmentSendResult) -> Void
    ) {
        calls += 1
    }
}

private final class ScheduledAttachmentFlowDelegateSpy: ChatAttachmentFlowCoordinatorDelegate {
    private(set) var dismissals = 0
    private(set) var sends = 0
    var accepted = false

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) { dismissals += 1 }
    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) { sends += 1 }
    func chatAttachmentFlowCoordinator(_ coordinator: ChatAttachmentFlowCoordinator, didRequestPremiumFor owner: String) {}
    func chatAttachmentFlowCoordinator(_ coordinator: ChatAttachmentFlowCoordinator, didFailWith error: ChatAttachmentFlowError) {
        XCTFail("Unexpected picker failure: \(error)")
    }
}

private final class ScheduledAttachmentUploaderSpy: ScheduledAttachmentFileUploading {
    private(set) var requests: [AttachmentPreparedFile] = []
    private var completion: ((Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>) -> Void)?

    func upload(file: AttachmentPreparedFile, owner: String, encrypted: Bool,
                completion: @escaping (Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>) -> Void) {
        requests.append(file)
        self.completion = completion
    }

    func finish(with result: Result<AttachmentUploadedRemoteFile, ScheduledAttachmentUploadError>) {
        guard let callback = completion else { return XCTFail("Expected upload") }
        completion = nil
        callback(result)
    }
}

private final class ScheduledAttachmentCloudStub: ChatAttachmentCloudStorageAvailabilityProviding {
    let available: Bool

    init(available: Bool) { self.available = available }

    func isCloudStorageAvailable(owner: String) -> Bool { available }
}

private final class ScheduledAttachmentQuotaStub: ChatAttachmentQuotaAccessProviding {
    let access: MediaUploadQuotaPolicy.Access

    init(access: MediaUploadQuotaPolicy.Access) { self.access = access }

    func currentAccess(owner: String) -> MediaUploadQuotaPolicy.Access { access }
}
