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
import StoreKit

extension String {
    
    func uuidString() -> String {
        return UUID(name: self, nameSpace: UUID.getNSForXMPPUUIDV5()).uuidString
    }
    
    func uuid() -> UUID {
        return UUID(name: self, nameSpace: UUID.getNSForXMPPUUIDV5())
    }
}

public struct ClandestinoProducts {
    
//    public static let productIdentifiers: Set<String> = ["subs.id.chat.clandestino.dev.month12",
//                                                         "subs.id.chat.clandestino.dev.month6",
//                                                         "subs.id.chat.clandestino.dev.month3",
//                                                         "subs.id.chat.clandestino.dev.month1"]
    
    public static let productIdentifiers: Set<String> = ["ru.clandestino.test.subscription_one_year_productID",
                                                         "ru.clandestino.test.subscription_one_month_productID"]
}

public enum StoreError: Error {
    case failedVerification
}

class Store {
    
    struct PurchasedProduct: Hashable {
        let product: Product
        let token: String?
    }
    
    open class var shared: Store {
        struct StoreSingleton {
            static let instance = Store()
        }
        return StoreSingleton.instance
    }
    
    private(set) var subscriptions: [Product]
    private(set) var purchasedSubscriptions: [PurchasedProduct] = []
    
    var delegate: SubscriptionsTableViewController?
    var updateListenerTask: Task<Void, Error>? = nil

    init() {
        subscriptions = []
        updateListenerTask = listenForTransactions()

        updateProductList()
    }

    deinit {
        updateListenerTask?.cancel()
    }
    
    public final func prepare() {
        
    }
    
    public final func updateProductList() {
        Task {
            await requestProducts()
            await updateCustomerProductStatus()
        }
    }

    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    await self.updateCustomerProductStatus()
                    await transaction.finish()
                } catch {
                    print("Transaction failed verification")
                }
            }
        }
    }

    @MainActor
    func requestProducts() async {
        do {
            let storeProducts = try await Product.products(for: ClandestinoProducts.productIdentifiers)
            var newSubscriptions: [Product] = []

            for product in storeProducts {
                switch product.type {
                case .autoRenewable:
                    newSubscriptions.append(product)
                default:
                    print("Unknown product")
                }
            }
            subscriptions = sortByPrice(newSubscriptions)
        } catch {
            print("Failed product request from the App Store server: \(error)")
        }
    }
    
    func purchase(_ product: Product, jid: String) async throws -> Transaction? {
        
        let result = try await product.purchase(options: [.appAccountToken(jid.uuid())])

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateCustomerProductStatus()
            await transaction.finish()
            return transaction
        case .userCancelled, .pending:
            return nil
        default:
            return nil
        }
    }

    func isPurchased(_ product: Product) async throws -> Bool {
        switch product.type {
        case .autoRenewable:
            return purchasedSubscriptions.contains(where: { $0.product == product })
        default:
            return false
        }
    }

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    @MainActor
    func updateCustomerProductStatus() async {
        
        var purchasedSubscriptions: [PurchasedProduct] = []

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                switch transaction.productType {
                case .autoRenewable:
                    if let subscription = subscriptions.first(where: { $0.id == transaction.productID }) {
                        purchasedSubscriptions.append(PurchasedProduct(product: subscription,
                                                                       token: transaction.appAccountToken?.uuidString))
                    }
                default:
                    break
                }
            } catch {
                print()
            }
        }
        self.purchasedSubscriptions = purchasedSubscriptions
        delegate?.reload()
    }

    func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { return $0.price < $1.price })
    }
}
