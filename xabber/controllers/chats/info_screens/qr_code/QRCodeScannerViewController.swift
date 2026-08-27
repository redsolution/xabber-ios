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

import AudioToolbox
import AVFoundation
import CoreImage
import UIKit
import UniformTypeIdentifiers
import XMPPFramework.XMPPJID

enum QRCodeScannerImageDecoder {
    static func firstCode(in image: UIImage) -> String? {
        guard
            let ciImage = image.ciImage ?? CIImage(image: image),
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        else {
            return nil
        }

        let features = detector.features(
            in: ciImage,
            options: [
                CIDetectorImageOrientation: exifOrientation(for: image.imageOrientation)
            ]
        )
        return features
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }

    private static func exifOrientation(for orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}

private final class QRCodeScannerDimmingView: UIView {
    var scanFrame: CGRect = .zero {
        didSet {
            setNeedsLayout()
        }
    }

    private let dimmingLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.fillColor = UIColor.black.withAlphaComponent(0.30).cgColor
        layer.addSublayer(dimmingLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimmingLayer.frame = bounds
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: scanFrame))
        dimmingLayer.path = path.cgPath
    }
}

private final class QRCodeScannerFocusView: UIView {
    private enum Layout {
        static let lineWidth: CGFloat = 3
        static let cornerLength: CGFloat = 27
        static let cornerRadius: CGFloat = 6
    }

    private let cornerLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        cornerLayer.fillColor = UIColor.clear.cgColor
        cornerLayer.strokeColor = UIColor.white.cgColor
        cornerLayer.lineWidth = Layout.lineWidth
        cornerLayer.lineCap = .round
        cornerLayer.lineJoin = .round
        layer.addSublayer(cornerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cornerLayer.frame = bounds
        cornerLayer.path = makeCornersPath(in: bounds).cgPath
    }

    private func makeCornersPath(in bounds: CGRect) -> UIBezierPath {
        let inset = Layout.lineWidth / 2
        let minX = bounds.minX + inset
        let minY = bounds.minY + inset
        let maxX = bounds.maxX - inset
        let maxY = bounds.maxY - inset
        let path = UIBezierPath()

        path.move(to: CGPoint(x: minX, y: minY + Layout.cornerLength))
        path.addLine(to: CGPoint(x: minX, y: minY + Layout.cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: minX + Layout.cornerRadius, y: minY),
            controlPoint: CGPoint(x: minX, y: minY)
        )
        path.addLine(to: CGPoint(x: minX + Layout.cornerLength, y: minY))

        path.move(to: CGPoint(x: maxX - Layout.cornerLength, y: minY))
        path.addLine(to: CGPoint(x: maxX - Layout.cornerRadius, y: minY))
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: minY + Layout.cornerRadius),
            controlPoint: CGPoint(x: maxX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX, y: minY + Layout.cornerLength))

        path.move(to: CGPoint(x: maxX, y: maxY - Layout.cornerLength))
        path.addLine(to: CGPoint(x: maxX, y: maxY - Layout.cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: maxX - Layout.cornerRadius, y: maxY),
            controlPoint: CGPoint(x: maxX, y: maxY)
        )
        path.addLine(to: CGPoint(x: maxX - Layout.cornerLength, y: maxY))

        path.move(to: CGPoint(x: minX + Layout.cornerLength, y: maxY))
        path.addLine(to: CGPoint(x: minX + Layout.cornerRadius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: maxY - Layout.cornerRadius),
            controlPoint: CGPoint(x: minX, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX, y: maxY - Layout.cornerLength))

        return path
    }
}

class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private enum Layout {
        static let focusSize: CGFloat = 260
        static let backSize: CGFloat = 44
        static let actionSize: CGFloat = 56
        static let actionSpacing: CGFloat = 88
        static let actionsTopSpacing: CGFloat = 88
    }

    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?

    open var leftMenuSelectRootCategoryDelegate: LeftMenuSelectRootScreenDelegate?

    private let sessionQueue = DispatchQueue(label: "com.xabber.qr-scanner.capture")
    private var metadataOutput: AVCaptureMetadataOutput?
    private var captureDevice: AVCaptureDevice?
    private var previousNavigationBarHidden: Bool?
    private weak var invalidAlertBackdropView: UIView?

    private let cameraView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.accessibilityIdentifier = "qr_scanner.camera"
        return view
    }()

    private let dimmingView: QRCodeScannerDimmingView = {
        let view = QRCodeScannerDimmingView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let focusView: QRCodeScannerFocusView = {
        let view = QRCodeScannerFocusView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityIdentifier = "qr_scanner.focus"
        return view
    }()

    private lazy var backButton = makeCircularButton(
        systemName: "chevron.left",
        pointSize: 24,
        accessibilityIdentifier: "qr_scanner.back",
        accessibilityLabel: "Back".localizeString(id: "back", arguments: [])
    )

    private lazy var galleryButton = makeCircularButton(
        systemName: "photo.fill",
        pointSize: 25,
        accessibilityIdentifier: "qr_scanner.gallery",
        accessibilityLabel: "Photo Library".localizeString(id: "photo_library", arguments: [])
    )

    private lazy var torchButton = makeCircularButton(
        systemName: "flashlight.on.fill",
        pointSize: 25,
        accessibilityIdentifier: "qr_scanner.torch",
        accessibilityLabel: "Flashlight".localizeString(id: "flashlight", arguments: [])
    )

    private lazy var actionsStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [galleryButton, torchButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Layout.actionSpacing
        return stack
    }()

    public func setupSubviews() {
        view.accessibilityIdentifier = "qr_scanner.screen"
        view.backgroundColor = .black
        view.addSubview(cameraView)
        view.addSubview(dimmingView)
        view.addSubview(focusView)
        view.addSubview(backButton)
        view.addSubview(actionsStackView)

        backButton.layer.cornerRadius = Layout.backSize / 2
        galleryButton.layer.cornerRadius = Layout.actionSize / 2
        torchButton.layer.cornerRadius = Layout.actionSize / 2

        NSLayoutConstraint.activate([
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            focusView.widthAnchor.constraint(equalToConstant: Layout.focusSize),
            focusView.heightAnchor.constraint(equalToConstant: Layout.focusSize),
            focusView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            focusView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            backButton.widthAnchor.constraint(equalToConstant: Layout.backSize),
            backButton.heightAnchor.constraint(equalToConstant: Layout.backSize),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),

            galleryButton.widthAnchor.constraint(equalToConstant: Layout.actionSize),
            galleryButton.heightAnchor.constraint(equalToConstant: Layout.actionSize),
            torchButton.widthAnchor.constraint(equalToConstant: Layout.actionSize),
            torchButton.heightAnchor.constraint(equalToConstant: Layout.actionSize),
            actionsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionsStackView.topAnchor.constraint(
                equalTo: focusView.bottomAnchor,
                constant: Layout.actionsTopSpacing
            )
        ])

        backButton.addTarget(self, action: #selector(closeScanner), for: .touchUpInside)
        galleryButton.addTarget(self, action: #selector(openPhotoLibrary), for: .touchUpInside)
        torchButton.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
    }

    public func configure() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(for: .video),
            let videoInput = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(videoInput)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        cameraView.layer.insertSublayer(previewLayer, at: 0)

        captureSession = session
        captureDevice = device
        metadataOutput = output
        self.previewLayer = previewLayer
        torchButton.isEnabled = device.hasTorch
        torchButton.alpha = device.hasTorch ? 1 : 0.5
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        setupSubviews()
        configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = cameraView.bounds
        dimmingView.scanFrame = focusView.frame
        if let previewLayer, let metadataOutput {
            metadataOutput.rectOfInterest = previewLayer.metadataOutputRectConverted(
                fromLayerRect: focusView.frame
            )
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController {
            if previousNavigationBarHidden == nil {
                previousNavigationBarHidden = navigationController.isNavigationBarHidden
            }
            navigationController.setNavigationBarHidden(true, animated: false)
        }
        startCaptureSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCaptureSession()
        turnTorchOff()

        guard let navigationController else { return }
        let isLeavingNavigationStack = isMovingFromParent
            || navigationController.isBeingDismissed
            || navigationController.topViewController !== self
        if isLeavingNavigationStack, let previousNavigationBarHidden {
            navigationController.setNavigationBarHidden(previousNavigationBarHidden, animated: false)
        }
    }

    func failed() {
        view.makeToast(
            "Invalid QR code".localizeString(id: "account_invalid_qr_message", arguments: [])
        )
        startCaptureSession()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let stringValue = readableObject.stringValue
        else {
            return
        }
        stopCaptureSession()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        found(code: stringValue)
    }

    func found(code: String) {
        guard
            let url = URL(string: code),
            let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true),
            let jidComponent = components.path,
            let formattedJid = XMPPJID(string: jidComponent)?.bare
        else {
            failed()
            return
        }

        let controller = AddNewContactViewController()
        controller.contactJid.accept(formattedJid)
        if let rootController = navigationController?.viewControllers.first {
            navigationController?.setViewControllers([rootController, controller], animated: true)
        } else {
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    func showInvalidGalleryQRCodeAlert() {
        guard invalidAlertBackdropView == nil else { return }

        let backdrop = UIView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.10)
        view.addSubview(backdrop)

        let alert = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
        alert.translatesAutoresizingMaskIntoConstraints = false
        alert.accessibilityIdentifier = "qr_scanner.invalid_alert"
        alert.layer.cornerRadius = 28
        alert.layer.cornerCurve = .continuous
        alert.clipsToBounds = true
        alert.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.36)
        backdrop.addSubview(alert)

        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.accessibilityIdentifier = "qr_scanner.invalid_alert.message"
        messageLabel.text = "No valid QR code found in the image. Please try again."
            .localizeString(id: "qr_scanner_invalid_gallery_message", arguments: [])
        messageLabel.font = .systemFont(ofSize: 17)
        messageLabel.textColor = .black
        messageLabel.numberOfLines = 0
        alert.contentView.addSubview(messageLabel)

        let okButton = UIButton(type: .system)
        okButton.translatesAutoresizingMaskIntoConstraints = false
        okButton.accessibilityIdentifier = "qr_scanner.invalid_alert.ok"
        okButton.setTitle("OK".localizeString(id: "ok", arguments: []), for: .normal)
        okButton.setTitleColor(.white, for: .normal)
        okButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        okButton.backgroundColor = .systemBlue
        okButton.layer.cornerRadius = 24
        okButton.layer.cornerCurve = .continuous
        okButton.addTarget(self, action: #selector(hideInvalidGalleryQRCodeAlert), for: .touchUpInside)
        alert.contentView.addSubview(okButton)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            alert.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            alert.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            alert.widthAnchor.constraint(equalToConstant: 300),

            messageLabel.leadingAnchor.constraint(equalTo: alert.contentView.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: alert.contentView.trailingAnchor, constant: -24),
            messageLabel.topAnchor.constraint(equalTo: alert.contentView.topAnchor, constant: 20),

            okButton.leadingAnchor.constraint(equalTo: alert.contentView.leadingAnchor, constant: 16),
            okButton.trailingAnchor.constraint(equalTo: alert.contentView.trailingAnchor, constant: -16),
            okButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            okButton.heightAnchor.constraint(equalToConstant: 48),
            okButton.bottomAnchor.constraint(equalTo: alert.contentView.bottomAnchor, constant: -14)
        ])

        invalidAlertBackdropView = backdrop
        backdrop.alpha = 0
        alert.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        let animations = {
            backdrop.alpha = 1
            alert.transform = .identity
        }
        if UIAccessibility.isReduceMotionEnabled {
            animations()
        } else {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: animations
            )
        }
    }

    override var prefersStatusBarHidden: Bool {
        false
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    private func makeCircularButton(
        systemName: String,
        pointSize: CGFloat,
        accessibilityIdentifier: String,
        accessibilityLabel: String
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityLabel = accessibilityLabel
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.46)
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        button.layer.cornerCurve = .continuous
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium),
            forImageIn: .normal
        )
        button.setImage(
            UIImage(systemName: systemName) ?? UIImage(systemName: "flashlight.off.fill"),
            for: .normal
        )
        return button
    }

    private func startCaptureSession() {
        guard let captureSession else { return }
        sessionQueue.async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func stopCaptureSession() {
        guard let captureSession else { return }
        sessionQueue.async {
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    private func turnTorchOff() {
        setTorch(enabled: false)
    }

    private func setTorch(enabled: Bool) {
        guard let captureDevice, captureDevice.hasTorch else {
            updateTorchAppearance(enabled: false)
            return
        }

        do {
            try captureDevice.lockForConfiguration()
            defer { captureDevice.unlockForConfiguration() }
            let mode: AVCaptureDevice.TorchMode = enabled ? .on : .off
            guard captureDevice.isTorchModeSupported(mode) else { return }
            captureDevice.torchMode = mode
            updateTorchAppearance(enabled: enabled)
        } catch {
            updateTorchAppearance(enabled: false)
        }
    }

    private func updateTorchAppearance(enabled: Bool) {
        torchButton.isSelected = enabled
        torchButton.accessibilityTraits = enabled ? [.button, .selected] : .button
        torchButton.backgroundColor = enabled
            ? UIColor.systemYellow.withAlphaComponent(0.34)
            : UIColor.black.withAlphaComponent(0.46)
        torchButton.layer.borderColor = enabled
            ? UIColor.systemYellow.withAlphaComponent(0.62).cgColor
            : UIColor.white.withAlphaComponent(0.12).cgColor
    }

    @objc
    private func closeScanner() {
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc
    private func openPhotoLibrary() {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        stopCaptureSession()

        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        picker.mediaTypes = [UTType.image.identifier]
        picker.modalPresentationStyle = .fullScreen
        picker.navigationBar.prefersLargeTitles = false
        picker.view.tintColor = .systemBlue
        present(picker, animated: true)
    }

    @objc
    private func toggleTorch() {
        setTorch(enabled: !torchButton.isSelected)
    }

    @objc
    private func hideInvalidGalleryQRCodeAlert() {
        guard let backdrop = invalidAlertBackdropView else { return }
        let completion: (Bool) -> Void = { [weak self, weak backdrop] _ in
            backdrop?.removeFromSuperview()
            self?.startCaptureSession()
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            completion(true)
            return
        }
        UIView.animate(
            withDuration: 0.18,
            animations: { backdrop.alpha = 0 },
            completion: completion
        )
    }
}

extension QRCodeScannerViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            self?.startCaptureSession()
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard let image else {
                showInvalidGalleryQRCodeAlert()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let code = QRCodeScannerImageDecoder.firstCode(in: image)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let code else {
                        self.showInvalidGalleryQRCodeAlert()
                        return
                    }
                    self.found(code: code)
                }
            }
        }
    }
}
