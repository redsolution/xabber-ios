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
import RxSwift
import MaterialComponents.MDCPalettes

class CallScreenFingerprintViewPopover: UIViewController {
    
    internal let mainStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.distribution = .equalCentering
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return stack
    }()
    
    internal var ownerFp: UILabel = {
        let label = UILabel()
        label.text = nil//CallManager.shared.ownerFingerprint.value.split(separator: ":").joined(separator: " ")
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 5
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint700
        return label
    }()
    
    
    internal var opponentFp: UILabel = {
        let label = UILabel()
        label.text = nil//CallManager.shared.opponentfingerprint.value.split(separator: ":").joined(separator: " ")
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 5
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint700
        return label
    }()
    
    private func configure() {
        view.addSubview(mainStack)
        mainStack.fillSuperview()
        
        let ownerStack = UIStackView()
        ownerStack.axis = .vertical
        ownerStack.alignment = .leading
        ownerStack.distribution = .equalSpacing
        ownerStack.spacing = 8
        let ownerFpDescription = UILabel()
//        ownerFpDescription.text = "\(CallManager.shared.call?.owner ?? "") fingerprint:"
        ownerFpDescription.font = UIFont.preferredFont(forTextStyle: .caption1)
        ownerFpDescription.textColor = MDCPalette.grey.tint900
        ownerStack.addArrangedSubview(ownerFpDescription)
        ownerStack.addArrangedSubview(ownerFp)
        
        let opponentStack = UIStackView()
        opponentStack.axis = .vertical
        opponentStack.alignment = .leading
        opponentStack.distribution = .equalSpacing
        opponentStack.spacing = 8
        let opponentFpDescription = UILabel()
//        opponentFpDescription.text = "\(CallManager.shared.call?.opponent.bare ?? "") fingerprint:"
        opponentFpDescription.font = UIFont.preferredFont(forTextStyle: .caption1)
        opponentFpDescription.textColor = MDCPalette.grey.tint900
        opponentStack.addArrangedSubview(opponentFpDescription)
        opponentStack.addArrangedSubview(opponentFp)
        
        mainStack.addArrangedSubview(ownerStack)
        mainStack.addArrangedSubview(opponentStack)

    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
//        view.backgroundColor = .white
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
