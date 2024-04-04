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

//MARK: - Protocols
protocol InfoVCDelegate {
    func presentVC(vc: UIViewController)
    func presentYesNoPresenter(with url: URL)
    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int)
    func scrollToMediaGallery()
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
        let gallery = PhotoGallery(urls: urls,
                                   senders: senders,
                                   dates: dates,
                                   times: times,
                                   messageIds: messageIds)
        gallery.setPage(page: page)
        gallery.setupDelegate(photoGalleryDelegate: self.footerView)
        
        let nvc = UINavigationController(rootViewController: gallery)
        nvc.modalPresentationStyle = .overFullScreen
        
        present(nvc, animated: true, completion: nil)
    }

    func scrollToMediaGallery() {
        guard let y = tableView.tableFooterView?.frame.height else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: tableView.contentSize.height - y - 12), animated: true)
    }
}
