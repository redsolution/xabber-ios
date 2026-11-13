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
import XMPPFramework
import QuickLook

//MARK: - Protocols
protocol InfoVCDelegate {
    func presentVC(vc: UIViewController)
    func presentYesNoPresenter(with url: URL)
    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int)
    func scrollToMediaGallery()
}

/// Retains its own data source while previewing a staged media file.
final class InfoMediaFilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}

@MainActor
func presentInfoMediaFile(_ url: URL, owner: String, from presenter: BaseViewController) {
    YesNoPresenter().present(
        in: presenter,
        title: L10n.text("open_file_message", fallback: "Open this file"),
        message: url.lastPathComponent,
        yesText: L10n.text("common__action__open", fallback: "Open"),
        noText: L10n.text("common__action__cancel", fallback: "Cancel"),
        animated: true, confirmAfterDismissal: true
    ) { [weak presenter] confirmed in
        guard confirmed, let presenter, presenter.owner == owner else { return }
        guard !url.isFileURL, PrivacyProxyMediaRouter.shared.restrictsRedirects(owner: owner) else {
            if url.isFileURL {
                presenter.present(InfoMediaFilePreviewController(fileURL: url), animated: true)
            } else {
                UIApplication.shared.open(url, options: [:])
            }
            return
        }
        Task { [weak presenter] in
            do {
                let local = try await PrivacyProxyMediaRouter.shared.download(url, owner: owner)
                guard let presenter, presenter.owner == owner,
                      presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
                presenter.present(InfoMediaFilePreviewController(fileURL: local), animated: true)
            } catch {
                guard let presenter, presenter.owner == owner, presenter.viewIfLoaded?.window != nil else { return }
                presenter.view.makeToast(L10n.text("chat_attachment_status_file_transfer_unavailable_title", fallback: "File transfer unavailable"))
            }
        }
    }
}

class XMPPIDInfoScreenYableViewCell: UITableViewCell {
    
    static public let cellName: String = "XMPPIDInfoScreenYableViewCell"
    
    var stack: UIStackView = {
        let stack = UIStackView()
//            stack.axis = .vertical
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        
//        stack.isLayoutMarginsRelativeArrangement = true
//        stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 20, right: 8)
        return stack
    }()
    
    var titleLabel: XCopyableLabel = {
        let label = XCopyableLabel()
        
        label.textColor = .tintColor
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        
        return label
    }()
    
    var qrButton: UIButton = {
        var conf = UIButton.Configuration.plain()
        conf.image = imageLiteral("qrcode")
        conf.baseForegroundColor = .tintColor
        conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        let button = UIButton(configuration: conf, primaryAction: nil)
        
        return button
    }()
    
    final func configure(title: String, jid: String) {
        self.titleLabel.text = title
        self.jid = jid
    }
    
    open var onQRCodeTouchUpInsideCallback: ((String) -> Void)? = nil
    
    internal var jid: String = ""
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .none
        self.contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 6, bottom: 6, left: 20, right: 16)
//        UIEdgeInsets(top: 6, bottom: 6, left: 20, right: 8)
        
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(qrButton)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        qrButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        qrButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            qrButton.widthAnchor.constraint(equalToConstant: 44),
            qrButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        self.qrButton.addTarget(self, action: #selector(self.onQRCodeButtonTouchUpInside), for: .touchUpInside)
    }
    
    @objc
    private func onQRCodeButtonTouchUpInside(_ sender: UIButton) {
        self.onQRCodeTouchUpInsideCallback?(self.jid)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}

//MARK: - Extensions
extension ContactInfoViewController: InfoVCDelegate {
    func presentVC(vc: UIViewController) {
        present(vc, animated: true, completion: nil)
    }
    
    func presentYesNoPresenter(with url: URL) {
        presentInfoMediaFile(url, owner: owner, from: self)
    }

    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int) {
//        let gallery = PhotoGallery(urls: urls,
//                                   senders: senders,
//                                   dates: dates,
//                                   times: times,
//                                   messageIds: messageIds)
//        gallery.setPage(page: page)
//        gallery.setupDelegate(photoGalleryDelegate: self.footerView)
//        
//        let nvc = UINavigationController(rootViewController: gallery)
//        nvc.modalPresentationStyle = .overFullScreen
//        
//        present(nvc, animated: true, completion: nil)
    }

    func scrollToMediaGallery() {
        guard let y = tableView.tableFooterView?.frame.height else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: tableView.contentSize.height - y - 12), animated: true)
    }
}
