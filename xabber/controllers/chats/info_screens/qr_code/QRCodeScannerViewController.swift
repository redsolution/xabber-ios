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
import AVFoundation
import UIKit
import RealmSwift
import MaterialComponents.MDCPalettes
import XMPPFramework.XMPPJID
import Toast_Swift
import Kingfisher

protocol QRCodeScannerDelegate {
    func didReceive(jid: String, username: String?)
}

class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!

    
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
    
    private let qrScannerView: UIView = {
        let view = UIView()
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        view.layer.cornerRadius = 32
//        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        
        return view
    }()
    
    private let dragToDismissButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        button.layer.cornerRadius = 3
        
        return button
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        
        return stack
    }()
    
    
    private let openButton: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        button.isEnabled = true
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.setTitle("Check".localizeString(id: "check", arguments: []), for: .normal)
        button.setTitle("Check".localizeString(id: "check", arguments: []), for: .disabled)
        
        return button
    }()
    
    private let contactInfoStack: UIStackView = {
        let view = UIStackView()
        
        view.axis = .horizontal
        view.alignment = .center
        view.spacing = 16
        
        return view
    }()
    
    private let avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(square:  176))
        
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.layer.masksToBounds = true
        view.isHidden = true
        
        return view
    }()
    
    private let usernameLabel: UILabel = {
        let label = UILabel()
        
        if #available(iOS 13.0, *) {
            label.textColor = .label
        } else {
            label.textColor = .darkText
        }
        
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        
        label.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        
        label.isHidden = true
        
        return label
    }()
        
    private let jidLabel: UILabel = {
        let label = UILabel()
        
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        
        label.font = UIFont.systemFont(ofSize: 15, weight: .light)
        
        label.isHidden = true
        
        return label
    }()
    
    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        
        view.startAnimating()
        
        return view
    }()
    
    public var delegate: QRCodeScannerDelegate? = nil
    
    private var jid: String = ""
    private var owner: String = ""
    private var nickname: String? = nil
    private var dataLoaded: Bool = false
    private var hasError: Bool = false
    
    internal var avatarUrl: String? = nil
    
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
            self.openButton.isEnabled = true
            self.openButton.backgroundColor = .systemBlue
            self.openButton.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.openButton.isEnabled = false
            self.openButton.backgroundColor = MDCPalette.grey.tint100
            self.openButton.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    public func activateConstraints() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NSLayoutConstraint.activate([
                openButton.widthAnchor.constraint(equalToConstant: 264),
                openButton.heightAnchor.constraint(equalToConstant: 44),
                qrScannerView.widthAnchor.constraint(equalToConstant: 382),
                qrScannerView.heightAnchor.constraint(equalToConstant: 280)
            ])
        } else {
            NSLayoutConstraint.activate([
                openButton.widthAnchor.constraint(equalToConstant: 264),
                openButton.heightAnchor.constraint(equalToConstant: 44),
                qrScannerView.widthAnchor.constraint(equalToConstant: self.view.frame.width - 32),
                qrScannerView.heightAnchor.constraint(equalToConstant: 280)
            ])
        }
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 176),
            avatarView.heightAnchor.constraint(equalToConstant: 176)
        ])
    }
    
    public func setupSubviews() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            contentView.frame = CGRect(
                x: (self.view.frame.width - 414) / 2,
                y: self.view.frame.height / 2 + 16,
                width: 414,
                height: (self.view.frame.height / 2) - 16)
            dragToDismissButton.frame = CGRect(x: 414 / 2 - 32, y: 8, width: 64, height: 6)
        } else {
            contentView.frame = CGRect(
                x: 0,
                y: self.view.frame.height / 2 - 96,
                width: self.view.frame.width,
                height: (self.view.frame.height / 2) + 96)
            dragToDismissButton.frame = CGRect(x: self.view.frame.width / 2 - 32, y: 8, width: 64, height: 6)
        }
        
        view.addSubview(contentView)
        contentView.addSubview(dragToDismissButton)
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 60, bottom: 36, left: 32, right: 32)
//        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(qrScannerView)
        stack.addArrangedSubview(avatarView)
//        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(usernameLabel)
        stack.addArrangedSubview(jidLabel)
        stack.addArrangedSubview(openButton)
       
    }
    
    public func configure() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        let dismissGestureRecognizer = PanDirectionGestureRecognizer(direction: .vertical, target: self, action: #selector(self.onDismissGestureRecognizerDidChange))
        dismissGestureRecognizer.delaysTouchesBegan = true
        dismissGestureRecognizer.maximumNumberOfTouches = 1
        
        contentView.addGestureRecognizer(dismissGestureRecognizer)
        let dismissGesture = UITapGestureRecognizer(target: self, action: #selector(dismissOnTap))
        dismissGesture.delaysTouchesBegan = true
        self.view.addGestureRecognizer(dismissGesture)
        makeButtonDisabled(false)
        openButton.addTarget(self, action: #selector(onOpenButtonTouchUpInside), for: .touchUpInside)
                
        captureSession = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        let videoInput: AVCaptureDeviceInput

        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            return
        }

        if (captureSession.canAddInput(videoInput)) {
            captureSession.addInput(videoInput)
        } else {
            failed()
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        if (captureSession.canAddOutput(metadataOutput)) {
            captureSession.addOutput(metadataOutput)

            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            failed()
            return
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            previewLayer.frame = CGRect(
                width: 350,
                height: 280
            )
        } else {
            previewLayer.frame = CGRect(
                width: self.view.frame.width - 64,
                height: 280
            )
        }
        
        
        previewLayer.cornerRadius = 24
//        previewLayer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        
        previewLayer.videoGravity = .resizeAspectFill
        qrScannerView.layer.addSublayer(previewLayer)

        captureSession.startRunning()
        
        do {
            let realm = try WRealm.safe()
            if let owner = realm.objects(AccountStorageItem.self).filter("enabled == %@", true).sorted(byKeyPath: "order").first?.jid {
                self.owner = owner
                XMPPUIActionManager.shared.open(owner: owner)
            } else {
                self.view.makeToast("Connect at least one account to get information".localizeString(id: "account_connect_account_message", arguments: []))
            }
        } catch {
            DDLogDebug("QRCodeScannerViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func addObservers() {
        
    }
    
    public func removeObservers() {
        
    }
    
    public func localizeResources() {
        
    }
    
    public func onAppear() {
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSubviews()
        configure()
        localizeResources()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    @objc
    func reloadDatasource() {
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        addObservers()
        onAppear()
        
        if (captureSession?.isRunning == false) {
            captureSession.startRunning()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if (captureSession?.isRunning == true) {
            captureSession.stopRunning()
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeObservers()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
        
    @objc
    private final func onOpenButtonTouchUpInside(_ sender: UIButton) {
        if hasError {
            self.dismiss(animated: true, completion: nil)
            return
        }
        guard let formattedJid = XMPPJID(string: jid)?.bare else {
            return
        }
        if dataLoaded {
            self.dismiss(animated: true, completion: nil)
            self.delegate?.didReceive(jid: formattedJid, username: nickname)
            return
        }
        makeButtonDisabled(true)
        
    }
    
    @objc
    private final func onDismissGestureRecognizerDidChange(_ sender: UIPanGestureRecognizer) {
        let y = sender.translation(in: self.contentView).y
        if sender.state == .ended {
            if y > 160 {
                FeedbackManager.shared.tap()
                self.dismiss(animated: true, completion: nil)
                return
            }
            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                let rect = self.contentView.frame
                self.contentView.frame = CGRect(
                    x: 0,
                    y: self.view.frame.height / 2 - 96,
                    width: rect.width,
                    height: rect.height
                )
            } completion: { result in
                
            }

        }
        if sender.state != .changed { return }
        let rect = self.contentView.frame
        if y > 0 {
            self.contentView.frame = CGRect(
                x: 0,
                y: self.view.frame.height / 2 - 96 + y,
                width: rect.width,
                height: rect.height
            )
        }
    }
    
    @objc
    private final func dismissOnTap(_ sender: AnyObject) {
//        FeedbackManager.shared.tap()
//        self.dismiss(animated: true, completion: nil)
    }
           
    

    func failed() {
        self.view.makeToast("Invalid QR code".localizeString(id: "account_invalid_qr_message", arguments: []))
        self.captureSession = nil
        self.hasError = true
        self.openButton.setTitle("Close".localizeString(id: "close", arguments: []), for: .normal)
        self.makeButtonEnabled(true)
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        captureSession.stopRunning()
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            found(code: stringValue)
        }
    }

    func found(code: String) {
        
        guard let url = URL(string: code),
            let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true),
            let jidComponent = components.path,
            let formattedJid = XMPPJID(string: jidComponent)?.bare else {
            self.hasError = true
            DispatchQueue.main.async {
                UIView.performWithoutAnimation {
                    self.stack.insertArrangedSubview(UIStackView(), at: 0)
                    self.qrScannerView.isHidden = true
                    self.avatarView.isHidden = false
                    self.usernameLabel.isHidden = false
                    self.jidLabel.isHidden = false
                }
                self.usernameLabel.text = "Error: Invalid QR code value".localizeString(id: "account_error_invalid_qr", arguments: [])
                self.jidLabel.text = "Value: \(code)".localizeString(id: "account_qr_code_value", arguments: [])
                self.openButton.setTitle("Close".localizeString(id: "close", arguments: []), for: .normal)
                self.makeButtonEnabled(true)
            }
            return
        }
        self.jid = formattedJid
        DispatchQueue.main.async {
            self.activityIndicator.frame = self.avatarView.bounds
            self.avatarView.addSubview(self.activityIndicator)
            self.avatarView.bringSubviewToFront(self.activityIndicator)
            self.avatarView.layoutSubviews()
            self.makeButtonEnabled(true)
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                session.vcardAvatarManager?.fetch(stream, for: formattedJid)
                session.vcardManager?.requestItem(stream, jid: formattedJid)
            } fail: {
                AccountManager.shared.users.filter { $0.xmppStream.isAuthenticated }.first?.action({ user, stream in
//                    user.vCardAvatars.fetch(stream, for: formattedJid)
                    user.vcards.requestItem(stream, jid: formattedJid)
                })
            }
            self.nickname = " "
            self.onUpdateVcard()
            let vcardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                do {
                    let realm = try WRealm.safe()
                    if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: formattedJid) {
                        timer.invalidate()
                        self.nickname = instance.generatedNickname
                        self.onUpdateVcard()
                        DispatchQueue.main.async {
                            self.dataLoaded = true
                            self.openButton.setTitle("Add contact".localizeString(id: "add_contact", arguments: []), for: .normal)
                            self.openButton.setTitle("Load".localizeString(id: "load", arguments: []), for: .disabled)
                            self.makeButtonEnabled(true)
                        }
                    }
                    self.activityIndicator.stopAnimating()
                } catch {
                    DDLogDebug("QRCodeScannerViewController: \(#function). \(error.localizedDescription)")
                }
            }
            vcardTimer.fire()
            RunLoop.main.add(vcardTimer, forMode: .default)
            let avatarTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                self.onUpdateAvatar()
            }
            avatarTimer.fire()
            RunLoop.main.add(avatarTimer, forMode: .default)
            UIView.performWithoutAnimation {
                self.stack.insertArrangedSubview(UIStackView(), at: 4)
                self.qrScannerView.isHidden = true
                self.avatarView.isHidden = false
                self.usernameLabel.isHidden = false
                self.jidLabel.isHidden = false
            }
        }
    }
    
    private final func onUpdateVcard() {
        self.usernameLabel.text = self.nickname
        self.jidLabel.text = JidManager.shared.prepareJid(jid: self.jid)
    }
    
    private final func onUpdateAvatar() {
        DefaultAvatarManager.shared.getAvatar(url: self.avatarUrl, jid: self.jid, owner: self.owner, size: 256) { image in
            if let image = image {
                self.avatarView.image = image
            } else {
                self.avatarView.setDefaultAvatar(for: self.jid, owner: self.owner)
            }
        }
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
}
