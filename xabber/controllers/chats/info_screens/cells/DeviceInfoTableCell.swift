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
        stack.alignment = .leading
        stack.axis = .vertical
        stack.distribution = .equalCentering
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 10, bottom: 12, left: 20, right: 16)
        return stack
    }()
    
    var topStack: UIStackView = {
        let stack = UIStackView()
//            stack.alignment = .leading
        stack.axis = .horizontal
//        stack.distribution = .equalSpacing
//            stack.spacing = 16
        return stack
    }()
    
    var clientLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = MDCPalette.grey.tint900
        return label
    }()
    
    var deviceLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
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
            topStack.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
            deviceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
            trustIconView.widthAnchor.constraint(equalToConstant: 24),
            trustIconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    
    func configure(fingerprint: String? = nil, client: String, device: String, description descr: String, ip: String, lastAuth: Date, current: Bool, editable: Bool, isOnline: Bool, trustState: SignalDeviceStorageItem.TrustState? = nil, hasBundle: Bool? = nil) {
        let dateFormatter = DateFormatter()
        if Calendar.current.isDateInToday(lastAuth) {
            dateFormatter.dateStyle = .none
            dateFormatter.timeStyle = .short
        } else {
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
        }
        
        clientLabel.text = descr.isNotEmpty ? descr : client
        if let fingerprint = fingerprint {
            self.deviceLabel.numberOfLines = 2
            self.deviceLabel.text = fingerprint
        } else {
            deviceLabel.numberOfLines = 1
            if device.isNotEmpty {
                deviceLabel.text = [client, device].joined(separator: ", ")
            } else {
                deviceLabel.text = [client, device].joined(separator: "")
            }
        }
        
        if isOnline {
            authDateLabel.text = "Online".localizeString(id: "account_state_connected", arguments: [])
            authDateLabel.textColor = .systemBlue
        } else {
            authDateLabel.text = dateFormatter.string(from: lastAuth)
            authDateLabel.textColor = MDCPalette.grey.tint700
        }
        
        if let trustState = trustState {
            self.trustIconView.isHidden = false
            self.trustIconView.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
            switch trustState {
            case .unknown:
                self.trustIconView.tintColor = .systemOrange
                self.authDateLabel.text = "Action required"
                self.authDateLabel.textColor = .systemOrange
            case .Ignore:
                self.trustIconView.tintColor = .gray
            case .trusted:
                self.authDateLabel.text = (self.authDateLabel.text ?? "") + " Trusted"
                self.authDateLabel.textColor = .systemGreen
                self.trustIconView.tintColor = .systemGreen
            case .fingerprintChanged:
                self.trustIconView.tintColor = .systemRed
                self.authDateLabel.text = "Action required"
                self.authDateLabel.textColor = .systemRed
            }
        } else {
            if let hasBundle = hasBundle,
               !hasBundle  {
                self.trustIconView.isHidden = false
                self.trustIconView.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
                self.trustIconView.tintColor = .systemGray
                self.authDateLabel.text = "Encryption not enabled"
                self.authDateLabel.textColor = .systemGray
            } else {
                self.trustIconView.isHidden = true
            }
        }
        
        descriptionLabel.text = ip
        
        
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
        stack.fillSuperview()
        
        topStack.addArrangedSubview(clientLabel)
        topStack.addArrangedSubview(authDateLabel)
        topStack.addArrangedSubview(trustIconView)
        
        stack.addArrangedSubview(topStack)
        stack.addArrangedSubview(deviceLabel)
        stack.addArrangedSubview(descriptionLabel)
        
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
