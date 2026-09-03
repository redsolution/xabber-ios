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

final class CloudStorageCategoryCell: UITableViewCell {
    static let cellName = "CloudStorageCategoryCell"

    private let iconContainer: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 18
        view.layer.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
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
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let valueLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(category: CloudStorageOverviewCategory, value: String?) {
        iconContainer.backgroundColor = category.tintColor
        iconView.image = UIImage(systemName: category.systemImageName)
        titleLabel.text = category.title
        subtitleLabel.text = category.subtitle
        valueLabel.text = value
        accessoryType = .disclosureIndicator

        isAccessibilityElement = true
        accessibilityIdentifier = "cloudStorage.category.\(category.rawValue)"
        accessibilityLabel = category.title
        accessibilityValue = [category.subtitle, value]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityTraits = .button
    }

    private func setupSubviews() {
        contentView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        contentView.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 36),
            iconContainer.heightAnchor.constraint(equalToConstant: 36),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.bottomAnchor),

            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
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

final class CloudStorageUpsellCardCell: UITableViewCell {
    static let cellName = "CloudStorageUpsellCardCell"

    private let iconContainer: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let iconView: UIImageView = {
        let view = UIImageView()
        view.image = UIImage(systemName: "cloud.fill")
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with state: CloudStorageUpsellCardState) {
        titleLabel.text = state.title
        bodyLabel.text = state.body
        selectionStyle = state.isEnabled ? .default : .none
        isUserInteractionEnabled = state.isEnabled

        if state.isEnabled {
            titleLabel.textColor = .label
            iconContainer.backgroundColor = .systemBlue
            iconView.tintColor = .white
            contentView.alpha = 1.0
        } else {
            titleLabel.textColor = .secondaryLabel
            iconContainer.backgroundColor = .systemGray5
            iconView.tintColor = .secondaryLabel
            contentView.alpha = 0.82
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1.0
        isUserInteractionEnabled = true
    }

    private func setupSubviews() {
        contentView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            iconContainer.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 44),
            iconContainer.heightAnchor.constraint(equalToConstant: 44),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4)
        ])
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
        tableView.register(CloudStorageUpsellCardCell.self, forCellReuseIdentifier: CloudStorageUpsellCardCell.cellName)
        tableView.register(CloudStorageCategoryCell.self, forCellReuseIdentifier: CloudStorageCategoryCell.cellName)
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

    func currentUpsellCardState() -> CloudStorageUpsellCardState {
        let hasActivePremium = SubscribtionsManager.shared
            .subscriptionPresentationState(for: self.jid)
            .hasActiveEntitlement
        return CloudStorageUpsellCardState.resolve(hasActivePremium: hasActivePremium)
    }

    func rebuildDatasource() {
        datasource = []

        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.text, title: "Media Gallery".localizeString(id: "account_media_gallery", arguments: []),
                       key: "quota_info")
        ]))

        datasource.append(Datasource(.text, title: "", children: CloudStorageOverviewCategory.allCases.map { category in
            Datasource(
                .text,
                title: category.title,
                subtitle: categoryValue(for: category),
                key: category.rawValue
            )
        }))

        if CommonConfigManager.shared.config.support_subscribtions {
            let upsellState = currentUpsellCardState()
            datasource.append(Datasource(.text, title: "", children: [
                Datasource(.button,
                           title: upsellState.title,
                           subtitle: upsellState.body,
                           key: "storage_upsell")
            ]))
        }
        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.button, title: "Free up space".localizeString(id: "account_delete_files", arguments: []),
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

    private func categoryValue(for category: CloudStorageOverviewCategory) -> String {
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
