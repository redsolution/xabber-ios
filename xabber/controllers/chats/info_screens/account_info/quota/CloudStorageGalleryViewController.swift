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
    internal let footerView: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView()
        view.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        
        return view
    }()
    
    internal var bag: DisposeBag = DisposeBag()
    
    @objc func optionButtonTapped() {
        let viewController = UIViewController()
        let tableView = UITableView()
        tableView.backgroundColor = .incomingGray
        viewController.view.addSubview(tableView)
        tableView.fillSuperview()
        viewController.modalPresentationStyle = .popover
        viewController.preferredContentSize = CGSize(width: 150, height: 44)
        tableView.dataSource = self
        tableView.delegate = self
        
        guard let presentationVC = viewController.popoverPresentationController else { return }
        presentationVC.permittedArrowDirections = []
        presentationVC.delegate = self
        
        if #available(iOS 16.0, *) {
            presentationVC.sourceItem = optionButton
        } else {
            presentationVC.barButtonItem = optionButton
        }
        presentationVC.sourceRect = CGRect(width: 150, height: 44)
        
        present(viewController, animated: true)
    }
    
    var optionButton: UIBarButtonItem? = nil

    internal func configure(jid: String, _ selectedKind: CloudInfoScreenView.Kind) {
        self.jid = jid
        self.owner = ""
        self.footerView.selectedKind = selectedKind
        
        optionButton = UIBarButtonItem(image: #imageLiteral(resourceName: "ellipsis.circle").withRenderingMode(.alwaysTemplate), style: .plain, target: self, action: #selector(optionButtonTapped))
        navigationItem.setRightBarButtonItems([optionButton!], animated: false)
        
        tableView.contentInset = UIEdgeInsets(top: -52, bottom: 0, left: 0, right: 0)
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        footerView.jid = self.jid
        footerView.owner = self.owner
        footerView.infoVCDelegate = self
        footerView.getReferences()
        footerView.setCollectionLayout()
        footerView.mediaCollectionView.collectionViewLayout = footerView.collectionFlowLayout
        switch footerView.selectedKind {
        case .images:
            title = "Images".localizeString(id: "account_images_storage", arguments: [])
            if footerView.datasource.count % 3 == 0 {
                footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count / 3 : 0) * 124)
            } else {
                footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count / 3 + 1 : 0) * 124)
            }
        case .videos:
            title = "Videos".localizeString(id: "account_videos_storage", arguments: [])
            if footerView.datasource.count % 3 == 0 {
                footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count / 3 : 0) * 124)
            } else {
                footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count / 3 + 1 : 0) * 124)
            }
        case .files:
            title = "Files".localizeString(id: "account_files_storage", arguments: [])
            footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count : 0) * 60)
        case .voice:
            title = "Voice".localizeString(id: "account_voice_storage", arguments: [])
            footerView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: CGFloat(footerView.datasource.isNotEmpty ? footerView.datasource.count : 0) * 60)
        }
        
        tableView.tableFooterView = footerView
    }
    
    
}

extension CloudStorageGalleryViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}

extension CloudStorageGalleryViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        let label = UILabel()
        label.text = "Select files"
        label.font = UIFont.preferredFont(forTextStyle: .body)
        cell.addSubview(label)
        label.fillSuperviewWithOffset(top: 0, bottom: 0, left: 15, right: 0)
        return cell
    }
}

extension CloudStorageGalleryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
}
