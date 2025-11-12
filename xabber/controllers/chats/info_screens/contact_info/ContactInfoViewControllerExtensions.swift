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

//MARK: - Protocols
protocol InfoVCDelegate {
    func presentVC(vc: UIViewController)
    func presentYesNoPresenter(with url: URL)
    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int)
    func scrollToMediaGallery()
}

class XMPPIDInfoScreenYableViewCell: UITableViewCell {
    
    static public let cellName: String = "XMPPIDInfoScreenYableViewCell"
    
    var stack: UIStackView = {
        let stack = UIStackView()
//            stack.axis = .vertical
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 2
        
//        stack.isLayoutMarginsRelativeArrangement = true
//        stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 20, right: 8)
        return stack
    }()
    
    var titleLabel: XCopyableLabel = {
        let label = XCopyableLabel()
        
        label.textColor = .tintColor
        
        return label
    }()
    
    var qrButton: UIButton = {
        var conf = UIButton.Configuration.plain()
        conf.image = imageLiteral("qrcode")
        conf.baseForegroundColor = .tintColor
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
        stack.fillSuperviewWithOffset(top: 6, bottom: 6, left: 20, right: 20)
//        UIEdgeInsets(top: 6, bottom: 6, left: 20, right: 8)
        
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(qrButton)
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
        YesNoPresenter().present(in: self, title: "Open this file".localizeString(id: "open_file_message", arguments: []),
                                 message: url.lastPathComponent, yesText: "Open", noText: "Cancel", animated: true) { (value) in
            if value {
                UIApplication.shared.open(url, options: [:]) { (_) in }
            }
        }
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
