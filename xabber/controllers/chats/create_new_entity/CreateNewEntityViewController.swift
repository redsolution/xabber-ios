//
//  CreateNewEntityViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 28.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift

import RxSwift
import RxCocoa
import RxRealm

class CreateNewEntityViewController: UIViewController {
        
    struct Datasource {
        let title: String
        let iconImage: UIImage?
        let icon: String
        let key: String
        var subtitle: String
    }
    
    var datasource: [[Datasource]] = []
    
    var chatsVc: LastChatsViewController? = nil
    var archivedVc: LastChatsViewController? = nil
    var callsVc: LastCallsViewController? = nil
    var notificationsVc: NotificationsListViewController? = nil
    var notificationsCategoriesVc: NotificationsCategoriesViewController? = nil
    var contactsVc: ContactsViewController? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.separatorStyle = .singleLine
        
        return view
    }()
    
    private func loadDatasource() {
        
        if CommonConfigManager.shared.config.locked_conversation_type == "none" {
            self.datasource = [
                [
                    Datasource(title: "Add contact", iconImage: nil ,icon: "person.fill", key: "add_contact", subtitle: ""),
                    Datasource(title: "Create group", iconImage: nil, icon: "person.2.fill", key: "create_group", subtitle: ""),
                    Datasource(title: "Create incognito group", iconImage:  nil, icon: "custom.person.2", key: "create_incognito", subtitle: ""),
                    Datasource(title: "Start secret chat", iconImage: nil, icon: "custom.lock.bubble.left.fill", key: "start_secret_chat", subtitle: ""),
                ],
                [
                    Datasource(title: "Scan QR code", iconImage: nil, icon: "qrcode.viewfinder", key: "qr_code", subtitle: ""),
                ]
            ]
        } else {
            self.datasource = [
                [
                    Datasource(title: "Add contact", iconImage: nil ,icon: "person.fill", key: "add_contact", subtitle: ""),
                ],
                [
                    Datasource(title: "Scan QR code", iconImage: nil, icon: "qrcode.viewfinder", key: "qr_code", subtitle: ""),
                ]
            ]
        }
        
        
        
    }
        
    public func configure() {
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.backButtonDisplayMode = .minimal
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
    }
        
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
    }
    
    private func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
    }

    @objc
    func languageChanged() {
        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        removeNotificationObserer()
    }
    
    internal var randTitle: String = RandomTitleManager.shared.title()
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.title = CommonConfigManager.shared.config.motivating ? self.randTitle : "New chat"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}


extension CreateNewEntityViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "tablecell")
        
        cell.textLabel?.text = datasource[indexPath.section][indexPath.row].title
        if let image = datasource[indexPath.section][indexPath.row].iconImage {
            cell.imageView?.image = image.withRenderingMode(.alwaysTemplate)
            cell.tintColor = .tintColor
        } else {
            cell.imageView?.image = imageLiteral(datasource[indexPath.section][indexPath.row].icon, dimension: 24)
        }
        cell.selectionStyle = .none
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
}

extension CreateNewEntityViewController: UITableViewDelegate {
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
            case "add_contact":
                let vc = AddNewContactViewController()
                self.navigationController?.pushViewController(vc, animated: true)
            case "create_group":
                let vc = CreateNewGroupViewController()
                vc.createIncognitoGroup = false
                self.navigationController?.pushViewController(vc, animated: true)
            case "create_incognito":
                let vc = CreateNewGroupViewController()
                vc.createIncognitoGroup = true
                self.navigationController?.pushViewController(vc, animated: true)
            case "start_secret_chat":
                let vc = NewSecretChatViewController()
                self.navigationController?.pushViewController(vc, animated: true)
            case "qr_code":
                let vc = QRCodeScannerViewController()
                self.navigationController?.pushViewController(vc, animated: true)
            default:
                break
        }
    }
}
