//
//  CloudStorageDeleteViewController.swift
//  xabber
//
//  Created by MacIntel on 11.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RxSwift

class CloudStorageDeleteViewController: CloudStorageGalleryViewController {
    
    private let footerDeleteView: CloudDeleteInfoScreenView = {
        let view = CloudDeleteInfoScreenView(frame: .zero)
        
        return view
    }()
    
    internal func configure(jid: String) {
        self.jid = jid
        self.owner = ""
        
        title = "Delete files"
        
        tableView.contentInset = UIEdgeInsets(top: -52, bottom: 0, left: 0, right: 0)
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        footerDeleteView.jid = self.owner
        footerDeleteView.owner = self.jid
        footerDeleteView.infoVCDelegate = self
        footerDeleteView.configure()
        
//        setFrameForSection(section: footerDeleteView.sectionImages)
//        setFrameForSection(section: footerDeleteView.sectionFiles)
//        setFrameForSection(section: footerDeleteView.sectionVoices)
        
        footerDeleteView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 2500)
        footerDeleteView.sectionImages.mediaCollectionView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerDeleteView.sectionImages.datasource.count / 3 + 1) * 124)
        footerDeleteView.sectionImages.frame = footerDeleteView.sectionImages.mediaCollectionView.frame
        footerDeleteView.sectionVoices.mediaCollectionView.frame = CGRect(x: 0, y: footerDeleteView.sectionImages.frame.height, width: view.frame.width, height: CGFloat(footerDeleteView.sectionVoices.datasource.count) * 42.7)
        footerDeleteView.sectionVoices.frame = footerDeleteView.sectionVoices.mediaCollectionView.frame
        tableView.tableFooterView = footerDeleteView
    }
    
    func setFrameForSection(section: CloudInfoScreenView) {
        section.mediaCollectionView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(section.datasource.isNotEmpty ? section.datasource.count / 3 + 1 : 0) * 124)
        section.frame = section.mediaCollectionView.frame
    }
}
