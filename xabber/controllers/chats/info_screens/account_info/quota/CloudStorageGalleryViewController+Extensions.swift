//
//  CloudStorageGalleryViewController+Extensions.swift
//  xabber
//
//  Created by MacIntel on 09.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension CloudStorageGalleryViewController: InfoVCDelegate {
    func presentVC(vc: UIViewController) {
        present(vc, animated: true)
    }
    
    func presentYesNoPresenter(with url: URL) {
        YesNoPresenter().present(in: self, title: "Open this file".localizeString(id: "open_file_message", arguments: []), message: url.lastPathComponent, yesText: "Open", noText: "Cancel", animated: true) { (value) in
            if value {
                UIApplication.shared.open(url, options: [:]) { (_) in }
            }
        }
    }
    
    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int) {
        let gallery = CloudPhotoGallery(urls: urls, senders: senders, dates: dates, times: times, messageIds: messageIds)
        gallery.setPage(page: page)
        gallery.setupDelegate(photoGalleryDelegate: self.footerView)
        
        let navigationViewController = UINavigationController(rootViewController: gallery)
        navigationViewController.modalPresentationStyle = .overFullScreen
        
        present(navigationViewController, animated: true)
    }
    
    func scrollToMediaGallery() {
    }
}
