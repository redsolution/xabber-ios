//
//  UIImage+Avatar.swift
//  xabber
//
//  Created by Игорь Болдин on 23.10.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import LetterAvatarKit
import UIKit

extension UIImageView {
    func setDefaultAvatar(for username: String, owner: String) {
        let color = AccountColorManager.shared.palette(for: owner)
        let conf = LetterAvatarBuilderConfiguration()
        conf.useSingleLetter = true
        conf.username = username
        conf.backgroundColors = [color.tint700, color.tint600, color.tint500, color.tint400, color.tint300]
        conf.size = self.bounds.size
        let image = UIImage.makeLetterAvatar(withConfiguration: conf)
        self.image = image
    }
    
    static func getDefaultAvatar(for username: String, owner: String, size: CGFloat) -> UIImage? {
        let color = AccountColorManager.shared.palette(for: owner)
        let conf = LetterAvatarBuilderConfiguration()
        conf.useSingleLetter = true
        conf.username = username
        conf.backgroundColors = [color.tint700, color.tint600, color.tint500, color.tint400, color.tint300]
        conf.size = CGSize(square: size)
        let image = UIImage.makeLetterAvatar(withConfiguration: conf)
        return image
    }
}
