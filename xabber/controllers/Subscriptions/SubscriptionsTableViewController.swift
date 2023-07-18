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

import UIKit
import StoreKit
import XMPPFramework.XMPPJID

class SubscriptionsTableViewController: UITableViewController {

    let conflictView: UIView = {
        let verticalStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.distribution = .fillProportionally
            stack.alignment = .center
            stack.spacing = 10
            return stack
        }()
        
        let image = UIImage(systemName: "exclamationmark.triangle")
        let imageView = UIImageView(image: image)
        var config = UIImage.SymbolConfiguration(paletteColors: [.systemOrange])
        config = config.applying(UIImage.SymbolConfiguration(font: .systemFont(ofSize: 64.0)))
        imageView.preferredSymbolConfiguration = config
        
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .systemOrange
        label.textAlignment = .center
        label.text = "Premium subscription made with current\nApple ID is linked to a different\nClandestino Account"
        
        let subLabel = UILabel()
        subLabel.numberOfLines = 0
        subLabel.textAlignment = .left
        let attributedString1 = NSMutableAttributedString(string: "To buy subscription for this Clandestino Account, go to ",
                                                          attributes: [NSAttributedString.Key.foregroundColor : UIColor.systemGray, .font: UIFont.systemFont(ofSize: 13, weight: .regular)])
        let attributedString2 = NSMutableAttributedString(string: "Settings → Apple ID → Subscriptions → Clandestino ",
                                                          attributes: [NSAttributedString.Key.foregroundColor : UIColor.black, .font: UIFont.systemFont(ofSize: 13, weight: .semibold)])
        let attributedString3 = NSMutableAttributedString(string: "and cancel existing subscription. Then you will be able to buy subscription for this Clandestino Account",
                                                          attributes: [NSAttributedString.Key.foregroundColor : UIColor.systemGray, .font: UIFont.systemFont(ofSize: 13, weight: .regular)])
        attributedString1.append(attributedString2)
        attributedString1.append(attributedString3)
        subLabel.attributedText = attributedString1
        
        verticalStack.addArrangedSubview(UILabel())
        verticalStack.addArrangedSubview(imageView)
        verticalStack.addArrangedSubview(label)
        verticalStack.addArrangedSubview(subLabel)
        
        return verticalStack
    }()
    
    var products: [Product] = []
    var purchasedProducts: [Store.PurchasedProduct] = []
    open var jid: String = ""
    var store: Store?
    
    var isModal: Bool = false
    
    var loading: Bool = false
    
    internal var cancelButton: UIBarButtonItem?
    
    convenience init() {
        self.init(style: .insetGrouped)
        store = Store.shared
        store?.delegate = self
    }
    
    override init(style: UITableView.Style) {
        super.init(style: style)
        store = Store.shared
        store?.delegate = self
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        store = Store.shared
        store?.delegate = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        title = "Subscriptions"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(SubscriptionsTableViewController.reload), for: .valueChanged)
        self.tabBarController?.tabBar.isHidden = true
        self.cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismisScreen))
        ApplicationStateManager.shared.checkApplicationBlockedState(for: self.jid)
        guard let store = store else {
            return
        }
        products = store.subscriptions
        purchasedProducts = store.purchasedSubscriptions
    }

    @objc
    private final func dismisScreen(_ sender: AnyObject) {
        self.dismiss(animated: true)
    }
    
    @objc
    func reload() {
        guard let store = store else {
            return
        }
        
        store.updateProductList()
        
        if Set(products).symmetricDifference(Set(store.subscriptions)).isEmpty,
           Set(purchasedProducts).symmetricDifference(Set(store.purchasedSubscriptions)).isEmpty,
           self.refreshControl?.isRefreshing == nil {
            return
        }
        products = store.subscriptions
        purchasedProducts = store.purchasedSubscriptions
            
        ApplicationStateManager.shared.checkApplicationBlockedState(for: self.jid) {
            DispatchQueue.main.async {
                self.tableView.reloadData()
                self.refreshControl?.endRefreshing()
                if ApplicationStateManager.shared.isApplicationBlocked() {
                    if self.isModal {
                        self.navigationItem.setLeftBarButton(nil, animated: true)
                    }
                } else {
                    if self.isModal {
                        self.navigationItem.setLeftBarButton(self.cancelButton, animated: true)
                    }
                }
            }
        }
    }
    
    private func checkConflict() -> Bool {
        
        if self.purchasedProducts.isNotEmpty,
           self.purchasedProducts.first(where: { $0.token != self.jid.uuidString() }) != nil {
            return true
        }
        return false
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "Your subscription"
        case 1:
            guard !checkConflict(), products.isNotEmpty else { return nil }
            return "Subscription Options"
        default:
            return nil
        }
    }
    
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        
        guard checkConflict(), section == 0 else {
            return nil
        }
        
        return conflictView
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 1
        case 1:
            return checkConflict() ? 0 : products.count
        case 2:
            return SubscribtionsManager.shared.trialEnd == nil ? 1 : 0
        default:
            return 0
        }
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 2 {
            return 44
        }
        return 64
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        guard indexPath.section == 2 else {
            return
        }
        if let expires = SubscribtionsManager.shared.accountExpirationDate ?? ApplicationStateManager.shared.getApplicationBlockedDate(),
           expires.timeIntervalSinceReferenceDate > Date().timeIntervalSinceReferenceDate {
            let vc = DeliveryAddressViewController()
            vc.jid = self.jid
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            let presenter = QuitAccountPresenter(jid: jid)
            presenter.present(in: self, animated: true) {
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
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        switch indexPath.section {
        
        case 0:
            let cell = SubscribtionTopInfoTableViewCell(style: .subtitle, reuseIdentifier: "Cell")
            cell.accessoryType = .none
            if let expires = SubscribtionsManager.shared.accountExpirationDate ?? ApplicationStateManager.shared.getApplicationBlockedDate() {
                if expires.timeIntervalSinceReferenceDate > Date().timeIntervalSinceReferenceDate {
                    cell.bottomLabel.text = "Expires " + expires.formatted()
                    cell.statusLabel.text = "Active"
                    cell.statusLabel.textColor = .systemGreen
                } else {
                    cell.bottomLabel.text = "Expired " + expires.formatted()
                    cell.statusLabel.text = "Expired"
                    cell.statusLabel.textColor = .systemRed
                }
                if loading {
                    cell.activityIndicator.isHidden = false
                    cell.statusLabel.isHidden = true
                } else {
                    cell.activityIndicator.isHidden = true
                    cell.statusLabel.isHidden = false
                }
            }
            let username = XMPPJID(string: self.jid)?.user ?? self.jid
            if SubscribtionsManager.shared.trialEnd != nil {
                let mutableString = NSMutableAttributedString(string: "\(username) • trial account")

                mutableString.addAttribute(NSAttributedString.Key.font,
                                           value: UIFont.preferredFont(forTextStyle: .body).bold(),
                                           range: NSRange(location: 0, length: username.count))
                cell.topLabel.attributedText = mutableString
            } else {
                let mutableString = NSMutableAttributedString(string: "\(username) • premium account")

                mutableString.addAttribute(NSAttributedString.Key.font,
                                           value: UIFont.preferredFont(forTextStyle: .body).bold(),
                                           range: NSRange(location: 0, length: username.count))
                cell.topLabel.attributedText = mutableString
            }
            
            return cell
        
        case 1:
            let cell = ProductCell(style: .subtitle, reuseIdentifier: "ProductCell")
            let product = products[indexPath.row]
            let isPurchased = self.purchasedProducts.contains(where: { $0.product == product })
            cell.configure(for: product, isPurchased: isPurchased)
            cell.product = product
            cell.buyButtonHandler = { product in
                Task {
                    if try await self.store?.purchase(product, jid: self.jid) != nil {
                        self.loading = true
                        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                        self.periodicCheckSubscribtion()
                    } else {
                        cell.cancelLoading()
                        self.loading = false
                        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                    }
                }
            }
            return cell
        
        case 2:
            if !checkConflict(), let expires = SubscribtionsManager.shared.accountExpirationDate ?? ApplicationStateManager.shared.getApplicationBlockedDate(),
               expires.timeIntervalSinceReferenceDate > Date().timeIntervalSinceReferenceDate {
                let cell = UITableViewCell()
                cell.textLabel?.text = "Request Yubikey delivery"
                cell.textLabel?.textColor = .systemBlue
                cell.accessoryType = .none
                cell.textLabel?.textAlignment = .center
                return cell
            } else {
                let cell = UITableViewCell()
                cell.textLabel?.text = "Quit account"
                cell.textLabel?.textColor = .systemRed
                cell.accessoryType = .none
                cell.textLabel?.textAlignment = .center
                return cell
            }
            
        default:
            return UITableViewCell()
        }
    }
    
    final func periodicCheckSubscribtion() {
        ApplicationStateManager.shared.checkApplicationBlockedState(for: jid) {
            if !self.checkSubscribtionResult() {
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) {
                    self.periodicCheckSubscribtion()
                }
            }
        }
    }
    
    final func checkSubscribtionResult() -> Bool {
        if let expires = SubscribtionsManager.shared.accountExpirationDate ?? ApplicationStateManager.shared.getApplicationBlockedDate(),
            expires.timeIntervalSinceReferenceDate > Date().timeIntervalSinceReferenceDate {
                DispatchQueue.main.async {
                    self.loading = false
                    self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                }
                YesNoPresenter().present(
                    in: self,
                    style: .alert,
                    title: nil,
                    message: "Subscrption activated",
                    yesText: "Ok",
                    dangerYes: false,
                    showCancelAction: false,
                    noText: "",
                    animated: true) { _ in
                        DispatchQueue.main.async {
                            
                            ApplicationStateManager.shared.unblockApplication(date: Date())
                            AccountManager.shared.find(for: self.jid)?.asyncConnect()
                            XMPPUIActionManager.shared.shouldRecreate = true
                            self.dismiss(animated: true)
                            let viewController: UIViewController = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "tabBarControllerRID") as UIViewController
                            if (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController?.restorationIdentifier != viewController.restorationIdentifier {
                                (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = viewController
                            }
                            ApplicationStateManager.shared.isSubscribtionsShowed = false
                        }
                    }
            return true
        }
        return false
    }
    
}
