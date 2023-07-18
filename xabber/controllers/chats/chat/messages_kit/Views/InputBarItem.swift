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


class CustomResponderView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {

        if clipsToBounds || isHidden || alpha == 0 {
            return nil
        }

        for subview in subviews.reversed() {
            let subPoint = subview.convert(point, from: self)
            if let result = subview.hitTest(subPoint, with: event) {
                return result
            }
        }

        return nil
    }
}

final class InputBarButtonItem: UIButton {

    public enum Spacing {
        case fixed(CGFloat)
        case flexible
        case none
    }
    
    public typealias InputBarButtonItemAction = ((InputBarButtonItem) -> Void)
    
    public typealias InputBarButtonItemActionWithEvent = ((InputBarButtonItem, UIEvent) -> Void)
    
    // MARK: - Properties
    
    final var isRecordingButton: Bool = false
    
    /// The spacing property of the InputBarButtonItem that determines the contentHuggingPriority and any
    /// additional space to the intrinsicContentSize
    final var spacing: Spacing = .none {
        didSet {
            switch spacing {
            case .flexible:
                setContentHuggingPriority(UILayoutPriority(rawValue: 1), for: .horizontal)
            case .fixed:
                setContentHuggingPriority(UILayoutPriority(rawValue: 1000), for: .horizontal)
            case .none:
                setContentHuggingPriority(UILayoutPriority(rawValue: 500), for: .horizontal)
            }
        }
    }
    
    /// When not nil this size overrides the intrinsicContentSize
    private var size: CGSize? = CGSize(width: 20, height: 20) {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }
    
    final override var intrinsicContentSize: CGSize {
        var contentSize = size ?? super.intrinsicContentSize
        switch spacing {
        case .fixed(let width):
            contentSize.width += width
        case .flexible, .none:
            break
        }
        return contentSize
    }
    
    /// A reference to the stack view position that the InputBarButtonItem is held in
    final var parentStackViewPosition: InputStackView.Position?
    
    /// The title for the UIControlState.normal
    final var title: String? {
        get {
            return title(for: .normal)
        }
        set {
            setTitle(newValue, for: .normal)
        }
    }
    
    /// The image for the UIControlState.normal
    final var image: UIImage? {
        get {
            return image(for: .normal)
        }
        set {
            setImage(newValue, for: .normal)
        }
    }
    
    /// Calls the onSelectedAction or onDeselectedAction when set
    final override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                onSelectedAction?(self)
            } else {
                onDeselectedAction?(self)
            }
        }
    }
    
    /// Calls the onEnabledAction or onDisabledAction when set
    final override var isEnabled: Bool {
        didSet {
            if isEnabled {
                onEnabledAction?(self)
            } else {
                onDisabledAction?(self)
            }
        }
    }
    
    final var canChangeButtonPosition: Bool = false
    internal var indicatorPosition: CGFloat = 0.0
    
    public class BacklightView: UIButton {
        internal let shadowView: UIView = {
            let view = UIView()
            
            return view
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
            addShadow()
            
            isMultipleTouchEnabled = false
        }
        
        public var shadowColor: UIColor = UIColor.blue
        
        enum RecordButtonIcon: String {
            case send = "send"
            case microphone = "microphone"
            case stop = "pause"
        }
        
        public final func changeIcon(sendIcon: RecordButtonIcon) {
            self.setImage(#imageLiteral(resourceName: sendIcon.rawValue).withRenderingMode(.alwaysTemplate), for: .normal)
            self.tintColor = .white
            self.bringSubviewToFront(self.imageView!)
        }
        
        public final func changeStateTo(cancelled: Bool) {
            if cancelled {
                self.shadowView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
            } else {
                self.shadowView.backgroundColor = self.shadowColor.withAlphaComponent(0.6)
            }
        }
        
        open func setupShadow(color: UIColor) {
            self.shadowColor = color
            shadowView.backgroundColor = self.shadowColor.withAlphaComponent(0.6)
            shadowView.frame = bounds
            shadowView.layer.cornerRadius = frame.width / 2
            shadowView.isUserInteractionEnabled = false
        }
        
        open func removeShadow() {
            shadowView.removeFromSuperview()
        }
        
        open func addShadow() {
            if shadowView.superview == self { return }
            self.addSubview(shadowView)
            self.sendSubviewToBack(shadowView)
        }
        
        open func hideShadow(animated: Bool, completion: ((Bool) -> Void)? = nil) {
            func resize() {
                let shadowFrame = self.shadowView.frame
                self.shadowView.frame = CGRect(
                    x: shadowFrame.width / 2,
                    y: shadowFrame.height / 2,
                    width: 0.1,
                    height: 0.1
                )
                self.shadowView.layer.cornerRadius = 0.1
            }
            if animated {
                UIView.animateKeyframes(
                    withDuration: 0.2,
                    delay: 0,
                    options: [.allowUserInteraction],
                    animations: resize,
                    completion: completion
                )
            } else {
                UIView.performWithoutAnimation(resize)
                completion?(true)
            }
        }
        
        open func updateShadow(to percentage: Float, grow: CGFloat, animated: Bool, completion: ((Bool) -> Void)? = nil) {
            func resize() {
                let delta = CGFloat(percentage) * grow
                self.shadowView.frame = CGRect(
                    x: -(delta / 2),
                    y: -(delta / 2),
                    width: self.bounds.height + delta,
                    height: self.bounds.height + delta
                )
                self.shadowView.layer.cornerRadius = (self.bounds.height + delta) / 2
                self.sendSubviewToBack(self.shadowView)
                self.alpha = 1.0
            }
            if animated {
                UIView.animateKeyframes(
                    withDuration: 0.33,
                    delay: 0,
                    options: [.allowUserInteraction],
                    animations: resize,
                    completion: completion
                )
            } else {
                UIView.performWithoutAnimation(resize)
                completion?(true)
            }
        }
    }
    
    public let additionalAccesoryView: CustomResponderView = {
        let view = CustomResponderView()
        
        view.isHidden = true
        
        return view
    }()
    
    public let backlightView: BacklightView = {
        let button = BacklightView()
        
        button.setImage(#imageLiteral(resourceName: "microphone").withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .white
        
        return button
    }()
    
    private var onTouchUpOutsideAction: InputBarButtonItemAction?
    private var onTouchUpInsideAction: InputBarButtonItemAction?
    private var onTouchDownAction: InputBarButtonItemAction?
    private var onDragOutsideAction: InputBarButtonItemActionWithEvent?
    private var onDragInsideAction: InputBarButtonItemActionWithEvent?
    private var onKeyboardEditingBeginsAction: InputBarButtonItemAction?
    private var onKeyboardEditingEndsAction: InputBarButtonItemAction?
    private var onTextViewDidChangeAction: ((InputBarButtonItem, InputTextView) -> Void)?
    private var onSelectedAction: InputBarButtonItemAction?
    private var onDeselectedAction: InputBarButtonItemAction?
    private var onEnabledAction: InputBarButtonItemAction?
    private var onDisabledAction: InputBarButtonItemAction?
    private var onLockedAction: InputBarButtonItemAction?
    
    final var onTouchesCancelled: (() -> Void)? = nil
    
    internal var initialMovementLocation: CGFloat = 0
    
    // MARK: - Initialization
    
    public convenience init() {
        self.init(frame: .zero)
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    final func setup() {
        contentVerticalAlignment = .center
        contentHorizontalAlignment = .center
        imageView?.contentMode = .scaleAspectFit
        setContentHuggingPriority(UILayoutPriority(rawValue: 500), for: .horizontal)
        setContentHuggingPriority(UILayoutPriority(rawValue: 500), for: .vertical)
        setTitleColor(UIColor(red: 0, green: 122/255, blue: 1, alpha: 1), for: .normal)
        setTitleColor(UIColor(red: 0, green: 122/255, blue: 1, alpha: 0.3), for: .highlighted)
        setTitleColor(.lightGray, for: .disabled)
        adjustsImageWhenHighlighted = false

        isMultipleTouchEnabled = false
        showsTouchWhenHighlighted = true
        
        backlightView.isMultipleTouchEnabled = false
        
        addSubview(additionalAccesoryView)
        
        addTarget(self, action: #selector(onCancelRecord), for: .touchCancel)
        addTarget(self, action: #selector(onCancelRecord), for: .touchUpOutside)
        addTarget(self, action: #selector(InputBarButtonItem.touchUpInsideAction), for: .touchUpInside)
        addTarget(self, action: #selector(InputBarButtonItem.touchUpOutsideAction), for: .touchUpOutside)
        addTarget(self, action: #selector(InputBarButtonItem.touchDownAction), for: .touchDown)
        addTarget(self, action: #selector(InputBarButtonItem.dragOutsideAction), for: .touchDragOutside)
        addTarget(self, action: #selector(InputBarButtonItem.dragInsideAction), for: .touchDragInside)
    }
    
    @discardableResult
    final func configure(_ item: InputBarButtonItemAction) -> Self {
        item(self)
        return self
    }
    
    @discardableResult
    final func onKeyboardEditingBegins(_ action: @escaping InputBarButtonItemAction) -> Self {
        onKeyboardEditingBeginsAction = action
        return self
    }
    
    @discardableResult
    final func onKeyboardEditingEnds(_ action: @escaping InputBarButtonItemAction) -> Self {
        onKeyboardEditingEndsAction = action
        return self
    }
    
    @discardableResult
    final func onTextViewDidChange(_ action: @escaping (_ item: InputBarButtonItem, _ textView: InputTextView) -> Void) -> Self {
        onTextViewDidChangeAction = action
        return self
    }
    

    @discardableResult
    final func onTouchUpOutside(_ action: @escaping InputBarButtonItemAction) -> Self {
        onTouchUpOutsideAction = action
        return self
    }
    
    @discardableResult
    final func onTouchUpInside(_ action: @escaping InputBarButtonItemAction) -> Self {
        onTouchUpInsideAction = action
        return self
    }
    
    @discardableResult
    final func onTouchDown(_ action: @escaping InputBarButtonItemAction) -> Self {
        onTouchDownAction = action
        return self
    }
    
    @discardableResult
    final func onDragOutside(_ action: @escaping InputBarButtonItemActionWithEvent) -> Self {
        onDragOutsideAction = action
        return self
    }
    
    @discardableResult
    final func onDragInside(_ action: @escaping InputBarButtonItemActionWithEvent) -> Self {
        onDragInsideAction = action
        return self
    }
    
    @discardableResult
    final func onSelected(_ action: @escaping InputBarButtonItemAction) -> Self {
        onSelectedAction = action
        return self
    }
    
    @discardableResult
    final func onDeselected(_ action: @escaping InputBarButtonItemAction) -> Self {
        onDeselectedAction = action
        return self
    }
    
    @discardableResult
    final func onEnabled(_ action: @escaping InputBarButtonItemAction) -> Self {
        onEnabledAction = action
        return self
    }
    
    @discardableResult
    final func onDisabled(_ action: @escaping InputBarButtonItemAction) -> Self {
        onDisabledAction = action
        return self
    }
    
    @discardableResult
    final func onLocked(_ action: @escaping InputBarButtonItemAction) -> Self {
        onLockedAction = action
        return self
    }
    
    final func textViewDidChangeAction(with textView: InputTextView) {
        onTextViewDidChangeAction?(self, textView)
    }
    
    final func keyboardEditingEndsAction() {
        onKeyboardEditingEndsAction?(self)
    }
    
    final func keyboardEditingBeginsAction() {
        onKeyboardEditingBeginsAction?(self)
    }
    
    @objc
    final func touchUpOutsideAction() {
        onTouchUpOutsideAction?(self)
    }
    @objc
    final func touchUpInsideAction() {
        onTouchUpInsideAction?(self)
    }
    
    @objc
    final func touchDownAction(sender: UIButton, event: UIEvent) {
        onTouchDownAction?(self)
    }
    
    @objc
    final func dragOutsideAction(sender: UIButton, event: UIEvent) {
        onDragOutsideAction?(self, event)
    }
    
    @objc
    final func dragInsideAction(sender: UIButton, event: UIEvent) {
        onDragInsideAction?(self, event)
    }
    
    @objc
    internal func onCancelRecord(_ sender: AnyObject) {
        if canChangeButtonPosition {
            onTouchesCancelled?()
        }
    }

//    public static var flexibleSpace: InputBarButtonItem {
//        let item = InputBarButtonItem()
//        item.spacing = .flexible
//        return item
//    }
//
//    final class func fixedSpace(_ width: CGFloat) -> InputBarButtonItem {
//        let item = InputBarButtonItem()
//        item.spacing = .fixed(width)
//        return item
//    }
    
    final func configureShadow() {
        self.addSubview(backlightView)
        backlightView.frame = self.bounds
        backlightView.setupShadow(color: .blue)
    }
    
    final func removeShadow() {
        backlightView.removeFromSuperview()
    }
    
    final func resetShadow() {
        backlightView.backgroundColor = tintColor
        backlightView.tintColor = .white
        backlightView.addShadow()
    }
}
