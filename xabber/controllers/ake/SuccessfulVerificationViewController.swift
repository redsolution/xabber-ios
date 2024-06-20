//
//  SuccessVerificationViewController.swift
//  xabber
//
//  Created by Admin on 19.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import XMPPFramework
import TOInsetGroupedTableView

class SuccessfulVerificationViewController: SimpleBaseViewController {
    class Datasource {
        let name: String
        let ip: String
        let lastAuth: Date
        let client: String
        
        init(name: String, ip: String, lastAuth: Date, client: String) {
            self.name = name
            self.ip = ip
            self.lastAuth = lastAuth
            self.client = client
        }
    }
    
    var deviceId: String = ""
    var datasource: [Datasource] = []
    var headerHeightMax: CGFloat = 236
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        view.titleButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        view.additionalTopOffset = 56
        
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let stackLabels: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = label.font.bold()
        label.textAlignment = .left
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = "Verification Successful"
        
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = "Verification has been successfully completed. Your devices can now seamlessly share encrypted communications. The following devices are now trusted:"
        
        return label
    }()
    
    let closeButton: UIButton = {
        let button = UIButton()
        button.setTitle("Great!", for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    override func setupSubviews() {
        
        view.addSubview(stackLabels)
        view.addSubview(tableView)
        view.addSubview(closeButton)
        view.addSubview(headerView)
        
        stackLabels.addArrangedSubview(titleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        
        tableView.fillSuperviewWithOffset(top: headerHeightMax + 125, bottom: 0, left: 0, right: 0)
        tableView.dataSource = self
        
        headerView.backgroundColor = .systemGroupedBackground
        self.headerView.imageButton.imageEdgeInsets = UIEdgeInsets(top: 20, bottom: 20, left: 20, right: 20)
        self.headerView.imageButton.backgroundColor = .white
        self.headerView.imageButton.imageView?.contentMode = .scaleAspectFit
        
        closeButton.addTarget(self, action: #selector(self.close), for: .touchUpInside)
    }
    
    override func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            guard let deviceIdInt = Int(self.deviceId),
                  let currentDevice = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, deviceIdInt).first else {
                return
            }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy"
            let dateRaw = currentDevice.authDate
            let date = dateFormatter.string(from: dateRaw)
            
            self.headerView.configure(
                avatarUrl: nil,
                owner: self.owner,
                jid: self.jid,
                titleColor: .black,
                title: currentDevice.device,
                subtitle: currentDevice.ip + " • " + date,
                thirdLine: nil
            )
            
            
            if currentDevice.client == "XabberIOS" {
                self.headerView.imageButton.setImage(UIImage(systemName: "iphone")?.withTintColor(.systemBlue), for: .normal)
            } else if currentDevice.client == "Xabber for Web" {
                self.headerView.imageButton.setImage(UIImage(systemName: "desktopcomputer")?.withTintColor(.systemBlue), for: .normal)
            } else {
                self.headerView.imageButton.setImage(UIImage(systemName: "questionmark")?.withTintColor(.systemBlue), for: .normal)
            }
            
            self.datasource = []
            self.datasource.append(Datasource(name: currentDevice.device, ip: currentDevice.ip, lastAuth: currentDevice.authDate, client: currentDevice.client))
            let instances = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND state_ == %@ AND trustedByDeviceId == %@", self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue, self.deviceId)
            for instance in instances {
                guard let device = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, instance.deviceId).first else {
                    continue
                }
                self.datasource.append(Datasource(name: device.device, ip: device.ip, lastAuth: device.authDate, client: device.client))
            }
        } catch {
            DDLogDebug("SuccessfulVerificationViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func activateConstraints() {
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            titleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
//            tableView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
//            tableView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 33),
//            tableView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70)
        ])
    }
    
    override func onAppear() {
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
    }
}

extension SuccessfulVerificationViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
            return UITableViewCell(frame: .zero)
        }
        cell.configure(client: item.client, device: item.name, description: "description", ip: item.ip, lastAuth: item.lastAuth, current: false, editable: false, isOnline: false)
        
        return cell
    }
}
