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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import UIKit
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm

enum QuotaInfoCellPresentation {
    static let legendRows: [[CloudStorageOverviewCategory]] = [
        [.images, .videos, .voice],
        [.calls, .files, .avatars]
    ]

    static func quotaText(
        used: String,
        quotaBytes: Int,
        quotaFormatter: (Int) -> String = AccountQuotaStorageItem.beautify(size:)
    ) -> String {
        let displayedQuota = quotaBytes < 0 ? "Unlimited" : quotaFormatter(quotaBytes)
        return used + " of ".localizeString(id: "of", arguments: []) + displayedQuota
    }

    static func usageBytes(from item: AccountQuotaStorageItem) -> [CloudStorageOverviewCategory: Int] {
        return [
            .images: max(0, item.imagesBytes),
            .videos: max(0, item.videosBytes),
            .voice: max(0, item.voicesBytes),
            .calls: max(0, item.audioBytes),
            .files: max(0, item.filesBytes),
            .avatars: max(0, item.avatarsBytes)
        ]
    }
}

private final class CloudStorageQuotaBarView: UIView {
    private var usage: [CloudStorageOverviewCategory: Int] = [:]
    private var quotaBytes = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "Cloud storage usage"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(usage: [CloudStorageOverviewCategory: Int], quotaBytes: Int) {
        self.usage = usage
        self.quotaBytes = quotaBytes

        let rawTotal = usage.values.reduce(0.0) { $0 + Double($1) }
        let safeTotal = Int(min(rawTotal, Double(Int.max)))
        accessibilityValue = QuotaInfoCellPresentation.quotaText(
            used: AccountQuotaStorageItem.beautify(size: safeTotal),
            quotaBytes: quotaBytes
        )
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard rect.width > 0,
              rect.height > 0,
              let context = UIGraphicsGetCurrentContext() else {
            return
        }

        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 7).addClip()
        UIColor.systemGray5.setFill()
        context.fill(rect)

        let totalUsage = usage.values.reduce(0.0) { $0 + Double($1) }
        let denominator: Double
        if quotaBytes > 0 {
            denominator = Double(quotaBytes)
        } else if quotaBytes < 0, totalUsage > 0 {
            denominator = totalUsage
        } else {
            denominator = 0
        }

        guard denominator > 0 else {
            context.restoreGState()
            return
        }

        var currentX = rect.minX
        for category in CloudStorageOverviewCategory.allCases {
            let bytes = Double(usage[category] ?? 0)
            guard bytes > 0, currentX < rect.maxX else { continue }

            let proposedWidth = rect.width * CGFloat(bytes / denominator)
            let width = min(max(1, proposedWidth), rect.maxX - currentX)
            category.tintColor.setFill()
            context.fill(CGRect(x: currentX, y: rect.minY, width: width, height: rect.height))
            currentX += width

            if currentX < rect.maxX {
                UIColor.systemBackground.setFill()
                context.fill(CGRect(x: currentX, y: rect.minY, width: 1, height: rect.height))
                currentX += 1
            }
        }
        context.restoreGState()
    }
}

private final class CloudStorageIncreaseView: UIControl {
    private var action: (() -> Void)?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemBlue
        label.numberOfLines = 0
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: CloudStorageUpsellCardState?, action: (() -> Void)?) {
        isHidden = state == nil
        titleLabel.text = state?.title
        bodyLabel.text = state?.body
        self.action = action

        accessibilityIdentifier = "cloudStorage.increaseStorage"
        accessibilityLabel = state?.title
        accessibilityValue = state?.body
        accessibilityTraits = .button
    }

    @objc private func tapped() {
        action?()
    }

    private func setupViewHierarchy() {
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let labels = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        labels.axis = .vertical
        labels.alignment = .fill
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let chevronConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: chevronConfiguration))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(labels)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            labels.leadingAnchor.constraint(equalTo: leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            labels.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
            chevron.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
}

final class QuotaInfoCell: UITableViewCell {
    static let cellName = "QuotaInfoCell-CloudStorage"

    private var owner = ""
    private var bag = DisposeBag()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let quotaLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let headerSpacer = UIView()
    private let quotaBar = CloudStorageQuotaBarView()
    private let legendStack = UIStackView()
    private let increaseView = CloudStorageIncreaseView()
    private let skeletonQuotaView = QuotaInfoCell.makeSkeletonView(width: 92, height: 16)
    private let skeletonProgressView = QuotaInfoCell.makeSkeletonView(width: 1, height: 20)
    private let skeletonLegendStack = UIStackView()
    private var skeletonLegendViews: [SkeletonView] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetObservation()
        increaseView.configure(state: nil, action: nil)
    }

    func setup(
        title: String,
        owner: String,
        displayState: CloudStorageQuotaDisplayState = .loading,
        requiresDataFromServer: Bool = false,
        increaseStorage: CloudStorageUpsellCardState? = nil,
        onIncreaseStorage: (() -> Void)? = nil
    ) {
        resetObservation()
        self.owner = owner
        titleLabel.text = title
        increaseView.configure(state: increaseStorage, action: onIncreaseStorage)

        switch displayState {
        case .loading:
            showLoadingState()
        case .error, .unavailable:
            showMessageState("Cloud Storage is unavailable.")
        case .content, .empty, .unlimited:
            showContentState()
            subscribe()
        }
    }

    deinit {
        resetObservation()
    }

    private func setupViewHierarchy() {
        selectionStyle = .none

        let headerStack = UIStackView(arrangedSubviews: [
            titleLabel,
            headerSpacer,
            quotaLabel,
            skeletonQuotaView
        ])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 8

        quotaBar.translatesAutoresizingMaskIntoConstraints = false
        quotaBar.heightAnchor.constraint(equalToConstant: 20).isActive = true
        skeletonProgressView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        configureLegendStack()
        configureSkeletonLegendStack()

        let rootStack = UIStackView(arrangedSubviews: [
            headerStack,
            quotaBar,
            skeletonProgressView,
            legendStack,
            skeletonLegendStack,
            increaseView
        ])
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    private func configureLegendStack() {
        legendStack.axis = .vertical
        legendStack.alignment = .fill
        legendStack.spacing = 8
        legendStack.accessibilityIdentifier = "cloudStorage.quota.legend"

        QuotaInfoCellPresentation.legendRows.forEach { categories in
            let row = UIStackView(arrangedSubviews: categories.map(makeLegendItem(for:)))
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .fillEqually
            row.spacing = 8
            legendStack.addArrangedSubview(row)
        }
    }

    private func makeLegendItem(for category: CloudStorageOverviewCategory) -> UIView {
        let indicator = UIView()
        indicator.backgroundColor = category.tintColor
        indicator.layer.cornerRadius = 3
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 6),
            indicator.heightAnchor.constraint(equalToConstant: 6)
        ])

        let label = UILabel()
        label.text = category.title
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.minimumScaleFactor = 0.8
        label.adjustsFontSizeToFitWidth = true

        let item = UIStackView(arrangedSubviews: [indicator, label])
        item.axis = .horizontal
        item.alignment = .center
        item.spacing = 6
        item.isAccessibilityElement = true
        item.accessibilityLabel = category.title
        return item
    }

    private func configureSkeletonLegendStack() {
        skeletonLegendStack.axis = .vertical
        skeletonLegendStack.alignment = .fill
        skeletonLegendStack.spacing = 8

        QuotaInfoCellPresentation.legendRows.forEach { categories in
            let views = categories.map { _ -> SkeletonView in
                let view = QuotaInfoCell.makeSkeletonView(width: 1, height: 12)
                view.heightAnchor.constraint(equalToConstant: 12).isActive = true
                skeletonLegendViews.append(view)
                return view
            }
            let row = UIStackView(arrangedSubviews: views)
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            skeletonLegendStack.addArrangedSubview(row)
        }
    }

    private func subscribe() {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(AccountQuotaStorageItem.self).filter("jid == %@", owner)
            if let item = collection.first,
               AccountGalleryConfiguration(owner: owner).cachedQuotaMatchesCurrentGallery() {
                apply(item)
            }

            Observable.collection(from: collection)
                .observe(on: MainScheduler.instance)
                .subscribe(onNext: { [weak self] results in
                    guard let self,
                          let item = results.first,
                          AccountGalleryConfiguration(owner: self.owner).cachedQuotaMatchesCurrentGallery() else {
                        return
                    }
                    self.apply(item)
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("QuotaInfoCell: \(#function). \(error.localizedDescription)")
        }
    }

    private func apply(_ item: AccountQuotaStorageItem) {
        quotaLabel.text = QuotaInfoCellPresentation.quotaText(
            used: item.total,
            quotaBytes: item.quotaBytes
        )
        quotaBar.configure(
            usage: QuotaInfoCellPresentation.usageBytes(from: item),
            quotaBytes: item.quotaBytes
        )
    }

    private func showLoadingState() {
        quotaLabel.isHidden = true
        quotaBar.isHidden = true
        legendStack.isHidden = true
        skeletonQuotaView.isHidden = false
        skeletonProgressView.isHidden = false
        skeletonLegendStack.isHidden = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ([self.skeletonQuotaView, self.skeletonProgressView] + self.skeletonLegendViews)
                .forEach { $0.startAnimating() }
        }
    }

    private func showContentState() {
        stopSkeletons()
        quotaLabel.isHidden = false
        quotaBar.isHidden = false
        legendStack.isHidden = false
        skeletonQuotaView.isHidden = true
        skeletonProgressView.isHidden = true
        skeletonLegendStack.isHidden = true
    }

    private func showMessageState(_ message: String) {
        stopSkeletons()
        quotaLabel.text = message
        quotaLabel.isHidden = false
        quotaBar.isHidden = true
        legendStack.isHidden = true
        skeletonQuotaView.isHidden = true
        skeletonProgressView.isHidden = true
        skeletonLegendStack.isHidden = true
    }

    private func resetObservation() {
        bag = DisposeBag()
        stopSkeletons()
    }

    private func stopSkeletons() {
        ([skeletonQuotaView, skeletonProgressView] + skeletonLegendViews).forEach { view in
            if view.gradientLayer != nil {
                view.stopAnimating()
            }
        }
    }

    private static func makeSkeletonView(width: CGFloat, height: CGFloat) -> SkeletonView {
        let view = SkeletonView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.backgroundColor = .systemGray5
        view.layer.cornerRadius = min(height / 2, 6)
        view.layer.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        if width > 1 {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return view
    }
}
