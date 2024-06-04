//
//  NotificationsCategoriesViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack

class NotificationsCategoriesViewController: UIViewController {
        
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        var subtitle: String
    }
    
    var datasource: [[Datasource]] = []
    
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.separatorStyle = .none
        view.backgroundColor = .systemBackground
        
        return view
    }()
    
    private func loadDatasource() {
        self.datasource = [[
            Datasource(title: "All", icon: "bell.fill", key: "all", subtitle: "\(0)"),
            Datasource(title: "Security", icon: "exclamationmark.shield.fill", key: "security", subtitle: "\(0)"),
            Datasource(title: "Subscribtion requests", icon: "person.crop.circle.fill.badge.plus", key: "subscribtion", subtitle: "\(0)"),
            Datasource(title: "Information", icon: "info.circle.fill", key: "info", subtitle: "\(0)")
        ]]
    }
    
    @objc
    private func onAppear() {
        
    }
    
    
    func subscribe() {
        
    }
    
    func unsubscribe() {
        
    }
    
    
    
    public func configure() {
        self.title = "Notifications"
        navigationController?.navigationBar.prefersLargeTitles = true
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
//        bottomBar.configure()
//        self.view.addSubview(bottomBar)
//        self.view.bringSubviewToFront(bottomBar)
//        var inputHeight: CGFloat = 80
//        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
//            inputHeight += bottomInset
//        }
//        
//        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
//        bottomBar.frame = frame
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
    }
    
    private func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(onAppear),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)
    }

    @objc
    func languageChanged() {
        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        unsubscribe()
        removeNotificationObserer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}


extension NotificationsCategoriesViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "tablecell")
        
        cell.textLabel?.text = datasource[indexPath.section][indexPath.row].title
        cell.imageView?.image = UIImage(systemName: datasource[indexPath.section][indexPath.row].icon)
//        cell.selectionStyle = 
        cell.backgroundColor = .clear
        let text = datasource[indexPath.section][indexPath.row].subtitle
        
        cell.detailTextLabel?.text = text == "0" ? "" : text
        
        let view = UIView()
        view.layer.cornerRadius = 16
        view.layer.masksToBounds = true
        view.backgroundColor = AccountColorManager.shared.topPalette().tint50
        cell.selectedBackgroundView = view
        
        return cell
    }
    
    
}

extension NotificationsCategoriesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return tableView.estimatedRowHeight
    }
    
    private func show(controller vc: UIViewController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.setViewController(vc, for: .supplementary)
//            self.splitViewController?.show(.supplementary)
            self.splitViewController?.hide(.primary)
        } else {
            UIView.performWithoutAnimation {
                self.splitViewController?.setViewController(vc, for: .supplementary)
                self.splitViewController?.show(.supplementary)
                self.splitViewController?.hide(.primary)
            }
        }
        
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = self.datasource[indexPath.section][indexPath.row].key
        switch key {
            case "all":
                let vc = NotificationsListViewController()
                self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: self)
                self.splitViewController?.hide(.primary)
            default:
                break
        }
    }
}
