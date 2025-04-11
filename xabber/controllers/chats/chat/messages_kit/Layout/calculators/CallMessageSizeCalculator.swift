//
//  CallMessageSizeCalculator.swift
//  xabber
//
//  Created by Игорь Болдин on 18.02.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//
import Foundation
import UIKit

class CallMessageSizeCalculator: CellSizeCalculator {
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        return .zero
    }
}
