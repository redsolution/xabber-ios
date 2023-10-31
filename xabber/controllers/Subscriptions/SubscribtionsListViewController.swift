//
//  SubscribtionsListViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 04.10.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack
import TOInsetGroupedTableView

class SubscribtionsListViewController: SimpleBaseViewController {
    
    enum State {
        case active
        case expired
        case trial
        case update
    }
    
    enum ControllerCloseReason {
        case navigationStack
        case modal
        case startup
        case signin
    }
    
    struct Datasource {
        var productId: String
        var onRefreshing: Bool
        var title: String
        var price: String
        var renewDate: Date?
    }
    
    var datasoucre: [Datasource] = []
    var currentSubscribtions: [SubscribtionsManager.AppSubscribtions] = []
    var accountState: State = .update
    var expires: Date = Date()
    
    public var controllerCloseReason: ControllerCloseReason = .navigationStack
    
    public var canShowCloseButton: Bool = false
    
    var currentlyPurchaisedSubscribtion: String? = nil
    
    var closeButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Close", style: .done, target: nil, action: nil)
        
        return button
    }()
    
    let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(AccountStateCell.self, forCellReuseIdentifier: AccountStateCell.cellName)
        view.register(SubscribtionItemCell.self, forCellReuseIdentifier: SubscribtionItemCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        title = "Subscriptions"
        
        self.closeButton.target = self
        self.closeButton.action = #selector(onCloseButtonTouchUpInside)
    }
    
    @objc
    private func reload(_ sender: AnyObject) {
        SubscribtionsManager.shared.checkXMPPAccountState(jid: self.owner) {
            _ in
            SubscribtionsManager.shared.checkSubscriptionStateForAccount(jid: self.owner) {
                _ in
                self.loadDatasource()
                DispatchQueue.main.async {
                    self.tableView.refreshControl?.endRefreshing()
                    self.tableView.reloadData()
                }
            }
        }
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.reload(self)
//        if SubscribtionsManager.shared.products.isEmpty {
//            Subscr
//        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        self.currentSubscribtions = Array(SubscribtionsManager.shared.subscribtionsList.filter({ $0.uuid == self.owner.uuid() }))
        self.expires = SubscribtionsManager.shared.accounts.first(where: { $0.jid == self.owner })?.date ?? Date()
        switch SubscribtionsManager.shared.getState(account: self.owner) {
            case .active: self.accountState = .active
            case .trial: self.accountState = .trial
            case .expired: self.accountState = .expired
        }
        switch self.accountState {
            case .active, .trial:
                self.canShowCloseButton = true
                self.updateCloseButton()
            default:
                break
        }
        self.datasoucre = SubscribtionsManager.shared.products.sorted(by: { $0.price < $1.price }).compactMap {
            product in
            return Datasource(
                productId: product.id,
                onRefreshing: false,
                title: product.displayName,
                price: product.displayPrice,
                renewDate: nil
            )
        }
    }
    
    func updateCloseButton() {
        if canShowCloseButton {
            switch self.controllerCloseReason {
                case .navigationStack:
                    self.navigationItem.setHidesBackButton(false, animated: true)
                case .modal, .startup, .signin:
                    self.navigationItem.setLeftBarButton(self.closeButton, animated: true)
            }
        } else {
            self.navigationItem.setHidesBackButton(true, animated: true)
            self.navigationItem.setLeftBarButton(nil, animated: true)
        }
    }
    
    @objc
    private func onCloseButtonTouchUpInside(_ sender: UIBarButtonItem) {
        DispatchQueue.main.async {
            switch self.controllerCloseReason {
                case .modal:
                    self.dismiss(animated: true)
                    
                case .signin, .startup:
                    let viewController: UIViewController = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "tabBarControllerRID") as UIViewController
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = viewController
                default:
                    self.dismiss(animated: true)
                    self.navigationController?.popViewController(animated: true)
            }
        }
    }
}

extension SubscribtionsListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
            case 0:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: AccountStateCell.cellName, for: indexPath) as? AccountStateCell else {
                    fatalError()
                }
                
                var expiresText: String = "Expires"
                if self.accountState == .expired {
                    expiresText = "Expired"
                }
                cell.configure(account: AccountManager.shared.find(for: self.owner)!.username, subtitle: "\(expiresText) at \(self.expires.formatted())", state: self.accountState)
                
                return cell
            case 1:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SubscribtionItemCell.cellName, for: indexPath) as? SubscribtionItemCell else {
                    fatalError()
                }
                
                let item = self.datasoucre[indexPath.row]
                let showIndicator = item.productId == self.currentlyPurchaisedSubscribtion
                cell.configure(title: item.title, subtitle: item.price, isPurchaised: self.currentSubscribtions.contains(where: { $0.product_id == item.productId }), showIndicator: showIndicator)
                return cell
            case 2:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                    fatalError()
                }
                
                switch accountState {
                    case .expired:
                        cell.configure(for: "Quit account", style: .danger)
                    default:
                        cell.configure(for: "Request Yubikey delivery", style: .normal)
                }
                
                return cell
            default:
                fatalError()
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
            case 0:
                return 1
            case 1:
                return datasoucre.count
            case 2:
                return 1
            default:
                return 0
        }
    }
    
}

extension SubscribtionsListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch indexPath.section {
            case 0:
                return tableView.estimatedRowHeight
            case 1:
                return 56
            case 2:
                return 44
            default:
                return 0
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
            case 1:
                if self.currentlyPurchaisedSubscribtion != nil {
                    return
                }
                let productId = self.datasoucre[indexPath.row].productId
                self.currentlyPurchaisedSubscribtion = productId
                tableView.reloadRows(at: [indexPath], with: .none)
                self.makePurchaise(productId: productId)
            case 2:
                switch accountState {
                    case .expired:
                        let presenter = QuitAccountPresenter(jid: jid)
                        presenter.present(in: self, animated: true) {
                            self.unsubscribe()
                            AccountManager.shared.deleteAccount(by: self.jid)
                            if AccountManager.shared.emptyAccountsList() {
                                DispatchQueue.main.async {
                                    let vc = OnboardingViewController()
                                    
                                    let navigationController = UINavigationController(rootViewController: vc)
                                    
                                    navigationController.isNavigationBarHidden = true
                                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                                }
                            } else {
                                DispatchQueue.main.async {
                                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                                    self.navigationController?.navigationBar.shadowImage = nil
                                    self.navigationController?.popToRootViewController(animated: true)
                                }
                            }
                        }
                    default:
                        let vc = DeliveryAddressViewController()
                        vc.jid = self.jid
                        self.navigationController?.pushViewController(vc, animated: true)
                }
                
            default:
                break
        }
    }
    
}

extension SubscribtionsListViewController {
    class AccountStateCell: BaseTableCell {
        
        static let cellName: String = "AccountStateCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 4
                        
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        let indicatorView: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            
//            view.frame =
            
            return view
        }()
        
        let stateIndicator: UILabel = {
            let label = UILabel(frame: CGRect(width: 64, height: 22))
            
            label.font = UIFont.systemFont(ofSize: 17, weight: .regular)
            label.textAlignment = .right
            
            return label
        }()
        
        
        
        func configure(account: String, subtitle: String, state: SubscribtionsListViewController.State) {
            
            let titleString = NSMutableAttributedString()
            let accountString = NSAttributedString(string: account, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.label.cgColor
            ])
            var accountTypeDescription: String = " · premium account"
            switch state {
                case .trial:
                    accountTypeDescription = " · trial account"
                default:
                    break
            }
            
            let accountTypeString = NSAttributedString(string: accountTypeDescription, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .regular),
                .foregroundColor: UIColor.label.cgColor
            ])
            
            titleString.append(accountString)
            titleString.append(accountTypeString)
            
            titleLabel.attributedText = titleString
            subtitleLabel.text = subtitle
            
            switch state {
                case .active:
                    stateIndicator.text = "Active"
                    stateIndicator.textColor = .systemGreen
                case .expired:
                    stateIndicator.text = "Expired"
                    stateIndicator.textColor = .systemRed
                case .trial:
                    stateIndicator.text = "Active"
                    stateIndicator.textColor = .systemGreen
                case .update:
                    stateIndicator.isHidden = true
                    indicatorView.isHidden = false
                    indicatorView.startAnimating()
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            stateIndicator.isHidden = false
            indicatorView.isHidden = true
        }
        
        override func setupSubviews() {
            super.setupSubviews()
            contentView.addSubview(stack)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            contentView.addSubview(stateIndicator)
            contentView.addSubview(indicatorView)
            stateIndicator.center = CGPoint(
                x: UIScreen.main.bounds.width - 80,
                y: self.contentView.center.y + 4
            )
            indicatorView.center = CGPoint(
                x: UIScreen.main.bounds.width - 80,
                y: self.contentView.center.y + 4
            )
        }
        
        override func activateConstraints() {
            super.activateConstraints()
            stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 16, right: 72)
        }
        
    }
    
    class SubscribtionItemCell: BaseTableCell {
        
        static let cellName: String = "SubscribtionItemCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 4
                        
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        let buyButton: UILabel = {
            let label = UILabel(frame: CGRect(width: 64, height: 44))
            
            label.text = "Buy"
            label.textColor = .systemBlue
            label.font = UIFont.systemFont(ofSize: 15, weight: .regular)
            
            return label
        }()
        
        let indicatorView: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            
            view.frame = CGRect(width: 64, height: 22)
            
            return view
        }()
        
        func configure(title: String, subtitle: String, isPurchaised: Bool, showIndicator: Bool) {
            self.titleLabel.text = title
            self.subtitleLabel.text = subtitle
            if isPurchaised {
                self.accessoryType = .checkmark
                self.buyButton.isHidden = true
                
            } else {
                self.accessoryType = .none
                self.buyButton.isHidden = false
            }
            if showIndicator {
                self.indicatorView.isHidden = false
                self.indicatorView.startAnimating()
                self.buyButton.isHidden = true
                self.accessoryType = .none
            } else {
                self.indicatorView.isHidden = true
            }
        }
        
        override func setupSubviews() {
            super.setupSubviews()
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 16, right: 72)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            contentView.addSubview(buyButton)
            contentView.addSubview(indicatorView)
            indicatorView.center = CGPoint(
                x: UIScreen.main.bounds.width - 64,
                y: 28
            )
            buyButton.center = CGPoint(
                x: UIScreen.main.bounds.width - 48,
                y: 28
            )
        }
        
        override func activateConstraints() {
            super.activateConstraints()
//            NSLayoutConstraint.activate([
//                self.buyButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
//                self.buyButton.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -44)
//            ])
        }
        
    }
}

// MARK: Flow
extension SubscribtionsListViewController {
    
    internal final func makePurchaise(productId: String) {
        guard let index = self.datasoucre.firstIndex(where: { $0.productId == productId }) else {
            self.currentlyPurchaisedSubscribtion = nil
            self.tableView.reloadData()
            return
        }
        let indexPath = IndexPath(row: index, section: 1)
        SubscribtionsManager.shared.purchase(
            jid: self.owner,
            subscribtion: productId) {
                result in
                self.currentlyPurchaisedSubscribtion = nil
                if result {
                    self.accountState = .update
                    
                    let cellsForUpdate = [
                        IndexPath(row: 0, section: 0),
                        indexPath
                    ]
                    DispatchQueue.main.async {
                        self.tableView.reloadRows(at: cellsForUpdate, with: .none)
                    }
                    SubscribtionsManager.shared.confirmPurchaise(jid: self.owner, productId: productId) {
                        result in
                        if result {
                            AccountManager.shared.reloadAccount(withJid: self.owner, autoConnect: true)
                            DispatchQueue.main.async {
                                self.loadDatasource()
                                self.canShowCloseButton = true
                                self.updateCloseButton()
                                self.tableView.reloadData()
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.loadDatasource()
                                self.canShowCloseButton = false
                                self.updateCloseButton()
                                self.tableView.reloadData()
                                ToastPresenter(message: "Error: confirmation").present(animated: true)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        let cellsForUpdate = [
                            IndexPath(row: 0, section: 0),
                            indexPath
                        ]
                        self.tableView.reloadRows(at: cellsForUpdate, with: .none)
                        self.loadDatasource()
                        self.canShowCloseButton = false
                        self.updateCloseButton()
                        self.tableView.reloadData()
                        ToastPresenter(message: "Error: fail purchaise").present(animated: true)
                    }
                }
                
            }
    }
    
}
