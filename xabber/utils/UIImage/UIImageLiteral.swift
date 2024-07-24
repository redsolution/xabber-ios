//
//  UIImageLiteral.swift
//  xabber
//
//  Created by Игорь Болдин on 23.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

func imageLiteral(_ name: String, dimension: CGFloat = 0) -> UIImage? {
    return (UIImage(named: name) ?? UIImage(systemName: name))?
        .upscale(dimension: dimension)
        .withRenderingMode(.alwaysTemplate)
}

