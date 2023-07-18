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
import Toast_Swift

class QRCodeViewController: UIViewController {
    
    internal let QRSize: CGSize = CGSize(square: 280)
    
    open var stringValue: String = ""
    open var username: String = ""
    open var jid: String = ""
    
    internal var qrImage: UIImage? = nil
    internal var brightness: CGFloat = 0.0
    
    internal let imageView: UIImageView = {
        let view = UIImageView()
        view.tintColor = .red
        return view
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.alignment = .center
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 32
        
        return stack
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
        
        return label
    }()
    
    @objc
    internal func cancel(_ sender: UIBarButtonItem) {
        UIScreen.main.brightness = self.brightness
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    internal func share(_ sender: UIBarButtonItem) {
        guard let image = qrImage else {
            self.view.makeToast("Can`t share QR-code".localizeString(id: "account_cant_share_qr", arguments: []))
            return
        }
        let shareVC = UIActivityViewController(activityItems: [image, stringValue],
                                               applicationActivities: [])
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = shareVC.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        self.present(shareVC, animated: true, completion: nil)
    }
    
    internal func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: String.Encoding.ascii)

        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            let transform = CGAffineTransform(scaleX: 3, y: 3)

            if let output = filter.outputImage?.transformed(by: transform) {
                return UIImage(ciImage: output)
            }
        }

        return nil
    }
    
    internal func configure() {
        title = "QR-code".localizeString(id: "dialog_show_qr_code__header", arguments: [])
        imageView.frame = CGRect(
            x: (view.frame.width - QRSize.width) / 2,
            y: (view.frame.height - QRSize.height) / 2,
            width: QRSize.width,
            height: QRSize.height
        )
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        view.addSubview(imageView)
        imageView.centerInSuperview()
        qrImage = generateQRCode(from: stringValue)?.upscale(dimension: 280)
        imageView.image = qrImage
        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share))
        navigationItem.setLeftBarButton(cancelButton, animated: true)
        navigationItem.setRightBarButton(shareButton, animated: true)
        
        view.addSubview(stack)
        stack.fillSuperviewWithOffset(top: (view.frame.height - QRSize.height) / 2 + QRSize.height + 24, bottom: 0, left: 16, right: 16)
        stack.addArrangedSubview(usernameLabel)
        stack.addArrangedSubview(jidLabel)
        stack.addArrangedSubview(UIStackView())
        usernameLabel.text = username
        jidLabel.text = JidManager.shared.prepareJid(jid: jid)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.brightness = UIScreen.main.brightness
        UIScreen.main.brightness = 1.0
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIScreen.main.brightness = self.brightness
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
