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
    
    class FileView: UIView {
                
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
        
        var primary: String
        var url: URL
        
        init(frame: CGRect, primary: String, url: URL) {
            self.primary = primary
            self.url = url
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        var palette: MDCPalette = .amber
        
        internal func setup() {
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
        }
        
        public func configure(filename: String, size: String) {
            iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            let mimeType = url.absoluteString
            switch MimeIconTypes(rawValue: mimeType) {
                case .image:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .audio:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .video:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .document:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .pdf:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .table:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .presentation:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .archive:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .file:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .none:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                default:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
            self.iconButton.backgroundColor = palette.tint500
            self.filenameLabel.text = filename
            self.sizeLabel.text = size
        }
    }
    
    var views: [FileView] = []
    
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
        views.forEach { $0.removeFromSuperview() }
        views.removeAll()
        contentViews.removeAll()
        grid.removeAll()
    }
    
    func configure(_ attachments: [FileAttachment], palette: MDCPalette) {
        self.palette = palette
        resetState()
        if attachments.isEmpty { return }
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            let item = attachments[index]
            if let url = item.url {
                let view = FileView(frame: rect, primary: item.primary, url: url)
                view.palette = palette
                view.configure(filename: item.name, size: item.prettySize)
                self.addSubview(view)
                self.views.append(view)
            }
        }
    }

    func updateContent(_ attachments: [FileAttachment], palette: MDCPalette) {
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
            guard let url = item.url else { return }
            let view = self.views[index]
            view.frame = rect
            view.primary = item.primary
            view.url = url
            view.palette = palette
            view.configure(filename: item.name, size: item.prettySize)
        }
    }
    
    func handleTouch(at point: CGPoint, callback: ((URL) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        for item in views {
            if item.frame.contains(point) {
                callback?(item.url)
                isMyTouch = true
            }
        }
        return isMyTouch
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
