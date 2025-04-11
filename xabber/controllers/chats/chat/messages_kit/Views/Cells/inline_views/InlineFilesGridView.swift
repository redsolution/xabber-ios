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

class InlineFilesGridView: InlineAttachmentView {
    
    class FileView: UIView {
                
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 4)
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            
            button.backgroundColor = MDCPalette.blue.tint500
            button.tintColor = UIColor.white
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 0, right: 0)
            
            return stack
        }()
        
        let filenameLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.textColor = UIColor.label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            
            return label
        }()
        
        let sizeLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()
        
        var url: URL
        
        init(frame: CGRect, url: URL) {
            self.url = url
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        var palette: MDCPalette = .amber
        
        internal func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(iconButton)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(filenameLabel)
            contentStack.addArrangedSubview(sizeLabel)
            NSLayoutConstraint.activate([
                iconButton.widthAnchor.constraint(equalToConstant: 36),
                iconButton.heightAnchor.constraint(equalToConstant: 36),
                filenameLabel.heightAnchor.constraint(equalToConstant: 20),
                sizeLabel.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
        
        public func configure(filename: String, size: String) {
            iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            let mimeType = url.absoluteString
            switch MimeIconTypes(rawValue: mimeType) {
                case .image:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .audio:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .video:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .document:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .pdf:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .table:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .presentation:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .archive:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .file:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                case .none:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
                default:
                    iconButton.setImage(imageLiteral("doc.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
            self.iconButton.backgroundColor = palette.tint500
            self.filenameLabel.text = filename
            self.sizeLabel.text = size
        }
    }
    
    var views: [FileView] = []
    
    func prepareGrid(_ attachments: [FileAttachment]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = CommonMessageSizeCalculator.inlineFileViewHeight//MessageSizeCalculator.fileViewHeight
        var offset: CGFloat = padding
        return attachments
            .compactMap { _ in
                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
                offset += height + padding
                return rect
            }
    }
    
    var palette: MDCPalette = .amber
    
    func configure(_ attachments: [FileAttachment], palette: MDCPalette) {
        self.palette = palette
        subviews.forEach { $0.removeFromSuperview() }
        if attachments.isEmpty { return }
        grid.removeAll()
        self.views.forEach { $0.removeFromSuperview() }
        self.views = []
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            let item = attachments[index]
            if let url = item.url {
                let view = FileView(frame: rect, url: url)
                view.palette = palette
                view.configure(filename: item.name, size: item.prettySize)
                self.addSubview(view)
                self.views.append(view)
            }
        }
    }
    
    func handleTouch(at point: CGPoint, callback: ((URL) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        for (index, item) in views.enumerated() {
            if item.frame.contains(point) {
                callback?(item.url)
                isMyTouch = true
            }
        }
        return isMyTouch
    }
    
}
