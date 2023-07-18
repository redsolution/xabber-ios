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
import UIKit
//import SwipeCellKit

//class CellWithBadge : SwipeTableViewCell {
class CellWithBadge : UITableViewCell {
    
    public var badgeString: String = "" {
        didSet {
            if(badgeString == "") {
                badgeView.removeFromSuperview()
                layoutSubviews()
            } else {
                contentView.addSubview(badgeView)
                drawBadge()
            }
        }
    }
    
    public var subRequest: Bool = false {
        didSet {
            if subRequest {
                contentView.addSubview(subBadgeView)
                drawSubBadge()
            } else {
                subBadgeView.removeFromSuperview()
                layoutSubviews()
            }
        }
    }
    
    public var badgeColor : UIColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1.0)
    public var badgeColorHighlighted : UIColor = .darkGray
    public var badgeFontSize : Float = 13.0
    public var badgeTextStyle: UIFont.TextStyle?
    public var badgeTextColor: UIColor?
    public var badgeRadius : Float = 20
    public var badgeOffset = CGPoint(x:12, y:10)
    public var subBadgeOffset: CGFloat = 30
    internal let badgeView = UIImageView()
    internal let subBadgeView = UIImageView()
    
    override open func layoutSubviews() {
        super.layoutSubviews()
        var offsetX = badgeOffset.x
        if(isEditing == false && accessoryType != .none || (accessoryView) != nil) {
            offsetX = 0
        }
        badgeView.frame.origin.x = floor(contentView.frame.width - badgeView.frame.width - offsetX)
        badgeView.frame.origin.y = floor((frame.height / 2 + 4) - (badgeView.frame.height / 2))
        
        subBadgeView.frame.origin.x = floor(contentView.frame.width - subBadgeView.frame.width - offsetX) - subBadgeOffset
        subBadgeView.frame.origin.y = floor((frame.height / 2 + 4) - (subBadgeView.frame.height / 2))
        print(badgeView.frame.width)
        print(subBadgeView.frame.width)
        print((offsetX * 2))
        let labelWidth = self.contentView.frame.width - (badgeView.frame.width + (offsetX * 2));
        if textLabel != nil {
            textLabel!.frame.size.width = labelWidth - textLabel!.frame.origin.x
        }
        if detailTextLabel != nil {
            detailTextLabel!.frame.size.width = labelWidth - detailTextLabel!.frame.origin.x
        }
    }
    
    override open func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        drawBadge()
        drawSubBadge()
    }
    
    override open func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        drawBadge()
        drawSubBadge()
    }
    
    internal func drawSubBadge() {
        var badgeFont = UIFont.boldSystemFont(ofSize: CGFloat(badgeFontSize))
        if let textStyle = self.badgeTextStyle {
            badgeFont = UIFont.preferredFont(forTextStyle: textStyle)
        }
        let textSize: CGSize = NSString(string: "0").size(withAttributes: [NSAttributedString.Key.font: badgeFont])
        let height = textSize.height + 4
        let width = height
        let badgeFrame : CGRect = CGRect(x: 0, y: 0, width: width, height: height)
        let badge = CALayer()
        badge.frame = badgeFrame
        if isHighlighted || isSelected {
            badge.backgroundColor = badgeColorHighlighted.cgColor
        } else {
            badge.backgroundColor = badgeColor.cgColor
        }
        badge.cornerRadius = (CGFloat(badgeRadius) < (badge.frame.size.height / 2)) ? CGFloat(badgeRadius) : CGFloat(badge.frame.size.height / 2)
        UIGraphicsBeginImageContextWithOptions(badge.frame.size, false, UIScreen.main.scale)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.saveGState()
        badge.render(in: ctx)
        ctx.saveGState()
        if badgeTextColor == nil {
            ctx.setBlendMode(CGBlendMode.clear)
        }
        NSString(string: "＋").draw(in: CGRect(x: 3.5, y: 2, width: textSize.width + 4, height: textSize.height), withAttributes: [
            NSAttributedString.Key.font: badgeFont,
            NSAttributedString.Key.foregroundColor: badgeTextColor ?? UIColor.clear
            ])
        let badgeImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        subBadgeView.frame = CGRect(x: 0, y: 0, width: badgeImage.size.width, height: badgeImage.size.height)
        subBadgeView.image = badgeImage
        layoutSubviews()
    }
    
    internal func drawBadge() {
        
        var badgeFont = UIFont.boldSystemFont(ofSize: CGFloat(badgeFontSize))
        if let textStyle = self.badgeTextStyle {
            badgeFont = UIFont.preferredFont(forTextStyle: textStyle)
        }
        let textSize : CGSize = NSString(string: badgeString).size(withAttributes: [NSAttributedString.Key.font: badgeFont])
        let height = textSize.height + 4
        var width = textSize.width + 12
        if width < height {
            width = height
        }
        let badgeFrame : CGRect = CGRect(x: 0, y: 0, width: width, height: height)
        let badge = CALayer()
        badge.frame = badgeFrame
        if isHighlighted || isSelected {
            badge.backgroundColor = badgeColorHighlighted.cgColor
        } else {
            badge.backgroundColor = badgeColor.cgColor
        }
        badge.cornerRadius = (CGFloat(badgeRadius) < (badge.frame.size.height / 2)) ? CGFloat(badgeRadius) : CGFloat(badge.frame.size.height / 2)
        UIGraphicsBeginImageContextWithOptions(badge.frame.size, false, UIScreen.main.scale)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.saveGState()
        badge.render(in: ctx)
        ctx.saveGState()
        if badgeTextColor == nil {
            ctx.setBlendMode(CGBlendMode.clear)
        }
        NSString(string: badgeString).draw(in: CGRect(x: 6, y: 2, width: textSize.width, height: textSize.height), withAttributes: [
            NSAttributedString.Key.font: badgeFont,
            NSAttributedString.Key.foregroundColor: badgeTextColor ?? UIColor.clear
            ])
        let badgeImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        badgeView.frame = CGRect(x: 0, y: 0, width: badgeImage.size.width, height: badgeImage.size.height)
        badgeView.image = badgeImage
        layoutSubviews()
    }
}
