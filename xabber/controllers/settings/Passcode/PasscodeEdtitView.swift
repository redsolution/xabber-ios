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

extension UIStackView {
    func removeAllArrangedSubviews() {
        let removedSubviews = arrangedSubviews.reduce([]) { (allSubviews, subview) -> [UIView] in
            self.removeArrangedSubview(subview)
            return allSubviews + [subview]
        }
        NSLayoutConstraint.deactivate(removedSubviews.flatMap({ $0.constraints }))
        removedSubviews.forEach({ $0.removeFromSuperview() })
    }
}

class PasscodeEdtitView: UIView, UITextInputTraits {
    
    class Pin: UIView {
        
        let pin = UIView()
        let diameter: CGFloat = 19.0
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupUI()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupUI() {
            pin.backgroundColor = .black
            pin.layer.cornerRadius = diameter / 2.0
            pin.layer.borderWidth = 1
            pin.layer.borderColor = UIColor.black.cgColor
            pin.layer.masksToBounds = true
            pin.translatesAutoresizingMaskIntoConstraints = false
            self.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pin)
            NSLayoutConstraint.activate([pin.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                                         pin.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                                         pin.widthAnchor.constraint(equalToConstant: diameter),
                                         pin.heightAnchor.constraint(equalToConstant: diameter)
                                        ])
        }
    }
    
    var code: String = "" {
        didSet {
            updateStack(by: code)
            if code.count == maxLength, let didFinishedEnterCode = didFinishedEnterCode {
                self.resignFirstResponder()
                didFinishedEnterCode(code)
            }
        }
    }
    
    var didFinishedEnterCode: ((String) -> Void)?
    
    
    var maxLength = 6
    var keyboardType: UIKeyboardType = .numberPad
    let stack = UIStackView()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        showKeyboardIfNeeded()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setupUI() {
        addSubview(stack)
        self.backgroundColor = .clear
        stack.backgroundColor = .clear
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: self.topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
                                    ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        updateStack(by: code)
    }
    
    func updateStack(by code: String) {
        var emptyPins: [UIView] = Array(0..<maxLength).map { _ in emptyPin() }
        let userPinLength = code.count
        let pins: [UIView] = Array(0..<userPinLength).map { _ in pin() }
        
        for (index, element) in pins.enumerated() {
            emptyPins[index] = element
        }
        stack.removeAllArrangedSubviews()
        for view in emptyPins {
            stack.addArrangedSubview(view)
        }
        
    }
    
    private func emptyPin() -> UIView {
        let pin = Pin()
        pin.pin.backgroundColor = .clear
        return pin
    }
    
    private func pin() -> UIView {
        let pin = Pin()
        pin.pin.backgroundColor = .black
        return pin
    }

}

extension PasscodeEdtitView {
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    private func showKeyboardIfNeeded() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showKeyboard))
        self.addGestureRecognizer(tapGesture)
    }
    
    @objc private func showKeyboard() {
        self.becomeFirstResponder()
    }
}

extension PasscodeEdtitView: UIKeyInput {
    var hasText: Bool {
        return code.count > 0
    }
    
    func insertText(_ text: String) {
        let characterSet = CharacterSet(charactersIn: text)
        guard code.count < maxLength,
              CharacterSet.decimalDigits.isSuperset(of: characterSet) else {
            return
        }
        code.append(contentsOf: text)
        print(code)
    }
    
    func deleteBackward() {
        if hasText {
            code.removeLast()
        }
        print(code)
    }
}
