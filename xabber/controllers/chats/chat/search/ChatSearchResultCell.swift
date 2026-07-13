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

import UIKit

enum ChatSearchResultCellLayoutPolicy {
    struct Frames: Equatable {
        let avatar: CGRect
        let sender: CGRect
        let snippet: CGRect
        let date: CGRect
        let status: CGRect
        let separator: CGRect
        let senderBaselineY: CGFloat
        let snippetBaselineY: CGFloat
        let dateBaselineY: CGFloat
    }

    static let standardRowHeight: CGFloat = 64
    static let avatarSize: CGFloat = 44
    static let horizontalInset: CGFloat = 12
    static let textLeading: CGFloat = 68
    static let metadataSpacing: CGFloat = 8
    static let statusSize = CGSize(width: 14, height: 18)
    static let statusDateSpacing: CGFloat = 3
    static let separatorHeight: CGFloat = 0.5

    static func rowHeight(for contentSizeCategory: UIContentSizeCategory) -> CGFloat {
        guard contentSizeCategory.isAccessibilityCategory else {
            return standardRowHeight
        }
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let senderFont = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 17, weight: .semibold),
            compatibleWith: traits
        )
        let snippetFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: UIFont.systemFont(ofSize: 15, weight: .regular),
            compatibleWith: traits
        )
        return ceil(max(
            standardRowHeight,
            senderFont.lineHeight + snippetFont.lineHeight + 24
        ))
    }

    static func frames(
        in bounds: CGRect,
        dateWidth requestedDateWidth: CGFloat,
        showsStatus: Bool,
        layoutDirection: UIUserInterfaceLayoutDirection,
        contentSizeCategory: UIContentSizeCategory
    ) -> Frames {
        let minimumHeight = rowHeight(for: contentSizeCategory)
        let height = max(bounds.height, minimumHeight)
        let width = max(0, bounds.width)
        let isAccessibility = contentSizeCategory.isAccessibilityCategory
        let dateWidth = min(
            max(0, requestedDateWidth),
            max(0, width - textLeading - horizontalInset)
        )

        let senderHeight: CGFloat
        let snippetHeight: CGFloat
        let senderTop: CGFloat
        let snippetTop: CGFloat
        let dateHeight: CGFloat
        let dateTop: CGFloat
        let senderBaselineY: CGFloat
        let snippetBaselineY: CGFloat
        let dateBaselineY: CGFloat

        if isAccessibility {
            let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            let senderFont = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: UIFont.systemFont(ofSize: 17, weight: .semibold),
                compatibleWith: traits
            )
            let snippetFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: UIFont.systemFont(ofSize: 15, weight: .regular),
                compatibleWith: traits
            )
            let metadataFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: UIFont.systemFont(ofSize: 12, weight: .regular),
                compatibleWith: traits
            )
            senderHeight = ceil(senderFont.lineHeight)
            snippetHeight = ceil(snippetFont.lineHeight)
            let contentHeight = senderHeight + 4 + snippetHeight
            senderTop = floor((height - contentHeight) / 2)
            snippetTop = senderTop + senderHeight + 4
            senderBaselineY = senderTop + ceil(senderFont.ascender)
            snippetBaselineY = snippetTop + ceil(snippetFont.ascender)
            dateHeight = ceil(metadataFont.lineHeight)
            dateTop = max(0, senderBaselineY - ceil(metadataFont.ascender))
            dateBaselineY = senderBaselineY
        } else {
            senderHeight = 20
            snippetHeight = 20
            senderTop = 8
            snippetTop = 32
            dateHeight = 18
            dateTop = 10
            senderBaselineY = 23
            snippetBaselineY = 47
            dateBaselineY = 23
        }

        let dateFrame = CGRect(
            x: width - horizontalInset - dateWidth,
            y: dateTop,
            width: dateWidth,
            height: dateHeight
        )
        let statusHeight = isAccessibility ? dateHeight : statusSize.height
        let statusFrame = showsStatus
            ? CGRect(
                x: dateFrame.minX - statusDateSpacing - statusSize.width,
                y: dateTop,
                width: statusSize.width,
                height: statusHeight
            )
            : .zero
        let metadataLeading = showsStatus ? statusFrame.minX : dateFrame.minX
        let senderFrame = CGRect(
            x: textLeading,
            y: senderTop,
            width: max(0, metadataLeading - metadataSpacing - textLeading),
            height: senderHeight
        )
        let snippetFrame = CGRect(
            x: textLeading,
            y: snippetTop,
            width: max(0, width - horizontalInset - textLeading),
            height: snippetHeight
        )
        let avatarFrame = CGRect(
            x: horizontalInset,
            y: floor((height - avatarSize) / 2),
            width: avatarSize,
            height: avatarSize
        )
        let separatorFrame = CGRect(
            x: textLeading,
            y: height - separatorHeight,
            width: max(0, width - textLeading),
            height: separatorHeight
        )

        guard layoutDirection == .rightToLeft else {
            return Frames(
                avatar: avatarFrame,
                sender: senderFrame,
                snippet: snippetFrame,
                date: dateFrame,
                status: statusFrame,
                separator: separatorFrame,
                senderBaselineY: senderBaselineY,
                snippetBaselineY: snippetBaselineY,
                dateBaselineY: dateBaselineY
            )
        }

        return Frames(
            avatar: mirrored(avatarFrame, in: width),
            sender: mirrored(senderFrame, in: width),
            snippet: mirrored(snippetFrame, in: width),
            date: mirrored(dateFrame, in: width),
            status: showsStatus ? mirrored(statusFrame, in: width) : .zero,
            separator: mirrored(separatorFrame, in: width),
            senderBaselineY: senderBaselineY,
            snippetBaselineY: snippetBaselineY,
            dateBaselineY: dateBaselineY
        )
    }

    private static func mirrored(_ frame: CGRect, in width: CGFloat) -> CGRect {
        CGRect(
            x: width - frame.maxX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

struct ChatSearchResultDateFormatter {
    typealias Presentation = ChatSearchResultDatePresentation

    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone

    init(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.locale = locale
        var calendar = calendar
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.timeZone = timeZone
    }

    func presentation(for date: Date, relativeTo now: Date) -> Presentation {
        ChatSearchFormatting(
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ).resultDate(for: date, relativeTo: now)
    }

    func string(for date: Date, relativeTo now: Date) -> String {
        presentation(for: date, relativeTo: now).text
    }
}

enum ChatSearchResultDeliveryPresentation {
    struct Value: Equatable {
        let systemImageName: String
        let fallbackAccessibilityLabel: String
        let accessibilityLabel: String
        let isFailure: Bool
    }

    static func presentation(for state: ChatSearchResult.DeliveryState) -> Value {
        let systemImageName: String
        let localizationKey: ChatSearchLocalizationKey
        let isFailure: Bool

        switch state {
        case .pending:
            systemImageName = "clock"
            localizationKey = .deliveryPending
            isFailure = false
        case .sent:
            systemImageName = "checkmark"
            localizationKey = .deliverySent
            isFailure = false
        case .delivered:
            systemImageName = "checkmark.circle"
            localizationKey = .deliveryDelivered
            isFailure = false
        case .read:
            systemImageName = "checkmark.circle.fill"
            localizationKey = .deliveryRead
            isFailure = false
        case .failed:
            systemImageName = "exclamationmark.circle.fill"
            localizationKey = .deliveryFailed
            isFailure = true
        }

        let localization = ChatSearchLocalization.production()
        let fallback = localizationKey.developmentFallback

        return Value(
            systemImageName: systemImageName,
            fallbackAccessibilityLabel: fallback,
            accessibilityLabel: localization.text(localizationKey),
            isFailure: isFailure
        )
    }
}

protocol ChatSearchResultAvatarLoadCancelling: AnyObject {
    func cancel()
}

protocol ChatSearchResultAvatarLoading: AnyObject {
    @discardableResult
    func loadAvatar(
        for avatar: ChatSearchResult.Avatar,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatSearchResultAvatarLoadCancelling?
}

private final class ChatSearchResultAvatarDeliveryToken: ChatSearchResultAvatarLoadCancelling {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func deliver(_ image: UIImage?, completion: @escaping (UIImage?) -> Void) {
        let delivery = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldDeliver = !self.cancelled
            self.lock.unlock()
            guard shouldDeliver else { return }
            completion(image)
        }
        if Thread.isMainThread {
            delivery()
        } else {
            DispatchQueue.main.async(execute: delivery)
        }
    }
}

private final class ChatSearchResultDefaultAvatarLoader: ChatSearchResultAvatarLoading {
    static let shared = ChatSearchResultDefaultAvatarLoader()

    private init() {}

    @discardableResult
    func loadAvatar(
        for avatar: ChatSearchResult.Avatar,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatSearchResultAvatarLoadCancelling? {
        let token = ChatSearchResultAvatarDeliveryToken()
        let callback: (UIImage?) -> Void = { image in
            token.deliver(image, completion: completion)
        }

        switch avatar.source {
        case let .contact(jid, owner):
            DefaultAvatarManager.shared.getAvatar(
                url: avatar.url,
                jid: jid,
                owner: owner,
                size: size,
                callback: callback
            )
        case let .group(userId, conversationJID, owner):
            DefaultAvatarManager.shared.getGroupAvatar(
                url: avatar.url,
                userId: userId,
                jid: conversationJID,
                owner: owner,
                size: size,
                callback: callback
            )
        }
        return token
    }
}

final class ChatSearchResultCell: UITableViewCell {
    static let reuseIdentifier = "ChatSearchResultCell"

    let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = ChatSearchResultCellLayoutPolicy.avatarSize / 2
        imageView.isAccessibilityElement = false
        return imageView
    }()

    let senderLabel: UILabel = {
        let label = UILabel()
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        return label
    }()

    let snippetLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        return label
    }()

    let dateLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        return label
    }()

    let statusImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemBlue
        imageView.isHidden = true
        imageView.isAccessibilityElement = false
        return imageView
    }()

    let separatorView: UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        view.isAccessibilityElement = false
        return view
    }()

    private let avatarLoader: ChatSearchResultAvatarLoading
    private let dateFormatter: ChatSearchResultDateFormatter
    private let now: () -> Date
    private var avatarRequest: ChatSearchResultAvatarLoadCancelling?
    private var deliveryAccessibilityLabel: String?
    private(set) var representedAvatarIdentity: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        avatarLoader = ChatSearchResultDefaultAvatarLoader.shared
        dateFormatter = ChatSearchResultDateFormatter()
        now = Date.init
        super.init(style: style, reuseIdentifier: reuseIdentifier ?? Self.reuseIdentifier)
        prepareView()
    }

    init(
        avatarLoader: ChatSearchResultAvatarLoading,
        dateFormatter: ChatSearchResultDateFormatter = ChatSearchResultDateFormatter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.avatarLoader = avatarLoader
        self.dateFormatter = dateFormatter
        self.now = now
        super.init(style: .default, reuseIdentifier: Self.reuseIdentifier)
        prepareView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarRequest?.cancel()
        avatarRequest = nil
        representedAvatarIdentity = nil
        deliveryAccessibilityLabel = nil
        avatarImageView.image = nil
        senderLabel.text = nil
        snippetLabel.attributedText = nil
        snippetLabel.text = nil
        dateLabel.text = nil
        statusImageView.image = nil
        statusImageView.isHidden = true
        accessibilityIdentifier = nil
        accessibilityLabel = nil
    }

    func configure(with result: ChatSearchResult) {
        avatarRequest?.cancel()
        avatarRequest = nil
        representedAvatarIdentity = result.avatar.identity

        senderLabel.text = result.senderTitle
        snippetLabel.attributedText = nil
        snippetLabel.text = result.snippet
        dateLabel.text = dateFormatter.string(
            for: result.anchor.date,
            relativeTo: now()
        )

        let delivery = ChatSearchResultDeliveryPresentation.presentation(for: result.deliveryState)
        deliveryAccessibilityLabel = result.outgoing ? delivery.accessibilityLabel : nil
        if result.outgoing {
            statusImageView.image = UIImage(systemName: delivery.systemImageName)
            statusImageView.tintColor = delivery.isFailure ? .systemRed : .systemBlue
            statusImageView.isHidden = false
        } else {
            statusImageView.image = nil
            statusImageView.isHidden = true
        }

        avatarImageView.image = fallbackAvatar(for: result.avatar)
        let representedIdentity = result.avatar.identity
        avatarRequest = avatarLoader.loadAvatar(
            for: result.avatar,
            size: ChatSearchResultCellLayoutPolicy.avatarSize
        ) { [weak self] image in
            guard let self,
                  self.representedAvatarIdentity == representedIdentity,
                  let image else {
                return
            }
            self.avatarImageView.image = image
        }

        accessibilityIdentifier = accessibilityIdentifier(for: result.id)
        updateAccessibilityLabel()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let dateWidth = min(
            96,
            ceil(dateLabel.sizeThatFits(
                CGSize(width: 96, height: CGFloat.greatestFiniteMagnitude)
            ).width)
        )
        let frames = ChatSearchResultCellLayoutPolicy.frames(
            in: contentView.bounds,
            dateWidth: dateWidth,
            showsStatus: !statusImageView.isHidden,
            layoutDirection: effectiveUserInterfaceLayoutDirection,
            contentSizeCategory: traitCollection.preferredContentSizeCategory
        )
        avatarImageView.frame = frames.avatar
        senderLabel.frame = frames.sender
        snippetLabel.frame = frames.snippet
        dateLabel.frame = frames.date
        statusImageView.frame = frames.status
        separatorView.frame = frames.separator
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: ChatSearchResultCellLayoutPolicy.rowHeight(
                for: traitCollection.preferredContentSizeCategory
            )
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory else {
            return
        }
        applyFonts()
        setNeedsLayout()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        restorePlainBackground()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        restorePlainBackground()
    }

    private func prepareView() {
        selectionStyle = .none
        accessoryType = .none
        selectedBackgroundView = nil
        separatorInset = .zero
        preservesSuperviewLayoutMargins = false
        layoutMargins = .zero
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        restorePlainBackground()
        applyFonts()

        contentView.addSubview(avatarImageView)
        contentView.addSubview(senderLabel)
        contentView.addSubview(snippetLabel)
        contentView.addSubview(statusImageView)
        contentView.addSubview(dateLabel)
        contentView.addSubview(separatorView)
    }

    private func restorePlainBackground() {
        backgroundColor = .systemBackground
        contentView.backgroundColor = .systemBackground
    }

    private func applyFonts() {
        senderLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 17, weight: .semibold),
            compatibleWith: traitCollection
        )
        snippetLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: UIFont.systemFont(ofSize: 15, weight: .regular),
            compatibleWith: traitCollection
        )
        dateLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: UIFont.systemFont(ofSize: 12, weight: .regular),
            compatibleWith: traitCollection
        )
    }

    private func fallbackAvatar(for avatar: ChatSearchResult.Avatar) -> UIImage? {
        let owner: String
        switch avatar.source {
        case let .contact(_, sourceOwner), let .group(_, _, sourceOwner):
            owner = sourceOwner
        }
        return UIImageView.getDefaultAvatar(
            for: avatar.fallbackTitle,
            owner: owner,
            size: ChatSearchResultCellLayoutPolicy.avatarSize
        )
    }

    private func accessibilityIdentifier(for id: ChatSearchResult.ID) -> String {
        switch id {
        case let .archived(value):
            return "chat.search.result.archived.\(value)"
        case let .primary(value):
            return "chat.search.result.primary.\(value)"
        }
    }

    private func updateAccessibilityLabel() {
        accessibilityLabel = [
            senderLabel.text,
            snippetLabel.text,
            dateLabel.text,
            deliveryAccessibilityLabel
        ]
        .compactMap { value in
            guard let value, value.isNotEmpty else { return nil }
            return value
        }
        .joined(separator: ", ")
    }
}
