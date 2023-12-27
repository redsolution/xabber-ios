//
//  SynchronizationArrayCallbackItem.swift
//  xabber
//
//  Created by Игорь Болдин on 14.12.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation

public class SynchronizedArrayCallbackItem: Equatable, Hashable {
    public static func == (lhs: SynchronizedArrayCallbackItem, rhs: SynchronizedArrayCallbackItem) -> Bool {
        return lhs.uuid == rhs.uuid
    }
    
    private var uuid: String
    public var callback: (() -> Void)?
    
    init(_ callback: (() -> Void)?) {
        self.uuid = UUID().uuidString
        self.callback = callback
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}
