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
    private var didActivateStaticConstraints = false
    
    var stack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.spacing = 8
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }()
    
    var leftStack: UIStackView = {
        let stack = UIStackView()

        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 4
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return stack
    }()

    var rightStack: UIStackView = {
        let stack = UIStackView()

        stack.axis = .horizontal
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .horizontal)

        return stack
    }()
    
    var clientLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = MDCPalette.grey.tint900
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
        
    var descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint700
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    var authDateLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint700
        label.textAlignment = .right
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }()
    
    var trustIconView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 24))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .horizontal)
        
        return view
    }()
    
    let customImageView: UIImageView = {
        let imageView = UIImageView(frame: CGRect(square: 40))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        return imageView
    }()
    
    private func activateConstraints() {
        guard !didActivateStaticConstraints else {
            return
        }
        didActivateStaticConstraints = true

        NSLayoutConstraint.activate([
//            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
            rightStack.widthAnchor.constraint(equalToConstant: 24),
            trustIconView.widthAnchor.constraint(equalToConstant: 24),
            trustIconView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    
    func configure(fingerprint: String? = nil, client: String, device: String, description descr: String, ip: String, lastAuth date: Date?, current: Bool, editable: Bool, isOnline: Bool, trustState: SignalDeviceStorageItem.TrustState? = nil, hasBundle: Bool? = nil, isTrustebByCertificate: Bool = false, trustedBy: String? = nil) {
        resetConfigurationState()

        if trustedBy == "manual" {
            descriptionLabel.text = L10n.format(
                "device_info__text__trusted_manually",
                fallback: "%@ ⦁ trusted manually",
                arguments: [String(describing: ip)]
            )
        } else if trustedBy != nil {
            descriptionLabel.text = L10n.format("device_info__text__value_trusted_via_value", fallback: "%1$@ ⦁ trusted via %2$@", arguments: [String(describing: ip), String(describing: trustedBy!)])
        } else if date != nil {
            let formatter = L10n.formatters.relativeDateTimeFormatter()
            let dateString = formatter.localizedString(for: date!, relativeTo: Date())
            descriptionLabel.text = L10n.format(
                "device_info__text__last_authenticated_format",
                fallback: "%1$@ ⦁ %2$@",
                arguments: [String(describing: ip), String(describing: dateString)]
            )
        } else if trustState == .trusted {
            descriptionLabel.text = L10n.format("device_info__text__value_trusted_by_code", fallback: "%@ ⦁ trusted by code", arguments: [String(describing: ip)])
        } else {
            descriptionLabel.text = "\(ip)"
        }
        
        if device.lowercased().contains("iphone") {
            self.imageView?.image = imageLiteral("iphone.gen1")?.withTintColor(.systemBlue)
        } else if device.lowercased().contains("ipad") {
            self.imageView?.image = imageLiteral("ipad.gen1")?.withTintColor(.systemBlue).withRenderingMode(.alwaysOriginal)
        } else if device.lowercased().contains("pc,") {
            self.imageView?.image = imageLiteral("display")?.withTintColor(.systemBlue).withRenderingMode(.alwaysOriginal)
        } else {
            self.imageView?.image = imageLiteral("questionmark.app.dashed")?.withTintColor(.systemBlue).withRenderingMode(.alwaysOriginal)
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
                case .unknown, .distrusted:
                    self.trustIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
                    self.trustIconView.tintColor = .systemOrange
                    self.authDateLabel.text = L10n.text("device__cell__action_required", fallback: "Action required")
                    self.authDateLabel.textColor = .systemOrange
                case .ignore:
                    self.trustIconView.tintColor = .gray
                case .trusted:
                    if isTrustebByCertificate {
                        self.trustIconView.image = UIImage(systemName: "lock.circle.fill")?.withRenderingMode(.alwaysTemplate)
                    } else {
                        self.trustIconView.image = UIImage(systemName: "lock.fill")?.withRenderingMode(.alwaysTemplate)
                    }
                    
                    self.authDateLabel.text = isTrustebByCertificate ? L10n.text("device_info__text__signed", fallback: " Signed") : L10n.text("device_info__text__trusted", fallback: " Trusted")
                    self.authDateLabel.textColor = .systemGreen
                    self.trustIconView.tintColor = .systemGreen
                case .fingerprintChanged, .revoked:
                    self.trustIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
                    self.trustIconView.tintColor = .systemRed
                    self.authDateLabel.text = L10n.text("device__cell__fingerprint_changed", fallback: "Fingerprint changed")
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
                self.authDateLabel.text = L10n.text("device__cell__encryption_not_enabled", fallback: "Encryption not enabled")
                self.authDateLabel.textColor = .systemGray
            } else {
                self.trustIconView.isHidden = true
            }
        }
        
        
        
        if editable {
            accessoryType = .disclosureIndicator
            selectionStyle = .default
        } else {
            accessoryType = .none
            selectionStyle = .none
        }
        
        updateAccessibilityLabel(
            client: client,
            device: device,
            current: current,
            editable: editable,
            isOnline: isOnline,
            trustState: trustState,
            hasBundle: hasBundle,
            isTrustebByCertificate: isTrustebByCertificate
        )
        activateConstraints()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetConfigurationState()
    }

    private func resetConfigurationState() {
        clientLabel.text = " "
        descriptionLabel.text = " "
        authDateLabel.text = " "
        clientLabel.textColor = MDCPalette.grey.tint900
        descriptionLabel.textColor = MDCPalette.grey.tint700
        authDateLabel.textColor = MDCPalette.grey.tint700
        trustIconView.isHidden = true
        trustIconView.image = nil
        trustIconView.tintColor = .systemGray
        accessoryType = .none
        selectionStyle = .default
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
    }

    private func updateAccessibilityLabel(client: String, device: String, current: Bool, editable: Bool, isOnline: Bool, trustState: SignalDeviceStorageItem.TrustState?, hasBundle: Bool?, isTrustebByCertificate: Bool) {
        var parts: [String] = [L10n.text("device__accessibility__session", fallback: "Device session")]
        let title = device.isNotEmpty ? device : client
        if title.isNotEmpty {
            parts.append(title)
        }
        if client.isNotEmpty && client != title {
            parts.append(client)
        }
        if let details = descriptionLabel.text,
           details.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
            parts.append(details)
        }
        parts.append(isOnline ? L10n.text("device__accessibility__online", fallback: "Online") : L10n.text("device__accessibility__offline", fallback: "Offline"))
        if current {
            parts.append(L10n.text("device__accessibility__this_device", fallback: "This device"))
        }

        switch trustState {
        case .unknown, .distrusted:
            parts.append(L10n.text("device__accessibility__action_required", fallback: "Action required"))
        case .ignore:
            parts.append(L10n.text("device__accessibility__ignored", fallback: "Ignored"))
        case .trusted:
            parts.append(isTrustebByCertificate ? L10n.text("device__accessibility__signed", fallback: "Signed") : L10n.text("device__accessibility__trusted", fallback: "Trusted"))
        case .fingerprintChanged:
            parts.append(L10n.text("device__accessibility__fingerprint_changed", fallback: "Fingerprint changed"))
        case .revoked:
            parts.append(L10n.text("device__accessibility__revoked", fallback: "Revoked"))
        case nil:
            if hasBundle == false {
                parts.append(L10n.text("device__accessibility__encryption_not_enabled", fallback: "Encryption not enabled"))
            }
        }

        isAccessibilityElement = true
        accessibilityLabel = parts.joined(separator: ", ")
        accessibilityTraits = editable ? .button : .staticText
    }
    
    func setup() {
        contentView.addSubview(stack)
        contentView.bringSubviewToFront(stack)
        stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 65, right: 10)
        
        leftStack.addArrangedSubview(clientLabel)
        leftStack.addArrangedSubview(descriptionLabel)
        
        rightStack.addArrangedSubview(trustIconView)
        
//        stack.addArrangedSubview(customImageView)
        stack.addArrangedSubview(leftStack)
        stack.addArrangedSubview(rightStack)
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
