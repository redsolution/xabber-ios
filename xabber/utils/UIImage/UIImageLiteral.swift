//
//  UIImageLiteral.swift
//  xabber
//
//  Created by Игорь Болдин on 23.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

func imageLiteral(_ name: String, dimension: CGFloat = 18) -> UIImage? {
    if dimension > 0 {
        return (UIImage(
                named: name,
                in: nil,
                with: UIImage.SymbolConfiguration(
                    font: .systemFont(ofSize: dimension, weight: CommonConfigManager.shared.symbolWeight)
                )
            ) ?? UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(
                font: .systemFont(ofSize: dimension, weight: CommonConfigManager.shared.symbolWeight)
            )))?
            .withRenderingMode(.alwaysTemplate)
    } else {
        return (UIImage(named: name) ?? UIImage(systemName: name))?
            .withRenderingMode(.alwaysTemplate)
    }
}
