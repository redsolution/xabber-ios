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
        if lastRefreshFailed {
            return .error
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

final class CloudStorageStatSkeletonCell: UITableViewCell {
    static let cellName = "CloudStorageStatSkeletonCell"

    private let valueSkeleton: SkeletonView = {
        let view = SkeletonView()
        view.backgroundColor = .systemGray5
        view.layer.cornerRadius = 6
        view.layer.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        textLabel?.text = title
        detailTextLabel?.text = nil
        selectionStyle = .none
        accessoryType = .none
        DispatchQueue.main.async { [weak self] in
            self?.valueSkeleton.startAnimating()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if valueSkeleton.gradientLayer != nil {
            valueSkeleton.stopAnimating()
        }
    }

    private func setupSubviews() {
        contentView.addSubview(valueSkeleton)
        NSLayoutConstraint.activate([
            valueSkeleton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueSkeleton.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            valueSkeleton.widthAnchor.constraint(equalToConstant: 86),
            valueSkeleton.heightAnchor.constraint(equalToConstant: 16)
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
    var filesUsed: String = "0 KiB"
    var audioUsed: String = "0 KiB"
    var avatarUsed: String = "0 KiB"
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
        tableView.register(CloudStorageStatSkeletonCell.self, forCellReuseIdentifier: CloudStorageStatSkeletonCell.cellName)
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
            Datasource(.text, title: galleryConfiguration().currentGalleryType.displayTitle,
                       key: "quota_info")
        ]))

        datasource.append(Datasource(.text, title: "".localizeString(id: "images", arguments: []), children: [
            Datasource(.text, title: "Images", subtitle: imagesUsed, key: "images"),
            Datasource(.text, title: "Videos".localizeString(id: "videos", arguments: []),
                       subtitle: videosUsed, key: "videos"),
            Datasource(.text, title: "Files".localizeString(id: "files", arguments: []),
                       subtitle: filesUsed, key: "files"),
            Datasource(.text, title: "Voice".localizeString(id: "voice", arguments: []),
                       subtitle: audioUsed, key: "audio")
        ]))

        datasource.append(Datasource(.text, title: "", children: [
            Datasource(.text, title: "Avatars".localizeString(id: "avatars", arguments: []),subtitle: avatarUsed,  key: "avatars")
        ]))

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
        guard configuration.isPremiumGalleryAvailable else {
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
        audioUsed = "0 KiB"
        avatarUsed = "0 KiB"
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
        imagesUsed = item.imagesUsed
        videosUsed = item.videosUsed
        filesUsed = item.filesUsed
        audioUsed = item.voicesUsed
        avatarUsed = item.avatarUsed
        usedQuota = item.totalBytes
        quota = item.quotaBytes
    }

    func subscribe() {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(AccountQuotaStorageItem.self).filter("jid == %@", self.jid)
            applyQuotaItem(collection.first)
            Observable.collection(from: collection).debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance).subscribe { results in
                self.applyQuotaItem(results.first)
                self.datasource[1].children.forEach {
                    switch $0.key {
                    case "images":
                        $0.subtitle = self.imagesUsed
                    case "videos":
                        $0.subtitle = self.videosUsed
                    case "files":
                        $0.subtitle = self.filesUsed
                    case "voice":
                        $0.subtitle = self.audioUsed
                    default:
                        break
                    }
                }
                self.datasource[2].children[0].subtitle = self.avatarUsed
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
        return imagesUsed != "0 KiB" || videosUsed != "0 KiB" || audioUsed != "0 KiB" || filesUsed != "0 KiB"
    }

    func freeQuotaPercentage() -> Int {
        guard quota > 0 else { return 0 }
        let value = 100 * max(0, quota - usedQuota) / quota
        return min(100, max(0, value))
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
