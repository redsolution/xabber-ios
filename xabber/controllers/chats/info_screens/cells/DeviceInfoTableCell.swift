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

class DeviceInfoTableCell: UITableViewCell {
    
    static let cellName = "DeviceInfoTableCell"
    
    var stack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.spacing = 8
        return stack
    }()
    
    var leftStack: UIStackView = {
        let stack = UIStackView()

        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 4

        return stack
    }()

    var rightStack: UIStackView = {
        let stack = UIStackView()

        stack.axis = .horizontal

        return stack
    }()

    
    var clientLabel: UILabel = {
        let label = UILabel()
        label.text = " "
//        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = MDCPalette.grey.tint900
        return label
    }()
        
    var descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = MDCPalette.grey.tint700
        return label
    }()
    
    var authDateLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = MDCPalette.grey.tint700
        label.textAlignment = .right
        return label
    }()
    
    var trustIconView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 24))
        
        return view
    }()
    
    private func activateConstraints() {
        NSLayoutConstraint.activate([
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
            rightStack.widthAnchor.constraint(equalToConstant: 20),
        ])
    }
    
    func configure(fingerprint: String? = nil, client: String, device: String, description descr: String, ip: String, lastAuth date: Date?, current: Bool, editable: Bool, isOnline: Bool, trustState: SignalDeviceStorageItem.TrustState? = nil, hasBundle: Bool? = nil, isTrustebByCertificate: Bool = false, trustedBy: String? = nil) {
        
        if trustedBy != nil {
            descriptionLabel.text = "\(ip) ⦁ trusted via: \(trustedBy!)"
        } else if date != nil {
            let today = Date()
            
            var dateString = "Unknown"
            
            let diffComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!, to: today)
            let year = diffComponents.year ?? 0
            let month = diffComponents.month ?? 0
            let day = diffComponents.day ?? 0
            let hour = diffComponents.hour ?? 0
            let minutes = diffComponents.minute ?? 0
            let seconds = diffComponents.second ?? 0
            if year > 0 {
                dateString = "\(year) year ago"
            } else if month > 0 {
                dateString = "\(month) month ago"
            } else if day > 0 {
                dateString = "\(day) days ago"
            } else if hour > 0 {
                dateString = "\(hour) hours ago"
            } else if minutes > 0 {
                dateString = "\(minutes) min ago"
            } else if seconds > 0 {
                dateString = "\(seconds) seconds ago"
            }
            
            descriptionLabel.text = "\(ip) ⦁ \(dateString)"
        } else if trustState == .trusted {
            descriptionLabel.text = "\(ip) ⦁ trusted by code"
        } else {
            descriptionLabel.text = "\(ip)"
        }
        
        if device.isNotEmpty {
            clientLabel.text = device//[client, device].joined(separator: ", ")
        } else {
            clientLabel.text = client//[client, device].joined(separator: "")
        }
        
        clientLabel.textColor = MDCPalette.grey.tint900
        descriptionLabel.textColor = MDCPalette.grey.tint700
        
        if let trustState = trustState {
            self.trustIconView.isHidden = false
            
            switch trustState {
                case .unknown:
                    self.trustIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
                    self.trustIconView.tintColor = .systemOrange
                    self.authDateLabel.text = "Action required"
                    self.authDateLabel.textColor = .systemOrange
                case .ignore:
                    self.trustIconView.tintColor = .gray
                case .trusted:
                    if isTrustebByCertificate {
                        self.trustIconView.image = UIImage(systemName: "lock.circle.fill")?.withRenderingMode(.alwaysTemplate)
                    } else {
                        self.trustIconView.image = UIImage(systemName: "lock.fill")?.withRenderingMode(.alwaysTemplate)
                    }
                    
                    self.authDateLabel.text = isTrustebByCertificate ? " Signed" : " Trusted"
                    self.authDateLabel.textColor = .systemGreen
                    self.trustIconView.tintColor = .systemGreen
                case .fingerprintChanged:
                    self.trustIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
                    self.trustIconView.tintColor = .systemRed
                    self.authDateLabel.text = "Fingerprint changed"
                    self.authDateLabel.textColor = .systemRed
                    self.descriptionLabel.textColor = .systemRed
                    self.clientLabel.textColor = .systemRed
            }
        } else {
            if let hasBundle = hasBundle,
               !hasBundle  {
                self.trustIconView.isHidden = false
                self.trustIconView.image = nil//UIImage(systemName: "lock.fill")?.withRenderingMode(.alwaysTemplate)
                self.trustIconView.tintColor = .systemGray
                self.authDateLabel.text = "Encryption not enabled"
                self.authDateLabel.textColor = .systemGray
            } else {
                self.trustIconView.isHidden = true
            }
        }
        
        
        
        if editable {
            accessoryType = .disclosureIndicator
        } else {
            selectionStyle = .none
        }
        
        activateConstraints()
    }
    
    func setup() {
        contentView.addSubview(stack)
        contentView.bringSubviewToFront(stack)
        stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 16, right: 10)
        
        
        leftStack.addArrangedSubview(clientLabel)
        leftStack.addArrangedSubview(descriptionLabel)
//        rightStack.addArrangedSubview(UIStackView())
        rightStack.addArrangedSubview(trustIconView)
        
        stack.addArrangedSubview(leftStack)
        stack.addArrangedSubview(rightStack)
        
        activateConstraints()
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setup()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setup()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
