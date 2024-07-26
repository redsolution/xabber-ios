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

class InlineCallGridView: InlineMediaBaseView {
    
    class CallView: UIView {
                
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 4, left: 6, right: 6)
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            
//            button.backgroundColor = MDCPalette.grey.tint300
//            button.tintColor = MDCPalette.grey.tint700
//            button.layer.cornerRadius = button.frame.width / 2
//            button.layer.masksToBounds = true
//            button.imageEdgeInsets = UIEdgeInsets(square: 10)
            
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
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
//            label.textColor = MDCPalette.grey.tint700
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            
            return label
        }()
        
        let subtitleButton: UIButton = {
            let button = UIButton()
            
            if #available(iOS 13.0, *) {
                button.setTitleColor(.secondaryLabel, for: .normal)
            } else {
                button.setTitleColor(.gray, for: .normal)
            }
            
            button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .regular)
//            button.imageEdgeInsets = UIEdgeInsets(square: 2)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 0)
            button.contentMode = .scaleAspectFit
            button.contentHorizontalAlignment = .left
            
            return button
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
            stack.addArrangedSubview(contentStack)
            stack.addArrangedSubview(iconButton)
            contentStack.addArrangedSubview(titleLabel)
            contentStack.addArrangedSubview(subtitleButton)
            NSLayoutConstraint.activate([
                iconButton.widthAnchor.constraint(equalToConstant: 36),
                iconButton.heightAnchor.constraint(equalToConstant: 36),
                subtitleButton.heightAnchor.constraint(equalToConstant: 18),
                subtitleButton.widthAnchor.constraint(equalToConstant: 108)
            ])
        }
        
        public func configure(outgoing: Bool, duration: TimeInterval?, callState: String, date: Date, color: UIColor) {
            let state = MessageStorageItem.VoIPCallState(rawValue: callState) ?? .none
            if outgoing {
                titleLabel.text = "Outgoing call".localizeString(id: "chat_message_outgoing", arguments: [])
            } else {
                titleLabel.text = "Incoming call".localizeString(id: "chat_message_incoming", arguments: [])
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let dateString = formatter.string(from: date)
//            if #available(iOS 13.0, *) {
//                iconButton.tintColor = .secondaryLabel
//            } else {
                iconButton.tintColor = color
//            }
            subtitleButton.setTitleColor(color, for: .normal)
            subtitleButton.setImage(imageLiteral("phone.arrow.down.left.fill")?.withRenderingMode(.alwaysTemplate).resize(targetSize: CGSize(square: 12)), for: .normal)
            iconButton.setImage(imageLiteral("phone.fill"), for: .normal)
            
            switch state {
            case .missed:
                subtitleButton.setTitle(dateString, for: .normal)
                titleLabel.text = "Missed call".localizeString(id: "chat_message_missed_call", arguments: [])
            case .noanswer, .busy:
//                iconButton.setImage(imageLiteral( "call-noanswer").withRenderingMode(.alwaysTemplate), for: .normal)
                subtitleButton.setTitle(dateString, for: .normal)
                titleLabel.text = "Cancelled call".localizeString(id: "chat_message_cancelled_call", arguments: [])
            case .made:
//                iconButton.setImage(imageLiteral( "call-made").withRenderingMode(.alwaysTemplate), for: .normal)
                if let duration = duration,
                   duration > 0 {
                    subtitleButton.setTitle(
                        [dateString, duration.prettyMinuteFormatedString].joined(separator: ", "),
                        for: .normal
                    )
                } else {
                    subtitleButton.setTitle(dateString, for: .normal)
                }
            case .received:
//                iconButton.setImage(imageLiteral( "call-received").withRenderingMode(.alwaysTemplate), for: .normal)
                if let duration = duration,
                   duration > 0 {
                    subtitleButton.setTitle(
                        [dateString, duration.minuteFormatedString].joined(separator: ", "),
                        for: .normal
                    )
                } else {
                    subtitleButton.setTitle(dateString, for: .normal)
                }
            case .none:
                subtitleButton.setTitle(dateString, for: .normal)
//                iconButton.setImage(imageLiteral( "call-outline").withRenderingMode(.alwaysTemplate), for: .normal)
            }
        }
    }
    
    public var tintViewColor: UIColor = .blue
    
    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = 48
        var offset: CGFloat = padding
        return references
//            .filter { [.call].contains($0.kind) }
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
        grid.removeAll()
        let items = references
        prepareGrid(items).enumerated().forEach {
            index, cell in
//            print(cell)
            if let outgoing =   items[index].metadata?["outgoing"] as? Bool,
                let callState = items[index].metadata?["callState"] as? String {
                let duration =  items[index].metadata?["duration"] as? TimeInterval
                let dateInterval = items[index].metadata?["date"] as? TimeInterval ?? Date().timeIntervalSince1970
                let date = Date(timeIntervalSince1970: dateInterval)
                let view = CallView(frame: cell)
                view.configure(
                    outgoing: outgoing,
                    duration: duration,
                    callState: callState,
                    date: date,
                    color: tintViewColor
                )
                addSubview(view)
                grid.append(GridItem(cell: cell, url: nil))
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
