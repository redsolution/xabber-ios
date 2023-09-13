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
import MaterialComponents

class FilesMediaCollectionCell: UICollectionViewCell {
    static let cellName = "FilesMediaCollectionCell"
    
    let primaryStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 6, right: 6)
        
        return stack
    }()
    
    let contentStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fillEqually
        
        return stack
    }()
    
    let nameAndDateStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        
        return stack
    }()
    
    let fileNameStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        
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
    
    let senderNameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = .black
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let dateLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = MDCPalette.grey.tint500
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let fileNameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .black
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(UILayoutPriority(900), for: .horizontal)
        
        return label
    }()
    
    let fileSizeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = MDCPalette.grey.tint500
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(UILayoutPriority(700), for: .horizontal)
        
        return label
    }()
    
    let separatorLine: UIView = {
        let view = UIView()
        view.backgroundColor = .systemGray
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    
    internal func setup(mimeType: String, sender: String, date: String, time: String, sizeInBytes: String, filename: String) {
        addSubview(primaryStack)
        addSubview(separatorLine)
        
        primaryStack.backgroundColor = .white
        primaryStack.fillSuperview()
        primaryStack.addArrangedSubview(iconButton)
        primaryStack.addArrangedSubview(contentStackView)
        
        contentStackView.addArrangedSubview(nameAndDateStack)
        nameAndDateStack.addArrangedSubview(senderNameLabel)
        nameAndDateStack.addArrangedSubview(dateLabel)
        
        contentStackView.addArrangedSubview(fileNameStack)
        fileNameStack.addArrangedSubview(fileNameLabel)
        fileNameStack.addArrangedSubview(fileSizeLabel)
        
        activateConstraints()
        configure(mimeType: mimeType, sender: sender, date: date, time: time, sizeInBytes: sizeInBytes, filename: filename)
    }
    
    
    
    internal func configure(mimeType: String, sender: String, date: String, time: String, sizeInBytes: String, filename: String) {
        senderNameLabel.text = sender
        dateLabel.text = date + ", " + time
        fileNameLabel.text = filename
        fileSizeLabel.text = ", " + sizeInBytes
        

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
        }
    }
    
    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            contentStackView.heightAnchor.constraint(equalToConstant: 46),
            
            iconButton.widthAnchor.constraint(equalToConstant: 44),
            iconButton.heightAnchor.constraint(equalToConstant: 44),
            
            senderNameLabel.leftAnchor.constraint(equalTo: nameAndDateStack.leftAnchor),
            dateLabel.rightAnchor.constraint(equalTo: nameAndDateStack.rightAnchor),
            
            fileNameLabel.leftAnchor.constraint(equalTo: fileNameStack.leftAnchor),
            fileSizeLabel.leftAnchor.constraint(equalTo: fileNameLabel.rightAnchor),
            fileSizeLabel.rightAnchor.constraint(equalTo: fileNameStack.rightAnchor),
            
            separatorLine.leftAnchor.constraint(equalTo: nameAndDateStack.leftAnchor),
//            separatorLine.rightAnchor.constraintEq(equalToC: contentStackView.frame.width),
            separatorLine.widthAnchor.constraint(equalToConstant: separatorLine.superview!.frame.width - iconButton.frame.width - 2 * InfoScreenFooterView.cellSpacing),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }
}
