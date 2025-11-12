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

import UIKit
import MaterialComponents.MDCPalettes

class RoundedStatusView: UIView {

    var color: UIColor = UIColor.gray
    var borderColor: UIColor = UIColor.gray
    
    private func callNeedsDisplay() {
        DispatchQueue.main.async {
            self.setNeedsDisplay()
        }
    }
/*
    chat - LightGreen 500
    nil - Green 700
    away - Amber 700
    xa - Blue 500
    dnd - Red 700
    unavailable - Grey 500
*/
    func setCustomStatus(color: UIColor, iconName: String?) {
        self.backgroundColor = .clear
        self.borderColor = .systemBackground
        self.color = color
        subviews
            .forEach { $0.removeFromSuperview() }
        if let iconName = iconName {
            let view = UIImageView(image: imageLiteral(iconName))
            view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
            view.tintColor = .white
            view.contentMode = .scaleAspectFit
            view.backgroundColor = self.color
            self.backgroundColor = .systemBackground
            addSubview(view)
            bringSubviewToFront(view)
        }
        layer.borderColor = borderColor.cgColor
        setNeedsDisplay()
    }
    
    func setStatus(status: ResourceStatus, entity: RosterItemEntity?) {
        self.backgroundColor = .clear
        self.borderColor = .systemBackground
        switch status {
            case .online:
                self.color = MDCPalette.green.tint700 | .systemGreen
            case .offline:
                if [.groupchat, .incognitoChat, .server, .privateChat, .issue].contains(entity) {
                    self.color = MDCPalette.grey.tint500 | .systemGray
                } else {
                    self.color = .clear
                    self.borderColor = .clear
                }
            case .away:
                self.color = MDCPalette.amber.tint700 | .systemOrange
            case .chat:
                self.color = MDCPalette.lightGreen.tint500
            case .dnd:
                self.color = MDCPalette.red.tint700 | .systemRed
            case .xa:
                self.color = MDCPalette.blue.tint500 | .systemBlue
        }
        subviews
            .forEach { $0.removeFromSuperview() }
        print(imageLiteral("badge-circle-big-group-incognito-variant") == nil)
        switch entity {
            case .privateChat:
                let view = UIImageView(image: imageLiteral("badge-circle-big-group-incognito-variant"))
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                view.backgroundColor = self.color
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            case .groupchat:
                let view = UIImageView(image: UIImage(imageLiteralResourceName: "badge-circle-big-group-public").withRenderingMode(.alwaysTemplate))// imageLiteral("badge-circle-big-group-public", dimension: 0)?.withRenderingMode(.alwaysTemplate))
                
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                view.backgroundColor = self.color
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            case .bot:
                let view = UIImageView(image: imageLiteral("badge-circle-big-bot-variant"))
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = self.color
                view.contentMode = .scaleAspectFit
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            case .server:
                let view = UIImageView(image: imageLiteral("badge-circle-big-server"))
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                view.backgroundColor = self.color
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            case .incognitoChat:
                let view = UIImageView(image: imageLiteral("badge-circle-big-group-incognito"))
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                view.backgroundColor = self.color
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            case .issue:
                let view = UIImageView(image: imageLiteral("badge-circle-big-task"))
                view.frame = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                view.backgroundColor = self.color
                self.backgroundColor = .systemBackground
                addSubview(view)
                bringSubviewToFront(view)
            default:
                break
        }
        layer.borderColor = borderColor.cgColor
        setNeedsDisplay()
    }
    
    override func draw(_ rect: CGRect) {
//        super.draw(rect)
        let modifiedRect = CGRect(x: rect.minX + 0.5, y: rect.minY + 0.5, width: rect.width - 1, height: rect.height - 1)
        self.backgroundColor = .clear
        guard let context = UIGraphicsGetCurrentContext() else {return}
        context.addEllipse(in: modifiedRect)
        context.setFillColor(self.color.cgColor)
        context.fillPath()
    }
    
    open func border(_ width: CGFloat) {
        layer.cornerRadius = frame.height / 2
        layer.borderWidth = width
        layer.masksToBounds = true
    }
}
