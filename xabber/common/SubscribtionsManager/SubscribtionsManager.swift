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
    
    private var lockedAccounts: Set<String> = Set()
    
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
    
    private var nearlyBuyedSubscribtionId: String? = nil
    
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
    
    func prepare() {
        self.loadProductList()
    }
    
    
    
    func getState(account jid: String) -> AccountState {
        self.checkSubscriptionStateForAccount(jid: jid)
        return .trial
//        if let item = self.accounts.first(where: { $0.jid == jid }),
//           item.date.timeIntervalSince1970 > Date().timeIntervalSince1970 {
//            if subscribtionsList.filter ({ $0.uuid == jid.uuid() }).isEmpty {
//                return .trial
//            } else {
//                return .active
//            }
//        }
//        return .expired
    }

    fileprivate func loadProductList() {
        guard let products_ids = SubscribtionsSecretStore.bundle?.product_list else {
            return
        }
        Task {
            self.products = try await Product.products(for: products_ids)
        }
    }
    
    var anotherAccountHasSubscribtion: Bool = false
    
    public func hasSubscribtionToAnotherAccount(jid: String) -> Bool {
//        self.products.first.
        return anotherAccountHasSubscribtion
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
    
    func checkSubscriptionStateForAccount(jid: String, callback: ((Bool) -> Void)? = nil) {
        Task {
            var accounts: Set<String> = Set()
            self.anotherAccountHasSubscribtion = false
            for await entitlement in Transaction.currentEntitlements {
                switch entitlement {
                    case .verified(let transaction):
                        if let expiration = transaction.expirationDate ?? transaction.revocationDate {
                            if Date().timeIntervalSince1970 < expiration.timeIntervalSince1970 {
                                if let token = transaction.appAccountToken?.uuidString {
                                    accounts.insert(token)
                                }
                            }
                        }
                    default:
                        break
                }
            }
            if accounts.contains(jid.uuid().uuidString) {
                if accounts.count > 1 {
                    self.anotherAccountHasSubscribtion = true
                }
                callback?(true)
            } else {
                if accounts.isNotEmpty {
                    self.anotherAccountHasSubscribtion = true
                }
                callback?(false)
            }
        }
    }
    
    private final func recursivelyCheckXMPPState(jid: String, retry: Int = 0, callback: ((Bool) -> Void)? = nil) {
        if retry > 30 {
            callback?(false)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.checkXMPPAccountState(jid: jid) {
                result in
                if result {
                    callback?(true)
                    return
                } else {
                    self.recursivelyCheckXMPPState(jid: jid, retry: retry + 1, callback: callback)
                }
            }
        }
    }
    
    public final func confirmPurchaise(jid: String, productId: String, callback: ((Bool) -> Void)? = nil) {
        self.updatePurchaisedStatus(jid: jid, productId: productId) {
            result in
            if result {
                self.recursivelyCheckXMPPState(jid: jid, callback: callback)
            } else {
                callback?(false)
            }
        }
    }
    
    func updatePurchaisedStatus(jid: String, productId: String, callback: ((Bool) -> Void)? = nil) {
        Task {
            var purchaisedProducts: Set<String> = Set()
            for await entitlement in Transaction.currentEntitlements {
                switch entitlement {
                    case .verified(let transaction):
//                        print(transaction.jsonRepresentation)
                        if let expiration = transaction.expirationDate {
                            if Date().timeIntervalSince1970 < expiration.timeIntervalSince1970 {
                                purchaisedProducts.insert(transaction.productID)
                            }
                        }
                    default:
                        break
                }
            }
            if purchaisedProducts.contains(productId) {
                callback?(true)
            } else {
                callback?(false)
            }
        }
    }
    
    public final func purchase(jid: String, subscribtion id: String, callback: ((Bool) -> Void)?) {
        guard let product = self.products.first(where: { $0.id == id }) else {
            callback?(false)
            return
        }
        Task {
            do {
                let result = try await product.purchase(options:[.appAccountToken(jid.uuid())])
                switch result {
                    case .success(let verification):
                        switch verification {
                            case .verified(let transaction):
//                                transaction.
                                await transaction.finish()
                                if (transaction.expirationDate?.timeIntervalSince1970 ?? 0) > Date().timeIntervalSince1970 {
                                    callback?(true)
                                } else {
                                    callback?(false)
                                }
                            default:
                                callback?(false)
                        }
                    default:
                        callback?(false)
                }
            } catch {
                callback?(false)
                DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
}


