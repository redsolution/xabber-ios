//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import Toast_Swift
import RealmSwift
import RxSwift
import RxCocoa
import CocoaLumberjack
import TOInsetGroupedTableView


class TokenInfoViewController: UIViewController {
        
    class Datasource: Hashable, Equatable {
        static func == (lhs: TokenInfoViewController.Datasource, rhs: TokenInfoViewController.Datasource) -> Bool {
            return lhs.key == rhs.key
        }
        
        var title: String
        var value: String?
        var key: String
        
        init(title: String, value: String?, key: String) {
            self.title = title
            self.value = value
            self.key = key
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
        }
    }
    
    open var jid: String = ""
    open var uid: String = ""
    open var canEdit: Bool = false
    private var datasource: [[Datasource]] = []
    
    private var resource: String? = nil
    private var statusTitle: String? = nil
    private var status: ResourceStatus = .offline
    
    internal var accountResources: Results<ResourceStorageItem>? = nil
    
    open var delegate: XabberUpdateIfNeededDelegate? = nil
    
    private var pageHeight: CGFloat = 416
    
    
    
    private var currentDeviceDescription: String? = nil
    
    private let topDimmedView: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        
        return view
    }()
    
    private let contentView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .groupTableViewBackground
        
        view.layer.cornerRadius = 32
        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        
        return view
    }()
    
    private let dragToDismissButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        button.layer.cornerRadius = 3
        
        return button
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        
        stack.isUserInteractionEnabled = true
        
        return stack
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        
        if #available(iOS 13.0, *) {
            label.textColor = .label
        } else {
            label.textColor = .darkText
        }
        
        
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 17, weight: .light)
        label.numberOfLines = 0
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        return label
    }()
    
    private let editAvatarButton: UIButton = {
        let button = UIButton(
            frame: CGRect(
                origin: CGPoint(x: 120, y: 120),
                size: CGSize(square: 44)
            )
        )
        
        button.setImage(#imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate), for: .normal)
        button.layer.cornerRadius = button.frame.width / 2
        button.backgroundColor = MDCPalette.grey.tint100
        button.tintColor = MDCPalette.grey.tint500
        
        return button
    }()
    
    private let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DangerCell")
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        
        view.isScrollEnabled = false
        
        return view
    }()
    
    private final func doAnimationsBlock(animated: Bool, block: @escaping (() -> Void)) {
        if animated {
            UIView.animate(
                withDuration: 0.33,
                delay: 0.0,
                options: [.curveEaseIn],
                animations: block,
                completion: nil
            )
        } else {
            UIView.performWithoutAnimation(block)
        }
    }
    
    public func activateConstraints() {
        NSLayoutConstraint.activate([
            tableView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableView.heightAnchor.constraint(equalToConstant: pageHeight - 82)
        ])
    }
    
    public func setupSubviews() {
//        if UIDevice.current.userInterfaceIdiom == .pad {
//            contentView.frame = CGRect(
//                x: (self.view.frame.width - 414) / 2,
//                y: self.view.frame.height - pageHeight,
//                width: 414,
//                height: pageHeight)
//            dragToDismissButton.frame = CGRect(x: 414 / 2 - 32, y: 8, width: 64, height: 6)
//        } else {
//            contentView.frame = CGRect(
//                x: 0,
//                y: self.view.frame.height - pageHeight,
//                width: self.view.frame.width,
//                height: pageHeight
//            )
//            dragToDismissButton.frame = CGRect(x: self.view.frame.width / 2 - 32, y: 8, width: 64, height: 6)
//        }
        contentView.frame = CGRect(
            x: 0,
            y: self.view.frame.height - pageHeight,
            width: self.view.frame.width,
            height: pageHeight
        )
        dragToDismissButton.frame = CGRect(x: self.view.frame.width / 2 - 32, y: 8, width: 64, height: 6)
        
        view.addSubview(contentView)
        contentView.addSubview(dragToDismissButton)
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 32, bottom: 24, left: 16, right: 16)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(tableView)
    }
    
    public func configure() {
        topDimmedView.frame = CGRect(
            x: 0,
            y: -view.frame.height,
            width: view.frame.width,
            height: view.frame.height
        )
        view.addSubview(topDimmedView)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        let dismissGestureRecognizer = PanDirectionGestureRecognizer(direction: .vertical, target: self, action: #selector(self.onDismissGestureRecognizerDidChange))
        dismissGestureRecognizer.delaysTouchesBegan = true
        dismissGestureRecognizer.maximumNumberOfTouches = 1
        
        contentView.addGestureRecognizer(dismissGestureRecognizer)
        let dismissGesture = UITapGestureRecognizer(target: self, action: #selector(dismissOnTap))
        dismissGesture.delaysTouchesBegan = true
        
//        self.view.addGestureRecognizer(dismissGesture)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsSelection = true
        tableView.isUserInteractionEnabled = true
    }
    
    private final func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            guard let tokenInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, jid].prp()) else {
                return
            }
            let resourceInstance = realm.objects(AccountStorageItem.self).filter("jid == %@", jid)
            
            titleLabel.text = tokenInstance.descr.isNotEmpty ? tokenInstance.descr : tokenInstance.client
            currentDeviceDescription = tokenInstance.descr.isNotEmpty ? tokenInstance.descr : nil
            
            self.resource = tokenInstance.resource
            
            if let resource = self.resource {
                if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: self.jid, owner: self.jid, resource: resource)) {
                    self.statusTitle = instance.displayedStatus
                    self.status = instance.status
                }
            }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy HH:mm"
            if canEdit {
                datasource = [
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value:  dateFormatter.string(from: tokenInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: tokenInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "device__info__client__label", arguments: []),
                                   value: tokenInstance.client, key: "client"),
                        Datasource(title: "Resource".localizeString(id: "account_resource", arguments: []),
                                   value: resourceInstance.first?.resource?.resource, key: "resource"),
                        Datasource(title: "IP", value: tokenInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: tokenInstance.expire), key: "expire")
                    ],
                    [
                        Datasource(title: "Rename".localizeString(id: "input_widget__button_rename", arguments: []),
                                   value: nil, key: "rename")
                    ],
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
                                   value: nil, key: "terminate")
                    ],
                ]
            } else {
                datasource = [
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value: dateFormatter.string(from: tokenInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: tokenInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "contact_viewer_client", arguments: []),
                                   value: tokenInstance.client, key: "client"),
                        Datasource(title: "IP", value: tokenInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: tokenInstance.expire), key: "expire")
                    ],
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []), value: nil, key: "terminate")
                    ],
                ]
            }
        } catch {
            DDLogDebug("TokenInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func addObservers() {
        
    }
    
    public func removeObservers() {
        
    }
    
    public func localizeResources() {
        
    }
    
    public func onAppear() {
        willShow()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if canEdit {
            pageHeight = 540//496
        } else {
            pageHeight = 416
        }
        setupSubviews()
        configure()
        localizeResources()
        loadDatasource()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        addObservers()
        onAppear()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeObservers()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    private final func willShow() {
        topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        UIView.animate(withDuration: 0.5) {
            self.topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.23)
            self.view.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        }
    }
    
    private final func dismiss() {
        UIView.animate(withDuration: 0.1) {
            self.topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
            self.view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        }
        self.delegate?.updateIfNeeded()
        FeedbackManager.shared.tap()
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    private final func onDismissGestureRecognizerDidChange(_ sender: UIPanGestureRecognizer) {
        let y = sender.translation(in: self.contentView).y
        if sender.state == .ended {
            if y > 200 {
                dismiss()
            }
            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                let rect = self.contentView.frame
                self.contentView.frame = CGRect(
                    x: 0,
                    y: self.view.frame.height - self.pageHeight,
                    width: rect.width,
                    height: rect.height
                )
            } completion: { result in
                
            }

        }
        if sender.state != .changed { return }
        let rect = self.contentView.frame
        if y > 0 {
            self.contentView.frame = CGRect(
                x: 0,
                y: self.view.frame.height - pageHeight + y,
                width: rect.width,
                height: rect.height
            )
        }
    }
    
    @objc
    private final func dismissOnTap(_ sender: AnyObject) {
//        FeedbackManager.shared.tap()
//        self.dismiss(animated: true, completion: nil)
    }
}

extension TokenInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "rename":
            onRename()
        case "terminate":
            onTerminate()
        case "status":
            do {
                let realm = try WRealm.safe()
                if let resource = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: self.uid, owner: self.jid))?.resource {
                    let vc = ContactInfoResourceController()
                    vc.jid = self.jid
                    vc.owner = self.jid
                    vc.resource = resource
                    vc.isModal = true
                    let nvc = UINavigationController(rootViewController: vc)
                    nvc.modalPresentationStyle = .fullScreen
                    nvc.modalTransitionStyle = .coverVertical
                    self.definesPresentationContext = true
                    self.present(nvc, animated: true, completion: nil)
                    self.dismiss(animated: false, completion: nil)
                }
            } catch {
                DDLogDebug("TokenInfoViewController: \(#function). \(error.localizedDescription)")
            }
        case "resource":
            let vc = AccountConnectionViewController()
            vc.configure(for: jid)
            
            let nvc = UINavigationController(rootViewController: vc)
            nvc.modalPresentationStyle = .fullScreen
            nvc.modalTransitionStyle = .coverVertical
            self.definesPresentationContext = true
            self.present(nvc, animated: true, completion: nil)
            self.dismiss(animated: false, completion: nil)
        default:
            break
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
}

extension TokenInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "terminate":
            let cell = tableView.dequeueReusableCell(withIdentifier: "DangerCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemRed
            return cell
        case "rename":
            let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemBlue
            return cell
        case "status":
            if self.resource != nil {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
                    fatalError()
                }
                
                cell.configure(
                    title: self.statusTitle ?? "Offline".localizeString(id: "unavailable", arguments: []),
                    status: self.status,
                    entity: .contact,
                    isTemporary: false
                )
                
                return cell
            } else {
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = item.value
                return cell
            }
        case "resource":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.value
            cell.accessoryType = .disclosureIndicator
            return cell
        default:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.value
            return cell
        }
    }
}

extension TokenInfoViewController {
    private final func onRename() {
        TextViewPresenter().present(
            in: self,
            title: "Rename device".localizeString(id: "device_info_rename_device", arguments: []),
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Rename".localizeString(id: "device__info__rename__button", arguments: []),
            currentValue: self.currentDeviceDescription,
            animated: true) { value in
            if value != self.currentDeviceDescription {
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.update(stream, descr: value)
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.update(stream, descr: value)
                    })
                }
            }
            DispatchQueue.main.async {
                self.dismiss()
            }
        }
    }
    
    private final func onTerminate() {
        let items = [
            ActionSheetPresenter.Item(destructive: true, title: "Terminate session?".localizeString(id: "device__info__terminate_session__button", arguments: []), value: "terminate")
        ]
        
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: items,
            animated: true) { value in
            switch value {
            case "terminate":
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.revoke(stream, uids: [self.uid])
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.revoke(stream, uids: [self.uid])
                    })
                }
            default:
                break
            }
            DispatchQueue.main.async {
                self.dismiss()
            }
        }
    }
    
}
