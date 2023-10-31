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

class InlineFilesGridView: InlineMediaBaseView {
    
    class FileView: UIView {
                
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 6, right: 6)
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 44))
            
            button.backgroundColor = MDCPalette.grey.tint300
            button.tintColor = MDCPalette.grey.tint700
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            button.imageEdgeInsets = UIEdgeInsets(square: 10)
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
//            stack.spacing = 0
            
            return stack
        }()
        
        let filenameLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = MDCPalette.grey.tint700
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            
            return label
        }()
        
        let sizeLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(iconButton)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(filenameLabel)
            contentStack.addArrangedSubview(sizeLabel)
            NSLayoutConstraint.activate([
                iconButton.widthAnchor.constraint(equalToConstant: 44),
                iconButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        
        public func configure(file mimeType: String, filename: String, size: String) {
            switch MimeIconTypes(rawValue: mimeType) {
            case .image:
                iconButton.setImage(#imageLiteral(resourceName: "image").withRenderingMode(.alwaysTemplate), for: .normal)
            case .audio:
                iconButton.setImage(#imageLiteral(resourceName: "file-audio").withRenderingMode(.alwaysTemplate), for: .normal)
            case .video:
                iconButton.setImage(#imageLiteral(resourceName: "file-video").withRenderingMode(.alwaysTemplate), for: .normal)
            case .document:
                iconButton.setImage(#imageLiteral(resourceName: "file-document").withRenderingMode(.alwaysTemplate), for: .normal)
            case .pdf:
                iconButton.setImage(#imageLiteral(resourceName: "file-pdf").withRenderingMode(.alwaysTemplate), for: .normal)
            case .table:
                iconButton.setImage(#imageLiteral(resourceName: "file-table").withRenderingMode(.alwaysTemplate), for: .normal)
            case .presentation:
                iconButton.setImage(#imageLiteral(resourceName: "file-presentation").withRenderingMode(.alwaysTemplate), for: .normal)
            case .archive:
                iconButton.setImage(#imageLiteral(resourceName: "file-zip").withRenderingMode(.alwaysTemplate), for: .normal)
            case .file:
                iconButton.setImage(#imageLiteral(resourceName: "file").withRenderingMode(.alwaysTemplate), for: .normal)
            case .none:
                iconButton.setImage(#imageLiteral(resourceName: "file").withRenderingMode(.alwaysTemplate), for: .normal)
            default:
                iconButton.setImage(#imageLiteral(resourceName: "image").withRenderingMode(.alwaysTemplate), for: .normal)
            }
            filenameLabel.text = filename
            sizeLabel.text = size
        }
    }
    
    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = MessageSizeCalculator.fileViewHeight
        var offset: CGFloat = padding
        return references
            .filter { [.media, .voice].contains($0.kind) }
            .compactMap { _ in
                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
                offset += height + padding
                return rect
            }
    }
    
    override func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
        super.configure(references, messageId: messageId, indexPath: indexPath)
        self.messageId = messageId
        subviews.forEach { $0.removeFromSuperview() }
        let items = references
            .filter { [.media, .voice].contains($0.kind) }
        grid.removeAll()
        prepareGrid(references).enumerated().forEach {
            index, cell in
//            print(cell)
            if let name = items[index].metadata?["name"] as? String,
                let uri = items[index].metadata?["uri"] as? String,
                let url = URL(string: uri) {
                let view = FileView(frame: cell)
                view.configure(file: items[index].mimeType,
                               filename: name,
                               size: items[index].sizeInBytes ?? "")
                addSubview(view)
                grid.append(GridItem(cell: cell, url: url))
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
