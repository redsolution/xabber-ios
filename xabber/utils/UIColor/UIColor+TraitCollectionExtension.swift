//
//  UIColor+TraitCollectionExtension.swift
//  xabber
//
//  Created by Игорь Болдин on 07.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

infix operator |: AdditionPrecedence

public extension UIColor {
    static func | (lightMode: UIColor, darkMode: UIColor) -> UIColor {
        return UIColor { (traitCollection) -> UIColor in
            return traitCollection.userInterfaceStyle == .light ? lightMode : darkMode
        }
    }
}
