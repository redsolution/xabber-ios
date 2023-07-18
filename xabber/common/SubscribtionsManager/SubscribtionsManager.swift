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

class SubscribtionsManager: NSObject {
    
    struct AppSubscribtions: Codable {
        let product_id: String
        let expires: Date
    }
    
    open class var shared: SubscribtionsManager {
        struct SubscribtionsManagerSingleton {
            static let instance = SubscribtionsManager()
        }
        return SubscribtionsManagerSingleton.instance
    }
    
    open var accountExpirationDate: Date? = nil
    open var inTrialPeriod: Bool = false
    open var subscribtionsList: [AppSubscribtions] = []
    
    open var isSubscribtionsInfoUpdate: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    public final func setSubscribtionsInfoUpdated() {
        self.isSubscribtionsInfoUpdate.accept(true)
    }
    
    public final func reset() {
        self.isSubscribtionsInfoUpdate.accept(false)
        self.subscribtionsList = []
    }
    
    public final func trialPeriodRemains() -> TimeInterval? {
        let currentDate = Date()
        if subscribtionsList.isEmpty,
           let expiration = accountExpirationDate,
           expiration.timeIntervalSinceReferenceDate > currentDate.timeIntervalSinceReferenceDate {
            return expiration.timeIntervalSinceReferenceDate - currentDate.timeIntervalSinceReferenceDate
        }
        return nil
    }
    
    public final func subscribtionRemain() -> TimeInterval? {
        let currentDate = Date()
        if subscribtionsList.isNotEmpty,
           let expiration = accountExpirationDate,
           expiration.timeIntervalSinceReferenceDate > currentDate.timeIntervalSinceReferenceDate {
            return expiration.timeIntervalSinceReferenceDate - currentDate.timeIntervalSinceReferenceDate
        }
        
        return nil
    }
    
    public var trialEnd: Date? {
        get {
            let currentDate = Date()
            if subscribtionsList.isEmpty,
               let expiration = accountExpirationDate,
               expiration.timeIntervalSinceReferenceDate > currentDate.timeIntervalSinceReferenceDate {
                return expiration
            }
            return nil
        }
    }
    
    public var subscribtionEnd: Date? {
        get {
            let currentDate = Date()
            if subscribtionsList.isNotEmpty,
               let expiration = accountExpirationDate,
               expiration.timeIntervalSinceReferenceDate > currentDate.timeIntervalSinceReferenceDate {
                return expiration
            }
            return nil
        }
    }
    
}


