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
import MaterialComponents.MDCPalettes
import Kingfisher
import CoreMedia
import CocoaLumberjack
import RealmSwift

class InlineImagesGridView: InlineAttachmentView {
    
    class InlineMessageImageView: UIImageView {
        
        var url: URL
        var isSensitive: Bool {
            didSet {
                updateSensitiveAppearance()
            }
        }
        
        // Blur overlay using UIVisualEffectView
        private let blurOverlay: UIVisualEffectView = {
            let blurEffect = UIBlurEffect(style: .dark)   // .dark, .light, .regular, .prominent, .systemMaterial...
            let effectView = UIVisualEffectView(effect: blurEffect)
            effectView.isHidden = true
//            effectView.translatesAutoresizingMaskIntoConstraints = false
            return effectView
        }()
        
        // "Sensitive content" label with vibrancy (makes text pop nicely on blur)
        private let sensitiveLabel: UILabel = {
            let lbl = UILabel()
            lbl.text = "Sensitive content"
            lbl.textColor = .white
            lbl.font = .systemFont(ofSize: 16, weight: .semibold)
            lbl.textAlignment = .center
            lbl.numberOfLines = 1
            lbl.translatesAutoresizingMaskIntoConstraints = false
            return lbl
        }()
        
        // Optional: vibrancy container (makes text look better on blur)
        private lazy var vibrancyContainer: UIVisualEffectView = {
            let vibrancyEffect = UIVibrancyEffect(blurEffect: (blurOverlay.effect as! UIBlurEffect))
            let v = UIVisualEffectView(effect: vibrancyEffect)
//            v.translatesAutoresizingMaskIntoConstraints = false
            return v
        }()
        
        init(frame: CGRect, url: URL, isSensitive: Bool) {
            self.url = url
            self.isSensitive = isSensitive
            super.init(frame: frame)
            setup()
            updateSensitiveAppearance()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setup() {
            // Add blur overlay
            self.layer.masksToBounds = true
            addSubview(blurOverlay)
            blurOverlay.frame = CGRect(origin: .zero, size: self.bounds.size)
//            NSLayoutConstraint.activate([
//                blurOverlay.topAnchor.constraint(equalTo: topAnchor),
//                blurOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
//                blurOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
//                blurOverlay.trailingAnchor.constraint(equalTo: trailingAnchor)
//            ])
            
            // Optional vibrancy for nicer text appearance (recommended)
            blurOverlay.contentView.addSubview(vibrancyContainer)
            vibrancyContainer.frame = blurOverlay.bounds
//            NSLayoutConstraint.activate([
//                vibrancyContainer.topAnchor.constraint(equalTo: blurOverlay.contentView.topAnchor),
//                vibrancyContainer.bottomAnchor.constraint(equalTo: blurOverlay.contentView.bottomAnchor),
//                vibrancyContainer.leadingAnchor.constraint(equalTo: blurOverlay.contentView.leadingAnchor),
//                vibrancyContainer.trailingAnchor.constraint(equalTo: blurOverlay.contentView.trailingAnchor)
//            ])
            
            // Add label inside vibrancy container
            vibrancyContainer.contentView.addSubview(sensitiveLabel)
            NSLayoutConstraint.activate([
                sensitiveLabel.centerXAnchor.constraint(equalTo: vibrancyContainer.contentView.centerXAnchor),
                sensitiveLabel.centerYAnchor.constraint(equalTo: vibrancyContainer.contentView.centerYAnchor)
            ])
        }
        
        private func updateSensitiveAppearance() {
            blurOverlay.isHidden = !isSensitive
            
            // Optional: hide image completely or dim it while blurred
            // alpha = isSensitive ? 0.4 : 1.0
            // or: image = isSensitive ? nil : image  (if you want to remove it)
        }
        
        // Call this when user taps to reveal (e.g. "Show anyway")
        func revealContent() {
            isSensitive = false
        }
    }
    
    var views: [InlineMessageImageView] = []

    public func prepareGrid(_ attachments: [ImageAttachment]) -> [CGRect] {
        var rects: [CGRect] = []
        let halfPadding: CGFloat = 2
        let containerSize: CGSize = frame.size
        switch attachments
            .count {
        case 0: break
        case 1:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: containerSize.width,
                                height: containerSize.height))
        case 2:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
        case 3:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: containerSize.height))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,//halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
        case 4:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: 0,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
        default:
            rects.append(CGRect(x: 0,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            rects.append(CGRect(x: 0,
                                y: (containerSize.height / 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 2) - halfPadding))
            
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: 0,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - halfPadding))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: (containerSize.height / 3) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - (halfPadding * 2)))
            
            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
                                y: ((containerSize.height / 3) * 2) + halfPadding,
                                width: (containerSize.width / 2) - halfPadding,
                                height: (containerSize.height / 3) - halfPadding))
        }
        return rects
    }
    
    func configure(_ attachments: [ImageAttachment]) {
//        subviews.forEach { $0.removeFromSuperview() }
        self.views.forEach { $0.removeFromSuperview() }
        self.views = []
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            if let url = attachments[index].url {
                let view = InlineMessageImageView(frame: rect, url: url, isSensitive: attachments[index].isSensitive)
                self.contentViews.append(view)
                view.contentMode = .scaleAspectFill
//                view.layer.masksToBounds = true
//                view.layer.borderColor = UIColor.black.withAlphaComponent(0.1).cgColor
//                view.layer.borderWidth = 1
//                view.layer.cornerRadius = 7
//                view.layer.masksToBounds = true
                view.kf.setImage(
                    with: url,
                    placeholder: nil,
                    options: [
                        .alsoPrefetchToMemory,
                        .waitForCache,
                        .backgroundDecode,
                    ]) { (result) in
                        switch result {
                            case .success(_):
                                break
                            case .failure(let error):
                                print(error.errorCode)
                        }
                    }
                
                self.addSubview(view)
                self.views.append(view)
            } else {
                
            }
            
        }
        
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL, Bool) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        let urls = views.compactMap { $0.url }
        views.forEach {
            item in
            if !isMyTouch {
                if item.frame.contains(point) {
                    callback?(urls, item.url, item.isSensitive)
                    isMyTouch = true
                }
            }
        }
        return isMyTouch
    }
}
