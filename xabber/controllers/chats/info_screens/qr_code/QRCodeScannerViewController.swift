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


class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!

    private let qrScannerView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .black
        view.layer.cornerRadius = 24
        
        return view
    }()
        
    private var jid: String = ""
    private var owner: String = ""
    private var nickname: String? = nil
    private var dataLoaded: Bool = false
    private var hasError: Bool = false
    
    internal var avatarUrl: String? = nil
       
    public func setupSubviews() {
        self.view.backgroundColor = .systemBackground
        self.view.addSubview(self.qrScannerView)
        self.qrScannerView.fillSuperviewWithOffset(top: 56, bottom: 16, left: 16, right: 16)
    }
    
    public func configure() {
        
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

        previewLayer.cornerRadius = 24
        
        previewLayer.videoGravity = .resizeAspectFill
        qrScannerView.layer.addSublayer(previewLayer)

        captureSession.startRunning()
    }
    
    public func addObservers() {
        
    }
    
    public func removeObservers() {
        
    }
    
    public func localizeResources() {
        
    }
    
    public func onAppear() {
        self.previewLayer.frame = self.qrScannerView.bounds
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSubviews()
        configure()
        localizeResources()
    }

    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        addObservers()
        // TODO: -[AVCaptureSession startRunning] should be called from background thread. Calling it on the main thread can lead to UI unresponsiveness
        if (captureSession?.isRunning == false) {
            captureSession.startRunning()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        onAppear()
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

    func failed() {
        self.view.makeToast("Invalid QR code".localizeString(id: "account_invalid_qr_message", arguments: []))
//        self.captureSession = nil
        self.captureSession.startRunning()
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
            self.failed()
            return
        }
        let vc = AddNewContactViewController()
        vc.contactJid.accept(formattedJid)
        if let parentVc = self.navigationController?.viewControllers[0] {
            self.navigationController?.setViewControllers([parentVc, vc], animated: true)
        } else {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
        
    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
}
