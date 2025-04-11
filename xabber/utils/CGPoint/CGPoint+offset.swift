//
//  CGPoint+offset.swift
//  xabber
//
//  Created by Игорь Болдин on 20.02.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import UIKit

extension CGPoint {
    public func offset(by size: CGSize) -> CGPoint {
        return CGPoint(x: self.x + size.width, y: self.y + size.height)
    }
    
    func padding(x: CGFloat, y: CGFloat) -> CGPoint {
        return translate(x: x, y: y)
    }
    
    func translate(x: CGFloat, y: CGFloat) -> CGPoint {
        return CGPoint(
            x: self.x + x,
            y: self.y + y
        )
    }
    
    func offset(point: CGPoint)-> CGPoint {
        return CGPoint(
            x: self.x + point.x,
            y: self.y + point.y
        )
    }
    
}
