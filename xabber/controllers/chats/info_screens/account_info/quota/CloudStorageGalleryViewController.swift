//
//  CloudStorageGalleryViewController.swift
//  xabber
//
//  Created by MacIntel on 03.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import UIKit
import TOInsetGroupedTableView
import RxSwift

class CloudStorageGalleryViewController: BaseViewController {
//    class Datasource {
//        var title: String
//        var subtitle: String?
//        var key: String?
//
//        var childs: [Datasource]
//
//        init(title: String, subtitle: String? = nil, key: String? = nil, childs: [Datasource] = []) {
//            self.title = title
//            if subtitle?.isEmpty ?? true {
//                self.subtitle = nil
//            } else {
//                self.subtitle = subtitle
//            }
//            self.key = key
//            self.childs = childs
//        }
//    }
    
    internal let footerView: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "TextCell")
        
        return view
    }()
    
    internal var bag: DisposeBag = DisposeBag()
    
//    internal var datasource: [Datasource] = []

    internal func configure(jid: String, _ selectedKind: CloudInfoScreenView.Kind) {
        self.jid = jid
        self.owner = ""
        self.footerView.selectedKind = selectedKind
        
        switch footerView.selectedKind {
        case .images:
            title = "Images".localizeString(id: "account_images_storage", arguments: [])
        case .videos:
            title = "Videos".localizeString(id: "account_videos_storage", arguments: [])
        case .files:
            title = "Files".localizeString(id: "account_files_storage", arguments: [])
        case .voice:
            title = "Voice".localizeString(id: "account_voice_storage", arguments: [])
        }
        
        let optionsButton = UIBarButtonItem(image: #imageLiteral(resourceName: "ellipsis.circle").withRenderingMode(.alwaysTemplate), style: .plain, target: self, action: nil)
        navigationItem.setRightBarButtonItems([optionsButton], animated: false)
        
        tableView.contentInset = UIEdgeInsets(top: -52, bottom: 0, left: 0, right: 0)
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        footerView.jid = self.jid
        footerView.owner = self.owner
        footerView.infoVCDelegate = self
        footerView.getReferences()
        footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.count) * 42.7)
        tableView.tableFooterView = footerView
    }
}
