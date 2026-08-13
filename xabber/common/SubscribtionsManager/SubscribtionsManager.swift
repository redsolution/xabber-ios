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

enum SubscribtionsRemovalIdentity: Equatable {
    case skip
    case jidOnly
    case jidAndAccountUUID(String)
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

enum PremiumPurchasePreflightDecision: Equatable {
    case proceed
    case blockDuplicateActivePlan
}

struct PremiumGalleryAvailability: Equatable {
    let isAvailable: Bool
    let storageURL: String?
    let metadata: AccountGalleryPremiumMetadata?

    init(isAvailable: Bool, storageURL: String?, metadata: AccountGalleryPremiumMetadata? = nil) {
        self.isAvailable = isAvailable
        self.storageURL = storageURL
        self.metadata = metadata
    }
}

private struct XMPPAccountStateConnectionCheckKey: Hashable {
    let jid: String
    let connectionAttemptID: UInt64?
}

struct AccountProductsHTTPResponse {
    let statusCode: Int?
    let result: Result<Any, Error>

    var isAuthorizationFailure: Bool {
        statusCode == 401 || statusCode == 403
    }

    static func success(statusCode: Int?, value: Any) -> AccountProductsHTTPResponse {
        AccountProductsHTTPResponse(statusCode: statusCode, result: .success(value))
    }

    static func failure(statusCode: Int?, error: Error) -> AccountProductsHTTPResponse {
        AccountProductsHTTPResponse(statusCode: statusCode, result: .failure(error))
    }
}

enum AccountProductsAuthenticatedRequestResult {
    case response(AccountProductsHTTPResponse)
    case authenticationUnavailable
}

private final class AccountProductsSingleInvocation {
    private let lock = NSLock()
    private var didInvoke = false

    func perform(_ block: () -> Void) {
        lock.lock()
        guard !didInvoke else {
            lock.unlock()
            return
        }
        didInvoke = true
        lock.unlock()
        block()
    }
}

final class AccountProductsAuthenticatedRequestExecutor {
    typealias TokenProvider = () -> String?
    typealias ClearStoredToken = () -> Void
    typealias FreshTokenRequest = (@escaping (String?) -> Void) -> Bool
    typealias AuthenticatedRequest = (
        _ token: String,
        _ completion: @escaping (AccountProductsHTTPResponse) -> Void
    ) -> Void

    private let allowInitialTokenRequest: Bool
    private let tokenProvider: TokenProvider
    private let clearStoredToken: ClearStoredToken
    private let freshTokenRequest: FreshTokenRequest
    private let authenticatedRequest: AuthenticatedRequest
    private let completionLock = NSLock()
    private var completionHandler: ((AccountProductsAuthenticatedRequestResult) -> Void)?
    private var didComplete = false
    private var authorizationRetryCount = 0

    init(
        allowInitialTokenRequest: Bool = true,
        tokenProvider: @escaping TokenProvider,
        clearStoredToken: @escaping ClearStoredToken,
        requestFreshToken: @escaping FreshTokenRequest,
        request: @escaping AuthenticatedRequest
    ) {
        self.allowInitialTokenRequest = allowInitialTokenRequest
        self.tokenProvider = tokenProvider
        self.clearStoredToken = clearStoredToken
        self.freshTokenRequest = requestFreshToken
        self.authenticatedRequest = request
    }

    func execute(completion: @escaping (AccountProductsAuthenticatedRequestResult) -> Void) {
        completionLock.lock()
        guard completionHandler == nil, !didComplete else {
            completionLock.unlock()
            return
        }
        completionHandler = completion
        completionLock.unlock()

        if let token = usableToken(tokenProvider()) {
            performRequest(token: token)
            return
        }

        guard allowInitialTokenRequest else {
            complete(.authenticationUnavailable)
            return
        }
        acquireFreshToken { [self] token in
            guard let token else {
                complete(.authenticationUnavailable)
                return
            }
            performRequest(token: token)
        }
    }

    private func performRequest(token: String) {
        let responseGate = AccountProductsSingleInvocation()
        authenticatedRequest(token) { [self] response in
            responseGate.perform {
                handle(response)
            }
        }
    }

    private func handle(_ response: AccountProductsHTTPResponse) {
        guard response.isAuthorizationFailure else {
            complete(.response(response))
            return
        }

        // The server is authoritative: neither the rejected token nor its
        // expiry may remain available to another account-products request.
        clearStoredToken()
        guard authorizationRetryCount < 1 else {
            complete(.response(response))
            return
        }

        authorizationRetryCount += 1
        acquireFreshToken { [self] token in
            guard let token else {
                complete(.authenticationUnavailable)
                return
            }
            performRequest(token: token)
        }
    }

    private func acquireFreshToken(completion: @escaping (String?) -> Void) {
        let callbackGate = AccountProductsSingleInvocation()
        let didStart = freshTokenRequest { [self] token in
            callbackGate.perform {
                completion(usableToken(token))
            }
        }
        if !didStart {
            callbackGate.perform {
                completion(nil)
            }
        }
    }

    private func usableToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else {
            return nil
        }
        return token
    }

    private func complete(_ result: AccountProductsAuthenticatedRequestResult) {
        let completion: ((AccountProductsAuthenticatedRequestResult) -> Void)?
        completionLock.lock()
        if didComplete {
            completion = nil
        } else {
            didComplete = true
            completion = completionHandler
            completionHandler = nil
        }
        completionLock.unlock()
        completion?(result)
    }
}

final class AccountProductsRefreshGenerationTracker {
    private let lock = NSLock()
    private var generations: [String: Int] = [:]

    func begin(for jid: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let generation = (generations[jid] ?? 0) + 1
        generations[jid] = generation
        return generation
    }

    func isCurrent(for jid: String, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[jid] == generation
    }
}

private struct ActivePremiumAccountProduct {
    let item: [String: Any]
    let productData: [String: Any]
    let expires: Date
}

private struct PremiumGalleryAccountProductCandidate {
    let storageURL: String
    let metadata: AccountGalleryPremiumMetadata?
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
    private let xmppAccountStateConnectionCheckLock = NSLock()
    private var xmppAccountStateConnectionCheckKeys: Set<XMPPAccountStateConnectionCheckKey> = Set()
    private let accountProductsRefreshGenerationTracker = AccountProductsRefreshGenerationTracker()
    private let postStoreKitRefreshGenerationTracker = AccountProductsRefreshGenerationTracker()
    static let postStoreKitAccountProductsRetryDelays: [TimeInterval] = [2, 5]

    static func startBoundedAccountProductsRefresh(
        jid: String,
        retryDelays: [TimeInterval] = postStoreKitAccountProductsRetryDelays,
        refresh: @escaping (String) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        guard jid.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else {
            return
        }

        refresh(jid)
        retryDelays.prefix(2).forEach { delay in
            guard delay.isFinite, delay > 0 else { return }
            schedule(delay) {
                refresh(jid)
            }
        }
    }

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
        let removalIdentity = Self.removalIdentity(for: owner)
        guard removalIdentity != .skip else {
            return
        }

        do {
            let realm = try WRealm.safe()
            let objects = realm.objects(SubsriptionInfoRealmStorage.self)
            let collection: Results<SubsriptionInfoRealmStorage>
            switch removalIdentity {
            case .skip:
                return
            case .jidOnly:
                collection = objects.filter("jid == %@", owner)
            case .jidAndAccountUUID(let accountUUID):
                collection = objects.filter(
                    "jid == %@ OR accountUUID == %@",
                    owner,
                    accountUUID
                )
            }
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

    static func removalIdentity(
        for owner: String,
        namespace: String = UUID.getNSForXMPPUUIDV5()
    ) -> SubscribtionsRemovalIdentity {
        guard owner.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else {
            return .skip
        }
        guard let accountUUID = UUID(namespaceString: namespace, name: owner) else {
            return .jidOnly
        }
        return .jidAndAccountUUID(accountUUID.uuidString)
    }

    static func storeKitProductIdentifier(productId: String, priceId: String) -> String {
        guard priceId.isNotEmpty else {
            return productId
        }
        guard productId.isNotEmpty else {
            return priceId
        }
        if priceId.contains(".") || priceId.hasPrefix(productId) {
            return priceId
        }
        return "\(productId).\(priceId)"
    }

    static func normalizedPremiumPlanKey(for productId: String?) -> String? {
        guard let productId else {
            return nil
        }

        let normalized = productId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isNotEmpty else {
            return nil
        }

        let premiumPrefix = "\(premiumProductId)."
        let planComponent: String
        if normalized.hasPrefix(premiumPrefix) {
            planComponent = String(normalized.dropFirst(premiumPrefix.count))
        } else if normalized == premiumProductId {
            planComponent = normalized
        } else {
            planComponent = normalized.components(separatedBy: ".").last ?? normalized
        }

        if planComponent.contains("year") || planComponent.contains("annual") {
            return "yearly"
        }
        if planComponent.contains("month") {
            return "monthly"
        }
        return normalized
    }

    static func isSamePremiumSubscriptionPlan(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsKey = normalizedPremiumPlanKey(for: lhs),
              let rhsKey = normalizedPremiumPlanKey(for: rhs) else {
            return false
        }
        return lhsKey == rhsKey
    }

    static func premiumPlanRank(for productId: String?) -> Int {
        switch normalizedPremiumPlanKey(for: productId) {
        case "yearly":
            return 2
        case "monthly":
            return 1
        default:
            return 0
        }
    }

    func isDuplicateActivePremiumPurchase(targetProductId: String, jid: String?) -> Bool {
        premiumPurchasePreflightDecision(targetProductId: targetProductId, jid: jid) == .blockDuplicateActivePlan
    }

    func premiumPurchasePreflightDecision(targetProductId: String, jid: String?) -> PremiumPurchasePreflightDecision {
        guard let jid, jid.isNotEmpty else {
            return .proceed
        }
        let activeProductId = subscriptionPresentationState(for: jid).activeProductId
        return Self.isSamePremiumSubscriptionPlan(targetProductId, activeProductId) ? .blockDuplicateActivePlan : .proceed
    }

    static func accountProductsRequestParameters() -> Parameters {
        [
            "status": 2,
            "product__group": "ios"
        ]
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

    private static func activeIOSAccountProduct(from item: [String: Any], now: Date) -> ActivePremiumAccountProduct? {
        guard accountProductStatusIsActive(item["status"]),
              let productData = dictionary(from: item["product_data"]),
              string(from: productData["group"])?.lowercased() == "ios",
              nonEmptyString(from: productData["product_id"]) != nil,
              let expiresString = nonEmptyString(from: item["expires"]),
              let expires = Date.parseXMPPFormattedString(expiresString),
              expires > now else {
            return nil
        }
        if let quantity = int(from: item["quantity"]), quantity <= 0 {
            return nil
        }
        return ActivePremiumAccountProduct(item: item, productData: productData, expires: expires)
    }

    static func activePremiumAccountProducts(from value: Any, now: Date = Date()) -> [AccountProductEntitlement]? {
        guard let products = dictionaries(from: value) else {
            return nil
        }

        return products.compactMap { item in
            guard let activeProduct = activeIOSAccountProduct(from: item, now: now),
                  let productId = nonEmptyString(from: activeProduct.productData["product_id"]),
                  let priceData = dictionary(from: item["price_data"]),
                  let priceId = nonEmptyString(from: priceData["price_id"]) else {
                return nil
            }

            let storeKitProductId = storeKitProductIdentifier(productId: productId, priceId: priceId)
            guard storeKitProductId.isNotEmpty else {
                return nil
            }

            return AccountProductEntitlement(
                accountProductId: int(from: item["id"]) ?? 0,
                productId: productId,
                storeKitProductId: storeKitProductId,
                expires: activeProduct.expires
            )
        }
    }

    static func activePremiumGalleryAvailability(from value: Any, now: Date = Date()) -> PremiumGalleryAvailability? {
        guard let products = dictionaries(from: value) else {
            return nil
        }

        for item in products {
            guard let activeProduct = activeIOSAccountProduct(from: item, now: now),
                  let productId = nonEmptyString(from: activeProduct.productData["product_id"]),
                  productId == premiumProductId,
                  let priceData = dictionary(from: item["price_data"]),
                  nonEmptyString(from: priceData["price_id"]) != nil else {
                continue
            }

            if let candidate = topLevelPremiumGalleryCandidate(from: activeProduct)
                ?? servicePremiumGalleryCandidate(from: activeProduct) {
                return PremiumGalleryAvailability(
                    isAvailable: true,
                    storageURL: candidate.storageURL,
                    metadata: candidate.metadata
                )
            }
        }

        return PremiumGalleryAvailability(isAvailable: false, storageURL: nil)
    }

    private static func topLevelPremiumGalleryCandidate(from activeProduct: ActivePremiumAccountProduct) -> PremiumGalleryAccountProductCandidate? {
        guard let attributes = dictionary(from: activeProduct.item["attributes"]),
              let storageURL = validStorageURL(from: attributes) else {
            return nil
        }

        return PremiumGalleryAccountProductCandidate(
            storageURL: storageURL,
            metadata: premiumGalleryMetadata(
                from: attributes,
                productData: activeProduct.productData,
                expires: activeProduct.expires
            )
        )
    }

    private static func servicePremiumGalleryCandidate(from activeProduct: ActivePremiumAccountProduct) -> PremiumGalleryAccountProductCandidate? {
        let services = (dictionaries(from: activeProduct.productData["services"]) ?? [])
            + (dictionaries(from: activeProduct.item["services"]) ?? [])

        for service in services {
            guard string(from: service["service"])?.lowercased() == "gallery" else {
                continue
            }
            let attributes = dictionary(from: service["attributes"]) ?? dictionary(from: activeProduct.item["attributes"])
            guard let storageURL = validStorageURL(from: attributes) else {
                continue
            }
            return PremiumGalleryAccountProductCandidate(
                storageURL: storageURL,
                metadata: premiumGalleryMetadata(
                    from: attributes,
                    productData: activeProduct.productData,
                    expires: activeProduct.expires
                )
            )
        }
        return nil
    }

    private static func validStorageURL(from attributes: [String: Any]?) -> String? {
        guard let rawStorageURL = nonEmptyString(from: attributes?["storage_url"]),
              AccountGalleryConfiguration.normalizedBaseURLString(from: rawStorageURL) != nil else {
            return nil
        }
        return rawStorageURL
    }

    private static func premiumGalleryMetadata(
        from attributes: [String: Any]?,
        productData: [String: Any],
        expires: Date
    ) -> AccountGalleryPremiumMetadata? {
        guard let attributes = attributes else {
            return nil
        }

        let metadata = AccountGalleryPremiumMetadata(
            storageMegabytes: int(from: attributes["storage"]),
            storageDescription: nonEmptyString(from: attributes["storage_description"]),
            storageIncludes: stringArray(from: attributes["storage_includes"]) ?? [],
            messageRetention: nonEmptyString(from: attributes["message_retention"]),
            expires: expires,
            displayName: nonEmptyString(from: productData["display_name"])
        )

        guard metadata.storageMegabytes != nil
            || metadata.storageDescription != nil
            || metadata.storageIncludes.isNotEmpty
            || metadata.messageRetention != nil else {
            return nil
        }
        return metadata
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
        AccountManager.shared.users.forEach {
            user in
            self.checkXMPPAccountState(jid: user.jid)
        }
    }

    @discardableResult
    func reserveXMPPAccountStateCheckAfterConnection(jid: String, connectionAttemptID: UInt64?) -> Bool {
        let key = XMPPAccountStateConnectionCheckKey(jid: jid, connectionAttemptID: connectionAttemptID)
        xmppAccountStateConnectionCheckLock.lock()
        defer { xmppAccountStateConnectionCheckLock.unlock() }

        guard !xmppAccountStateConnectionCheckKeys.contains(key) else {
            return false
        }
        xmppAccountStateConnectionCheckKeys.insert(key)
        return true
    }

    func resetXMPPAccountStateConnectionCheckReservations() {
        xmppAccountStateConnectionCheckLock.lock()
        xmppAccountStateConnectionCheckKeys.removeAll()
        xmppAccountStateConnectionCheckLock.unlock()
    }

    @discardableResult
    public final func checkXMPPAccountStateAfterConnection(jid: String, connectionAttemptID: UInt64?) -> Bool {
        guard reserveXMPPAccountStateCheckAfterConnection(jid: jid, connectionAttemptID: connectionAttemptID) else {
            DDLogDebug("skip duplicate subscription check jid=\(jid) attempt=\(connectionAttemptID.map(String.init) ?? "none")")
            return false
        }

        checkXMPPAccountState(jid: jid)
        return true
    }

    public func checkXMPPAccountState(jid: String, retry: Int? = nil, callback: ((Bool) -> Void)? = nil) {
        guard let api_url = SubscribtionsSecretStore.bundle?.api_url else {
            callback?(hasActiveSubsription(for: jid))
            return
        }
        let refreshGeneration = beginAccountProductsRefresh(for: jid)
        self.loadProductList()
        let url = api_url + "accounts/account-products/"
        let accountManager = XabberAccountManager.shared
        let executor = AccountProductsAuthenticatedRequestExecutor(
            // Preserve the legacy retry argument's behavior for any external
            // caller while keeping 401/403 renewal independently bounded.
            allowInitialTokenRequest: retry == nil,
            tokenProvider: {
                accountManager.token(for: jid)
            },
            clearStoredToken: {
                accountManager.clearToken(for: jid)
            },
            requestFreshToken: { completion in
                accountManager.requestToken(for: jid, callback: completion)
            },
            request: { token, completion in
                let headers = HTTPHeaders([
                    "Cache-Control": "no-cache",
                    "Authorization": "Bearer \(token)"
                ])
                AF.request(
                    url,
                    method: .get,
                    parameters: Self.accountProductsRequestParameters(),
                    encoding: URLEncoding.default,
                    headers: headers
                ).responseJSON { response in
                    switch response.result {
                    case .success(let value):
                        completion(.success(statusCode: response.response?.statusCode, value: value))
                    case .failure(let error):
                        completion(.failure(statusCode: response.response?.statusCode, error: error))
                    }
                }
            }
        )

        executor.execute { [self] executionResult in
            guard isCurrentAccountProductsRefresh(
                for: jid,
                generation: refreshGeneration
            ) else {
                callback?(hasActiveSubsription(for: jid))
                return
            }
            switch executionResult {
            case .authenticationUnavailable:
                callback?(hasActiveSubsription(for: jid))

            case .response(let response):
                guard (response.statusCode ?? 500) < 301 else {
                    callback?(hasActiveSubsription(for: jid))
                    return
                }
                switch response.result {
                case .success(let value):
                    guard let isActive = reconcileAccountProductsRefresh(value, for: jid) else {
                        callback?(hasActiveSubsription(for: jid))
                        return
                    }
                    callback?(isActive)

                case .failure(let error):
                    DDLogDebug(error.localizedDescription)
                    callback?(hasActiveSubsription(for: jid))
                }
            }
        }
    }

    private func beginAccountProductsRefresh(for jid: String) -> Int {
        accountProductsRefreshGenerationTracker.begin(for: jid)
    }

    private func isCurrentAccountProductsRefresh(for jid: String, generation: Int) -> Bool {
        accountProductsRefreshGenerationTracker.isCurrent(for: jid, generation: generation)
    }

    // MARK: - Purchase

    public final func purchase(
        subscribtion id: String,
        accountUUID: String? = nil,
        jid: String? = nil,
        callback: ((Bool, Transaction?) -> Void)?
    ) {
        if premiumPurchasePreflightDecision(targetProductId: id, jid: jid) == .blockDuplicateActivePlan {
            DDLogDebug("SubscribtionsManager: skip duplicate active subscription purchase for \(id)")
            callback?(false, nil)
            return
        }

        guard let product = self.products.first(where: { $0.id == id }) else {
            callback?(false, nil)
            return
        }

        guard let purchaseJid = jid, purchaseJid.isNotEmpty else {
            performStoreKitPurchase(product: product, accountUUID: accountUUID, jid: jid, callback: callback)
            return
        }

        checkXMPPAccountState(jid: purchaseJid) { [weak self] _ in
            guard let self = self else {
                callback?(false, nil)
                return
            }
            if self.premiumPurchasePreflightDecision(targetProductId: id, jid: purchaseJid) == .blockDuplicateActivePlan {
                DDLogDebug("SubscribtionsManager: skip duplicate active subscription purchase after account-products preflight for \(id)")
                callback?(false, nil)
                return
            }
            self.performStoreKitPurchase(product: product, accountUUID: accountUUID, jid: purchaseJid, callback: callback)
        }
    }

    private func performStoreKitPurchase(
        product: Product,
        accountUUID: String?,
        jid: String?,
        callback: ((Bool, Transaction?) -> Void)?
    ) {
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
            return handleTerminalSubscriptionRemoval(
                transactionId: transactionId,
                productId: transaction.productID,
                accountUUID: transaction.appAccountToken?.uuidString,
                fallbackJid: fallbackJid
            )
        }

        guard let expiration = transaction.expirationDate else {
            return handleTerminalSubscriptionRemoval(
                transactionId: transactionId,
                productId: transaction.productID,
                accountUUID: transaction.appAccountToken?.uuidString,
                fallbackJid: fallbackJid
            )
        }

        guard expiration.timeIntervalSince1970 > Date().timeIntervalSince1970 else {
            return handleTerminalSubscriptionRemoval(
                transactionId: transactionId,
                productId: transaction.productID,
                accountUUID: transaction.appAccountToken?.uuidString,
                fallbackJid: fallbackJid
            )
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

        let persisted = saveSubscriptionInfo(
            productId: transaction.productID,
            jid: resolvedJid,
            accountUUID: transactionToken,
            expires: expiration,
            purchaseDate: transaction.purchaseDate,
            transactionId: transactionId
        )
        if persisted {
            startAccountProductsRefreshAfterStoreKitChange(for: resolvedJid)
        }
        return persisted
    }

    private func startAccountProductsRefreshAfterStoreKitChange(for jid: String) {
        let generation = postStoreKitRefreshGenerationTracker.begin(for: jid)
        Self.startBoundedAccountProductsRefresh(
            jid: jid,
            refresh: { [weak self] jid in
                guard let self,
                      self.postStoreKitRefreshGenerationTracker.isCurrent(
                        for: jid,
                        generation: generation
                      ) else {
                    return
                }
                self.checkXMPPAccountState(jid: jid)
            },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
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
               !Self.isSamePremiumSubscriptionPlan(scheduledProductId, activeRow?.productId) {
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
        Array(activeSubscriptionRows(in: realm, for: jid))
            .sorted { lhs, rhs in
                let lhsRank = Self.premiumPlanRank(for: lhs.productId)
                let rhsRank = Self.premiumPlanRank(for: rhs.productId)
                if lhsRank != rhsRank {
                    return lhsRank > rhsRank
                }
                if lhs.purchaseDate != rhs.purchaseDate {
                    return lhs.purchaseDate > rhs.purchaseDate
                }
                if lhs.expires != rhs.expires {
                    return lhs.expires > rhs.expires
                }
                return lhs.transactionId > rhs.transactionId
            }
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

    @discardableResult
    func handleTerminalSubscriptionRemoval(
        transactionId: String,
        productId: String,
        accountUUID: String?,
        fallbackJid: String?
    ) -> Bool {
        do {
            let realm = try WRealm.safe()
            let storedItem = realm.object(
                ofType: SubsriptionInfoRealmStorage.self,
                forPrimaryKey: transactionId
            )
            let storedJid = storedItem?.jid
            let storedAccountUUID = storedItem?.accountUUID
            let removedProductId = storedItem.flatMap { item in
                item.productId.isNotEmpty ? item.productId : nil
            } ?? productId
            let resolvedJid: String?
            if let storedJid, storedJid.isNotEmpty {
                resolvedJid = storedJid
            } else if let storedAccountUUID, storedAccountUUID.isNotEmpty {
                resolvedJid = self.resolvedJid(
                    forAccountUUID: storedAccountUUID,
                    fallbackJid: fallbackJid
                )
            } else if let accountUUID, accountUUID.isNotEmpty {
                resolvedJid = self.resolvedJid(
                    forAccountUUID: accountUUID,
                    fallbackJid: fallbackJid
                )
            } else {
                resolvedJid = nil
            }

            var rowsToDelete: [SubsriptionInfoRealmStorage] = []
            if let storedItem {
                rowsToDelete.append(storedItem)
            }
            if Self.isPremiumEntitlementProductId(removedProductId),
               let resolvedJid,
               resolvedJid.isNotEmpty {
                let resolvedAccountUUID = Self.appAccountToken(for: resolvedJid).uuidString
                let accountRows = realm.objects(SubsriptionInfoRealmStorage.self)
                    .filter(
                        "jid == %@ OR accountUUID == %@",
                        resolvedJid,
                        resolvedAccountUUID
                    )
                let backendMirrors = Array(accountRows).filter { item in
                    item.transactionId.hasPrefix("backend-account-product-")
                        && Self.isSameCanonicalPremiumProductPlan(
                            item.productId,
                            removedProductId
                        )
                }
                rowsToDelete.append(contentsOf: backendMirrors)
            }

            if rowsToDelete.isNotEmpty {
                var seenTransactionIds = Set<String>()
                let uniqueRows = rowsToDelete.filter {
                    seenTransactionIds.insert($0.transactionId).inserted
                }
                try realm.write {
                    realm.delete(uniqueRows)
                }
            }

            guard Self.isPremiumEntitlementProductId(removedProductId),
                  let resolvedJid,
                  resolvedJid.isNotEmpty else {
                return true
            }
            let hasAnotherActivePremiumEntitlement = activeSubscriptionRows(
                in: realm,
                for: resolvedJid
            ).contains { row in
                Self.isPremiumEntitlementProductId(row.productId)
            }
            guard !hasAnotherActivePremiumEntitlement else {
                return true
            }

            accounts = accounts.filter { $0.jid != resolvedJid }
            subscribtionsList = subscribtionsList.filter {
                $0.uuid != Self.appAccountToken(for: resolvedJid)
            }
            AccountGalleryConfiguration(owner: resolvedJid)
                .reconcilePremiumGalleryAvailability(
                    isAvailable: false,
                    storageURL: nil
                )
            postPremiumEntitlementDidChange(for: resolvedJid)
            return true
        } catch {
            DDLogDebug("SubscribtionsManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private static func isPremiumEntitlementProductId(_ productId: String) -> Bool {
        let normalized = productId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == premiumProductId
            || normalized.hasPrefix("\(premiumProductId).")
    }

    private static func isSameCanonicalPremiumProductPlan(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        return isPremiumEntitlementProductId(lhs)
            && isPremiumEntitlementProductId(rhs)
            && isSamePremiumSubscriptionPlan(lhs, rhs)
    }

    @discardableResult
    func reconcileAccountProductsRefresh(_ value: Any, for jid: String) -> Bool? {
        guard let activeProducts = Self.activePremiumAccountProducts(from: value),
              let galleryAvailability = Self.activePremiumGalleryAvailability(from: value) else {
            return nil
        }

        guard activeProducts.isNotEmpty else {
            // The account-products backend is updated asynchronously after a
            // StoreKit transaction. An empty valid response is therefore a
            // transient state, not an authoritative revocation signal.
            return hasActiveSubsription(for: jid)
        }

        AccountGalleryConfiguration(owner: jid).reconcilePremiumGalleryAvailability(
            isAvailable: galleryAvailability.isAvailable,
            storageURL: galleryAvailability.storageURL,
            metadata: galleryAvailability.metadata
        )

        let reconciled = reconcileAccountProducts(activeProducts, for: jid)
        return reconciled ? true : hasActiveSubsription(for: jid)
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
