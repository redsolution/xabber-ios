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
import RxCocoa
import RxSwift

class UITextFiledWithShadow: UITextField {
    
    private var shadowLayer: CAShapeLayer!
    
    internal let button: UIButton = {
        let button = UIButton(frame: CGRect(square: 28))
        
        button.tintColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        button.isHidden = true
        
        return button
    }()
    

    
    func configure() {
        self.addSubview(button)
        self.bringSubviewToFront(button)
    }
    
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        button.frame = CGRect(
            origin: CGPoint(x: self.frame.size.width - 36, y: 8),
            size: CGSize(square: 28)
        )
        self.bringSubviewToFront(button)
        
        if shadowLayer == nil {
            shadowLayer = CAShapeLayer()
            shadowLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
            shadowLayer.fillColor = UIColor.white.cgColor

            shadowLayer.shadowColor = MDCPalette.grey.tint400.cgColor
            shadowLayer.shadowPath = shadowLayer.path
            shadowLayer.shadowOffset = CGSize(width: 0.0, height: 1.0)
            if isSelected {
                shadowLayer.shadowOpacity = 0.6
                shadowLayer.shadowRadius = 4
                layer.insertSublayer(shadowLayer, at: 0)
            } else {
                shadowLayer.shadowOpacity = 0.42
                shadowLayer.shadowRadius = 1.5
                layer.insertSublayer(shadowLayer, at: 0)
            }
                
        } else {
            if isSelected {
                shadowLayer.shadowOpacity = 0.6
                shadowLayer.shadowRadius = 4
                
            } else {
                shadowLayer.shadowOpacity = 0.42
                shadowLayer.shadowRadius = 1.5
            }
        }
    }
}

class VerticalTopAlignLabel: UILabel {

    override func drawText(in rect:CGRect) {
        guard let labelText = text else {  return super.drawText(in: rect) }

        let attributedText = NSAttributedString(string: labelText, attributes: [NSAttributedString.Key.font: font ?? UIFont.systemFont(ofSize: 14)])
        var newRect = rect
        newRect.size.height = attributedText.boundingRect(with: rect.size, options: .usesLineFragmentOrigin, context: nil).size.height

        if numberOfLines != 0 {
            newRect.size.height = min(newRect.size.height, CGFloat(numberOfLines) * font.lineHeight)
        }

        super.drawText(in: newRect)
    }

}

class SignUpBaseViewController: SimpleBaseViewController {
    
    let container: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        return stack
    }()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        stack.spacing = 16
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        return label
    }()
    
    let textField: UITextFiledWithShadow = {
        let field = UITextFiledWithShadow()
        
        field.textAlignment = .center
        field.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        return field
    }()
    
    let subtitleLabel: VerticalTopAlignLabel = {
        let label = VerticalTopAlignLabel()
                
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        
        return label
    }()
    
    let button: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        return button
    }()
    
    let secondaryButton: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        button.isHidden = true
        
        return button
    }()
    
    public var metadata: [String: String] = [:]
    
    public var textFieldValueObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    public var textFieldValue: String = ""
    
    private final func doAnimationsBlock(animated: Bool, block: @escaping (() -> Void)) {
        if animated {
            UIView.animate(
                withDuration: 0.33,
                delay: 0.0,
                options: [.curveEaseIn],
                animations: block,
                completion: nil
            )
        } else {
            UIView.performWithoutAnimation(block)
        }
    }
    
    public final func makeSecondaryButtonEnabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.secondaryButton.isHidden = false
            self.secondaryButton.isEnabled = true
            self.secondaryButton.backgroundColor = .systemBlue
            self.secondaryButton.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeSecondaryButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.secondaryButton.isHidden = true
            self.secondaryButton.isEnabled = false
            self.secondaryButton.backgroundColor = MDCPalette.grey.tint100
            self.secondaryButton.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    public final func makeButtonEnabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.button.isEnabled = true
            self.button.backgroundColor = .systemBlue
            self.button.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.button.isEnabled = false
            self.button.backgroundColor = MDCPalette.grey.tint100
            self.button.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    public func setupPlaceholder(_ string: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        self.textField.attributedPlaceholder = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            NSAttributedString.Key.foregroundColor: UIColor.black.withAlphaComponent(0.23),
            NSAttributedString.Key.paragraphStyle: paragraph
        ])
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(container)
        
        var offset: CGFloat = 0
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                offset += topOffset
            }
        }
        let displayHeigth = UIScreen.main.bounds.height
        container.fillSuperviewWithOffset(top: view.safeAreaInsets.top + displayHeigth * 0.1 + offset, bottom: 0, left: 48, right: 48)
        
        //container.fillSuperviewWithOffset(top: view.safeAreaInsets.top + 132, bottom: 0, left: 48, right: 48)
        container.addArrangedSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(textField)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(secondaryButton)
        stack.addArrangedSubview(UIStackView())
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        let constraints: [NSLayoutConstraint] = [
            stack.widthAnchor.constraint(equalToConstant: 375),
            textField.heightAnchor.constraint(equalToConstant: 44),
            textField.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            textField.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            button.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            secondaryButton.heightAnchor.constraint(equalToConstant: 44),
            secondaryButton.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            secondaryButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            subtitleLabel.heightAnchor.constraint(equalToConstant: 64),
        ]
        NSLayoutConstraint.activate(constraints)
        stack.setCustomSpacing(24, after: titleLabel)
    }
    
    override func configure() {
        super.configure()
        self.navigationController?.navigationBar.prefersLargeTitles = false
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.setNeedsLayout()
        self.makeButtonDisabled(false)
        self.textField.delegate = self
        self.textField.becomeFirstResponder()
        self.button.addTarget(self, action: #selector(self.onButtonTouchUpSelector), for: .touchUpInside)
        self.secondaryButton.addTarget(self, action: #selector(self.onSecondaryButtonTouchUpSelector), for: .touchUpInside)
        self.textField.addTarget(self, action: #selector(self.onTextFieldDidChangeSelector), for: .editingChanged)
    }
    
    override func subscribe() {
        super.subscribe()

        textFieldValueObserver
            .asObservable()
            .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.validateTextFiled(value: value) { result in
                    DispatchQueue.main.async {
                        if result {
                            self.makeButtonEnabled(true)
                        } else {
                            self.makeButtonDisabled(true)
                        }
                    }
                }
                if let value = value {
                    self.textFieldValue = value
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)

    }
    
    override func unsubscribe() {
        super.unsubscribe()
    }
    
    func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        callback(true)
    }
    
    func onButtonTouchUp() {
        FeedbackManager.shared.tap()
        title = " "
        self.navigationController?.title = " "
    }
    
    @objc
    private final func onButtonTouchUpSelector(_ sender: UIButton) {
        self.onButtonTouchUp()
    }
    
    func onSecondaryButtonTouchUp() {
        FeedbackManager.shared.tap()
        title = " "
        self.navigationController?.title = " "
    }
    
    @objc
    private final func onSecondaryButtonTouchUpSelector(_ sender: UIButton) {
        self.onSecondaryButtonTouchUp()
    }
    
    @objc
    public func onTextFieldDidChangeSelector(_ sender: UITextField) {
        self.textFieldValueObserver.accept(sender.text)
    }
}

extension SignUpBaseViewController: UITextFieldDelegate {
    
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if !textField.isSelected {
            textField.isSelected = true
        }
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField.isSelected {
            textField.isSelected = false
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        if textField.isSelected {
            textField.isSelected = false
        }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        print(#function)
        textField.resignFirstResponder()
        return true
    }
}
