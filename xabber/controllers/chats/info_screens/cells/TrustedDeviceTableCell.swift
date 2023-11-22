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

class TrustedDeviceTableCell: UITableViewCell {
    
    static let cellName = "TrusteddDeviceInfoTableCell"
    
    open var deviceId: Int = 0
    
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
        stack.distribution = .equalSpacing
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
    
    var fingerprintLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = MDCPalette.grey.tint700
        label.numberOfLines = 2
        return label
    }()
    
    var stateLabel: UILabel = {
        let label = UILabel()
        label.text = " "
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = MDCPalette.grey.tint700
        return label
    }()
    
    var stateSwitch: UISwitch = {
        let view = UISwitch()
        
        return view
    }()
    
    var signedLabel: UILabel = {
        let label = UILabel()
        
        label.text = "Signed"
        label.textColor = .systemGreen
        label.isHidden = true
        label.textAlignment = .right
        
        return label
    }()
    
    open var callback: ((Bool, Int) -> Void)? = nil
    
    private func activateConstraints() {
        topStack.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9).isActive = true
        deviceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9).isActive = true
        fingerprintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9).isActive = true
    }
    
    func configure(name: String, state: SignalDeviceStorageItem.TrustState, fingerprint: String, devieId: String, editable: Bool, signed: Bool = false) {
        if state == .trusted {
            stateSwitch.isOn = true
        } else {
            stateSwitch.isOn = false
        }
        if signed {
            stateSwitch.isHidden = true
            signedLabel.isHidden = false
        } else {
            stateSwitch.isHidden = false
            signedLabel.isHidden = true
        }
        fingerprintLabel.text = fingerprint
        if #available(iOS 13.0, *) {
            fingerprintLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .light)
        } else {
            // Fallback on earlier versions
        }
        clientLabel.text = name
        deviceLabel.text = devieId
        if !signed {
            self.stateSwitch.isHidden = !editable
        }
    }
    
    func setupSubviews() {
        contentView.addSubview(stack)
        contentView.bringSubviewToFront(stack)
        stack.fillSuperview()
        
        topStack.addArrangedSubview(clientLabel)
        topStack.addArrangedSubview(stateSwitch)
        topStack.addArrangedSubview(signedLabel)
        
        stack.addArrangedSubview(topStack)
        stack.addArrangedSubview(fingerprintLabel)
        stack.addArrangedSubview(deviceLabel)
        activateConstraints()
        stateSwitch.addTarget(self, action: #selector(onStateChange), for: .valueChanged)
        selectionStyle = .none
    }
    
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .value1, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
    
    @objc
    private final func onStateChange(_ sender: UISwitch) {
        self.callback?(sender.isOn, self.deviceId)
    }
}

