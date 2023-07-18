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

class InlineMessageView: UIView {
    
    public var index: Int = 0
    public var messageId: String = ""
    
    internal var kind: MessageForwardsInlineStorageItem.Kind = .text
    
    internal var datasource: MessagesDataSource? = nil
    
    internal var hasSubforward: Bool = false
    
//    internal var
    
    internal let subforwardsLabel: UILabel = {
        let label = UILabel()
        
        label.numberOfLines = 1
        
        return label
    }()
    
    internal let messageLabel: UILabel = {
        let label = UILabel()
        
        label.numberOfLines = 0
        
        return label
    }()
    
    internal let contentView: UIView = {
        let view = UIView()
        
        view.layer.cornerRadius = 2
        view.clipsToBounds = true
        view.layer.masksToBounds = true
        
        return view
    }()
    
    internal let dateLabel: UILabel = {
        let label = UILabel(frame: CGRect(width: 38, height: 16))
        
        label.textAlignment = .center
        label.textColor = MDCPalette.grey.tint600
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        
        return label
    }()
    
    
    internal let authorLabel: UILabel = {
        let label = UILabel(frame: CGRect(width: 44, height: 16))
        
        label.textColor = MDCPalette.grey.tint800
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        label.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 4)
        label.lineBreakMode = .byTruncatingMiddle
        
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    convenience init(frame: CGRect, for index: Int) {
        self.init(frame: frame)
//        self.restorationIdentifier = UUID().uuidString
        self.index = index
        addSubview(backgroundView)
        backgroundView.fillSuperview()
        backgroundView.image = backgroundImage
        
        subforwardsLabel.frame = CGRect(x: 8,
                                        y: 20,
                                        width: frame.width - 16,
                                        height: 24)
        
        messageLabel.frame =  CGRect(x: 8,
                                     y: 24,
                                     width: frame.width - 16,
                                     height: frame.height - 28)
        contentView.frame =  CGRect(x: 4,
                                    y: 22,
                                    width: frame.width - 8,
                                    height: frame.height - 26)
        
        
        dateLabel.frame = CGRect(x: frame.width - 44,
                                 y: frame.height - 22,
                                 width: 40,
                                 height: 16)
        
        authorLabel.frame = CGRect(x: 4,
                                   y: 2,
                                   width: frame.width,
                                   height: 16)
        addSubview(messageLabel)
        addSubview(contentView)
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal var backgroundImage: UIImage = {
        let image = #imageLiteral(resourceName: "message_bubble_inline").withRenderingMode(.alwaysTemplate)
            .resizableImage(withCapInsets: UIEdgeInsets(top: 6,
                                                        bottom: 6,
                                                        left: 6,
                                                        right: 6),
                            resizingMode: .stretch)
        
        return image
    }()
    
    let backgroundView: UIImageView = {
        let view = UIImageView()
        
        view.tintColor = .clear
        
        return view
    }()
    
    func update(_ message: MessageType, indexPath: IndexPath, with item: MessageForwardsInlineStorageItem.Model, accountColor: UIColor, palette: MDCPalette) {
        if item.isOutgoing {
            backgroundView.tintColor = message.isOutgoing ? MDCPalette.grey.tint200 : .white // was tint100
        } else {
            backgroundView.tintColor = accountColor
        }
        
        if item.subforwards.isNotEmpty {
            addSubview(self.subforwardsLabel)
            self.subforwardsLabel.attributedText = item.forwardedBody
            self.messageLabel.frame =  CGRect(x: 8,
                                              y: 48,
                                              width: frame.width - 16,
                                              height: frame.height - 52)
            self.contentView.frame =  CGRect(x: 4,
                                             y: 46,
                                             width: frame.width - 8,
                                             height: frame.height - 52)
            self.hasSubforward = true
        }
        
        self.messageId = item.messageId
//        contentView.backgroundColor = item.isOutgoing ? .white : MDCPalette.grey.tint100
        
        switch item.kind {
        case .text:
//            addSubview(messageLabel)
            messageLabel.attributedText = item.attributedBody
            dateLabel.frame = CGRect(x: frame.width - 42,
                                     y: frame.height - 18,
                                     width: 40,
                                     height: 16)
        case .quote:
            let view = InlineQuoteGridView(frame: contentView.bounds)
            view.configure(item.attributedQuotes,
                           messageId: item.messageId,
                           indexPath: indexPath,
                           color: palette.tint400)
            contentView.frame = messageLabel.frame
            contentView.addSubview(view)
        case .images:
//            addSubview(contentView)
            
            let view = InlineImagesGridView(frame: contentView.bounds)
            view.configure(item.references, messageId: item.messageId, indexPath: indexPath)
            contentView.addSubview(view)
//            [dateLabel].forEach {
//                label in
//                label.backgroundColor = MDCPalette.grey.tint50.withAlphaComponent(0.8)
                
                dateLabel.layer.cornerRadius = 2
                dateLabel.layer.masksToBounds = true
//            }
//            authorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            dateLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            dateLabel.textColor = MDCPalette.grey.tint50
        case .videos:
            let view = InlineVideosGridView(frame: contentView.bounds)
            view.configure(item.references, messageId: item.messageId, indexPath: indexPath)
            contentView.addSubview(view)
            
        case .files:
//            addSubview(contentView)
            let view = InlineFilesGridView(frame: contentView.bounds)
            view.configure(item.references, messageId: item.messageId, indexPath: indexPath)
            contentView.addSubview(view)
        case .voice:
//            addSubview(contentView)
            let view = InlineAudioGridView(frame: contentView.bounds)
            view.datasource = datasource
            view.configure(item.references, messageId: item.messageId, indexPath: indexPath)
            contentView.addSubview(view)
        }
        if let date = item.originalDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            addSubview(dateLabel)
            dateLabel.text = formatter.string(from: date)
        }
        authorLabel.attributedText = item.attributedAuthor
        authorLabel.sizeToFit()
        authorLabel.frame = CGRect(x: authorLabel.frame.minX,
                                   y: authorLabel.frame.minY,
                                   width: (authorLabel.frame.width + 8) >= frame.width ? frame.width : authorLabel.frame.width + 8,
                                   height: authorLabel.frame.height + 4)
        addSubview(authorLabel)
    }
    
    
    func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
        if hasSubforward {
            if subforwardsLabel.frame.contains(point) {
                callback?(messageId, 0, true)
            }
        }
        switch kind {
        case .text:
            if messageLabel.frame.contains(point) {
                callback?(messageId, 0, false)
            }
        default:
            contentView
                .subviews
                .compactMap { return $0 as? InlineMediaBaseView }
                .forEach { $0.handleTouch(at: point, callback: callback) }
        }
        
    }
    
    func update(state: InlineAudioGridView.AudioCellPlayingState) {
        if let view = self.contentView
            .subviews
            .compactMap({  return $0 as? InlineAudioGridView })
            .first {
            view.update(state: state)
        }
    }
    
    func update(durationLabel: String?) {
        if let view = self.contentView
            .subviews
            .compactMap({  return $0 as? InlineAudioGridView })
            .first {
            view.update(durationLabel: durationLabel)
        }
    }
}
