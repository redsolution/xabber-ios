////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import UIKit
//import MaterialComponents.MDCPalettes
//import Kingfisher
//import CoreMedia
//import CocoaLumberjack
//
//class InlineVideosGridView: InlineAttachmentView {
//    let videoPlayIconBackground: UIView = {
//        let view = UIView()
//        view.translatesAutoresizingMaskIntoConstraints = false
//        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
//        view.layer.cornerRadius = 24
//        view.layer.borderWidth = 1
//        view.layer.borderColor = UIColor.white.cgColor
//        
//        return view
//    }()
//    
//    let videoPlayIcon: UIImageView = {
//        let view = UIImageView()
//        view.image = imageLiteral( "play")?.withRenderingMode(.alwaysTemplate)
//        view.tintColor = .white
//        view.backgroundColor = .clear
//        view.translatesAutoresizingMaskIntoConstraints = false
//        
//        return view
//    }()
//    
//    let errorImageView: UIImageView = {
//        let view = UIImageView()
//        view.translatesAutoresizingMaskIntoConstraints = false
//        view.tintColor = MDCPalette.grey.tint300
//        
//        return view
//    }()
//
//    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
//        var rects: [CGRect] = []
//        let halfPadding: CGFloat = 1
//        let containerSize: CGSize = frame.size
//        switch references
////            .filter({ $0.mimeType == MimeIconTypes.image.rawValue })
//            .count {
//        case 0: break
//        case 1:
//            rects.append(CGRect(x: 0,
//                                y: 0,
//                                width: containerSize.width,
//                                height: containerSize.height))
//        case 2:
//            rects.append(CGRect(x: 0,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: containerSize.height))
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: containerSize.height))
//        case 3:
//            rects.append(CGRect(x: 0,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: containerSize.height))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: 0,//halfPadding,
//                                width: (containerSize.width / 2) - (halfPadding * 2),
//                                height: (containerSize.height / 2) - (halfPadding * 2)))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: (containerSize.height / 2) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//        case 4:
//            rects.append(CGRect(x: 0,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//            
//            rects.append(CGRect(x: 0,
//                                y: (containerSize.height / 2) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: (containerSize.height / 2) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//        default:
//            rects.append(CGRect(x: 0,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//            
//            rects.append(CGRect(x: 0,
//                                y: (containerSize.height / 2) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 2) - halfPadding))
//            
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: 0,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 3) - halfPadding))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: (containerSize.height / 3) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 3) - (halfPadding * 2)))
//            
//            rects.append(CGRect(x: (containerSize.width / 2) + halfPadding,
//                                y: ((containerSize.height / 3) * 2) + halfPadding,
//                                width: (containerSize.width / 2) - halfPadding,
//                                height: (containerSize.height / 3) - halfPadding))
//        }
//        return rects
//    }
//    
//    override func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
//        super.configure(references, messageId: messageId, indexPath: indexPath)
//        self.messageId = messageId
//        subviews.forEach { $0.removeFromSuperview() }
//        let urls = references
////            .filter({ $0.mimeType == MimeIconTypes.image.rawValue })
//            .compactMap { return $0.metadata?["uri"] as? String }
//            .compactMap { return URL(string: $0.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") }
//        if urls.isEmpty { return }
//        prepareGrid(references).enumerated().forEach {
//            index, cell in
//            if index < urls.count {
//                let imageView = UIImageView(frame: cell)
//                addSubview(imageView)
//                imageView.kf.indicatorType = .activity
//                imageView.startAnimating()
//                
//                imageView.backgroundColor = .black
//                guard let key = references[index].videoPreviewKey else { return }
//                
//                if references[index].isDownloaded {
//                    self.videoPlayIcon.image = imageLiteral( "play")
//                } else {
//                    self.videoPlayIcon.image = imageLiteral( "square.and.arrow.down")
//                }
//                ImageCache.default.retrieveImage(forKey: key) { result in
//                    switch result {
//                    case .success(let value):
//                        imageView.addSubview(self.videoPlayIconBackground)
//                        self.videoPlayIconBackground.addSubview(self.videoPlayIcon)
//                        imageView.image = value.image
//                        self.activateConstraints(view: imageView)
//                        imageView.stopAnimating()
//                    case .failure(let value):
//                        self.errorImageView.image = imageLiteral( "video.slash")?.withRenderingMode(.alwaysTemplate)
//                        self.activateErrorImage(on: imageView)
//                        imageView.stopAnimating()
//                        DDLogDebug("InlineImagesGridView: \(#function). \(value.localizedDescription)")
//                    }
//                }
//                
//                imageView.contentMode = .scaleAspectFill
//                imageView.layer.cornerRadius = 2
//                imageView.layer.masksToBounds = true
//
//                imageView.layer.borderColor = MDCPalette.grey.tint500.withAlphaComponent(0.2).cgColor
//                imageView.layer.borderWidth = 0.5
//                
//                grid.append(GridItem(cell: cell, url: urls[index]))
//                contentViews.append(imageView)
//                if urls.count > 5 && index == 4  {
//                    let view = UIView(frame: CGRect(origin: .zero, size: cell.size))
//                    view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
//                    let label = UILabel(frame: view.frame)
//                    label.textAlignment = .center
//                    label.numberOfLines = 1
//                    label.font = UIFont.preferredFont(forTextStyle: .title1)
//                    label.text = "+\(urls.count - 5)"
//                    label.textColor = .white
//                    view.addSubview(label)
//                    view.bringSubviewToFront(label)
//                    imageView.addSubview(view)
//                    imageView.bringSubviewToFront(view)
//                }
//            }
//        }
//    }
//    
//    private func activateConstraints(view: UIImageView) {
//        NSLayoutConstraint.activate([
//            videoPlayIconBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
//            videoPlayIconBackground.centerYAnchor.constraint(equalTo: view.centerYAnchor),
//            videoPlayIconBackground.heightAnchor.constraint(equalToConstant: 48),
//            videoPlayIconBackground.widthAnchor.constraint(equalToConstant: 48),
//            
//            videoPlayIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
//            videoPlayIcon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
//            videoPlayIcon.heightAnchor.constraint(equalToConstant: 32),
//            videoPlayIcon.widthAnchor.constraint(equalToConstant: 32)
//        ])
//    }
//    
//    private func activateErrorImage(on view: UIImageView) {
//        view.addSubview(errorImageView)
//        NSLayoutConstraint.activate([
//            errorImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
//            errorImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
//            errorImageView.heightAnchor.constraint(equalToConstant: 48),
//            errorImageView.widthAnchor.constraint(equalToConstant: 48)
//        ])
//    }
//    
//    override func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
//        for (index, item) in grid.enumerated() {
//            if item.cell.contains(point) {
//                callback?(messageId, index, false)
//            }
//        }
//    }
//}

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import Kingfisher
import CoreMedia
import CocoaLumberjack
import RealmSwift

class InlineVideosGridView: InlineAttachmentView {
    
    class InlineMessageVideoView: UIImageView {
        var url: URL?
        
        internal let playButton: UIButton = {
            var conf = UIButton.Configuration.borderless()
            conf.image = imageLiteral("play.fill")?.withTintColor(.white)
            conf.title = nil
            conf.background.cornerRadius = 32
            
            
            let button = UIButton(frame: CGRect(square: 64))
            
            button.configuration = conf
            button.tintColor = .white
            
            return button
        }()
        
        init(frame: CGRect, url: URL?) {
            self.url = url
            super.init(frame: frame)
            playButton.center = self.center
            addSubview(playButton)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    var views: [InlineMessageVideoView] = []

    public func prepareGrid(_ attachments: [VideoAttachment]) -> [CGRect] {
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
    
    func configure(_ attachments: [VideoAttachment]) {
        self.views.forEach { $0.removeFromSuperview() }
        self.views = []
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            let view = InlineMessageVideoView(frame: rect, url: attachments[index].url)
            self.contentViews.append(view)
            view.contentMode = .scaleAspectFill
            view.layer.cornerRadius = 7
            view.layer.masksToBounds = true
            if let previewUrl = attachments[index].previewUrl {
                
                view.kf.setImage(
                    with: previewUrl,
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
            } else {
                view.backgroundColor = .black
            }
            self.addSubview(view)
            self.views.append(view)
            
        }
        
    }
    
    func handleTouch(at point: CGPoint, callback: (([URL], URL) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        let urls = views.compactMap { $0.url }
        for (index, item) in views.enumerated() {
            if item.frame.contains(point) {
                if let url = item.url {
                    callback?(urls, url)
                }
                isMyTouch = true
            }
        }
        return isMyTouch
    }
}
