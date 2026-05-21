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
        
        var primary: String
        var url: URL
        var isSensitive: Bool {
            didSet {
                updateSensitiveAppearance()
            }
        }
        
        private let sensitiveOverlay = SensitiveMediaOverlayView()
        
        init(frame: CGRect, primary: String, url: URL, isSensitive: Bool) {
            self.primary = primary
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
            self.layer.masksToBounds = true
            addSubview(sensitiveOverlay)
            sensitiveOverlay.frame = bounds
            sensitiveOverlay.isUserInteractionEnabled = false
        }
        
        private func updateSensitiveAppearance() {
            sensitiveOverlay.isHidden = !isSensitive
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            sensitiveOverlay.frame = bounds
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
        self.contentViews.removeAll()
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            if let url = attachments[index].url {
                let view = InlineMessageImageView(frame: rect, primary: attachments[index].primary, url: url, isSensitive: attachments[index].isSensitive && !attachments[index].isSensitiveRevealed)
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

    func updateContent(_ attachments: [ImageAttachment]) {
        if attachments.isEmpty {
            self.views.forEach { $0.removeFromSuperview() }
            self.views = []
            self.contentViews.removeAll()
            return
        }

        guard self.views.map(\.primary) == attachments.map(\.primary),
              self.views.count == attachments.count else {
            configure(attachments)
            return
        }

        prepareGrid(attachments).enumerated().forEach { index, rect in
            let item = attachments[index]
            guard let url = item.url else { return }
            let view = self.views[index]
            view.frame = rect
            view.primary = item.primary
            view.isSensitive = item.isSensitive && !item.isSensitiveRevealed
            if view.url != url {
                view.url = url
                view.kf.setImage(
                    with: url,
                    placeholder: nil,
                    options: [
                        .alsoPrefetchToMemory,
                        .waitForCache,
                        .backgroundDecode,
                    ]
                )
            }
        }
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL, String, Bool) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        let urls = views.compactMap { $0.url }
        views.forEach {
            item in
            if !isMyTouch {
                if item.frame.contains(point) {
                    callback?(urls, item.url, item.primary, item.isSensitive)
                    isMyTouch = true
                }
            }
        }
        return isMyTouch
    }
}
