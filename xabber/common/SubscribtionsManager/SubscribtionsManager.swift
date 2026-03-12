//
//  SubscribtionsManager.swift
//  clandestino
//
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
import RxSwift
import RxCocoa
import StoreKit
import CocoaLumberjack
import Alamofire
import RealmSwift

public struct SubscribtionsSecretStore: Codable {
    var uuid_ns: String
    var api_url: String
    var product_list: Array<String>
    
    static var bundle: SubscribtionsSecretStore? {
        get {
            guard let path = Bundle.main.path(forResource: "subscribtions_secret", ofType: "plist"),
                  let xml = FileManager.default.contents(atPath: path),
                  let instance = try? PropertyListDecoder().decode(SubscribtionsSecretStore.self, from: xml) else {
                  return nil
            }
            return instance
        }
    }
}

class SubscribtionsManager: NSObject {
    
    struct AppSubscribtions: Hashable {
        static func == (lhs: AppSubscribtions, rhs: AppSubscribtions) -> Bool {
            return lhs.product_id == rhs.product_id && lhs.uuid == rhs.uuid
        }
        
        let product_id: String
        let expires: Date
        let uuid: UUID
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(product_id)
            hasher.combine(uuid.uuidString)
        }
    }
    
    struct AccountSubscriptions: Hashable {
        static func == (lhs: AccountSubscriptions, rhs: AccountSubscriptions) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        let jid: String
        let date: Date
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
    }
    
    open class var shared: SubscribtionsManager {
        struct SubscribtionsManagerSingleton {
            static let instance = SubscribtionsManager()
        }
        return SubscribtionsManagerSingleton.instance
    }
    
    enum AccountState {
        case active
        case expired
        case trial
    }
    
    open var subscribtionsList: Set<AppSubscribtions> = Set()
    
    open var accounts: Set<AccountSubscriptions> = Set()
    
    var products: [Product] = []

    
    override init() {
        super.init()
        Task.detached {
            for await result in Transaction.updates {
                switch result {
                    case .verified(let transaction):
                        await transaction.finish()
                    default:
                        break
                }
            }
        }
    }
    
    func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(SubsriptionInfoRealmStorage.self)
                .filter("jid == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func prepare() {
        self.loadProductList()
        self.restoreSubscriptions()
    }

    /// Sync active App Store entitlements into Realm so the app knows about
    /// subscriptions purchased outside the current session (e.g. on another device,
    /// or when no Xabber Account was used).
    func restoreSubscriptions() {
        Task {
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    guard let expiration = transaction.expirationDate,
                          expiration.timeIntervalSince1970 > Date().timeIntervalSince1970 else {
                        continue
                    }
                    self.saveSubscriptionInfo(
                        productId: transaction.productID,
                        jid: "",
                        accountUUID: transaction.appAccountToken?.uuidString ?? "",
                        expires: expiration,
                        purchaseDate: transaction.purchaseDate,
                        transactionId: "\(transaction.id)"
                    )
                default:
                    break
                }
            }
        }
    }
    
    
    
    func getState(account jid: String) -> AccountState {
        return .trial
    }

    fileprivate func loadProductList() {
        guard let products_ids = SubscribtionsSecretStore.bundle?.product_list else {
            return
        }
        Task {
            self.products = try await Product.products(for: products_ids)
        }
    }
    
    public final func updateXMPPAccountsState() {
        if CommonConfigManager.shared.config.should_block_application_when_subscribtion_end {
            AccountManager.shared.users.forEach {
                user in
                self.checkXMPPAccountState(jid: user.jid)
            }
        }
    }
    
    public func checkXMPPAccountState(jid: String, retry: Int? = nil, callback: ((Bool) -> Void)? = nil) {
        guard let api_url = SubscribtionsSecretStore.bundle?.api_url else {
            callback?(false)
            return
        }
        self.loadProductList()
        let url = [api_url, "/v1/accounts/\(jid.uuid().uuidString.lowercased())/"].joined()
        AF
            .request(
                url,
                method: .get,
                parameters: [:],
                encoding: URLEncoding.default,
                headers: HTTPHeaders(["Cache-Control": "no-cache"])
            ).responseJSON {
                response in
//                print(response)
                if (response.response?.statusCode ?? 500) >= 301 {
                    callback?(false)
                    return
                }
                switch response.result {
                    case .success(let value):
                        guard let dict = value as? NSDictionary else {
                            callback?(false)
                            return
                        }
                        let status = dict["status"] as? String ?? "EXPIRED"
//                        print(dict)
                        self.accounts = self.accounts.filter({ $0.jid != jid })
                        if let expiresRaw = dict["expires"] as? String,
                           let expires = Date.parseXMPPFormattedString(expiresRaw) {
                            self.accounts.insert(AccountSubscriptions(jid: jid, date: expires))
                        }
                        if let subsListRaw = dict["subscriptions"] as? Array<NSDictionary> {
                            self.subscribtionsList = self.subscribtionsList.filter({ $0.uuid != jid.uuid()})
                            subsListRaw.compactMap({
                                dict in
                                guard let expiresRaw = dict["expires"] as? String,
                                      let expires = Date.parseXMPPFormattedString(expiresRaw),
                                      Date().timeIntervalSince1970 < expires.timeIntervalSince1970,
                                      let productId = dict["product_id"] as? String else {
                                    return nil
                                }
                                return AppSubscribtions(product_id: productId, expires: expires, uuid: jid.uuid())
                            }).forEach ({
                                item in
                                self.subscribtionsList.insert(item)
                            })
                        }
                        callback?(status == "ACTIVE")
                        
                case .failure(let error):
                    DDLogDebug(error.localizedDescription)
                    callback?(false)
                }
            }
    }
    
    // MARK: - Purchase

    public final func purchase(
        subscribtion id: String,
        accountUUID: String? = nil,
        callback: ((Bool, Transaction?) -> Void)?
    ) {
        guard let product = self.products.first(where: { $0.id == id }) else {
            callback?(false, nil)
            return
        }

        var options: Set<Product.PurchaseOption> = []
        if let accountUUID = accountUUID, let uuid = UUID(uuidString: accountUUID) {
            options.insert(.appAccountToken(uuid))
        }

        Task {
            do {
                let result = try await product.purchase(options: options)
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        await transaction.finish()
                        if (transaction.expirationDate?.timeIntervalSince1970 ?? 0) > Date().timeIntervalSince1970 {
                            callback?(true, transaction)
                        } else {
                            callback?(false, transaction)
                        }
                    default:
                        callback?(false, nil)
                    }
                case .userCancelled:
                    callback?(false, nil)
                case .pending:
                    callback?(false, nil)
                @unknown default:
                    callback?(false, nil)
                }
            } catch {
                callback?(false, nil)
                DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Realm Persistence

    func hasActiveSubsription() -> Bool {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = realm.objects(SubsriptionInfoRealmStorage.self).filter("expires > %@", Date())
            return !instances.isEmpty
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }

    func getExpiresDate() -> Date? {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = realm.objects(SubsriptionInfoRealmStorage.self)
                .filter("expires > %@", Date())
                .sorted(byKeyPath: "expires", ascending: false)
            return instances.first?.expires
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    func getPurchasedProductIds() -> Set<String> {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = realm.objects(SubsriptionInfoRealmStorage.self)
                .filter("expires > %@", Date())
            return Set(instances.map { $0.productId })
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return Set()
    }
    
    func saveSubscriptionInfo(
        productId: String,
        jid: String,
        accountUUID: String,
        expires: Date,
        purchaseDate: Date,
        transactionId: String
    ) {
        do {
            let realm = try WRealm.safe()
            let item = SubsriptionInfoRealmStorage()
            item.transactionId = transactionId
            item.productId = productId
            item.jid = jid
            item.accountUUID = accountUUID
            item.expires = expires
            item.purchaseDate = purchaseDate
            try realm.write {
                realm.add(item, update: .modified)
            }
        } catch {
            DDLogDebug("SubscribtionsManager: Failed to save subscription info: \(error.localizedDescription)")
        }
    }

}


