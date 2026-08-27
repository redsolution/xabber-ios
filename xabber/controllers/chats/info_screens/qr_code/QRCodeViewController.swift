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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import CoreImage
import Foundation
import UIKit

enum QRCodePresentationMode {
    case legacy
    case settingsAccountCard
}

struct SettingsAccountQRCodeTheme: Equatable {
    let gradient: ChatViewController.BackgroundColor
    let backgroundName: String
}

enum SettingsAccountQRCodePayload {
    static func string(for jid: String) -> String {
        let value = jid.hasPrefix("xmpp:") ? String(jid.dropFirst("xmpp:".count)) : jid
        let bareJID = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? value
        return "xmpp:\(bareJID)"
    }
}

enum SettingsAccountQRCodeThemeCatalog {
    static let chatBackgroundNames = [
        "Aliens",
        "Summer",
        "Honeycomb",
        "Cats",
        "Flowers",
        "Flowers-daisy",
        "Hearts"
    ]

    static func currentTheme() -> SettingsAccountQRCodeTheme {
        let rawGradient = SettingManager.shared.getString(for: "chat_chooseBackgroundColor") ?? "purple"
        let gradient = ChatViewController.BackgroundColor(rawValue: rawGradient) ?? .purple
        let savedBackground = SettingManager.shared.getString(for: "chat_chooseBackground") ?? chatBackgroundNames[0]
        let background = chatBackgroundNames.contains(savedBackground) ? savedBackground : chatBackgroundNames[0]
        return SettingsAccountQRCodeTheme(gradient: gradient, backgroundName: background)
    }

    static func themes(
        currentGradient: ChatViewController.BackgroundColor,
        currentBackgroundName: String
    ) -> [SettingsAccountQRCodeTheme] {
        let background = chatBackgroundNames.contains(currentBackgroundName)
            ? currentBackgroundName
            : chatBackgroundNames[0]
        let current = SettingsAccountQRCodeTheme(
            gradient: currentGradient,
            backgroundName: background
        )
        let chatThemes = ChatViewController.BackgroundColor.allCases.enumerated().map { index, gradient in
            SettingsAccountQRCodeTheme(
                gradient: gradient,
                backgroundName: chatBackgroundNames[index % chatBackgroundNames.count]
            )
        }
        return [current] + chatThemes.filter { $0 != current }
    }
}

enum SettingsAccountQRCodeRoute {
    @MainActor
    static func makeScanner() -> UIViewController {
        QRCodeScannerViewController()
    }
}

enum SettingsAccountQRCodeExportPolicy {
    static func activityItems(for image: UIImage) -> [Any] {
        [image]
    }
}

private enum SettingsAccountQRCodeAppearance {
    case light
    case dark
}

private enum SettingsAccountQRCodeImageRenderer {
    static func image(
        from string: String,
        foregroundColor: UIColor,
        backgroundColor: UIColor,
        dimension: CGFloat
    ) -> UIImage? {
        guard
            let data = string.data(using: .utf8),
            let generator = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }

        generator.setValue(data, forKey: "inputMessage")
        generator.setValue("H", forKey: "inputCorrectionLevel")
        guard let generatedImage = generator.outputImage else {
            return nil
        }

        let scale = max(1, floor(dimension / generatedImage.extent.width))
        let scaledImage = generatedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let coloredImage = scaledImage.applyingFilter(
            "CIFalseColor",
            parameters: [
                "inputColor0": CIColor(color: foregroundColor),
                "inputColor1": CIColor(color: backgroundColor)
            ]
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(coloredImage, from: coloredImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private extension UIColor {
    func settingsAccountQRCodeMixed(with color: UIColor, fraction: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard
            getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            color.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: &otherAlpha)
        else {
            return self
        }
        let boundedFraction = min(max(fraction, 0), 1)
        return UIColor(
            red: red + ((otherRed - red) * boundedFraction),
            green: green + ((otherGreen - green) * boundedFraction),
            blue: blue + ((otherBlue - blue) * boundedFraction),
            alpha: alpha + ((otherAlpha - alpha) * boundedFraction)
        )
    }
}

private final class SettingsAccountQRCodeCanvasView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let patternImageView = UIImageView()
    private let cardView = UIView()
    private let qrImageView = UIImageView()
    private let avatarBackdropView = UIView()
    private let logoBackdropView = UIView()
    private let appLogoImageView = UIImageView()
    private let jidLabel = UILabel()
    private let avatarImageView: UIImageView

    var controlsReservedHeight: CGFloat = 0 {
        didSet {
            setNeedsLayout()
        }
    }

    init(avatarImageView: UIImageView) {
        self.avatarImageView = avatarImageView
        super.init(frame: .zero)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        isOpaque = true
        backgroundColor = .black
        layer.insertSublayer(gradientLayer, at: 0)

        patternImageView.alpha = 0.12
        patternImageView.contentMode = .scaleAspectFill
        patternImageView.isUserInteractionEnabled = false
        addSubview(patternImageView)

        cardView.layer.cornerRadius = 30
        cardView.layer.cornerCurve = .continuous
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.12
        cardView.layer.shadowRadius = 20
        cardView.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(cardView)

        qrImageView.contentMode = .scaleAspectFit
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.layer.minificationFilter = .nearest
        cardView.addSubview(qrImageView)

        jidLabel.textAlignment = .center
        jidLabel.adjustsFontSizeToFitWidth = true
        jidLabel.minimumScaleFactor = 0.72
        jidLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        cardView.addSubview(jidLabel)

        avatarBackdropView.layer.cornerRadius = 42
        avatarBackdropView.layer.cornerCurve = .continuous
        addSubview(avatarBackdropView)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.mask = nil
        avatarImageView.layer.cornerRadius = 36
        avatarImageView.layer.cornerCurve = .continuous
        avatarImageView.accessibilityIdentifier = "settings.account_qr.avatar"
        avatarBackdropView.addSubview(avatarImageView)

        logoBackdropView.layer.cornerRadius = 29
        logoBackdropView.layer.cornerCurve = .continuous
        cardView.addSubview(logoBackdropView)

        appLogoImageView.image = UIImage(named: "onboarding_logo_128pt")
        appLogoImageView.contentMode = .scaleAspectFit
        appLogoImageView.accessibilityIdentifier = "settings.account_qr.app_logo"
        logoBackdropView.addSubview(appLogoImageView)
    }

    func apply(
        theme: SettingsAccountQRCodeTheme,
        appearance: SettingsAccountQRCodeAppearance,
        payload: String,
        jid: String
    ) {
        let gradientColors = ChatViewController.getColorsForGradient(forColor: theme.gradient)
        gradientLayer.colors = gradientColors
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)

        patternImageView.image = UIImage(named: theme.backgroundName.lowercased())?
            .withRenderingMode(.alwaysTemplate)
            .resizableImage(withCapInsets: .zero, resizingMode: .tile)
        patternImageView.tintColor = appearance == .light ? .white : .black

        let cardColor: UIColor
        let foregroundColor: UIColor
        switch appearance {
        case .light:
            cardColor = .white
            foregroundColor = UIColor(cgColor: gradientColors.last ?? UIColor.systemBlue.cgColor)
                .settingsAccountQRCodeMixed(with: .black, fraction: 0.34)
            jidLabel.textColor = foregroundColor
        case .dark:
            cardColor = UIColor(white: 0.075, alpha: 1)
            foregroundColor = .white
            jidLabel.textColor = .white
        }

        cardView.backgroundColor = cardColor
        avatarBackdropView.backgroundColor = cardColor
        logoBackdropView.backgroundColor = cardColor
        qrImageView.image = SettingsAccountQRCodeImageRenderer.image(
            from: payload,
            foregroundColor: foregroundColor,
            backgroundColor: cardColor,
            dimension: 320
        )
        jidLabel.text = jid
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        patternImageView.frame = bounds

        let safeTop = safeAreaInsets.top
        let cardWidth = min(max(bounds.width - 40, 250), 336)
        let cardHeight = cardWidth * 1.17
        let minimumCardY = safeTop + 74
        let maximumCardY = max(
            minimumCardY,
            bounds.height - controlsReservedHeight - cardHeight - 14
        )
        let preferredCardY = (bounds.height * 0.455) - (cardHeight * 0.5)
        let cardY = min(max(preferredCardY, minimumCardY), maximumCardY)
        cardView.frame = CGRect(
            x: (bounds.width - cardWidth) * 0.5,
            y: cardY,
            width: cardWidth,
            height: cardHeight
        )

        let avatarSize: CGFloat = 84
        avatarBackdropView.frame = CGRect(
            x: cardView.frame.midX - (avatarSize * 0.5),
            y: cardView.frame.minY - (avatarSize * 0.5),
            width: avatarSize,
            height: avatarSize
        )
        avatarImageView.frame = avatarBackdropView.bounds.insetBy(dx: 6, dy: 6)

        let qrInset: CGFloat = 30
        let qrTop: CGFloat = 48
        let qrSize = cardWidth - (qrInset * 2)
        qrImageView.frame = CGRect(x: qrInset, y: qrTop, width: qrSize, height: qrSize)

        let logoSize: CGFloat = 58
        logoBackdropView.frame = CGRect(
            x: qrImageView.frame.midX - (logoSize * 0.5),
            y: qrImageView.frame.midY - (logoSize * 0.5),
            width: logoSize,
            height: logoSize
        )
        appLogoImageView.frame = logoBackdropView.bounds.insetBy(dx: 8, dy: 8)

        jidLabel.frame = CGRect(
            x: 20,
            y: cardHeight - 53,
            width: cardWidth - 40,
            height: 28
        )
    }
}

private final class SettingsAccountQRCodeThemeCell: UICollectionViewCell {
    static let reuseIdentifier = "SettingsAccountQRCodeThemeCell"

    private let gradientLayer = CAGradientLayer()
    private let patternImageView = UIImageView()
    private let miniCardView = UIView()
    private let qrSymbolImageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        contentView.layer.cornerRadius = 13
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.layer.insertSublayer(gradientLayer, at: 0)

        patternImageView.alpha = 0.14
        patternImageView.tintColor = .white
        patternImageView.contentMode = .scaleAspectFill
        contentView.addSubview(patternImageView)

        miniCardView.backgroundColor = .white
        miniCardView.layer.cornerRadius = 7
        contentView.addSubview(miniCardView)

        qrSymbolImageView.image = UIImage(systemName: "qrcode")
        qrSymbolImageView.tintColor = .black
        qrSymbolImageView.contentMode = .scaleAspectFit
        miniCardView.addSubview(qrSymbolImageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            layer.borderWidth = isSelected ? 3 : 0
            layer.borderColor = UIColor.label.cgColor
            layer.cornerRadius = 16
            layer.cornerCurve = .continuous
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    func apply(theme: SettingsAccountQRCodeTheme, appearance: SettingsAccountQRCodeAppearance) {
        accessibilityLabel = "\(theme.backgroundName), \(theme.gradient.rawValue)"
        gradientLayer.colors = ChatViewController.getColorsForGradient(forColor: theme.gradient)
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        patternImageView.image = UIImage(named: theme.backgroundName.lowercased())?
            .withRenderingMode(.alwaysTemplate)
            .resizableImage(withCapInsets: .zero, resizingMode: .tile)
        miniCardView.backgroundColor = appearance == .light ? .white : UIColor(white: 0.075, alpha: 1)
        qrSymbolImageView.tintColor = appearance == .light ? .black : .white
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = contentView.bounds
        patternImageView.frame = contentView.bounds
        miniCardView.frame = CGRect(
            x: contentView.bounds.width * 0.23,
            y: contentView.bounds.height * 0.18,
            width: contentView.bounds.width * 0.54,
            height: contentView.bounds.height * 0.66
        )
        qrSymbolImageView.frame = miniCardView.bounds.insetBy(dx: 5, dy: 7)
    }
}

class QRCodeViewController: UIViewController {
    internal let QRSize: CGSize = CGSize(square: 280)

    open var stringValue: String = ""
    open var username: String = ""
    open var jid: String = ""
    open var presentationMode: QRCodePresentationMode = .legacy

    internal var qrImage: UIImage?
    internal var brightness: CGFloat = 0

    internal let imageView: UIImageView = {
        let view = UIImageView()
        view.tintColor = .red
        return view
    }()

    internal let logoInsideQR: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 128))
        view.backgroundColor = .white
        view.layer.cornerRadius = 40
        view.widthAnchor.constraint(equalToConstant: 80).isActive = true
        view.heightAnchor.constraint(equalToConstant: 80).isActive = true
        return view
    }()

    internal let avatarImageView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 56))
        view.contentMode = .center
        if
            let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 56),
            AccountMasksManager.shared.load() != "square"
        {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        return view
    }()

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        return label
    }()

    private let jidLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = UIFont.systemFont(ofSize: 15, weight: .light)
        return label
    }()

    private var settingsCanvasView: SettingsAccountQRCodeCanvasView?
    private var settingsThemes: [SettingsAccountQRCodeTheme] = []
    private var selectedSettingsThemeIndex = 0
    private var settingsAppearance: SettingsAccountQRCodeAppearance = .light

    private let settingsControlPanel: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 28
        view.layer.cornerCurve = .continuous
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 20
        view.layer.shadowOffset = CGSize(width: 0, height: 8)
        return view
    }()

    private let settingsTitleLabel: UILabel = {
        let label = UILabel()
        label.text = "QR-code".localizeString(id: "dialog_show_qr_code__header", arguments: [])
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    private lazy var settingsCloseButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.accessibilityLabel = "Close".localizeString(id: "close", arguments: [])
        button.addTarget(self, action: #selector(closeSettingsQRCode), for: .touchUpInside)
        return button
    }()

    private lazy var settingsAppearanceButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "moon.fill"), for: .normal)
        button.accessibilityIdentifier = "settings.account_qr.appearance"
        button.accessibilityLabel = "Appearance".localizeString(id: "category_appearance", arguments: [])
        button.addTarget(self, action: #selector(toggleSettingsAppearance), for: .touchUpInside)
        return button
    }()

    private lazy var settingsThemeCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 54, height: 70)
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "settings.account_qr.themes"
        collectionView.register(
            SettingsAccountQRCodeThemeCell.self,
            forCellWithReuseIdentifier: SettingsAccountQRCodeThemeCell.reuseIdentifier
        )
        return collectionView
    }()

    private lazy var settingsShareButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.image = UIImage(systemName: "square.and.arrow.up")
        configuration.imagePadding = 8
        configuration.title = "Share QR Code".localizeString(id: "share_qr_code", arguments: [])
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "settings.account_qr.share"
        button.addTarget(self, action: #selector(shareSettingsQRCode), for: .touchUpInside)
        return button
    }()

    private lazy var settingsScanButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .large
        configuration.image = UIImage(systemName: "qrcode.viewfinder")
        configuration.imagePadding = 8
        configuration.title = "Scan QR Code".localizeString(id: "scan_qr_code", arguments: [])
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "settings.account_qr.scan"
        button.addTarget(self, action: #selector(scanSettingsQRCode), for: .touchUpInside)
        return button
    }()

    @objc
    internal func cancel(_ sender: UIBarButtonItem) {
        UIScreen.main.brightness = brightness
        dismiss(animated: true, completion: nil)
    }

    @objc
    internal func share(_ sender: UIBarButtonItem) {
        guard let image = qrImage else {
            view.makeToast("Can`t share QR-code".localizeString(id: "account_cant_share_qr", arguments: []))
            return
        }

        let activityImage = UIImage(imageLiteralResourceName: "xabber_icon_call_kit")
            .resize(targetSize: CGSize(square: 60))
        let xabberActivity = XabberActivity(title: "Xabber", image: activityImage)
        let shareViewController = UIActivityViewController(
            activityItems: [image, stringValue],
            applicationActivities: [xabberActivity]
        )

        if let popoverController = shareViewController.popoverPresentationController {
            popoverController.sourceView = view
            popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        present(shareViewController, animated: true, completion: nil)
    }

    internal func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .ascii)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        let transform = CGAffineTransform(scaleX: 3, y: 3)
        guard let output = filter.outputImage?.transformed(by: transform) else {
            return nil
        }
        return UIImage(ciImage: output)
    }

    internal func configure() {
        switch presentationMode {
        case .legacy:
            configureLegacyQRCode()
        case .settingsAccountCard:
            configureSettingsAccountQRCode()
        }
    }

    private func configureLegacyQRCode() {
        title = "QR-code".localizeString(id: "dialog_show_qr_code__header", arguments: [])
        imageView.frame = CGRect(
            x: (view.frame.width - QRSize.width) / 2,
            y: (view.frame.height - QRSize.height) / 2,
            width: QRSize.width,
            height: QRSize.height
        )
        view.backgroundColor = .systemBackground
        view.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 56, bottom: 0, left: 0, right: 0)

        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(usernameLabel)
        stack.addArrangedSubview(jidLabel)
        stack.addArrangedSubview(UIStackView())
        stack.setCustomSpacing(32, after: imageView)

        qrImage = generateQRCode(from: stringValue)?.upscale(dimension: 280)
        imageView.image = qrImage
        imageView.addSubview(logoInsideQR)
        logoInsideQR.centerInSuperview()
        logoInsideQR.addSubview(avatarImageView)
        avatarImageView.centerInSuperview()

        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share))
        navigationItem.setLeftBarButton(cancelButton, animated: true)
        navigationItem.setRightBarButton(shareButton, animated: true)

        usernameLabel.text = username
        jidLabel.text = jid
    }

    private func configureSettingsAccountQRCode() {
        view.accessibilityIdentifier = "settings.account_qr.screen"
        view.backgroundColor = .black
        let currentTheme = SettingsAccountQRCodeThemeCatalog.currentTheme()
        settingsThemes = SettingsAccountQRCodeThemeCatalog.themes(
            currentGradient: currentTheme.gradient,
            currentBackgroundName: currentTheme.backgroundName
        )

        let canvasView = SettingsAccountQRCodeCanvasView(avatarImageView: avatarImageView)
        canvasView.controlsReservedHeight = 278
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        settingsCanvasView = canvasView

        settingsControlPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsControlPanel)

        let topRow = UIView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        settingsCloseButton.translatesAutoresizingMaskIntoConstraints = false
        settingsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsAppearanceButton.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(settingsCloseButton)
        topRow.addSubview(settingsTitleLabel)
        topRow.addSubview(settingsAppearanceButton)
        NSLayoutConstraint.activate([
            settingsCloseButton.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            settingsCloseButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            settingsCloseButton.widthAnchor.constraint(equalToConstant: 44),
            settingsCloseButton.heightAnchor.constraint(equalToConstant: 44),
            settingsAppearanceButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            settingsAppearanceButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            settingsAppearanceButton.widthAnchor.constraint(equalToConstant: 44),
            settingsAppearanceButton.heightAnchor.constraint(equalToConstant: 44),
            settingsTitleLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            settingsTitleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            settingsTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: settingsCloseButton.trailingAnchor),
            settingsTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsAppearanceButton.leadingAnchor),
            topRow.heightAnchor.constraint(equalToConstant: 44)
        ])

        settingsThemeCollectionView.translatesAutoresizingMaskIntoConstraints = false
        settingsShareButton.translatesAutoresizingMaskIntoConstraints = false
        settingsScanButton.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = UIStackView(arrangedSubviews: [
            topRow,
            settingsThemeCollectionView,
            settingsShareButton,
            settingsScanButton
        ])
        controlsStack.axis = .vertical
        controlsStack.spacing = 10
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsControlPanel.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            settingsControlPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            settingsControlPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            settingsControlPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlsStack.leadingAnchor.constraint(equalTo: settingsControlPanel.leadingAnchor, constant: 12),
            controlsStack.trailingAnchor.constraint(equalTo: settingsControlPanel.trailingAnchor, constant: -12),
            controlsStack.topAnchor.constraint(equalTo: settingsControlPanel.topAnchor, constant: 10),
            controlsStack.bottomAnchor.constraint(equalTo: settingsControlPanel.bottomAnchor, constant: -12),
            settingsThemeCollectionView.heightAnchor.constraint(equalToConstant: 78),
            settingsShareButton.heightAnchor.constraint(equalToConstant: 50),
            settingsScanButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        applySettingsAccountTheme()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.settingsThemes.isEmpty else { return }
            self.settingsThemeCollectionView.selectItem(
                at: IndexPath(item: self.selectedSettingsThemeIndex, section: 0),
                animated: false,
                scrollPosition: []
            )
        }
    }

    private func applySettingsAccountTheme() {
        guard settingsThemes.indices.contains(selectedSettingsThemeIndex) else {
            return
        }
        let theme = settingsThemes[selectedSettingsThemeIndex]
        settingsCanvasView?.apply(
            theme: theme,
            appearance: settingsAppearance,
            payload: stringValue,
            jid: jid
        )
        settingsThemeCollectionView.reloadData()

        let gradientColors = ChatViewController.getColorsForGradient(forColor: theme.gradient)
        let accent = UIColor(cgColor: gradientColors.last ?? UIColor.systemBlue.cgColor)
            .settingsAccountQRCodeMixed(with: .black, fraction: 0.28)
        settingsShareButton.configuration?.baseBackgroundColor = accent
        settingsShareButton.configuration?.baseForegroundColor = .white
        settingsScanButton.configuration?.baseBackgroundColor = accent.withAlphaComponent(0.16)
        settingsScanButton.configuration?.baseForegroundColor = accent
        settingsCloseButton.tintColor = .label
        settingsAppearanceButton.tintColor = .label
    }

    @objc
    private func closeSettingsQRCode() {
        dismiss(animated: true)
    }

    @objc
    private func toggleSettingsAppearance() {
        settingsAppearance = settingsAppearance == .light ? .dark : .light
        let imageName = settingsAppearance == .light ? "moon.fill" : "sun.max.fill"
        settingsAppearanceButton.setImage(UIImage(systemName: imageName), for: .normal)
        applySettingsAccountTheme()
    }

    @objc
    private func shareSettingsQRCode() {
        guard let image = makeSettingsAccountShareImage() else {
            view.makeToast("Can`t share QR-code".localizeString(id: "account_cant_share_qr", arguments: []))
            return
        }
        let shareViewController = UIActivityViewController(
            activityItems: SettingsAccountQRCodeExportPolicy.activityItems(for: image),
            applicationActivities: nil
        )
        if let popoverController = shareViewController.popoverPresentationController {
            popoverController.sourceView = settingsShareButton
            popoverController.sourceRect = settingsShareButton.bounds
        }
        present(shareViewController, animated: true)
    }

    @objc
    private func scanSettingsQRCode() {
        let scanner = SettingsAccountQRCodeRoute.makeScanner()
        scanner.title = "Scan QR Code".localizeString(id: "scan_qr_code", arguments: [])
        navigationController?.setNavigationBarHidden(false, animated: true)
        navigationController?.pushViewController(scanner, animated: true)
    }

    internal func makeSettingsAccountShareImage() -> UIImage? {
        guard settingsThemes.indices.contains(selectedSettingsThemeIndex) else {
            return nil
        }
        view.layoutIfNeeded()
        let exportSize = view.bounds.size.width > 0 && view.bounds.size.height > 0
            ? view.bounds.size
            : CGSize(width: 390, height: 844)
        let exportAvatar = UIImageView(image: avatarImageView.image)
        let exportCanvas = SettingsAccountQRCodeCanvasView(avatarImageView: exportAvatar)
        exportCanvas.frame = CGRect(origin: .zero, size: exportSize)
        exportCanvas.controlsReservedHeight = 0
        exportCanvas.apply(
            theme: settingsThemes[selectedSettingsThemeIndex],
            appearance: settingsAppearance,
            payload: stringValue,
            jid: jid
        )
        exportCanvas.setNeedsLayout()
        exportCanvas.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: exportSize, format: format).image { context in
            exportCanvas.layer.render(in: context.cgContext)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        switch presentationMode {
        case .legacy:
            brightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
        case .settingsAccountCard:
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if presentationMode == .legacy {
            UIScreen.main.brightness = brightness
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        presentationMode == .settingsAccountCard ? .portrait : super.supportedInterfaceOrientations
    }
}

extension QRCodeViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        settingsThemes.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SettingsAccountQRCodeThemeCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsAccountQRCodeThemeCell,
            settingsThemes.indices.contains(indexPath.item)
        else {
            return UICollectionViewCell()
        }
        cell.apply(theme: settingsThemes[indexPath.item], appearance: settingsAppearance)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard settingsThemes.indices.contains(indexPath.item) else {
            return
        }
        selectedSettingsThemeIndex = indexPath.item
        applySettingsAccountTheme()
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredHorizontally)
    }
}
