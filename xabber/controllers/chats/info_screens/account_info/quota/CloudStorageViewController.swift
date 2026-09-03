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

import UIKit
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxRealm
import RxCocoa

enum CloudStorageQuotaDisplayState: Equatable {
    case loading
    case content
    case empty
    case error
    case unlimited
    case unavailable

    static func resolve(
        hasQuotaItem: Bool,
        quotaBytes: Int,
        usedBytes: Int,
        isRefreshing: Bool,
        lastRefreshFailed: Bool,
        isAvailable: Bool
    ) -> CloudStorageQuotaDisplayState {
        if !hasQuotaItem {
            if isRefreshing { return .loading }
            if lastRefreshFailed { return .error }
            return isAvailable ? .loading : .unavailable
        }

        if isRefreshing {
            return usedBytes > 0 ? .content : .loading
        }
        if quotaBytes < 0 {
            return .unlimited
        }
        if quotaBytes == 0 {
            return .unavailable
        }
        return usedBytes == 0 ? .empty : .content
    }
}

enum CloudStorageGallerySwitcherPresentation {
    static func isVisible(configuration: AccountGalleryConfiguration) -> Bool {
        return configuration.isPremiumGalleryAvailable
            && configuration.allowsManualGallerySelection
    }
}

enum CloudStorageOverviewCategory: String, CaseIterable {
    case images
    case videos
    case voice
    case calls
    case files
    case avatars

    var title: String {
        switch self {
        case .images: return "Images".localizeString(id: "images", arguments: [])
        case .videos: return "Videos".localizeString(id: "videos", arguments: [])
        case .voice: return "Voice".localizeString(id: "voice", arguments: [])
        case .calls: return "Calls".localizeString(id: "chat_calls_title", arguments: [])
        case .files: return "Files".localizeString(id: "files", arguments: [])
        case .avatars: return "Avatars".localizeString(id: "avatars", arguments: [])
        }
    }

    var subtitle: String {
        switch self {
        case .images: return "Photos and pictures"
        case .videos: return "Video files"
        case .voice: return "Voice messages"
        case .calls: return "Call recordings"
        case .files: return "Documents and files"
        case .avatars: return "Account avatars"
        }
    }

    var systemImageName: String {
        switch self {
        case .images: return "photo.fill"
        case .videos: return "film.fill"
        case .voice: return "mic.fill"
        case .calls: return "phone.fill"
        case .files: return "doc.fill"
        case .avatars: return "camera.fill"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .images: return .systemOrange
        case .videos: return .systemIndigo
        case .voice: return .systemBlue
        case .calls: return .systemRed
        case .files: return .systemGreen
        case .avatars: return .systemPurple
        }
    }

    var fileFilter: CloudStorageFileFilter? {
        switch self {
        case .images: return .images
        case .videos: return .videos
        case .voice: return .voice
        case .calls: return .calls
        case .files: return .files
        case .avatars: return nil
        }
    }

    var mimeType: MimeIconTypes {
        switch self {
        case .images: return .image
        case .videos: return .video
        case .voice, .calls: return .audio
        case .files: return .file
        case .avatars: return .avatar
        }
    }

    var emptyStateText: String {
        switch self {
        case .voice: return "No voice messages"
        case .calls: return "No call recordings"
        default: return "No \(title.lowercased())"
        }
    }
}

struct CloudStorageCategoryGridItem {
    let category: CloudStorageOverviewCategory
    let value: String?
}

final class CloudStorageCategoryTile: UIControl {
    static let iconDimensions = CGSize(width: 36, height: 36)

    private(set) var category: CloudStorageOverviewCategory?
    var titleText: String? { titleLabel.text }
    var valueText: String? { valueLabel.text }
    var iconSize: CGSize { Self.iconDimensions }

    private let iconContainer: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 9
        view.layer.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private let iconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.tintColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let valueLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.65 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: CloudStorageCategoryGridItem) {
        category = item.category
        iconContainer.backgroundColor = item.category.tintColor
        iconView.image = UIImage(systemName: item.category.systemImageName)
        titleLabel.text = item.category.title
        valueLabel.text = item.value
        valueLabel.isHidden = item.value == nil

        accessibilityIdentifier = "cloudStorage.category.\(item.category.rawValue)"
        accessibilityLabel = item.category.title
        accessibilityValue = item.value
        accessibilityTraits = .button
    }

    private func setupViewHierarchy() {
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        isAccessibilityElement = true

        addSubview(iconContainer)
        iconContainer.addSubview(iconView)

        let labels = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labels.axis = .vertical
        labels.alignment = .fill
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: Self.iconDimensions.width),
            iconContainer.heightAnchor.constraint(equalToConstant: Self.iconDimensions.height),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            labels.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }
}

final class CloudStorageCategoryGridCell: UITableViewCell {
    static let cellName = "CloudStorageCategoryGridCell"

    private(set) var categoryTiles: [CloudStorageCategoryTile] = []
    private(set) var categoryRowCount = 0
    private var onSelect: ((CloudStorageOverviewCategory) -> Void)?

    private let gridStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSelect = nil
    }

    func configure(
        items: [CloudStorageCategoryGridItem],
        onSelect: @escaping (CloudStorageOverviewCategory) -> Void
    ) {
        self.onSelect = onSelect
        gridStack.arrangedSubviews.forEach {
            gridStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        categoryTiles = []
        categoryRowCount = 0

        for startIndex in stride(from: 0, to: items.count, by: 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillEqually
            row.spacing = 10

            for index in startIndex..<min(startIndex + 2, items.count) {
                let tile = CloudStorageCategoryTile()
                tile.configure(with: items[index])
                tile.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
                categoryTiles.append(tile)
                row.addArrangedSubview(tile)
            }
            if row.arrangedSubviews.count == 1 {
                row.addArrangedSubview(UIView())
            }
            gridStack.addArrangedSubview(row)
            categoryRowCount += 1
        }
    }

    @objc private func categoryTapped(_ sender: CloudStorageCategoryTile) {
        guard let category = sender.category else { return }
        onSelect?(category)
    }

    private func setupViewHierarchy() {
        selectionStyle = .none

        let indicator = UIView()
        indicator.backgroundColor = .systemGreen
        indicator.layer.cornerRadius = 6
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "Stored in Cloud Storage"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [indicator, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(header)
        contentView.addSubview(gridStack)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 12),
            indicator.heightAnchor.constraint(equalToConstant: 12),

            header.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 2),

            gridStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            gridStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            gridStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -2)
        ])
    }
}

struct CloudStorageUpsellCardState: Equatable {
    enum Action: Equatable {
        case openPremium
        case disabled
    }

    let title: String
    let body: String
    let action: Action

    var isEnabled: Bool {
        return action != .disabled
    }

    static func inlineState(hasActivePremium: Bool) -> CloudStorageUpsellCardState? {
        guard !hasActivePremium else { return nil }
        return resolve(hasActivePremium: false)
    }

    static func resolve(hasActivePremium: Bool) -> CloudStorageUpsellCardState {
        if hasActivePremium {
            return CloudStorageUpsellCardState(
                title: "Increase storage",
                body: "Buy external storage space: 100 GB for $5.",
                action: .disabled
            )
        }

        return CloudStorageUpsellCardState(
            title: "Increase storage",
            body: "Upgrade to Premium to increase your cloud storage capacity and store more media.",
            action: .openPremium
        )
    }
}

class CloudStorageViewController: BaseViewController {
    class Datasource {
        enum Kind {
            case text
            case button
        }

        var kind: Kind
        var viewController: UIViewController.Type?
        var title: String
        var subtitle: String?
        var key: String?

        var children: [Datasource]

        init(_ kind: Kind, viewController: UIViewController.Type? = nil, title: String, subtitle: String? = nil, key: String? = nil, children: [Datasource] = []) {
            self.kind = kind
            self.viewController = viewController
            self.title = title
            self.subtitle = subtitle
            self.key = key

            self.children = children
        }
    }

    var isDeletingFilesEnabled: Bool = false
    var imagesUsed: String = "0 KiB"
    var videosUsed: String = "0 KiB"
    var voiceUsed: String = "0 KiB"
    var callsUsed: String = "0 KiB"
    var filesUsed: String = "0 KiB"
    var avatarUsed: String = "0 KiB"
    private var eligibleCleanupBytes: Int = 0
    var usedQuota: Int = 0
    var quota: Int = 0
    var hasQuotaItem: Bool = false
    private var isRefreshingQuota: Bool = false
    private var lastQuotaRefreshFailed: Bool = false
    private var quotaServiceAvailable: Bool = true
    private var gallerySwitcher: UISegmentedControl?

    var bag: DisposeBag = DisposeBag()

    var datasource: [Datasource] = []

    let tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.register(QuotaInfoCell.self, forCellReuseIdentifier: QuotaInfoCell.cellName)
        tableView.register(CloudStorageCategoryGridCell.self, forCellReuseIdentifier: CloudStorageCategoryGridCell.cellName)
        tableView.estimatedRowHeight = 96
        tableView.rowHeight = UITableView.automaticDimension

        return tableView
    }()

    var isCellTapped: Bool = false

    func configure(jid: String) {
        self.jid = jid
        title = "Cloud Storage".localizeString(id: "account_cloud_storage", arguments: [])

        rebuildDatasource()

        view.addSubview(tableView)
        tableView.fillSuperview()

        tableView.delegate = self
        tableView.dataSource = self
    }

    func currentInlineUpsellState() -> CloudStorageUpsellCardState? {
        let hasActivePremium = SubscribtionsManager.shared
            .subscriptionPresentationState(for: jid)
            .hasActiveEntitlement
        return CloudStorageUpsellCardState.inlineState(hasActivePremium: hasActivePremium)
    }

    func rebuildDatasource() {
        datasource = []

        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.text, title: "Media Gallery".localizeString(id: "account_media_gallery", arguments: []),
                       key: "quota_info")
        ]))

        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.text, title: "", key: "category_grid")
        ]))

        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.button, title: "Free up space",
                       key: "delete_files")
        ]))
    }

    private func galleryConfiguration() -> AccountGalleryConfiguration {
        return AccountGalleryConfiguration(owner: jid)
    }

    private func configureGallerySwitcher() {
        let configuration = galleryConfiguration()
        guard CloudStorageGallerySwitcherPresentation.isVisible(configuration: configuration) else {
            gallerySwitcher = nil
            navigationItem.rightBarButtonItem = nil
            return
        }

        let switcher = UISegmentedControl(items: [
            AccountGalleryType.basic.segmentTitle,
            AccountGalleryType.premium.segmentTitle
        ])
        switcher.selectedSegmentIndex = configuration.currentGalleryType == .premium ? 1 : 0
        switcher.setEnabled(configuration.basicGalleryURL != nil, forSegmentAt: 0)
        switcher.setEnabled(configuration.premiumGalleryURL != nil, forSegmentAt: 1)
        switcher.addTarget(self, action: #selector(gallerySwitcherChanged(_:)), for: .valueChanged)
        gallerySwitcher = switcher
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: switcher)
    }

    @objc private func gallerySwitcherChanged(_ sender: UISegmentedControl) {
        let type: AccountGalleryType = sender.selectedSegmentIndex == 1 ? .premium : .basic
        guard galleryConfiguration().switchGallery(to: type) else {
            configureGallerySwitcher()
            return
        }
        isRefreshingQuota = true
        lastQuotaRefreshFailed = false
        quotaServiceAvailable = true
        resetQuotaMetrics()
        rebuildDatasource()
        updateDisplayState()
        tableView.reloadData()
        CloudStorageQuotaRefreshCoordinator.shared.refresh(owner: jid, reason: .galleryEndpointChanged, force: true)
    }

    private func resetQuotaMetrics() {
        hasQuotaItem = false
        imagesUsed = "0 KiB"
        videosUsed = "0 KiB"
        filesUsed = "0 KiB"
        voiceUsed = "0 KiB"
        callsUsed = "0 KiB"
        avatarUsed = "0 KiB"
        eligibleCleanupBytes = 0
        usedQuota = 0
        quota = 0
    }

    private func applyQuotaItem(_ item: AccountQuotaStorageItem?) {
        guard let item = item,
              galleryConfiguration().cachedQuotaMatchesCurrentGallery() else {
            resetQuotaMetrics()
            return
        }

        hasQuotaItem = true
        let rows = CloudStorageQuotaCategoryPresentation.rows(from: item)
        let emptySize = CloudStorageQuotaCategoryRow(count: 0, bytes: 0).sizeText
        imagesUsed = rows["images"]?.sizeText ?? emptySize
        videosUsed = rows["videos"]?.sizeText ?? emptySize
        voiceUsed = rows["voice"]?.sizeText ?? emptySize
        callsUsed = rows["calls"]?.sizeText ?? emptySize
        filesUsed = rows["files"]?.sizeText ?? emptySize
        avatarUsed = rows["avatars"]?.sizeText ?? emptySize
        eligibleCleanupBytes = [item.imagesBytes, item.videosBytes, item.filesBytes, item.voicesBytes, item.audioBytes]
            .reduce(0) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(max(0, value))
                return overflow ? Int.max : sum
            }
        usedQuota = item.totalBytes
        quota = item.quotaBytes
    }

    func categoryValue(for category: CloudStorageOverviewCategory) -> String {
        switch category {
        case .images: return imagesUsed
        case .videos: return videosUsed
        case .voice: return voiceUsed
        case .calls: return callsUsed
        case .files: return filesUsed
        case .avatars: return avatarUsed
        }
    }

    func subscribe() {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(AccountQuotaStorageItem.self).filter("jid == %@", self.jid)
            applyQuotaItem(collection.first)
            Observable.collection(from: collection).debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance).subscribe { results in
                self.applyQuotaItem(results.first)
                self.rebuildDatasource()
                self.updateDisplayState()
                self.tableView.reloadData()
            } onError: { _ in

            } onCompleted: {

            } onDisposed: {

            }.disposed(by: self.bag)

        } catch {
            DDLogDebug("CloudStorageViewController: \(#function). \(error.localizedDescription)")
        }
    }

    func subscribeQuotaRefreshNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quotaRefreshDidStart(_:)),
            name: .cloudStorageQuotaRefreshDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quotaRefreshDidFinish(_:)),
            name: .cloudStorageQuotaRefreshDidFinish,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
    }

    func unsubscribe() {
        self.bag = DisposeBag()
        NotificationCenter.default.removeObserver(self, name: .cloudStorageQuotaRefreshDidStart, object: nil)
        NotificationCenter.default.removeObserver(self, name: .cloudStorageQuotaRefreshDidFinish, object: nil)
        NotificationCenter.default.removeObserver(self, name: .cloudStorageGalleryDidChange, object: nil)
    }

    @objc private func quotaRefreshDidStart(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == self.jid else { return }
        guard notificationMatchesCurrentGallery(notification) else { return }
        isRefreshingQuota = true
        lastQuotaRefreshFailed = false
        updateDisplayState()
    }

    @objc private func quotaRefreshDidFinish(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == self.jid else { return }
        guard notificationMatchesCurrentGallery(notification) else { return }
        isRefreshingQuota = false
        let result = notification.userInfo?["result"] as? String
        lastQuotaRefreshFailed = result == CloudStorageQuotaRefreshResult.failure.rawValue || result == CloudStorageQuotaRefreshResult.unauthorized.rawValue
        quotaServiceAvailable = result != CloudStorageQuotaRefreshResult.unavailable.rawValue
        updateDisplayState()
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == self.jid else { return }
        configureGallerySwitcher()
        isRefreshingQuota = true
        lastQuotaRefreshFailed = false
        quotaServiceAvailable = true
        resetQuotaMetrics()
        rebuildDatasource()
        updateDisplayState()
        tableView.reloadData()
    }

    private func notificationMatchesCurrentGallery(_ notification: Notification) -> Bool {
        guard let identity = notification.userInfo?["galleryIdentity"] as? String else {
            return true
        }
        return identity == galleryConfiguration().currentGalleryIdentity
    }

    func currentDisplayState() -> CloudStorageQuotaDisplayState {
        return CloudStorageQuotaDisplayState.resolve(
            hasQuotaItem: hasQuotaItem,
            quotaBytes: quota,
            usedBytes: usedQuota,
            isRefreshing: isRefreshingQuota,
            lastRefreshFailed: lastQuotaRefreshFailed,
            isAvailable: quotaServiceAvailable
        )
    }

    func canFreeUpSpace() -> Bool {
        switch currentDisplayState() {
        case .loading, .error, .unavailable:
            return false
        case .content, .empty, .unlimited:
            break
        }
        guard quota > 0, usedQuota > 0 else { return false }
        return eligibleCleanupBytes > 0
            && CloudStorageCleanupPolicy.hasEnabledTarget(
                currentFreePercent: freeQuotaPercentage()
            )
    }

    func freeQuotaPercentage() -> Int {
        return CloudStorageCleanupPolicy.freePercentage(quotaBytes: quota, usedBytes: usedQuota)
    }

    private func updateDisplayState() {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)

        switch currentDisplayState() {
        case .loading:
            tableView.backgroundView = nil
        case .error:
            label.text = hasQuotaItem ? nil : "Cloud Storage is unavailable."
            tableView.backgroundView = label.text == nil ? nil : label
        case .unavailable:
            label.text = hasQuotaItem ? nil : "Cloud Storage is unavailable."
            tableView.backgroundView = label.text == nil ? nil : label
        case .content, .empty, .unlimited:
            tableView.backgroundView = nil
        }
        tableView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        configureGallerySwitcher()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

//        self.navigationController?.navigationBar.prefersLargeTitles = false
        rebuildDatasource()
        configureGallerySwitcher()
        tableView.reloadData()
        subscribe()
        subscribeQuotaRefreshNotifications()
        CloudStorageQuotaRefreshCoordinator.shared.refresh(owner: self.jid, reason: .screenOpen)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        tableView.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
}
