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

class InlineImagesGridView: InlineMediaBaseView {
    

    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
        var rects: [CGRect] = []
        let halfPadding: CGFloat = 1
        let containerSize: CGSize = frame.size
        switch references
//            .filter({ $0.mimeType == MimeIconTypes.image.rawValue })
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
                                width: (containerSize.width / 2) - (halfPadding * 2),
                                height: (containerSize.height / 2) - (halfPadding * 2)))
            
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
    
    override func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
        super.configure(references, messageId: messageId, indexPath: indexPath)
        self.messageId = messageId
        subviews.forEach { $0.removeFromSuperview() }
        let urls = references
            .compactMap { return $0.metadata?["uri"] as? String }
            .compactMap { return URL(string: $0) }
        if urls.isEmpty { return }
        prepareGrid(references).enumerated().forEach {
            index, cell in
            if index < urls.count {
                let imageView = UIImageView(frame: cell)
                addSubview(imageView)
                
                let errorImageView: UIImageView = {
                    let view = UIImageView()
                    view.translatesAutoresizingMaskIntoConstraints = false
                    view.tintColor = MDCPalette.grey.tint300
                    
                    return view
                }()
                
                imageView.kf.indicatorType = .activity
                imageView.startAnimating()
                
                if urls[index].absoluteString == "" {
                    errorImageView.image = imageLiteral( "badge-blocked")?.withRenderingMode(.alwaysTemplate)
                    activateErrorImage(on: imageView)
                    return
                }
                if let refItem = references[index].metadata,
                   let keyb64 = refItem["encryption-key"] as? String,
                   let ivb64 = refItem["iv"] as? String {
                    imageView.kf.setImage(with: KF.ImageResource(downloadURL: urls[index]),
                                          placeholder: InlineGridImagePlaceholderView(frame: CGRect(origin: .zero,
                                                                                                    size: cell.size)),
                                          options: [.encryptionKey(keyb64), .iv(ivb64)]) { result in
                        switch result {
                        case .success(let value):
                            if value.cacheType == .none {
                                break
                            }
                        case .failure(_):
                            errorImageView.image = imageLiteral("badge-blocked")?.withRenderingMode(.alwaysTemplate)
                            activateErrorImage(on: imageView)
                            imageView.stopAnimating()
                        }
                    }
                } else {
                    imageView.kf.setImage(with: KF.ImageResource(downloadURL: urls[index]),
                                          placeholder: InlineGridImagePlaceholderView(frame: CGRect(origin: .zero,
                                                                                                    size: cell.size)),
                                          options: []) { result in
                        switch result {
                        case .success(let value):
                            if value.cacheType == .none {
                                break
                            }
                        case .failure(_):
                            errorImageView.image = imageLiteral( "badge-blocked")?.withRenderingMode(.alwaysTemplate)
                            activateErrorImage(on: imageView)
                            imageView.stopAnimating()
                        }
                    }
                }
                
                
                
                imageView.contentMode = .scaleAspectFill
                imageView.layer.cornerRadius = 2
                imageView.layer.masksToBounds = true

                imageView.layer.borderColor = MDCPalette.grey.tint500.withAlphaComponent(0.2).cgColor
                imageView.layer.borderWidth = 0.5
                
                grid.append(GridItem(cell: cell, url: urls[index]))
                contentViews.append(imageView)
                if urls.count > 5 && index == 4  {
                    let view = UIView(frame: CGRect(origin: .zero, size: cell.size))
                    view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
                    let label = UILabel(frame: view.frame)
                    label.textAlignment = .center
                    label.numberOfLines = 1
                    label.font = UIFont.preferredFont(forTextStyle: .title1)
                    label.text = "+\(urls.count - 5)"
                    label.textColor = .white
                    view.addSubview(label)
                    view.bringSubviewToFront(label)
                    imageView.addSubview(view)
                    imageView.bringSubviewToFront(view)
                }
                
                func activateErrorImage(on view: UIImageView) {
                    view.addSubview(errorImageView)
                    NSLayoutConstraint.activate([
                        errorImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                        errorImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                        errorImageView.heightAnchor.constraint(equalToConstant: 48),
                        errorImageView.widthAnchor.constraint(equalToConstant: 48)
                    ])
                }
            }
        }
    }
    
    override func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
        for (index, item) in grid.enumerated() {
            if item.cell.contains(point) {
                callback?(messageId, index, false)
            }
        }
    }
}
