////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import UIKit
//import MaterialComponents.MDCPalettes
//import Toast_Swift
//import RealmSwift
//import RxSwift
//import RxCocoa
//import CocoaLumberjack
//import TOInsetGroupedTableView
//
//
//class TokenCounterIncorrectPresenter: UIViewController {
//        
//    class Datasource: Hashable, Equatable {
//        static func == (lhs: TokenCounterIncorrectPresenter.Datasource, rhs: TokenCounterIncorrectPresenter.Datasource) -> Bool {
//            return lhs.key == rhs.key
//        }
//        
//        var title: String
//        var value: String?
//        var key: String
//        
//        init(title: String, value: String?, key: String) {
//            self.title = title
//            self.value = value
//            self.key = key
//        }
//        
//        func hash(into hasher: inout Hasher) {
//            hasher.combine(key)
//        }
//    }
//    
//    open var jid: String = ""
//    open var uid: String = ""
//    open var canEdit: Bool = false
//    
//    open var delegate: XabberUpdateIfNeededDelegate? = nil
//    
//    private var pageHeight: CGFloat = 416
//    
//    private var datasource: [[Datasource]] = []
//    
//    private var currentDeviceDescription: String? = nil
//    
//    private let topDimmedView: UIView = {
//        let view = UIView()
//        
//        view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
//        
//        return view
//    }()
//    
//    private let contentView: UIView = {
//        let view = UIView()
//        
//        view.backgroundColor = .groupTableViewBackground
////        if #available(iOS 13.0, *) {
////        } else {
////            view.backgroundColor = .white
////        }
//        
//        view.layer.cornerRadius = 32
//        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
//        
//        return view
//    }()
//    
//    private let dragToDismissButton: UIButton = {
//        let button = UIButton()
//        
//        button.backgroundColor = UIColor.black.withAlphaComponent(0.23)
//        button.layer.cornerRadius = 3
//        
//        return button
//    }()
//    
//    private let stack: UIStackView = {
//        let stack = UIStackView()
//        
//        stack.axis = .vertical
//        stack.alignment = .center
//        stack.spacing = 8
//        
//        stack.isUserInteractionEnabled = true
//        
//        return stack
//    }()
//    
//    private let titleLabel: UILabel = {
//        let label = UILabel()
//        
//        label.textAlignment = .center
//        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
//        label.numberOfLines = 0
//        
//        if #available(iOS 13.0, *) {
//            label.textColor = .label
//        } else {
//            label.textColor = .darkText
//        }
//        
//        
//        return label
//    }()
//    
//    private let subtitleLabel: UILabel = {
//        let label = UILabel()
//        
//        label.textAlignment = .center
//        label.font = UIFont.systemFont(ofSize: 17, weight: .light)
//        label.numberOfLines = 0
//        if #available(iOS 13.0, *) {
//            label.textColor = .secondaryLabel
//        } else {
//            label.textColor = .gray
//        }
//        return label
//    }()
//    
//    private let editAvatarButton: UIButton = {
//        let button = UIButton(
//            frame: CGRect(
//                origin: CGPoint(x: 120, y: 120),
//                size: CGSize(square: 44)
//            )
//        )
//        
//        button.setImage(imageLiteral( "pencil").withRenderingMode(.alwaysTemplate), for: .normal)
//        button.layer.cornerRadius = button.frame.width / 2
//        button.backgroundColor = MDCPalette.grey.tint100
//        button.tintColor = MDCPalette.grey.tint500
//        
//        return button
//    }()
//    
//    private let tableView: UITableView = {
//        let view = InsetGroupedTableView(frame: .zero)
//        
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleCell")
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "DangerCell")
//        
////        view.isScrollEnabled = false
//        
//        return view
//    }()
//    
//    private final func doAnimationsBlock(animated: Bool, block: @escaping (() -> Void)) {
//        if animated {
//            UIView.animate(
//                withDuration: 0.33,
//                delay: 0.0,
//                options: [.curveEaseIn],
//                animations: block,
//                completion: nil
//            )
//        } else {
//            UIView.performWithoutAnimation(block)
//        }
//    }
//    
//    public func activateConstraints() {
//        NSLayoutConstraint.activate([
//            tableView.widthAnchor.constraint(equalTo: stack.widthAnchor),
//            tableView.heightAnchor.constraint(equalToConstant: pageHeight - 82)
//        ])
//    }
//    
//    public func setupSubviews() {
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
//        
//        view.addSubview(contentView)
//        contentView.addSubview(dragToDismissButton)
//        contentView.addSubview(stack)
//        stack.fillSuperviewWithOffset(top: 32, bottom: 24, left: 16, right: 16)
//        stack.addArrangedSubview(titleLabel)
//        stack.addArrangedSubview(tableView)
//    }
//    
//    public func configure() {
//        topDimmedView.frame = CGRect(
//            x: 0,
//            y: -view.frame.height,
//            width: view.frame.width,
//            height: view.frame.height
//        )
//        view.addSubview(topDimmedView)
//        view.backgroundColor = UIColor.black.withAlphaComponent(0.23)
//        let dismissGestureRecognizer = PanDirectionGestureRecognizer(direction: .vertical, target: self, action: #selector(self.onDismissGestureRecognizerDidChange))
//        dismissGestureRecognizer.delaysTouchesBegan = true
//        dismissGestureRecognizer.maximumNumberOfTouches = 1
//        
//        contentView.addGestureRecognizer(dismissGestureRecognizer)
//        let dismissGesture = UITapGestureRecognizer(target: self, action: #selector(dismissOnTap))
//        dismissGesture.delaysTouchesBegan = true
//        
////        self.view.addGestureRecognizer(dismissGesture)
//        tableView.delegate = self
//        tableView.dataSource = self
//        tableView.allowsSelection = true
//        tableView.isUserInteractionEnabled = true
//    }
//    
//    private final func loadDatasource() {
//        do {
//            let realm = try WRealm.safe()
//            guard let tokenInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, jid].prp()) else {
//                return
//            }
//            titleLabel.text = tokenInstance.descr.isNotEmpty ? tokenInstance.descr : tokenInstance.client
//            currentDeviceDescription = tokenInstance.descr.isNotEmpty ? tokenInstance.descr : nil
//            let dateFormatter = DateFormatter()
//            let today = Date()
//            let date = tokenInstance.authDate
//            if NSCalendar.current.isDateInToday(date) {
//                dateFormatter.dateFormat = "HH:mm"
//            } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
//                dateFormatter.dateFormat = "HH:mm"
//            } else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
//                dateFormatter.dateFormat = "E"
//            } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
//                dateFormatter.dateFormat = "MMM dd"
//            } else {
//                dateFormatter.dateFormat = "d MMM yyyy"
//            }
//            let expireDateFormatter = DateFormatter()
//            expireDateFormatter.dateFormat = "EEEE, MMM d, yyyy"
//            if canEdit {
//                datasource = [
//                    [
//                        Datasource(title: "Status".localizeString(id: "groupchat_status", arguments: []),
//                                   value: "Last seen at \(dateFormatter.string(from: date))".localizeString(id: "last_seen_today", arguments: ["\(dateFormatter.string(from: date))"]),
//                                   key: "status"),
//                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
//                                   value: tokenInstance.device, key: "device"),
//                        Datasource(title: "Client".localizeString(id: "contact_viewer_client", arguments: []),
//                                   value: tokenInstance.client, key: "client"),
//                        Datasource(title: "IP", value: tokenInstance.ip, key: "ip"),
//                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
//                                   value: expireDateFormatter.string(from: tokenInstance.expire), key: "expire")
//                    ],
//                    [
//                        Datasource(title: "Rename".localizeString(id: "device__info__rename__button", arguments: []),
//                                   value: nil, key: "rename")
//                    ],
//                    [
//                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
//                                   value: nil, key: "terminate")
//                    ],
//                ]
//            } else {
//                datasource = [
//                    [
//                        Datasource(title: "Status".localizeString(id: "groupchat_status", arguments: []),
//                                   value: "Last seen at \(dateFormatter.string(from: date))".localizeString(id: "last_seen_today", arguments: ["\(dateFormatter.string(from: date))"]),
//                                   key: "status"),
//                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
//                                   value: tokenInstance.device, key: "device"),
//                        Datasource(title: "Client".localizeString(id: "contact_viewer_client", arguments: []),
//                                   value: tokenInstance.client, key: "client"),
//                        Datasource(title: "IP", value: tokenInstance.ip, key: "ip"),
//                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
//                                   value: expireDateFormatter.string(from: tokenInstance.expire), key: "expire")
//                    ],
//                    [
//                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
//                                   value: nil, key: "terminate")
//                    ],
//                ]
//            }
//        } catch {
//            DDLogDebug("TokenInfoViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    public func addObservers() {
//        
//    }
//    
//    public func removeObservers() {
//        
//    }
//    
//    public func localizeResources() {
//        
//    }
//    
//    public func onAppear() {
//        willShow()
//    }
//    
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        if canEdit {
//            pageHeight = 496
//        } else {
//            pageHeight = 416
//        }
//        setupSubviews()
//        configure()
//        localizeResources()
//        loadDatasource()
//    }
//    
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//        activateConstraints()
//        addObservers()
//        onAppear()
//    }
//    
//    override func viewDidAppear(_ animated: Bool) {
//        super.viewDidAppear(animated)
//    }
//    
//    override func viewWillDisappear(_ animated: Bool) {
//        super.viewWillDisappear(animated)
//    }
//    
//    override func viewDidDisappear(_ animated: Bool) {
//        super.viewDidDisappear(animated)
//        removeObservers()
//    }
//    
//    override func didReceiveMemoryWarning() {
//        super.didReceiveMemoryWarning()
//    }
//    
//    private final func willShow() {
//        topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
//        view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
//        UIView.animate(withDuration: 0.5) {
//            self.topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.23)
//            self.view.backgroundColor = UIColor.black.withAlphaComponent(0.23)
//        }
//    }
//    
//    private final func dismiss() {
//        UIView.animate(withDuration: 0.1) {
//            self.topDimmedView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
//            self.view.backgroundColor = UIColor.black.withAlphaComponent(0.0)
//        }
//        self.delegate?.updateIfNeeded()
//        FeedbackManager.shared.tap()
//        self.dismiss(animated: true, completion: nil)
//    }
//    
//    @objc
//    private final func onDismissGestureRecognizerDidChange(_ sender: UIPanGestureRecognizer) {
//        let y = sender.translation(in: self.contentView).y
//        if sender.state == .ended {
//            if y > 200 {
//                dismiss()
//            }
//            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
//                let rect = self.contentView.frame
//                self.contentView.frame = CGRect(
//                    x: 0,
//                    y: self.view.frame.height - self.pageHeight,
//                    width: rect.width,
//                    height: rect.height
//                )
//            } completion: { result in
//                
//            }
//
//        }
//        if sender.state != .changed { return }
//        let rect = self.contentView.frame
//        if y > 0 {
//            self.contentView.frame = CGRect(
//                x: 0,
//                y: self.view.frame.height - pageHeight + y,
//                width: rect.width,
//                height: rect.height
//            )
//        }
//    }
//    
//    @objc
//    private final func dismissOnTap(_ sender: AnyObject) {
////        FeedbackManager.shared.tap()
////        self.dismiss(animated: true, completion: nil)
//    }
//}
//
//extension TokenCounterIncorrectPresenter: UITableViewDelegate {
//    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
//        return 44
//    }
//    
//    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        let item = datasource[indexPath.section][indexPath.row]
//        switch item.key {
//        case "rename":
//            onRename()
//        case "terminate":
//            onTerminate()
//        default:
//            break
//        }
//    }
//    
//}
//
//extension TokenCounterIncorrectPresenter: UITableViewDataSource {
//    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
//        return datasource[section].count
//    }
//    
//    func numberOfSections(in tableView: UITableView) -> Int {
//        return datasource.count
//    }
//    
//    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
//        let item = datasource[indexPath.section][indexPath.row]
//        switch item.key {
//        case "terminate":
//            let cell = tableView.dequeueReusableCell(withIdentifier: "DangerCell", for: indexPath)
//            cell.textLabel?.text = item.title
//            cell.textLabel?.textColor = .systemRed
//            return cell
//        case "rename":
//            let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
//            cell.textLabel?.text = item.title
//            cell.textLabel?.textColor = .systemBlue
//            return cell
//        default:
//            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
//            cell.textLabel?.text = item.title
//            cell.detailTextLabel?.text = item.value
//            return cell
//        }
//    }
//}
//
//extension TokenCounterIncorrectPresenter {
//    private final func onRename() {
//        TextViewPresenter().present(
//            in: self,
//            title: "Rename device".localizeString(id: "device_info_rename_device", arguments: []),
//            message: nil,
//            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
//            set: "Rename".localizeString(id: "device__info__rename__button", arguments: []),
//            currentValue: self.currentDeviceDescription,
//            animated: true) { value in
//            if value != self.currentDeviceDescription {
//                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
//                    session.xtokens?.update(stream, descr: value)
//                } fail: {
//                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
//                        user.xTokens.update(stream, descr: value)
//                    })
//                }
//            }
//            DispatchQueue.main.async {
//                self.dismiss()
//            }
//        }
//    }
//    
//    private final func onTerminate() {
//        let items = [
//            ActionSheetPresenter.Item(destructive: true, title: "Terminate session?".localizeString(id: "terminate_session_question", arguments: []), value: "terminate")
//        ]
//        
//        ActionSheetPresenter().present(
//            in: self,
//            title: nil,
//            message: nil,
//            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
//            values: items,
//            animated: true) { value in
//            switch value {
//            case "terminate":
//                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
//                    session.xtokens?.revoke(stream, uids: [self.uid])
//                } fail: {
//                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
//                        user.xTokens.revoke(stream, uids: [self.uid])
//                    })
//                }
//            default:
//                break
//            }
//            DispatchQueue.main.async {
//                self.dismiss()
//            }
//        }
//    }
//}
