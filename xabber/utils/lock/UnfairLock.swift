//
//  UnfairLock.swift
//  xabber
//
//  Created by Игорь Болдин on 16.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

final class UnfairLock {
    private var _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deallocate()
    }

    func locked<ReturnValue>(_ f: () throws -> ReturnValue) rethrows -> ReturnValue {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try f()
    }
}
