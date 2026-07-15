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

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class InlineFilesGridView: InlineAttachmentView {

    final class FileView: UIView {
        let stack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = false
            stack.preservesSuperviewLayoutMargins = false
            stack.insetsLayoutMarginsFromSafeArea = false
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            button.backgroundColor = MDCPalette.blue.tint500
            button.tintColor = UIColor.white
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = false
            stack.preservesSuperviewLayoutMargins = false
            stack.insetsLayoutMarginsFromSafeArea = false
            
            return stack
        }()
        
        let filenameLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = UIColor.label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            
            return label
        }()
        
        let sizeLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()

        private let progressTrackLayer = CAShapeLayer()
        private let progressLayer = CAShapeLayer()
        private let consumerID = UUID()
        private var transferSubscription: ChatFileTransferSubscription?
        private weak var transferPipeline: ChatFileTransferServing?
        private var activeSubscriptionID: UUID?
        private var representedPresentation: ChatFileAttachmentPresentation?

        private(set) var representedRequest: ChatFileAttachmentRequest?
        private(set) var renderedTransferState: ChatFileTransferState = .idle
        private(set) var metadataBindCount = 0
        var primary = ""
        var url: URL?
        var palette: MDCPalette = .amber

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let bounds = iconButton.bounds.insetBy(dx: 2, dy: 2)
            let path = UIBezierPath(ovalIn: bounds).cgPath
            progressTrackLayer.frame = iconButton.bounds
            progressLayer.frame = iconButton.bounds
            progressTrackLayer.path = path
            progressLayer.path = path
        }

        func bind(
            _ attachment: FileAttachment,
            request: ChatFileAttachmentRequest,
            palette: MDCPalette,
            pipeline: ChatFileTransferServing
        ) {
            self.primary = attachment.primary
            self.url = attachment.url
            self.palette = palette
            self.transferPipeline = pipeline
            iconButton.backgroundColor = palette.tint500

            if representedPresentation != attachment.presentation {
                representedPresentation = attachment.presentation
                metadataBindCount += 1
                filenameLabel.text = attachment.presentation.displayName
                sizeLabel.text = attachment.presentation.formattedSize
                iconButton.setImage(
                    UIImage(systemName: attachment.presentation.icon.fileAttachmentSystemImageName),
                    for: .normal
                )
            }

            render(attachment.transferState)
            if representedRequest != request {
                cancelSubscription()
                representedRequest = request
            }
            startSubscriptionIfNeeded()
        }

        func render(_ state: ChatFileTransferState) {
            let state = state.normalized
            renderedTransferState = state
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch state {
            case .idle, .available:
                progressTrackLayer.isHidden = true
                progressLayer.isHidden = true
                progressLayer.strokeEnd = 0
                iconButton.tintColor = .white
                sizeLabel.textColor = MDCPalette.grey.tint500
                sizeLabel.text = representedPresentation?.formattedSize
            case .transferring(let progress):
                progressTrackLayer.isHidden = false
                progressLayer.isHidden = false
                progressLayer.strokeEnd = CGFloat(progress)
                iconButton.tintColor = .white
                sizeLabel.textColor = MDCPalette.grey.tint500
                let percent = Int((progress * 100).rounded())
                sizeLabel.text = "\(representedPresentation?.formattedSize ?? "") · \(percent)%"
            case .failed:
                progressTrackLayer.isHidden = true
                progressLayer.isHidden = true
                progressLayer.strokeEnd = 0
                iconButton.tintColor = .systemRed
                sizeLabel.textColor = .systemRed
                sizeLabel.text = "Transfer failed"
            }
            CATransaction.commit()
        }

        func prepareForReuse() {
            cancelOffscreenWork()
            representedRequest = nil
            representedPresentation = nil
            transferPipeline = nil
            renderedTransferState = .idle
            primary = ""
            url = nil
            filenameLabel.text = nil
            sizeLabel.text = nil
            progressTrackLayer.isHidden = true
            progressLayer.isHidden = true
            progressLayer.strokeEnd = 0
        }

        func cancelOffscreenWork() {
            cancelSubscription()
            render(.idle)
        }

        func resumeOnscreenWork() {
            startSubscriptionIfNeeded()
        }

        private func startSubscriptionIfNeeded() {
            guard transferSubscription == nil,
                  let request = representedRequest,
                  let transferPipeline else {
                return
            }
            let subscriptionID = UUID()
            activeSubscriptionID = subscriptionID
            transferSubscription = transferPipeline.subscribe(
                to: request,
                consumerID: consumerID
            ) { [weak self] state in
                guard let self,
                      self.representedRequest == request,
                      self.activeSubscriptionID == subscriptionID else {
                    return
                }
                self.render(state)
            }
        }

        private func cancelSubscription() {
            activeSubscriptionID = nil
            transferSubscription?.cancel()
            transferSubscription = nil
        }

        private func setup() {
            addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(iconButton)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(filenameLabel)
            contentStack.addArrangedSubview(sizeLabel)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                iconButton.widthAnchor.constraint(equalToConstant: 36),
                iconButton.heightAnchor.constraint(equalToConstant: 36),
                filenameLabel.heightAnchor.constraint(equalToConstant: 20),
                sizeLabel.heightAnchor.constraint(equalToConstant: 20)
            ])

            [progressTrackLayer, progressLayer].forEach {
                $0.fillColor = UIColor.clear.cgColor
                $0.lineWidth = 2
                $0.lineCap = .round
                $0.isHidden = true
                iconButton.layer.addSublayer($0)
            }
            progressTrackLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            progressLayer.strokeColor = UIColor.white.cgColor
            progressLayer.strokeEnd = 0
        }
    }

    var views: [FileView] = []
    var transferPipeline: ChatFileTransferServing = ChatFileAttachmentPipeline.shared
    
    func prepareGrid(_ attachments: [FileAttachment]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = CommonMessageSizeCalculator.inlineFileViewHeight//MessageSizeCalculator.fileViewHeight
        var offset: CGFloat = padding
        return attachments
            .compactMap { _ in
                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
                offset += height + padding
                return rect
            }
    }
    
    var palette: MDCPalette = .amber

    func resetState() {
        views.forEach {
            $0.prepareForReuse()
            $0.removeFromSuperview()
        }
        views.removeAll()
        contentViews.removeAll()
        grid.removeAll()
    }

    func cancelOffscreenWork() {
        views.forEach { $0.cancelOffscreenWork() }
    }

    func resumeOnscreenWork() {
        views.forEach { $0.resumeOnscreenWork() }
    }
    
    func configure(
        _ attachments: [FileAttachment],
        palette: MDCPalette,
        representedBy containerPrimary: String = ""
    ) {
        self.palette = palette
        resetState()
        if attachments.isEmpty { return }
        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            let view = FileView(frame: rect)
            view.bind(
                item,
                request: item.representedRequest(containerPrimary: containerPrimary),
                palette: palette,
                pipeline: transferPipeline
            )
            addSubview(view)
            views.append(view)
        }
    }

    func updateContent(
        _ attachments: [FileAttachment],
        palette: MDCPalette,
        representedBy containerPrimary: String = ""
    ) {
        self.palette = palette
        if attachments.isEmpty {
            resetState()
            return
        }

        guard self.views.count == attachments.count else {
            configure(attachments, palette: palette, representedBy: containerPrimary)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            let view = self.views[index]
            view.frame = rect
            view.bind(
                item,
                request: item.representedRequest(containerPrimary: containerPrimary),
                palette: palette,
                pipeline: transferPipeline
            )
        }
    }

    func updateTransferStates(
        _ attachments: [FileAttachment],
        representedBy containerPrimary: String
    ) {
        guard views.count == attachments.count else { return }
        zip(views, attachments).forEach { view, attachment in
            guard view.representedRequest == attachment.representedRequest(
                containerPrimary: containerPrimary
            ) else { return }
            view.render(attachment.transferState)
        }
    }

    func handleTouch(at point: CGPoint, callback: ((URL) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        for item in views {
            if item.frame.contains(point), let url = item.url {
                callback?(url)
                isMyTouch = true
            }
        }
        return isMyTouch
    }
    
}

private extension MimeIconTypes {
    var fileAttachmentSystemImageName: String {
        switch self {
        case .image: return "photo.fill"
        case .audio: return "waveform"
        case .video: return "video.fill"
        case .document: return "doc.text.fill"
        case .pdf: return "doc.richtext.fill"
        case .table: return "tablecells.fill"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .archive: return "archivebox.fill"
        case .avatar: return "person.crop.circle.fill"
        case .file: return "doc.fill"
        }
    }
}

class InlineContactsGridView: InlineAttachmentView {

    class ContactView: UIView {
        let stack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = false
            stack.preservesSuperviewLayoutMargins = false
            stack.insetsLayoutMarginsFromSafeArea = false
            return stack
        }()

        let avatarImageView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 36))
            view.contentMode = .scaleAspectFill
            view.layer.cornerRadius = 18
            view.layer.masksToBounds = true
            view.backgroundColor = MDCPalette.grey.tint200
            return view
        }()

        let contentStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = false
            stack.preservesSuperviewLayoutMargins = false
            stack.insetsLayoutMarginsFromSafeArea = false
            return stack
        }()

        let titleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = UIColor.label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            return label
        }()

        let subtitleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = MDCPalette.grey.tint500
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            return label
        }()

        var primary: String
        var jid: String
        var owner: String
        var contact: ContactAttachment
        var avatarURL: String?
        var palette: MDCPalette = .amber
        private var avatarRequestGeneration = UUID()

        init(frame: CGRect, contact: ContactAttachment) {
            self.primary = contact.primary
            self.jid = contact.jid
            self.owner = contact.owner
            self.contact = contact
            self.avatarURL = contact.avatarURL
            super.init(frame: frame)
            setup()
            configure(contact: contact, palette: palette)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        internal func setup() {
            addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(avatarImageView)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(titleLabel)
            contentStack.addArrangedSubview(subtitleLabel)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                avatarImageView.widthAnchor.constraint(equalToConstant: 36),
                avatarImageView.heightAnchor.constraint(equalToConstant: 36),
                titleLabel.heightAnchor.constraint(equalToConstant: 20),
                subtitleLabel.heightAnchor.constraint(equalToConstant: 20)
            ])
        }

        public func configure(contact: ContactAttachment, palette: MDCPalette) {
            avatarRequestGeneration = UUID()
            self.primary = contact.primary
            self.jid = contact.jid
            self.owner = contact.owner
            self.contact = contact
            self.avatarURL = contact.avatarURL
            self.palette = palette
            titleLabel.text = contact.title
            subtitleLabel.text = contact.subtitle
            configureAvatar(for: contact)
        }

        private func configureAvatar(for contact: ContactAttachment) {
            let avatarURL = contact.avatarURL ?? rosterAvatarURL(owner: contact.owner, jid: contact.jid)
            self.avatarURL = avatarURL
            let requestGeneration = avatarRequestGeneration
            if let cachedAvatar = DefaultAvatarManager.shared.cachedAvatarImage(url: avatarURL) {
                avatarImageView.image = cachedAvatar
                return
            }
            avatarImageView.image = UIImageView.getDefaultAvatar(
                for: contact.title,
                owner: contact.owner,
                size: 36
            )
            DefaultAvatarManager.shared.getAvatar(
                url: avatarURL,
                jid: contact.jid,
                owner: contact.owner,
                size: 36
            ) { [weak self] image in
                guard let self,
                      self.avatarRequestGeneration == requestGeneration,
                      self.primary == contact.primary,
                      self.owner == contact.owner,
                      self.jid == contact.jid,
                      self.avatarURL == avatarURL,
                      let image else {
                    return
                }
                self.avatarImageView.image = image
            }
        }

        func resetState() {
            avatarRequestGeneration = UUID()
            avatarImageView.image = nil
            titleLabel.text = nil
            subtitleLabel.text = nil
            avatarURL = nil
        }

        private func rosterAvatarURL(owner: String, jid: String) -> String? {
            guard owner.isNotEmpty, jid.isNotEmpty else {
                return nil
            }
            do {
                let realm = try WRealm.safe()
                return realm
                    .object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?
                    .avatarUrl
            } catch {
                return nil
            }
        }
    }

    var views: [ContactView] = []
    var palette: MDCPalette = .amber

    func resetState() {
        views.forEach { view in
            view.resetState()
            view.removeFromSuperview()
        }
        views.removeAll()
        contentViews.removeAll()
        grid.removeAll()
    }

    func prepareGrid(_ attachments: [ContactAttachment]) -> [CGRect] {
        let frame = self.frame
        let height: CGFloat = CommonMessageSizeCalculator.inlineFileViewHeight
        var offset: CGFloat = 0
        return attachments.compactMap { _ in
            let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
            offset += height
            return rect
        }
    }

    func configure(_ attachments: [ContactAttachment], palette: MDCPalette) {
        self.palette = palette
        resetState()
        if attachments.isEmpty { return }
        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            let view = ContactView(frame: rect, contact: item)
            view.configure(contact: item, palette: palette)
            self.addSubview(view)
            self.views.append(view)
        }
    }

    func updateContent(_ attachments: [ContactAttachment], palette: MDCPalette) {
        self.palette = palette
        if attachments.isEmpty {
            resetState()
            return
        }

        guard self.views.count == attachments.count else {
            configure(attachments, palette: palette)
            return
        }

        guard self.views.map(\.primary) == attachments.map(\.primary) else {
            configure(attachments, palette: palette)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            let view = self.views[index]
            view.frame = rect
            view.configure(contact: item, palette: palette)
        }
    }

    func handleTouch(at point: CGPoint, callback: ((ContactAttachment) -> Void)?) -> Bool {
        for item in views where item.frame.contains(point) {
            callback?(item.contact)
            return true
        }
        return false
    }
}
