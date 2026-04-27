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

struct APIProductPrice {
    let name: String
    let price: String
    let priceId: String
    let priceDescription: String?
    let period: String
}

enum SubscriptionCatalogSource: Equatable {
    case remote
    case fallback
    case empty
}

struct APIProduct {
    let id: Int
    let productId: String
    let displayName: String
    let group: String
    let weight: Int
    let description: String?
    let priceDescription: String?
    let isDefault: Bool
    let includes: [String]?
    let prices: [APIProductPrice]
}

struct SubscriptionCatalogFetchResult: Equatable {
    let product: APIProduct?
    let source: SubscriptionCatalogSource
    let warningMessage: String?
    let errorMessage: String?
}

struct AccountProductEntitlement {
    let accountProductId: Int
    let productId: String
    let storeKitProductId: String
    let expires: Date
}

struct SubscriptionPresentationState: Equatable {
    let activeProductId: String?
    let activeExpires: Date?
    let scheduledProductId: String?
    let scheduledEffectiveDate: Date?
    let hasActiveEntitlement: Bool
}

extension APIProductPrice: Equatable {}
extension APIProduct: Equatable {}

class SubscribtionsManager: NSObject {

    static let premiumProductId = "com_xabber_premium_account"

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
    
    enum AccountState: Equatable {
        case active
        case expired
        case trial
    }
    
    open var subscribtionsList: Set<AppSubscribtions> = Set()
    
    open var accounts: Set<AccountSubscriptions> = Set()
    
    var products: [Product] = []
    var apiProduct: APIProduct? = nil

    override init() {
        super.init()
        Task.detached { [weak self] in
            guard let self = self else { return }
            for await result in Transaction.updates {
                switch result {
                    case .verified(let transaction):
                        let persisted = await self.handleVerifiedTransaction(transaction, fallbackJid: nil)
                        if persisted {
                            await transaction.finish()
                        }
                    default:
                        break
                }
            }
        }
    }
    
    func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let accountUUID = Self.appAccountToken(for: owner).uuidString
            let collection = realm.objects(SubsriptionInfoRealmStorage.self)
                .filter("jid == %@ OR accountUUID == %@", owner, accountUUID)
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

    static func appAccountToken(for jid: String) -> UUID {
        return jid.uuid()
    }

    static func storeKitProductIdentifier(productId: String, priceId: String) -> String {
        guard productId.isNotEmpty else {
            return priceId
        }
        if priceId.contains(".") || priceId.hasPrefix(productId) {
            return priceId
        }
        return "\(productId).\(priceId)"
    }

    static func storeKitProductIdentifiers(for product: APIProduct, fallbackIds: [String]) -> [String] {
        let apiIds = product.prices.map {
            storeKitProductIdentifier(productId: product.productId, priceId: $0.priceId)
        }
        var seen = Set<String>()
        return (apiIds + fallbackIds).filter { seen.insert($0).inserted }
    }

    static func apiProductFromFallbackProductIds(_ productIds: [String]) -> APIProduct? {
        let prices = productIds.compactMap { productId -> APIProductPrice? in
            guard productId.hasPrefix("\(premiumProductId).") else {
                return nil
            }

            let priceId = String(productId.dropFirst(premiumProductId.count + 1))
            guard priceId.isNotEmpty else {
                return nil
            }

            let period = priceId.lowercased()
            return APIProductPrice(
                name: period.capitalized,
                price: "",
                priceId: priceId,
                priceDescription: nil,
                period: period
            )
        }

        guard !prices.isEmpty else {
            return nil
        }

        return APIProduct(
            id: 0,
            productId: premiumProductId,
            displayName: "Premium",
            group: "ios",
            weight: 0,
            description: nil,
            priceDescription: nil,
            isDefault: false,
            includes: nil,
            prices: prices
        )
    }

    static func apiProduct(from value: Any, preferredProductId: String = SubscribtionsManager.premiumProductId) -> APIProduct? {
        guard let root = dictionary(from: value),
              let results = dictionaries(from: root["results"]) else {
            return nil
        }

        let products = results
            .compactMap { apiProduct(fromDictionary: $0) }
            .filter { !$0.isDefault && !$0.prices.isEmpty }

        return products.first(where: { $0.productId == preferredProductId }) ?? products.first
    }

    static func hasEmptyCatalogResponse(_ value: Any) -> Bool {
        guard let root = dictionary(from: value),
              let results = dictionaries(from: root["results"]) else {
            return false
        }
        return results.isEmpty
    }

    private static func apiProduct(fromDictionary item: [String: Any]) -> APIProduct? {
        let prices = dictionaries(from: item["prices"])?.compactMap { priceDictionary -> APIProductPrice? in
            guard let name = nonEmptyString(from: priceDictionary["name"]),
                  let priceId = nonEmptyString(from: priceDictionary["price_id"]),
                  let period = nonEmptyString(from: priceDictionary["period"]) else {
                return nil
            }
            return APIProductPrice(
                name: name,
                price: priceText(from: priceDictionary["price"]),
                priceId: priceId,
                priceDescription: string(from: priceDictionary["price_description"]),
                period: period
            )
        } ?? []

        return APIProduct(
            id: int(from: item["id"]) ?? 0,
            productId: string(from: item["product_id"]) ?? "",
            displayName: string(from: item["display_name"]) ?? "",
            group: string(from: item["group"]) ?? "",
            weight: int(from: item["weight"]) ?? 0,
            description: string(from: item["description"]),
            priceDescription: string(from: item["price_description"]),
            isDefault: bool(from: item["default"]) ?? false,
            includes: stringArray(from: item["includes"]),
            prices: prices
        )
    }

    private static func dictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else {
            return nil
        }
        var result: [String: Any] = [:]
        dictionary.forEach { key, value in
            if let key = key as? String {
                result[key] = value
            }
        }
        return result
    }

    private static func dictionaries(from value: Any?) -> [[String: Any]]? {
        if let dictionaries = value as? [[String: Any]] {
            return dictionaries
        }
        if let array = value as? [NSDictionary] {
            return array.compactMap { dictionary(from: $0) }
        }
        if let array = value as? NSArray {
            return array.compactMap { dictionary(from: $0) }
        }
        return nil
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let strings = value as? [String] {
            return strings
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return nil
    }

    private static func string(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let int = value as? Int {
            return "\(int)"
        }
        if let double = value as? Double {
            return "\(double)"
        }
        return nil
    }

    private static func nonEmptyString(from value: Any?) -> String? {
        guard let value = string(from: value), value.isNotEmpty else {
            return nil
        }
        return value
    }

    private static func int(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func bool(from value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return Bool(string)
        }
        return nil
    }

    private static func priceText(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            return formatter.string(from: number) ?? number.stringValue
        }
        if let double = value as? Double {
            return priceText(from: NSNumber(value: double))
        }
        if let int = value as? Int {
            return priceText(from: NSNumber(value: int))
        }
        return ""
    }

    static func activePremiumAccountProducts(from value: Any, now: Date = Date()) -> [AccountProductEntitlement]? {
        guard let products = dictionaries(from: value) else {
            return nil
        }

        return products.compactMap { item in
            guard accountProductStatusIsActive(item["status"]),
                  let productData = dictionary(from: item["product_data"]),
                  string(from: productData["group"]) == "ios",
                  string(from: productData["product_id"]) == premiumProductId,
                  let expiresString = nonEmptyString(from: item["expires"]),
                  let expires = Date.parseXMPPFormattedString(expiresString),
                  expires > now else {
                return nil
            }

            let priceData = dictionary(from: item["price_data"])
            let priceId = nonEmptyString(from: priceData?["price_id"]) ?? ""
            let storeKitProductId = storeKitProductIdentifier(productId: premiumProductId, priceId: priceId)
            guard storeKitProductId.isNotEmpty else {
                return nil
            }

            return AccountProductEntitlement(
                accountProductId: int(from: item["id"]) ?? 0,
                productId: premiumProductId,
                storeKitProductId: storeKitProductId,
                expires: expires
            )
        }
    }

    private static func accountProductStatusIsActive(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue == 2
        }
        if let int = value as? Int {
            return int == 2
        }
        guard let string = string(from: value)?.uppercased() else {
            return false
        }
        return string == "ACTIVE" || string == "2"
    }

    /// Sync active App Store entitlements into Realm so the app knows about
    /// subscriptions purchased outside the current session (e.g. on another device,
    /// or when no Xabber Account was used).
    func restoreSubscriptions() {
        Task {
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    _ = await self.handleVerifiedTransaction(transaction, fallbackJid: nil)
                default:
                    break
                }
            }
        }
    }
    
    
    
    func getState(account jid: String) -> AccountState {
        if hasActiveSubsription(for: jid) {
            return .active
        }

        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let accountUUID = Self.appAccountToken(for: jid).uuidString
            let expired = realm.objects(SubsriptionInfoRealmStorage.self)
                .filter("(jid == %@ OR accountUUID == %@) AND expires <= %@", jid, accountUUID, Date())
            return expired.isEmpty ? .trial : .expired
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return .trial
    }

    /// Fallback: load product IDs from plist. Only used if fetchProducts() hasn't run yet.
    fileprivate func loadProductList() {
        guard self.products.isEmpty,
              let products_ids = SubscribtionsSecretStore.bundle?.product_list else {
            return
        }
        Task {
            let fetched = try await Product.products(for: products_ids)
            // Only set if fetchProducts() hasn't populated them in the meantime
            if self.products.isEmpty {
                self.products = fetched
            }
        }
    }
    
    func fetchProducts(jid: String, completion: @escaping (SubscriptionCatalogFetchResult) -> Void) {
        guard let apiUrl = SubscribtionsSecretStore.bundle?.api_url else {
            let fallbackIds = SubscribtionsSecretStore.bundle?.product_list ?? []
            let fallbackProduct = Self.apiProductFromFallbackProductIds(fallbackIds)
            completion(
                SubscriptionCatalogFetchResult(
                    product: fallbackProduct,
                    source: fallbackProduct == nil ? .empty : .fallback,
                    warningMessage: nil,
                    errorMessage: fallbackProduct == nil ? "No subscriptions available right now." : nil
                )
            )
            return
        }

        let url = apiUrl + "accounts/products/"
        let fallbackIds = SubscribtionsSecretStore.bundle?.product_list ?? []
        let fallbackProduct = Self.apiProductFromFallbackProductIds(fallbackIds)

        AF.request(
            url,
            method: .get,
            parameters: ["group": "ios"],
            encoding: URLEncoding.default,
            headers: HTTPHeaders(["Cache-Control": "no-cache"])
        ).responseJSON { [weak self] response in
            guard let self = self else { return }
            switch response.result {
            case .success(let value):
                if Self.hasEmptyCatalogResponse(value) {
                    completion(
                        SubscriptionCatalogFetchResult(
                            product: nil,
                            source: .empty,
                            warningMessage: nil,
                            errorMessage: nil
                        )
                    )
                    return
                }

                guard let foundProduct = Self.apiProduct(from: value) else {
                    completion(
                        SubscriptionCatalogFetchResult(
                            product: fallbackProduct,
                            source: fallbackProduct == nil ? .empty : .fallback,
                            warningMessage: fallbackProduct == nil ? nil : "We couldn't refresh subscriptions. Showing fallback catalog.",
                            errorMessage: fallbackProduct == nil ? "We couldn't load subscriptions. Please try again." : nil
                        )
                    )
                    return
                }

                self.apiProduct = foundProduct

                // Extract price_ids and fetch StoreKit products
                let priceIds = Self.storeKitProductIdentifiers(for: foundProduct, fallbackIds: fallbackIds)
                Task {
                    do {
                        self.products = try await Product.products(for: priceIds)
                    } catch {
                        self.products = []
                        DDLogDebug("SubscribtionsManager: Failed to fetch StoreKit products: \(error.localizedDescription)")
                    }
                    completion(
                        SubscriptionCatalogFetchResult(
                            product: foundProduct,
                            source: .remote,
                            warningMessage: nil,
                            errorMessage: nil
                        )
                    )
                }

            case .failure(let error):
                DDLogDebug("SubscribtionsManager: fetchProducts failed: \(error.localizedDescription)")
                completion(
                    SubscriptionCatalogFetchResult(
                        product: fallbackProduct,
                        source: fallbackProduct == nil ? .empty : .fallback,
                        warningMessage: fallbackProduct == nil ? nil : "We couldn't refresh subscriptions. Showing fallback catalog.",
                        errorMessage: fallbackProduct == nil ? "We couldn't load subscriptions. Please try again." : nil
                    )
                )
            }
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
            callback?(hasActiveSubsription(for: jid))
            return
        }
        self.loadProductList()
        let url = api_url + "accounts/account-products/"
        var headers = HTTPHeaders(["Cache-Control": "no-cache"])
        if let token = XabberAccountManager.shared.token(for: jid) {
            headers.add(name: "Authorization", value: "Bearer \(token)")
        }
        AF
            .request(
                url,
                method: .get,
                parameters: [
                    "product__group": "ios",
                    "product__product_id": Self.premiumProductId
                ],
                encoding: URLEncoding.default,
                headers: headers
            ).responseJSON {
                response in
//                print(response)
                if (response.response?.statusCode ?? 500) >= 301 {
                    callback?(self.hasActiveSubsription(for: jid))
                    return
                }
                switch response.result {
                    case .success(let value):
                        guard let activeProducts = Self.activePremiumAccountProducts(from: value) else {
                            callback?(self.hasActiveSubsription(for: jid))
                            return
                        }

                        let reconciled = self.reconcileAccountProducts(activeProducts, for: jid)
                        callback?(reconciled ? !activeProducts.isEmpty : self.hasActiveSubsription(for: jid))
                        
                case .failure(let error):
                    DDLogDebug(error.localizedDescription)
                    callback?(self.hasActiveSubsription(for: jid))
                }
            }
    }
    
    // MARK: - Purchase

    public final func purchase(
        subscribtion id: String,
        accountUUID: String? = nil,
        jid: String? = nil,
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
                        let persisted = await self.handleVerifiedTransaction(transaction, fallbackJid: jid)
                        if persisted {
                            await transaction.finish()
                        }
                        if persisted && (transaction.expirationDate?.timeIntervalSince1970 ?? 0) > Date().timeIntervalSince1970 {
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

    @discardableResult
    func handleVerifiedTransaction(_ transaction: Transaction, fallbackJid: String?) async -> Bool {
        let transactionId = "\(transaction.id)"
        if transaction.revocationDate != nil {
            removeSubscriptionInfo(transactionId: transactionId)
            return true
        }

        guard let expiration = transaction.expirationDate else {
            removeSubscriptionInfo(transactionId: transactionId)
            return true
        }

        guard expiration.timeIntervalSince1970 > Date().timeIntervalSince1970 else {
            removeSubscriptionInfo(transactionId: transactionId)
            return true
        }

        guard let transactionToken = transaction.appAccountToken?.uuidString else {
            DDLogDebug("SubscribtionsManager: verified transaction \(transactionId) has no appAccountToken")
            return false
        }

        let jid = resolvedJid(forAccountUUID: transactionToken, fallbackJid: fallbackJid)
        guard let resolvedJid = jid else {
            DDLogDebug("SubscribtionsManager: verified transaction \(transactionId) belongs to unknown account token \(transactionToken)")
            return false
        }

        return saveSubscriptionInfo(
            productId: transaction.productID,
            jid: resolvedJid,
            accountUUID: transactionToken,
            expires: expiration,
            purchaseDate: transaction.purchaseDate,
            transactionId: transactionId
        )
    }

    func hasActiveSubsription(for jid: String? = nil) -> Bool {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = activeSubscriptionRows(in: realm, for: jid)
            return !instances.isEmpty
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }

    func getExpiresDate(for jid: String? = nil) -> Date? {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = activeSubscriptionRows(in: realm, for: jid)
                .sorted(byKeyPath: "expires", ascending: false)
            return instances.first?.expires
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    func getPurchasedProductIds(for jid: String? = nil) -> Set<String> {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let instances = activeSubscriptionRows(in: realm, for: jid)
            return Set(instances.map { $0.productId })
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return Set()
    }

    func subscriptionPresentationState(
        for jid: String? = nil,
        scheduledProductId: String? = nil,
        scheduledEffectiveDate: Date? = nil
    ) -> SubscriptionPresentationState {
        do {
            let realm = try WRealm.safe()
            realm.refresh()
            let activeRow = preferredActiveSubscriptionRow(in: realm, for: jid)
            let normalizedScheduledProductId: String?
            if let scheduledProductId,
               scheduledProductId.isNotEmpty,
               scheduledProductId != activeRow?.productId {
                normalizedScheduledProductId = scheduledProductId
            } else {
                normalizedScheduledProductId = nil
            }
            return SubscriptionPresentationState(
                activeProductId: activeRow?.productId,
                activeExpires: activeRow?.expires,
                scheduledProductId: normalizedScheduledProductId,
                scheduledEffectiveDate: normalizedScheduledProductId == nil ? nil : scheduledEffectiveDate,
                hasActiveEntitlement: activeRow != nil
            )
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return SubscriptionPresentationState(
            activeProductId: nil,
            activeExpires: nil,
            scheduledProductId: nil,
            scheduledEffectiveDate: nil,
            hasActiveEntitlement: false
        )
    }

    private func activeSubscriptionRows(in realm: Realm, for jid: String?) -> Results<SubsriptionInfoRealmStorage> {
        let rows = realm.objects(SubsriptionInfoRealmStorage.self)
            .filter("expires > %@", Date())
        if let jid = jid, jid.isNotEmpty {
            let accountUUID = Self.appAccountToken(for: jid).uuidString
            return rows.filter("jid == %@ OR accountUUID == %@", jid, accountUUID)
        }

        let accountJids = locallyKnownAccountJids(in: realm)
        let accountUUIDs = accountJids.map { Self.appAccountToken(for: $0).uuidString }
        guard accountJids.isNotEmpty || accountUUIDs.isNotEmpty else {
            return rows.filter("jid == %@", "__no_local_account__")
        }
        return rows.filter("jid IN %@ OR accountUUID IN %@", accountJids, accountUUIDs)
    }

    private func preferredActiveSubscriptionRow(in realm: Realm, for jid: String?) -> SubsriptionInfoRealmStorage? {
        activeSubscriptionRows(in: realm, for: jid)
            .sorted(by: [
                SortDescriptor(keyPath: "purchaseDate", ascending: false),
                SortDescriptor(keyPath: "expires", ascending: false),
                SortDescriptor(keyPath: "transactionId", ascending: false),
            ])
            .first
    }

    private func locallyKnownAccountJids(in realm: Realm) -> [String] {
        var jids = Set(AccountManager.shared.users.map { $0.jid })
        realm.objects(AccountStorageItem.self).forEach { item in
            if item.jid.isNotEmpty {
                jids.insert(item.jid)
            }
        }
        return Array(jids)
    }

    private func resolvedJid(forAccountUUID accountUUID: String, fallbackJid: String?) -> String? {
        let normalized = accountUUID.lowercased()
        if let fallbackJid = fallbackJid,
           Self.appAccountToken(for: fallbackJid).uuidString.lowercased() == normalized {
            return fallbackJid
        }

        if let user = AccountManager.shared.users.first(where: { Self.appAccountToken(for: $0.jid).uuidString.lowercased() == normalized }) {
            return user.jid
        }

        do {
            let realm = try WRealm.safe()
            return realm.objects(AccountStorageItem.self).first(where: { item in
                Self.appAccountToken(for: item.jid).uuidString.lowercased() == normalized
            })?.jid
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    private func removeSubscriptionInfo(transactionId: String) {
        do {
            let realm = try WRealm.safe()
            if let item = realm.object(ofType: SubsriptionInfoRealmStorage.self, forPrimaryKey: transactionId) {
                try realm.write {
                    realm.delete(item)
                }
            }
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
        }
    }

    @discardableResult
    func reconcileAccountProducts(_ activeProducts: [AccountProductEntitlement], for jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            let accountUUID = Self.appAccountToken(for: jid).uuidString
            try realm.write {
                let rows = realm.objects(SubsriptionInfoRealmStorage.self)
                    .filter("jid == %@ OR accountUUID == %@", jid, accountUUID)
                realm.delete(rows)

                self.accounts = self.accounts.filter { $0.jid != jid }
                self.subscribtionsList = self.subscribtionsList.filter { $0.uuid != Self.appAccountToken(for: jid) }

                for product in activeProducts {
                    let item = SubsriptionInfoRealmStorage()
                    item.transactionId = "backend-account-product-\(product.accountProductId)-\(product.storeKitProductId)"
                    item.productId = product.storeKitProductId
                    item.jid = jid
                    item.accountUUID = accountUUID
                    item.expires = product.expires
                    item.purchaseDate = Date()
                    realm.add(item, update: .modified)

                    self.accounts.insert(AccountSubscriptions(jid: jid, date: product.expires))
                    self.subscribtionsList.insert(AppSubscribtions(product_id: product.storeKitProductId, expires: product.expires, uuid: Self.appAccountToken(for: jid)))
                }
            }
            postPremiumEntitlementDidChange(for: jid)
            return true
        } catch {
            DDLogDebug("SubscribtionsManager: Failed to reconcile account products: \(error.localizedDescription)")
            return false
        }
    }
    
    @discardableResult
    func saveSubscriptionInfo(
        productId: String,
        jid: String,
        accountUUID: String,
        expires: Date,
        purchaseDate: Date,
        transactionId: String
    ) -> Bool {
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
            if jid.isNotEmpty && expires > Date() {
                postPremiumEntitlementDidChange(for: jid)
            }
            return true
        } catch {
            DDLogDebug("SubscribtionsManager: Failed to save subscription info: \(error.localizedDescription)")
            return false
        }
    }
    
    private func postPremiumEntitlementDidChange(for jid: String) {
        guard jid.isNotEmpty else { return }
        NotificationCenter.default.post(
            name: .premiumEntitlementDidChange,
            object: self,
            userInfo: ["jid": jid]
        )
    }

}
