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
    private let iconImageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .white
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        return view
    }()
    private var iconName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupIconView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupIconView()
    }

    private func setupIconView() {
        addSubview(iconImageView)
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    
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
        self.iconName = iconName
        if let iconName = iconName {
            iconImageView.image = imageLiteral(iconName)
            iconImageView.backgroundColor = self.color
            iconImageView.isHidden = false
            self.backgroundColor = .systemBackground
            bringSubviewToFront(iconImageView)
        } else {
            iconImageView.image = nil
            iconImageView.backgroundColor = .clear
            iconImageView.isHidden = true
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
        iconImageView.image = nil
        iconImageView.backgroundColor = .clear
        iconImageView.isHidden = true
        switch entity {
            case .privateChat:
                iconImageView.image = imageLiteral("badge-circle-big-group-incognito-variant")
                iconImageView.tintColor = .white
                iconImageView.backgroundColor = self.color
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
            case .groupchat:
                iconImageView.image = UIImage(imageLiteralResourceName: "badge-circle-big-group-public").withRenderingMode(.alwaysTemplate)
                iconImageView.tintColor = .white
                iconImageView.backgroundColor = self.color
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
            case .bot:
                iconImageView.image = imageLiteral("badge-circle-big-bot-variant")
                iconImageView.tintColor = self.color
                iconImageView.backgroundColor = .clear
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
            case .server:
                iconImageView.image = imageLiteral("badge-circle-big-server")
                iconImageView.tintColor = .white
                iconImageView.backgroundColor = self.color
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
            case .incognitoChat:
                iconImageView.image = imageLiteral("badge-circle-big-group-incognito")
                iconImageView.tintColor = .white
                iconImageView.backgroundColor = self.color
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
            case .issue:
                iconImageView.image = imageLiteral("badge-circle-big-task")
                iconImageView.tintColor = .white
                iconImageView.backgroundColor = self.color
                iconImageView.isHidden = false
                self.backgroundColor = .systemBackground
                bringSubviewToFront(iconImageView)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
