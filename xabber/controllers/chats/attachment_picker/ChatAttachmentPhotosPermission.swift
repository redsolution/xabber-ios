import Photos
import UIKit

enum ChatAttachmentPhotosAuthorizationStatus: Equatable {
    case notDetermined
    case limited
    case authorized
    case denied
    case restricted
    case unavailable
}

enum ChatAttachmentPhotosPermissionBlockReason: Equatable {
    case denied
    case restricted
    case unavailable
}

enum ChatAttachmentPhotosPermissionState: Equatable {
    case requestAccess
    case ready(isLimited: Bool)
    case blocked(reason: ChatAttachmentPhotosPermissionBlockReason)
}

enum ChatAttachmentPhotosPermissionPolicy {
    static func state(for authorizationStatus: ChatAttachmentPhotosAuthorizationStatus) -> ChatAttachmentPhotosPermissionState {
        switch authorizationStatus {
        case .notDetermined:
            return .requestAccess
        case .limited:
            return .ready(isLimited: true)
        case .authorized:
            return .ready(isLimited: false)
        case .denied:
            return .blocked(reason: .denied)
        case .restricted:
            return .blocked(reason: .restricted)
        case .unavailable:
            return .blocked(reason: .unavailable)
        }
    }
}

protocol ChatAttachmentPhotoLibraryAuthorizing: AnyObject {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus { get }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void)
    func registerChangeObserver(_ observer: AnyObject)
    func unregisterChangeObserver(_ observer: AnyObject)
    func containsAsset(localIdentifier: String) -> Bool
}

protocol ChatAttachmentLimitedLibraryPresenting: AnyObject {
    func presentLimitedLibraryPicker(from viewController: UIViewController)
}

protocol ChatAttachmentApplicationSettingsOpening: AnyObject {
    func openApplicationSettings()
}

struct ChatAttachmentGallerySelectionRefreshPolicy {
    static func refreshedDrafts(
        _ drafts: [AttachmentDraft],
        authorizationStatus: ChatAttachmentPhotosAuthorizationStatus,
        isAssetAccessible: (String) -> Bool
    ) -> [AttachmentDraft] {
        let permissionState = ChatAttachmentPhotosPermissionPolicy.state(for: authorizationStatus)

        return drafts.filter { draft in
            guard let assetLocalIdentifier = draft.galleryAssetLocalIdentifier else {
                return true
            }

            switch permissionState {
            case .ready:
                return isAssetAccessible(assetLocalIdentifier)
            case .requestAccess, .blocked:
                return false
            }
        }
    }
}

final class ChatAttachmentGallerySourceViewController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing {
    let source: ChatAttachmentSource = .gallery
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?
    var onSheetPresentationStateRequested: ((ChatAttachmentSheetPresentationState) -> Void)?
    var onDismissRequested: (() -> Void)?

    let permissionMessageLabel = UILabel()
    let allowAccessButton = UIButton(type: .system)
    let manageLimitedLibraryButton = UIButton(type: .system)
    let openSettingsButton = UIButton(type: .system)
    let galleryCollectionView: UICollectionView
    let emptyGalleryLabel = UILabel()
    let fullGalleryTopBarView = UIView()
    let collapseFullGalleryButton = UIButton(type: .system)
    let dismissFullGalleryButton = UIButton(type: .system)
    let fullGalleryActionMenuButton = UIButton(type: .system)
    let galleryTitleLabel = UILabel()
    let dateIndicatorLabel = UILabel()

    var albumSelectionButton: UIButton? {
        nil
    }

    private let contentStackView = UIStackView()
    private let photoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing
    private let limitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting
    private let settingsOpener: ChatAttachmentApplicationSettingsOpening
    private let galleryDataProvider: ChatAttachmentGalleryDataProviding
    private let thumbnailProvider: ChatAttachmentGalleryThumbnailProviding
    private let cameraAuthorizer: ChatAttachmentCameraAuthorizing
    private let cameraPresenter: ChatAttachmentCameraPresenting
    private let cameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding
    private let cameraPreviewProvider: ChatAttachmentCameraPreviewProviding
    private let galleryDraftBuilder: ChatAttachmentGalleryDraftBuilder
    private let maximumSelectedDraftCount: Int
    private var galleryDataSource: UICollectionViewDiffableDataSource<Int, ChatAttachmentGalleryItem>?
    private var didRegisterChangeObserver = false
    private var dateIndicatorHideWorkItem: DispatchWorkItem?

    private(set) var permissionState: ChatAttachmentPhotosPermissionState = .blocked(reason: .unavailable)
    private(set) var selectedDrafts: [AttachmentDraft] = []
    private(set) var galleryItems: [ChatAttachmentGalleryItem] = []
    private(set) var displayMode: ChatAttachmentGalleryDisplayMode = .full

    var viewController: UIViewController {
        self
    }

    var selectedAttachmentDrafts: [AttachmentDraft] {
        selectedDrafts
    }

    init(
        photoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing = PhotoKitChatAttachmentPhotoLibraryAuthorizer(),
        limitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting = PhotoKitChatAttachmentLimitedLibraryPresenter(),
        settingsOpener: ChatAttachmentApplicationSettingsOpening = ChatAttachmentApplicationSettingsOpener(),
        galleryDataProvider: ChatAttachmentGalleryDataProviding = PhotoKitChatAttachmentGalleryDataProvider(),
        thumbnailProvider: ChatAttachmentGalleryThumbnailProviding = PhotoKitChatAttachmentGalleryThumbnailProvider(),
        cameraAuthorizer: ChatAttachmentCameraAuthorizing = AVFoundationChatAttachmentCameraAuthorizer(),
        cameraPresenter: ChatAttachmentCameraPresenting = UIImagePickerChatAttachmentCameraPresenter(),
        cameraDraftBuilder: ChatAttachmentCameraCaptureDraftBuilding = ChatAttachmentCameraCaptureDraftBuilder(),
        cameraPreviewProvider: ChatAttachmentCameraPreviewProviding = AVCaptureChatAttachmentCameraPreviewProvider(),
        galleryDraftBuilder: ChatAttachmentGalleryDraftBuilder = ChatAttachmentGalleryDraftBuilder(),
        maximumSelectedDraftCount: Int = 10
    ) {
        self.photoLibraryAuthorizer = photoLibraryAuthorizer
        self.limitedLibraryPresenter = limitedLibraryPresenter
        self.settingsOpener = settingsOpener
        self.galleryDataProvider = galleryDataProvider
        self.thumbnailProvider = thumbnailProvider
        self.cameraAuthorizer = cameraAuthorizer
        self.cameraPresenter = cameraPresenter
        self.cameraDraftBuilder = cameraDraftBuilder
        self.cameraPreviewProvider = cameraPreviewProvider
        self.galleryDraftBuilder = galleryDraftBuilder
        self.maximumSelectedDraftCount = maximumSelectedDraftCount
        self.galleryCollectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeGalleryLayout()
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear

        galleryCollectionView.backgroundColor = .clear
        galleryCollectionView.alwaysBounceVertical = true
        galleryCollectionView.allowsSelection = true
        galleryCollectionView.isHidden = true
        galleryCollectionView.delegate = self
        galleryCollectionView.prefetchDataSource = self
        galleryCollectionView.register(
            ChatAttachmentGalleryCollectionViewCell.self,
            forCellWithReuseIdentifier: ChatAttachmentGalleryCollectionViewCell.reuseIdentifier
        )
        galleryCollectionView.translatesAutoresizingMaskIntoConstraints = false
        galleryCollectionView.accessibilityIdentifier = "chatAttachmentGallery.grid"

        contentStackView.axis = .vertical
        contentStackView.alignment = .center
        contentStackView.distribution = .fill
        contentStackView.spacing = 10
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.accessibilityIdentifier = "chatAttachmentGallery.permissionState"

        permissionMessageLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        permissionMessageLabel.textColor = .secondaryLabel
        permissionMessageLabel.textAlignment = .center
        permissionMessageLabel.numberOfLines = 0
        permissionMessageLabel.adjustsFontForContentSizeCategory = true
        permissionMessageLabel.accessibilityIdentifier = "chatAttachmentGallery.permissionMessage"

        emptyGalleryLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        emptyGalleryLabel.textColor = .secondaryLabel
        emptyGalleryLabel.textAlignment = .center
        emptyGalleryLabel.numberOfLines = 0
        emptyGalleryLabel.adjustsFontForContentSizeCategory = true
        emptyGalleryLabel.text = ChatAttachmentLocalization.string(.galleryNoPhotosVideos)
        emptyGalleryLabel.isHidden = true
        emptyGalleryLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyGalleryLabel.accessibilityIdentifier = "chatAttachmentGallery.emptyState"

        fullGalleryTopBarView.isHidden = true
        dismissFullGalleryButton.isHidden = true
        fullGalleryActionMenuButton.isHidden = true
        configureDateIndicator()
        configureButton(
            allowAccessButton,
            title: ChatAttachmentLocalization.string(.photosAllowAccessAction),
            accessibilityIdentifier: "chatAttachmentGallery.allowPhotoAccessButton"
        )
        configureButton(
            manageLimitedLibraryButton,
            title: ChatAttachmentLocalization.string(.photosManageAction),
            accessibilityIdentifier: "chatAttachmentGallery.managePhotosButton"
        )
        configureButton(
            openSettingsButton,
            title: ChatAttachmentLocalization.string(.photosOpenSettingsAction),
            accessibilityIdentifier: "chatAttachmentGallery.openSettingsButton"
        )

        allowAccessButton.addTarget(self, action: #selector(allowAccessButtonTapped), for: .touchUpInside)
        manageLimitedLibraryButton.addTarget(self, action: #selector(manageLimitedLibraryButtonTapped), for: .touchUpInside)
        openSettingsButton.addTarget(self, action: #selector(openSettingsButtonTapped), for: .touchUpInside)

        contentStackView.addArrangedSubview(permissionMessageLabel)
        contentStackView.addArrangedSubview(allowAccessButton)
        contentStackView.addArrangedSubview(manageLimitedLibraryButton)
        contentStackView.addArrangedSubview(openSettingsButton)

        rootView.addSubview(galleryCollectionView)
        rootView.addSubview(emptyGalleryLabel)
        rootView.addSubview(contentStackView)
        rootView.addSubview(dateIndicatorLabel)
        configureGalleryDataSource()
        NSLayoutConstraint.activate([
            galleryCollectionView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            galleryCollectionView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            galleryCollectionView.topAnchor.constraint(equalTo: rootView.topAnchor),
            galleryCollectionView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            emptyGalleryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            emptyGalleryLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            emptyGalleryLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            emptyGalleryLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),

            contentStackView.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            contentStackView.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            contentStackView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            contentStackView.topAnchor.constraint(greaterThanOrEqualTo: rootView.topAnchor, constant: 8),
            contentStackView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),

            dateIndicatorLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            dateIndicatorLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            dateIndicatorLabel.heightAnchor.constraint(equalToConstant: 28),
            dateIndicatorLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForPhotoLibraryChangesIfNeeded()
        applyAuthorizationStatus(photoLibraryAuthorizer.authorizationStatus, pruneSelection: false)
    }

    deinit {
        if didRegisterChangeObserver {
            photoLibraryAuthorizer.unregisterChangeObserver(self)
        }
        cameraPreviewProvider.stopPreview()
        cleanupTemporaryDrafts()
    }

    func replaceSelectedDrafts(_ drafts: [AttachmentDraft]) {
        updateSelectedDrafts(drafts, notifySelectionChanged: true)
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        updateSelectedDrafts(drafts, notifySelectionChanged: false)
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        let updatedDrafts = selectedDrafts.filter { $0.id != draftID }

        guard updatedDrafts != selectedDrafts else {
            return selectedDrafts
        }

        updateSelectedDrafts(updatedDrafts, notifySelectionChanged: true)
        return selectedDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        guard let index = selectedDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedDrafts
        }

        var updatedDrafts = selectedDrafts
        updatedDrafts[index] = updatedDraft
        updateSelectedDrafts(updatedDrafts, notifySelectionChanged: true)
        return selectedDrafts
    }

    func handlePhotoLibraryDidChange() {
        applyAuthorizationStatus(photoLibraryAuthorizer.authorizationStatus, pruneSelection: true)
    }

    func setDisplayMode(_ displayMode: ChatAttachmentGalleryDisplayMode) {
        _ = displayMode
        self.displayMode = .full
        guard isViewLoaded else {
            return
        }

        renderPermissionState()
    }

    func updateDateIndicator(forVisibleItemAt itemIndex: Int?) {
        guard displayMode == .full,
              let itemIndex,
              galleryItems.indices.contains(itemIndex),
              let label = ChatAttachmentGalleryDateIndicatorPolicy.label(for: galleryItems[itemIndex]) else {
            dateIndicatorLabel.isHidden = true
            return
        }

        dateIndicatorLabel.text = label
        dateIndicatorLabel.isHidden = false
    }

    func hideDateIndicatorForIdleState() {
        dateIndicatorHideWorkItem?.cancel()
        dateIndicatorHideWorkItem = nil
        dateIndicatorLabel.isHidden = true
    }

    var isCameraTileEnabled: Bool {
        switch cameraPermissionState {
        case .ready, .requestAuthorization:
            return true
        case .blocked:
            return false
        }
    }

    var cameraPermissionState: ChatAttachmentCameraPermissionState {
        ChatAttachmentCameraPermissionPolicy.state(
            isCameraAvailable: cameraPresenter.isCameraAvailable,
            authorizationStatus: cameraAuthorizer.authorizationStatus,
            availableMediaTypes: cameraPresenter.availableMediaTypes
        )
    }

    func handleCameraTileTapped() {
        switch cameraPermissionState {
        case .ready:
            presentCamera()
        case .requestAuthorization:
            requestCameraAuthorization()
        case .blocked:
            break
        }
    }

    private func registerForPhotoLibraryChangesIfNeeded() {
        guard !didRegisterChangeObserver else {
            return
        }

        photoLibraryAuthorizer.registerChangeObserver(self)
        didRegisterChangeObserver = true
    }

    private func applyAuthorizationStatus(
        _ authorizationStatus: ChatAttachmentPhotosAuthorizationStatus,
        pruneSelection: Bool
    ) {
        permissionState = ChatAttachmentPhotosPermissionPolicy.state(for: authorizationStatus)
        if pruneSelection {
            pruneSelectedDrafts(authorizationStatus: authorizationStatus)
        }
        renderPermissionState()
    }

    private func pruneSelectedDrafts(authorizationStatus: ChatAttachmentPhotosAuthorizationStatus) {
        let refreshedDrafts = ChatAttachmentGallerySelectionRefreshPolicy.refreshedDrafts(
            selectedDrafts,
            authorizationStatus: authorizationStatus,
            isAssetAccessible: { [photoLibraryAuthorizer] localIdentifier in
                photoLibraryAuthorizer.containsAsset(localIdentifier: localIdentifier)
            }
        )

        guard refreshedDrafts != selectedDrafts else {
            return
        }

        selectedDrafts = refreshedDrafts
        notifySelectionChanged()
    }

    private func requestCameraAuthorization() {
        cameraAuthorizer.requestAuthorization { [weak self] _ in
            let applyAuthorization: () -> Void = { [weak self] in
                guard let self else {
                    return
                }

                self.reloadGalleryItems()
                self.galleryCollectionView.reloadData()

                if self.cameraPermissionState == .ready {
                    self.presentCamera()
                }
            }

            if Thread.isMainThread {
                applyAuthorization()
            } else {
                DispatchQueue.main.async(execute: applyAuthorization)
            }
        }
    }

    private func presentCamera() {
        guard cameraPermissionState == .ready else {
            return
        }

        cameraPreviewProvider.stopPreview()
        cameraPresenter.presentCamera(from: self) { [weak self] result in
            let handleResult: () -> Void = { [weak self] in
                self?.handleCameraPresentationResult(result)
                self?.reloadGalleryItems()
            }

            if Thread.isMainThread {
                handleResult()
            } else {
                DispatchQueue.main.async(execute: handleResult)
            }
        }
    }

    private func handleCameraPresentationResult(_ result: ChatAttachmentCameraPresentingResult) {
        switch result {
        case .captured(let capture):
            appendCapturedDraft(from: capture)
        case .cancelled, .failed:
            break
        }
    }

    private func appendCapturedDraft(from capture: ChatAttachmentCameraCapture) {
        guard selectedDrafts.count < maximumSelectedDraftCount,
              let draft = try? cameraDraftBuilder.makeDraft(from: capture) else {
            return
        }

        applySelectionToggle(for: draft)
    }

    private func applySelectionToggle(for draft: AttachmentDraft) {
        let result = ChatAttachmentSelectionPolicy(maximumSelectedCount: maximumSelectedDraftCount)
            .toggle(draft: draft, in: selectedDrafts)

        switch result {
        case .selected(let drafts), .deselected(let drafts):
            updateSelectedDrafts(drafts, notifySelectionChanged: true)
        case .blocked:
            break
        }
    }

    private func updateSelectedDrafts(
        _ drafts: [AttachmentDraft],
        notifySelectionChanged shouldNotifySelectionChanged: Bool
    ) {
        guard drafts != selectedDrafts else {
            return
        }

        let previousDrafts = selectedDrafts
        selectedDrafts = drafts
        cleanupTemporaryDrafts(removedFrom: previousDrafts, now: drafts)
        refreshGalleryAfterSelectionChange()
        if shouldNotifySelectionChanged {
            notifySelectionChanged()
        }
    }

    private func notifySelectionChanged() {
        onSelectionCountChanged?(selectedDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedDrafts)
    }

    private func cleanupTemporaryDrafts() {
        selectedDrafts.forEach { draft in
            cleanupTemporaryFiles(for: draft)
        }
    }

    private func cleanupTemporaryDrafts(
        removedFrom previousDrafts: [AttachmentDraft],
        now currentDrafts: [AttachmentDraft]
    ) {
        let currentIDs = Set(currentDrafts.map(\.id))
        previousDrafts
            .filter { draft in
                isTemporaryDraft(draft)
                    && !currentIDs.contains(draft.id)
            }
            .forEach { cleanupTemporaryFiles(for: $0) }
    }

    private func isTemporaryDraft(_ draft: AttachmentDraft) -> Bool {
        AttachmentCapturedDraft.url(from: draft.id) != nil
            || AttachmentEditedDraft.url(from: draft.id) != nil
    }

    private func cleanupTemporaryFiles(for draft: AttachmentDraft) {
        if AttachmentCapturedDraft.url(from: draft.id) != nil {
            cameraDraftBuilder.removeTemporaryFiles(for: draft)
        }

        if let editedURL = AttachmentEditedDraft.url(from: draft.id) {
            try? FileManager.default.removeItem(at: editedURL)
        }
    }

    private func renderPermissionState() {
        contentStackView.isHidden = true
        galleryCollectionView.isHidden = true
        emptyGalleryLabel.isHidden = true
        updateFullGalleryTopBar(isReady: false, isLimited: false)
        hideDateIndicatorForIdleState()
        permissionMessageLabel.isHidden = true
        allowAccessButton.isHidden = true
        manageLimitedLibraryButton.isHidden = true
        openSettingsButton.isHidden = true
        let isGalleryReady: Bool
        if case .ready = permissionState {
            isGalleryReady = true
        } else {
            isGalleryReady = false
        }
        if !isGalleryReady {
            cameraPreviewProvider.stopPreview()
        }

        switch permissionState {
        case .requestAccess:
            contentStackView.isHidden = false
            permissionMessageLabel.text = ChatAttachmentLocalization.string(.photosRequestAccessMessage)
            permissionMessageLabel.isHidden = false
            allowAccessButton.isHidden = false
        case .ready(let isLimited):
            galleryCollectionView.isHidden = false
            reloadGalleryItems()
            updateFullGalleryTopBar(isReady: true, isLimited: isLimited)
        case .blocked(let reason):
            contentStackView.isHidden = false
            permissionMessageLabel.text = message(for: reason)
            permissionMessageLabel.isHidden = false
            if reason == .denied {
                openSettingsButton.isHidden = false
            }
        }
    }

    private func configureDateIndicator() {
        dateIndicatorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        dateIndicatorLabel.textColor = .white
        dateIndicatorLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        dateIndicatorLabel.textAlignment = .center
        dateIndicatorLabel.layer.cornerRadius = 14
        dateIndicatorLabel.layer.masksToBounds = true
        dateIndicatorLabel.isHidden = true
        dateIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        dateIndicatorLabel.accessibilityIdentifier = "chatAttachmentGallery.dateIndicator"
    }

    private func updateFullGalleryTopBar(isReady: Bool, isLimited: Bool) {
        _ = isReady
        _ = isLimited
        fullGalleryTopBarView.isHidden = true
        dismissFullGalleryButton.isHidden = true
        fullGalleryActionMenuButton.isHidden = true
    }

    private func configureGalleryDataSource() {
        galleryDataSource = UICollectionViewDiffableDataSource<Int, ChatAttachmentGalleryItem>(
            collectionView: galleryCollectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatAttachmentGalleryCollectionViewCell.reuseIdentifier,
                for: indexPath
            ) as? ChatAttachmentGalleryCollectionViewCell else {
                return UICollectionViewCell()
            }

            self?.configure(cell, with: item, at: indexPath)
            return cell
        }
    }

    private func reloadGalleryItems() {
        applyGalleryItems(makeGalleryItems())
    }

    private func refreshGalleryAfterSelectionChange() {
        let nextGalleryItems = makeGalleryItems()
        guard nextGalleryItems == galleryItems else {
            applyGalleryItems(nextGalleryItems)
            return
        }

        refreshVisibleSelectionIndicators()
        updateEmptyGalleryState()
    }

    private func makeGalleryItems() -> [ChatAttachmentGalleryItem] {
        ChatAttachmentGalleryItemPolicy.items(
            from: galleryDataProvider.fetchAssets(),
            capturedDrafts: selectedDrafts
        )
    }

    private func applyGalleryItems(_ items: [ChatAttachmentGalleryItem]) {
        galleryItems = items

        let sectionedItems = ChatAttachmentGallerySectionPolicy.sectionedItems(from: galleryItems)
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatAttachmentGalleryItem>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems(sectionedItems[0], toSection: 0)
        snapshot.appendItems(sectionedItems[1], toSection: 1)
        galleryDataSource?.apply(snapshot, animatingDifferences: false)
        updateEmptyGalleryState()
    }

    private func updateEmptyGalleryState() {
        let hasOnlyCameraTile = galleryItems == [.camera]
        emptyGalleryLabel.isHidden = galleryCollectionView.isHidden || !hasOnlyCameraTile
    }

    private func refreshVisibleSelectionIndicators() {
        galleryCollectionView.visibleCells
            .compactMap { $0 as? ChatAttachmentGalleryCollectionViewCell }
            .forEach { cell in
                guard let item = cell.representedItem,
                      let selectionIndicatorState = selectionIndicatorState(for: item) else {
                    return
                }

                cell.updateSelectionIndicator(selectionIndicatorState)
            }
    }

    private func selectionIndicatorState(
        for item: ChatAttachmentGalleryItem
    ) -> ChatAttachmentGallerySelectionIndicatorState? {
        switch item {
        case .camera:
            return nil
        case .captured(let capturedMedia):
            return selectionIndicatorState(forDraftID: capturedMedia.id)
        case .asset(let asset):
            let draftID = AttachmentAssetDraft(assetLocalIdentifier: asset.localIdentifier).id
            return selectionIndicatorState(forDraftID: draftID)
        }
    }

    private func selectionIndicatorState(forDraftID draftID: String) -> ChatAttachmentGallerySelectionIndicatorState {
        if let selectionOrder = selectionOrder(forDraftID: draftID) {
            return .selected(order: selectionOrder)
        }

        return isSelectionBlocked(forDraftID: draftID) ? .blocked : .available
    }

    private func configure(
        _ cell: ChatAttachmentGalleryCollectionViewCell,
        with item: ChatAttachmentGalleryItem,
        at indexPath: IndexPath
    ) {
        switch item {
        case .camera:
            cell.configure(
                state: ChatAttachmentGalleryCellStatePolicy.state(
                    for: .camera,
                    isCameraEnabled: isCameraTileEnabled
                ),
                image: nil,
                cameraPreviewProvider: cameraPermissionState == .ready ? cameraPreviewProvider : nil
            )
        case .captured(let capturedMedia):
            let image = thumbnailImage(for: capturedMedia)
            let state = ChatAttachmentGalleryCellStatePolicy.state(
                for: item,
                thumbnailState: image == nil ? .failed : .image,
                selectionOrder: selectionOrder(forDraftID: capturedMedia.id),
                isSelectionBlocked: isSelectionBlocked(forDraftID: capturedMedia.id)
            )
            cell.configure(state: state, image: image)
        case .asset(let asset):
            let draftID = AttachmentAssetDraft(assetLocalIdentifier: asset.localIdentifier).id
            let initialState = ChatAttachmentGalleryCellStatePolicy.state(
                for: item,
                thumbnailState: .loading,
                selectionOrder: selectionOrder(forDraftID: draftID),
                isSelectionBlocked: isSelectionBlocked(forDraftID: draftID)
            )
            cell.configure(state: initialState, image: nil)

            let targetSize = thumbnailTargetSize()
            let requestID = thumbnailProvider.requestThumbnail(
                for: asset,
                targetSize: targetSize
            ) { [weak self, weak cell] result in
                let applyResult = {
                    guard let self,
                          cell?.representedItem == item else {
                        return
                    }

                    switch result {
                    case .image(let image):
                        let state = ChatAttachmentGalleryCellStatePolicy.state(
                            for: item,
                            thumbnailState: .image,
                            selectionOrder: self.selectionOrder(forDraftID: draftID),
                            isSelectionBlocked: self.isSelectionBlocked(forDraftID: draftID)
                        )
                        cell?.configure(state: state, image: image)
                    case .iCloud:
                        let state = ChatAttachmentGalleryCellStatePolicy.state(
                            for: item,
                            thumbnailState: .iCloud,
                            selectionOrder: self.selectionOrder(forDraftID: draftID),
                            isSelectionBlocked: self.isSelectionBlocked(forDraftID: draftID)
                        )
                        cell?.configure(state: state, image: nil)
                    case .failed:
                        let state = ChatAttachmentGalleryCellStatePolicy.state(
                            for: item,
                            thumbnailState: .failed,
                            selectionOrder: self.selectionOrder(forDraftID: draftID),
                            isSelectionBlocked: self.isSelectionBlocked(forDraftID: draftID)
                        )
                        cell?.configure(state: state, image: nil)
                    }
                }

                if Thread.isMainThread {
                    applyResult()
                } else {
                    DispatchQueue.main.async(execute: applyResult)
                }
            }

            cell.onPrepareForReuse = { [weak self] in
                self?.thumbnailProvider.cancelThumbnailRequest(requestID)
            }
        }
    }

    func gallerySelectionOrder(forAssetLocalIdentifier assetLocalIdentifier: String) -> Int? {
        selectionOrder(for: assetLocalIdentifier)
    }

    private func selectionOrder(for assetLocalIdentifier: String) -> Int? {
        let draftID = AttachmentAssetDraft(assetLocalIdentifier: assetLocalIdentifier).id
        return selectionOrder(forDraftID: draftID)
    }

    private func selectionOrder(forDraftID draftID: String) -> Int? {
        guard let index = selectedDrafts.firstIndex(where: { $0.id == draftID }) else {
            return nil
        }

        return index + 1
    }

    private func isSelectionBlocked(forDraftID draftID: String) -> Bool {
        selectedDrafts.count >= maximumSelectedDraftCount
            && selectionOrder(forDraftID: draftID) == nil
    }

    private func thumbnailImage(for capturedMedia: ChatAttachmentGalleryCapturedMedia) -> UIImage? {
        let thumbnailURL = capturedMedia.thumbnailURL ?? capturedMedia.localFileURL
        return UIImage(contentsOfFile: thumbnailURL.path)
    }

    private func thumbnailTargetSize() -> CGSize {
        let itemWidth = max(88, galleryCollectionView.bounds.width / 3)
        let scale = UIScreen.main.scale
        return CGSize(width: itemWidth * scale, height: itemWidth * scale)
    }

    private static func makeGalleryLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
            if sectionIndex == 0 {
                return makeFeaturedGallerySection()
            }

            return makeStandardGallerySection()
        }
    }

    private static func makeFeaturedGallerySection() -> NSCollectionLayoutSection {
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(2.0 / 3.0)
        )
        let group = NSCollectionLayoutGroup.custom(layoutSize: groupSize) { environment in
            let width = environment.container.effectiveContentSize.width
            let tileSide = width / 3.0
            let inset: CGFloat = 0.5

            func frame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
                CGRect(
                    x: x + inset,
                    y: y + inset,
                    width: max(0, width - (inset * 2)),
                    height: max(0, height - (inset * 2))
                )
            }

            return [
                NSCollectionLayoutGroupCustomItem(
                    frame: frame(x: 0, y: 0, width: tileSide, height: tileSide * 2)
                ),
                NSCollectionLayoutGroupCustomItem(
                    frame: frame(x: tileSide, y: 0, width: tileSide, height: tileSide)
                ),
                NSCollectionLayoutGroupCustomItem(
                    frame: frame(x: tileSide * 2, y: 0, width: tileSide, height: tileSide)
                ),
                NSCollectionLayoutGroupCustomItem(
                    frame: frame(x: tileSide, y: tileSide, width: tileSide, height: tileSide)
                ),
                NSCollectionLayoutGroupCustomItem(
                    frame: frame(x: tileSide * 2, y: tileSide, width: tileSide, height: tileSide)
                )
            ]
        }

        return NSCollectionLayoutSection(group: group)
    }

    private static func makeStandardGallerySection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / 3.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 0.5, leading: 0.5, bottom: 0.5, trailing: 0.5)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(1.0 / 3.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitem: item, count: 3)
        return NSCollectionLayoutSection(group: group)
    }

    private func message(for reason: ChatAttachmentPhotosPermissionBlockReason) -> String {
        switch reason {
        case .denied:
            return ChatAttachmentLocalization.string(.photosDeniedMessage)
        case .restricted, .unavailable:
            return ChatAttachmentLocalization.string(.photosUnavailableMessage)
        }
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        accessibilityIdentifier: String
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        button.configuration = configuration
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityLabel = title
    }

    @objc
    private func allowAccessButtonTapped() {
        photoLibraryAuthorizer.requestAuthorization { [weak self] status in
            let applyStatus: () -> Void = { [weak self] in
                self?.applyAuthorizationStatus(status, pruneSelection: true)
            }

            if Thread.isMainThread {
                applyStatus()
            } else {
                DispatchQueue.main.async(execute: applyStatus)
            }
        }
    }

    @objc
    private func manageLimitedLibraryButtonTapped() {
        limitedLibraryPresenter.presentLimitedLibraryPicker(from: self)
    }

    @objc
    private func openSettingsButtonTapped() {
        settingsOpener.openApplicationSettings()
    }

}

extension ChatAttachmentGallerySourceViewController: ChatAttachmentSheetPresentationStateObserving,
    ChatAttachmentSheetPresentationRequesting {
    func chatAttachmentSheetPresentationStateDidChange(_ state: ChatAttachmentSheetPresentationState) {
        _ = state
        setDisplayMode(.full)
    }
}

extension ChatAttachmentGallerySourceViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)

        guard let item = ChatAttachmentGallerySectionPolicy.item(at: indexPath, in: galleryItems) else {
            return
        }

        switch item {
        case .camera:
            handleCameraTileTapped()
        case .captured(let capturedMedia):
            guard let draft = selectedDrafts.first(where: { $0.id == capturedMedia.id }) else {
                return
            }

            applySelectionToggle(for: draft)
        case .asset(let asset):
            guard case .ready = permissionState else {
                return
            }

            applySelectionToggle(for: galleryDraftBuilder.makeDraft(from: asset))
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard displayMode == .full else {
            return
        }
        updateDateIndicator(forVisibleItemAt: firstVisibleAssetItemIndex())
        scheduleDateIndicatorHide()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleDateIndicatorHide()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleDateIndicatorHide()
    }

    private func firstVisibleAssetItemIndex() -> Int? {
        galleryCollectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> Int? in
                guard let itemIndex = ChatAttachmentGallerySectionPolicy.globalIndex(
                    for: indexPath,
                    in: galleryItems
                ), galleryItems.indices.contains(itemIndex) else {
                    return nil
                }

                if case .asset = galleryItems[itemIndex] {
                    return itemIndex
                }

                return nil
            }
            .min()
    }

    private func scheduleDateIndicatorHide() {
        dateIndicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideDateIndicatorForIdleState()
        }
        dateIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
    }
}

extension ChatAttachmentGallerySourceViewController: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            self?.handlePhotoLibraryDidChange()
        }
    }
}

extension ChatAttachmentGallerySourceViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let assets = galleryAssets(at: indexPaths)
        guard !assets.isEmpty else {
            return
        }

        thumbnailProvider.startCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let assets = galleryAssets(at: indexPaths)
        guard !assets.isEmpty else {
            return
        }

        thumbnailProvider.stopCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }

    private func galleryAssets(at indexPaths: [IndexPath]) -> [ChatAttachmentGalleryAsset] {
        indexPaths.compactMap { indexPath in
            guard let item = ChatAttachmentGallerySectionPolicy.item(at: indexPath, in: galleryItems) else {
                return nil
            }

            if case .asset(let asset) = item {
                return asset
            }

            return nil
        }
    }
}

final class PhotoKitChatAttachmentPhotoLibraryAuthorizer: ChatAttachmentPhotoLibraryAuthorizing {
    var authorizationStatus: ChatAttachmentPhotosAuthorizationStatus {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization(completion: @escaping (ChatAttachmentPhotosAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            completion(Self.map(status))
        }
    }

    func registerChangeObserver(_ observer: AnyObject) {
        guard let observer = observer as? PHPhotoLibraryChangeObserver else {
            return
        }

        PHPhotoLibrary.shared().register(observer)
    }

    func unregisterChangeObserver(_ observer: AnyObject) {
        guard let observer = observer as? PHPhotoLibraryChangeObserver else {
            return
        }

        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
    }

    func containsAsset(localIdentifier: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).count > 0
    }

    private static func map(_ status: PHAuthorizationStatus) -> ChatAttachmentPhotosAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        @unknown default:
            return .unavailable
        }
    }
}

final class PhotoKitChatAttachmentLimitedLibraryPresenter: ChatAttachmentLimitedLibraryPresenting {
    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }
}

final class ChatAttachmentApplicationSettingsOpener: ChatAttachmentApplicationSettingsOpening {
    func openApplicationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else {
            return
        }

        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

extension AttachmentDraft {
    var galleryAssetLocalIdentifier: String? {
        let prefix = "asset:"
        guard source == .gallery,
              id.hasPrefix(prefix) else {
            return nil
        }

        return String(id.dropFirst(prefix.count))
    }
}
