//
//  FileDeletionConfirmation.swift
//  xabber
//
//  Created by MacIntel on 20.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import TOInsetGroupedTableView

class FileDeletionConfirmation: BaseViewController {
    var percent: Int = 0
    var dateOfLastFile: String? = nil
    var totalPages: Int = 0
    var items: [NSDictionary] = []
    
    let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ViewFilesCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DeleteFilesCell")
        return view
    }()
    
    lazy var spinner: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = UIColor.gray
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        return activityIndicator
    }()
    
    convenience init(percent: Int, owner: String) {
        self.init()
        self.percent = percent
        self.owner = owner
    }
    
    func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.navigationItem.title = "Delete files"
        self.navigationController?.navigationBar.prefersLargeTitles = true
        
        view.backgroundColor = .systemGroupedBackground
        spinner.startAnimating()
        view.addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        
        guard let account = AccountManager.shared.find(for: self.owner),
              let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
        uploader.getFilesToDeleteByPercent(percent: self.percent, page: 1) { items, totalObjects, objPerPage, pages in
            self.totalPages = pages
            self.items = items
            self.dateOfLastFile = items[0]["created_at"] as? String
            self.spinner.removeFromSuperview()
            self.spinner.stopAnimating()
            self.configure()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationItem.title = ""
        self.navigationController?.navigationBar.prefersLargeTitles = false
    }
}

extension FileDeletionConfirmation: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ViewFilesCell")
            var listContentConfiguration = cell!.defaultContentConfiguration()
            listContentConfiguration.text = "View files to delete"
            listContentConfiguration.textProperties.color = .systemBlue
            listContentConfiguration.textProperties.alignment = .center
            cell!.contentConfiguration = listContentConfiguration
            return cell!
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "DeleteFilesCell")
            var listContentConfiguration = cell!.defaultContentConfiguration()
            listContentConfiguration.text = "Delete files"
            listContentConfiguration.textProperties.color = .systemRed
            listContentConfiguration.textProperties.alignment = .center
            cell!.contentConfiguration = listContentConfiguration
            return cell!
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section != 0 {
            return nil
        }
        let headerView = UITableViewHeaderFooterView()
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.text = "You are about to delete files from your cloud storage. Press the button below to review the list of file`s that are about to be deleted."
        label.numberOfLines = 0
        headerView.addSubview(label)
        label.fillSuperviewWithOffset(top: 0, bottom: 35, left: 16, right: 16)
        return headerView
    }
}

extension FileDeletionConfirmation: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let viewController = CloudStorageDeleteViewController(percent: percent, owner: self.owner, items: self.items, totalPages: self.totalPages)
            self.navigationController?.pushViewController(viewController, animated: true)
            self.navigationController?.viewControllers.remove(at: (self.navigationController?.viewControllers.count)! - 2)
            
        } else if indexPath.section == 1 {
            ActionSheetPresenter()
                .present(in: self,
                         title: "Delete files",
                         message: "Please confirm deleting files from a cloud storage. This action can not be undone.",
                         cancel: "Cancel",
                         values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
                         animated: true) { _ in
                    guard let account = AccountManager.shared.find(for: self.owner),
                          let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
                    uploader.getFilesToDeleteByPercent(percent: self.percent, page: 1) { items, totalObjects, objPerPage, pages in
                        self.dateOfLastFile = items[0]["created_at"] as? String
                    }
                    uploader.deleteMediaForSelectedPeriod(earlierThanDate: self.dateOfLastFile!) {
                        self.navigationController?.popViewController(animated: true)
                    }
                }
        }
    }
}
