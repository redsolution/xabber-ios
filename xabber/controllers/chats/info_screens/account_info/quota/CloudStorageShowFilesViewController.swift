//
//  CloudStorageShowFilesViewController.swift
//  xabber
//
//  Created by MacIntel on 27.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RxSwift
import CocoaLumberjack

class CloudStorageShowFilesViewController: BaseViewController {
    struct Datasource {
        enum Kind {
            case image
            case video
            case file
            case voice
            case avatar
            case undefined
        }
        
        var uri: String? = nil
        var thumbnail: String? = nil
        var kind: Kind
        var videoPreviewKey: String? = nil
        var videoDuration: String? = nil
        var audioDuration: String? = nil
        var meters: String? = nil
        var mimeType: String? = nil
        var fileName: String? = nil
        var voiceModel: AudioAttachment? = nil
        var dateFormatted: Date? = nil
        var date: String? = nil
        var time: String? = nil
        var size: String? = nil
        var senderName: String? = nil
        var messageId: String? = nil
        var fileId: Int? = nil
    }
    
    var totalPages: Int
    var items: [NSDictionary]
    var currentPage: Int = 1
    
    lazy var spinner: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = UIColor.gray
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        return activityIndicator
    }()
    
    init(owner: String) {
        self.items = []
        self.totalPages = 0
        super.init(nibName: nil, bundle: nil)
        self.owner = owner
    }
    
    init(owner: String, items: [NSDictionary], totalPages: Int) {
        self.items = items
        self.totalPages = totalPages
        super.init(nibName: nil, bundle: nil)
        self.owner = owner
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

protocol TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String)
}

extension CloudStorageShowFilesViewController: TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String) {
        do {
            let realm = try WRealm.safe()
            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            let chatViewController = ChatViewController()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }
}
