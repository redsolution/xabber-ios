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
import Toast_Swift

protocol AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?)
}

class AvatarPickerView: UIView {
    public let label: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 92)
        label.textAlignment = .center
        
        return label
    }()
    
    private final func setupSubviews() {
        addSubview(label)
        bringSubviewToFront(label)
        label.frame = self.bounds
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }
}

class AvatarPickerViewController: BaseViewController {
    
    class ColorPickerRoundedButton: UIButton {
        public var colorItem: AccountColorManager.ColorItem
        
        private let selectedView: UIView = {
            let view = UIView()
            
            view.backgroundColor = .clear
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 3
            
            return view
        }()
        
        init(frame: CGRect, color: AccountColorManager.ColorItem) {
            colorItem = color
            super.init(frame: frame)
            backgroundColor = color.palette.tint400
            layer.cornerRadius = frame.width / 2
            selectedView.frame = CGRect(
                x: 3,
                y: 3,
                width: frame.width - 6,
                height: frame.height - 6
            )
            selectedView.layer.cornerRadius = selectedView.frame.width / 2
            addSubview(selectedView)
            selectedView.isHidden = true
        }
        
        public final func markAsSelected(selected: Bool) {
            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                self.selectedView.isHidden = !selected
            } completion: { _ in
                
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    private let contentView: UIView = {
        let view = UIView()
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        view.layer.cornerRadius = 32
        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner] 
        
        return view
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        
        return stack
    }()
    
    private let topStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 15
        
        return stack
    }()
    
    private let avatarView: AvatarPickerView = {
        let view = AvatarPickerView(frame: CGRect(square: 176))
        
        
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.label.text = ["💡", "😃", "👽", "👻", "🎃", "🤖", "🦷", "🧦", "🍺", "🦜", "🦩", "🦚", "🦃", "🐉", "🦧", "🦑", "🐙", "🦀"].randomElement() ?? "💡"
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private let avatarBackground: UIView = {
        let view = UIView(frame: CGRect(square: 176))
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private let colorPickerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
                
        return view
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        label.textColor = .black
        label.text = "Emoji Profile Image".localizeString(id: "account_emoji_profile_image_header", arguments: [])
        
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        label.text = "Choose an emoji and background color to use as your profile image.".localizeString(id: "account_emoji_profile_image_description", arguments: [])
        
        return label
    }()
    
    private let saveButton: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        button.isEnabled = true
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.setTitle("Save".localizeString(id: "save", arguments: []), for: .normal)
        
        return button
    }()
    
    private let editAvatarButton: UIButton = {
        let button = UIButton(
            frame: CGRect(
                origin: CGPoint(x: 120, y: 120),
                size: CGSize(square: 44)
            )
        )
        
        button.setImage(#imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate), for: .normal)
        button.layer.cornerRadius = button.frame.width / 2
        button.backgroundColor = MDCPalette.grey.tint200.withAlphaComponent(0.7)
        button.tintColor = MDCPalette.grey.tint500
        
        return button
    }()
    
    let colors: [AccountColorManager.ColorItem] = [
        AccountColorManager.ColorItem("green", title: "Green".localizeString(id: "settings_account__label_color_name_green", arguments: []), color: MDCPalette.green),
        AccountColorManager.ColorItem("orange", title: "Orange".localizeString(id: "settings_account__label_color_name_orange", arguments: []), color: MDCPalette.orange),
        AccountColorManager.ColorItem("red", title: "Red".localizeString(id: "settings_account__label_color_name_red", arguments: []), color: MDCPalette.red),
        AccountColorManager.ColorItem("blue", title: "Blue".localizeString(id: "settings_account__label_color_name_blue", arguments: []), color: MDCPalette.blue),
        AccountColorManager.ColorItem("indigo", title: "Indigo".localizeString(id: "settings_account__label_color_name_indigo", arguments: []), color: MDCPalette.indigo),
        AccountColorManager.ColorItem("purple", title: "Purple".localizeString(id: "settings_account__label_color_name_purple", arguments: []), color: MDCPalette.purple),
        AccountColorManager.ColorItem("lime", title: "Lime".localizeString(id: "settings_account__label_color_name_lime", arguments: []), color: MDCPalette.lime),
        AccountColorManager.ColorItem("pink", title: "Pink".localizeString(id: "settings_account__label_color_name_pink", arguments: []), color: MDCPalette.pink),
        AccountColorManager.ColorItem("amber", title: "Amber".localizeString(id: "settings_account__label_color_name_amber", arguments: []), color: MDCPalette.amber)
    ]
    
    private var colorPickerButtons: [ColorPickerRoundedButton] = []
    public var palette: MDCPalette? = nil
    public var lastSettedEmoji: String? = nil
    
    public var delegate: AvatarPickerViewControllerDelegate? = nil
    
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
    
    public final func makeButtonEnabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.saveButton.isEnabled = true
            self.saveButton.backgroundColor = .systemBlue
            self.saveButton.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.saveButton.isEnabled = false
            self.saveButton.backgroundColor = MDCPalette.grey.tint100
            self.saveButton.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    public func activateConstraints() {
        NSLayoutConstraint.activate([
            avatarBackground.widthAnchor.constraint(equalToConstant: 176),
            avatarBackground.heightAnchor.constraint(equalTo: avatarBackground.widthAnchor),
//            avatarBackground.centerXAnchor.constraint(equalTo: self.view.centerXAnchor, constant: -(view.frame.width / 2)),
            avatarView.widthAnchor.constraint(equalTo: avatarBackground.widthAnchor),
            avatarView.heightAnchor.constraint(equalTo: avatarBackground.widthAnchor),
//            colorPickerView.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
            colorPickerView.widthAnchor.constraint(equalToConstant: 146),
            colorPickerView.heightAnchor.constraint(equalTo: colorPickerView.widthAnchor),
//            colorPickerView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor, constant: self.view.frame.width / 2),
            saveButton.widthAnchor.constraint(equalToConstant: 264),
            saveButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    
    public func setupSubviews() {
        contentView.frame = view.bounds
        
        view.addSubview(contentView)
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 32, bottom: 24, left: 16, right: 16)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(topStack)
//        topStack.addArrangedSubview(avatarView)
        topStack.addArrangedSubview(avatarBackground)
        avatarBackground.addSubview(avatarView)
        topStack.addArrangedSubview(colorPickerView)
        stack.addArrangedSubview(saveButton)
        
//        avatarView.addSubview(editAvatarButton)
        avatarBackground.addSubview(editAvatarButton)
        
        let padding: CGFloat = 16
        var offsetX: CGFloat = padding / 2
        var offsetY: CGFloat = padding / 2
        let buttonSize: CGSize = CGSize(square: 36)
        var colorIndex: Int = 0
        (0..<3).forEach {
            y in
            (0..<3).forEach {
                x in
                let frame = CGRect(
                    origin: CGPoint(x: offsetX, y: offsetY),
                    size: buttonSize
                )
                offsetX += buttonSize.width + padding
                let button = ColorPickerRoundedButton(frame: frame, color: colors[colorIndex])
                colorPickerButtons.append(button)
                colorIndex += 1
            }
            offsetX = padding / 2
            offsetY += buttonSize.height + padding
        }
        colorPickerButtons.forEach {
            $0.addTarget(self, action: #selector(onColorButtonSelected), for: .touchUpInside)
            colorPickerView.addSubview($0)
        }
        colorPickerButtons.first?.markAsSelected(selected: true)
        if palette == nil {
            palette = colors.first?.palette
        }
        self.avatarView.backgroundColor = colors.first?.palette.tint100
        editAvatarButton.addTarget(self, action: #selector(onEditAvatarButtonTouchUpInside), for: .touchUpInside)
    }
    
    public func configure() {
        if let emoji = lastSettedEmoji {
            avatarView.label.text = emoji
            makeButtonEnabled(false)
        } else {
            makeButtonDisabled(false)
        }
        if let palette = palette,
           let index = colors.firstIndex(where: { $0.palette == palette }) {
            self.colorPickerButtons.forEach { $0.markAsSelected(selected: false) }
            self.colorPickerButtons[index].markAsSelected(selected: true)
            self.avatarView.backgroundColor = palette.tint100
        }
        saveButton.addTarget(self, action: #selector(onSaveButtonTouchUpInside), for: .touchUpInside)
        
        makeButtonEnabled(true)
    }
    
    public func addObservers() {
        
    }
    
    public func removeObservers() {
        
    }
    
    public func localizeResources() {
        
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        localizeResources()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupSubviews()
        activateConstraints()
        addObservers()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeObservers()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
        
    private final func dismiss() {
        FeedbackManager.shared.tap()
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    private final func onSaveButtonTouchUpInside(_ sender: UIButton) {
        self.avatarView.mask = nil
        self.avatarView.layer.cornerRadius = 0
        let renderer = UIGraphicsImageRenderer(size: avatarView.bounds.size)
        self.editAvatarButton.isHidden = true
        let image = renderer.image { context in
            self.avatarView.drawHierarchy(in: self.avatarView.bounds, afterScreenUpdates: true)
        }
        self.editAvatarButton.isHidden = false
        self.editAvatarButton.layoutIfNeeded()
        self.avatarView.layoutIfNeeded()
        self.delegate?.onReceiveAvatar(image: image, emoji: lastSettedEmoji, currentPalette: palette)
        self.dismiss()
    }
    
    @objc
    private final func onColorButtonSelected(_ sender: ColorPickerRoundedButton) {
        self.colorPickerButtons.forEach { $0.markAsSelected(selected: false) }
        sender.markAsSelected(selected: true)
        self.palette = sender.colorItem.palette
        UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
            self.avatarView.backgroundColor = sender.colorItem.palette.tint100
        } completion: { _ in
            
        }
    }
    
    @objc
    private final func onEditAvatarButtonTouchUpInside(_ sender: UIButton) {
        let vc = EmojiPickerViewController()
        vc.delegate = self
        showModal(vc)
    }
}

extension AvatarPickerViewController: EmojiPickerViewControllerDelegate {
    func onEmojiSelected(_ emoji: String) {
        avatarView.label.text = emoji
        avatarView.layoutIfNeeded()
        makeButtonEnabled(true)
    }
}
