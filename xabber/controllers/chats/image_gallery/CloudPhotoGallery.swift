//
//  CloudPhotoGallery.swift
//  xabber
//
//  Created by MacIntel on 10.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation

public class CloudPhotoGallery: PhotoGallery {
    var tappedCloudPhotoDelegate: TappedPhotoInCloudGallery?
    
    func setupDelegate(photoGalleryDelegate: CloudStorageShowFilesViewController) {
        self.tappedCloudPhotoDelegate = photoGalleryDelegate
    }
    
    override func didTapSenderInfoButton() {
        self.dismissGallery()
        guard let primary = messageIds[currentPage].split(separator: "_").first else { return }
        tappedCloudPhotoDelegate?.tappedPhotoInGallery(primary: String(primary))
    }
}
