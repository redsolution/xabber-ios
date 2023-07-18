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
import Kingfisher
import MaterialComponents.MDCPalettes

class CallScreenBackgroundView: UIView {
    
    enum State {
        case calling
        case connecting
        case connected
        case disconnected
        case rejected
    }
    
    var jid: String = "" {
        didSet {
            if self.owner.isNotEmpty {
                self.loadImage()
            }
        }
    }
    
    var owner: String = "" {
        didSet {
            if self.jid.isNotEmpty {
                self.loadImage()
            }
        }
    }
    
    var imageView: UIImageView = {
        var view = UIImageView()
        
        return view
    }()
    
    var dimmedView: UIView = {
        var view = UIView()
        
        return view
    }()
    
    var tonerView: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        
        return view
    }()
    
    var blurView: UIVisualEffectView = {
        let effect = UIBlurEffect(style: UIBlurEffect.Style.light)
        var view = UIVisualEffectView(effect: effect)
        
        return view
    }()
    
    private func loadImage() {
        DefaultAvatarManager.shared.getAvatar(jid: self.jid, owner: self.owner) { image in
            self.imageView.image = image
        }
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.fillSuperview()
        self.imageView.setNeedsDisplay()
    }
    
    open func update(_ state: State, animate: Bool) {
        func changeColor() {
            let alpha: CGFloat = 0.67
            switch state {
            case .calling:
//                self.dimmedView.backgroundColor = MDCPalette.blue.tint500.withAlphaComponent(alpha)
                self.dimmedView.backgroundColor = UIColor(red:0.01, green:0.66, blue:0.96, alpha: alpha)
            case .connecting:
//                self.dimmedView.backgroundColor = MDCPalette.teal.tint500.withAlphaComponent(alpha)
                self.dimmedView.backgroundColor = UIColor(red:0, green:0.74, blue:0.83, alpha: alpha)
            case .connected:
//                self.dimmedView.backgroundColor = MDCPalette.green.tint500.withAlphaComponent(alpha)
                self.dimmedView.backgroundColor = UIColor(red:0.3, green:0.69, blue:0.31, alpha: alpha)
            case .disconnected:
                self.dimmedView.backgroundColor = UIColor(red:1, green:0.63, blue:0, alpha: alpha)
            case .rejected:
                self.dimmedView.backgroundColor = UIColor(red:0.83, green:0.18, blue:0.18, alpha: alpha)
            }
            self.dimmedView.layoutIfNeeded()
        }
        if animate {
            UIView.animate(withDuration: 0.33) {
                changeColor()
            }
        } else {
            changeColor()
        }
    }
    
    private func activateConstraints() {
        
    }
    
    private func configure() {
        imageView.addSubview(blurView)
        addSubview(imageView)
        addSubview(dimmedView)
        [imageView, dimmedView, tonerView, blurView].forEach({$0.fillSuperview()})
        update(.calling, animate: false)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        activateConstraints()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("required init not implement")
    }
    
}
