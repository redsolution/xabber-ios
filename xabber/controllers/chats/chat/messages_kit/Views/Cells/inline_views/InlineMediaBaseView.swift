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

struct InlineAttachmentRepresentedRequest: Hashable {
    let containerPrimary: String
    let referencePrimary: String
    let resourceIdentity: String
}

//class InlineMediaBaseView: UIView {
//    struct GridItem {
//        let cell: CGRect
//        let url: URL?
//    }
//    
//    var contentViews: [UIView] = []
//    
//    var grid: [GridItem] = []
//    var messageId: String? = nil
//    
//    internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
//        return []
//    }
//    
//    func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
//        self.grid = []
//        self.messageId = nil
//    }
//    
//    func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
//        
//    }
//}

public class InlineAttachmentView: ModernContainerView {
    struct GridItem {
        let cell: CGRect
        let url: URL?
    }
    
    var contentViews: [UIView] = []
    
    var grid: [GridItem] = []
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SensitiveMediaOverlayView: UIControl {
    private let blurOverlay: UIVisualEffectView = {
        let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        effectView.isUserInteractionEnabled = false
        return effectView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Sensitive Content".localizeString(id: "sensitive_media_overlay_title", arguments: [])
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "This media may contain sensitive content.".localizeString(id: "sensitive_media_overlay_body", arguments: [])
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let viewLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "View".localizeString(id: "sensitive_media_overlay_view", arguments: [])
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 1
        label.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        label.layer.borderWidth = 1
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        return label
    }()

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurOverlay.frame = bounds
    }

    private func setup() {
        isAccessibilityElement = true
        accessibilityIdentifier = "sensitive_media_overlay"
        accessibilityLabel = "Sensitive Content".localizeString(id: "sensitive_media_overlay_title", arguments: [])
        accessibilityHint = "View".localizeString(id: "sensitive_media_overlay_view", arguments: [])
        addSubview(blurOverlay)
        addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(bodyLabel)
        stack.addArrangedSubview(viewLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            viewLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            viewLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
    }
}
