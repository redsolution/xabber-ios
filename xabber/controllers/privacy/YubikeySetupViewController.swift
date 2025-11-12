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
import YubiKit


class YubikeySetupViewController: SimpleBaseViewController {
    open var isFromOnboarding: Bool = true
    open var isModal: Bool = false
    
    class Datasource {
        enum Kind {
            case lbael
            case button(String)
        }
        
        var title: String
        var subtitle: String
        var kind: Kind
        var isTimeField: Bool
        
        init(title: String, subtitle: String, kind: Kind, isTimeField: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.kind = kind
            self.isTimeField = isTimeField
        }
    }
    
    internal var datasource: [[Datasource]] = []
    var timer: Timer? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "YKTableCell")
        
        
        
        return view
    }()
    
    internal let skipButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Skip", style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    var state: SignatureManager.ActionKind = .certificate

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        
        
        var signatureDatasource: [Datasource] = []
        if let _ = CredentialsManager.shared.getSignatureTimestamp() {
            signatureDatasource = [
                Datasource(title: "Valid for", subtitle: "", kind: .lbael, isTimeField: true),
                Datasource(title: "Update signature", subtitle: "", kind: .button("sign"))
            ]
        } else {
            signatureDatasource = [
                Datasource(title: "Signature not set", subtitle: "", kind: .lbael),
                Datasource(title: "Update signature", subtitle: "", kind: .button("sign"))
            ]
        }
        
        var certDatasource: [Datasource] = []
        
        if let cert = SignatureManager.shared.certificate {
            if let subjectSummary = SecCertificateCopySubjectSummary(cert) as String? {
                certDatasource.append(Datasource(
                    title: "ID",
                    subtitle: subjectSummary,
                    kind: .lbael
                ))
            }
            var cfName: CFString?
            SecCertificateCopyCommonName(cert, &cfName)
            var issuedBy: String?
            if let name = cfName as? String,
               let last = name.split(separator: "@").last,
               let serverName = last.split(separator: ".").first {
                issuedBy = String(serverName).capitalized
            }
            certDatasource.append(Datasource(
                title: "Issued by",
                subtitle: issuedBy ?? cfName as String? ?? "Undefined",
                kind: .lbael
            ))
            var cfEmail: CFArray?
            SecCertificateCopyEmailAddresses(cert, &cfEmail)
        }
        
        
        self.datasource = [
            certDatasource,
            signatureDatasource//,
//            [
//                Datasource(title: "Forget yubikey", subtitle: "", kind: .button("delete"))
//            ]
        ]
    }
    
    override func configure() {
        super.configure()
        self.title = "Yubikey"
        self.tableView.delegate = self
        self.tableView.dataSource = self
        if !isFromOnboarding {
            self.skipButton.title = "Cancel"
        }
//        self.navigationItem.setRightBarButton(skipButton, animated: true)
        skipButton.target = self
        skipButton.action = #selector(onSkipButtonTouchUpInside)
        
    }
    
    @objc
    internal func onSkipButtonTouchUpInside(_ sender: UIBarButtonItem) {
        dismissView()
    }
    
    override func onAppear() {
        super.onAppear()
        self.timer = Timer.scheduledTimer(timeInterval: 0.5,
                                          target: self,
                                          selector: #selector(updateTsCell),
                                          userInfo: nil,
                                          repeats: true)
    }
    
    @objc
    internal func updateTsCell(_ sender: AnyObject) {
        DispatchQueue.main.async {
            let section = 1
            guard let row = self.datasource[section].firstIndex(where: { $0.isTimeField }) else {
                return
            }
            let path = IndexPath(row: row, section: section)
            self.tableView.reloadRows(at: [path], with: .none)
        }
    }
    
    
    private final func dismissView() {
        if isFromOnboarding {
            let vc = SignUpEnableNotificationsViewController()
            self.navigationController?.setViewControllers([vc], animated: true)
        } else {
            if isModal {
                self.navigationController?.dismiss(animated: true, completion: nil)
            } else {
                self.navigationController?.popViewController(animated: true)
            }
            
        }
        
    }
}

extension YubikeySetupViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button(let value):
            switch value {
            case "sign":
                SignatureManager.shared.delegate = self
                FeedbackManager.shared.tap()
                if #available(iOS 13.0, *) {
                    if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                        SignatureManager.shared.currentAction = .signature
                        YubiKitExternalLocalization.nfcScanAlertMessage = "Generate digital signature"
                        YubiKitManager.shared.startNFCConnection()
                        YubiKitManager.shared.delegate = SignatureManager.shared
                    }
                }
            case "delete":
                YesNoPresenter().present(
                    in: self,
                    style: .actionSheet,
                    title: "Forget registered Yubikey",
                    message: "Some text about deleting yubikey",
                    yesText: "Forget",
                    dangerYes: true,
                    noText: "Cancel",
                    animated: true) { result in
                        if result {
                            DispatchQueue.main.async {
                                SignatureManager.shared.clear()
                                CredentialsManager.shared.clearSignature()
                                self.navigationController?.popViewController(animated: true)
                            }
                        }
                    }
                
                
            default:
                break
            }
        default: break
        }
    }
}

extension YubikeySetupViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        let cell = UITableViewCell(style: UITableViewCell.CellStyle.value1, reuseIdentifier: "YKTableCell")
        cell.selectionStyle = .none
        switch item.kind {
        case .lbael:
            cell.textLabel?.text = item.title
            if item.isTimeField {
                if let signatureTs = CredentialsManager.shared.getSignatureTimestamp() {
                    let interval = signatureTs + Double(CommonConfigManager.shared.config.time_signature_for_messages_period) - Date().timeIntervalSince1970
                    if interval < 0 {
                        cell.detailTextLabel?.text = "Expired"
                    } else {
                        let formatter = DateComponentsFormatter()
                        cell.detailTextLabel?.attributedText = NSAttributedString(string: formatter.string(from: interval) ?? " ",
                                                                                  attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: UIFont.labelFontSize, weight: .regular)])
                    }
                    
                }
            } else {
                cell.detailTextLabel?.text = item.subtitle
                let checkView = UIImageView(frame: CGRect(square: 24))
                checkView.image = imageLiteral( "xabber.checkmark")
                checkView.tintColor = .systemGreen
                cell.accessoryView = checkView
            }
        case .button(let value):
            cell.textLabel?.text = item.title
            if value == "delete" {
                cell.textLabel?.textColor = .systemRed
            } else {
                cell.textLabel?.textColor = .systemBlue
            }
            
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Certificate"
        case 1: return "Signature"
        default: return nil
        }
    }
    
    
}


extension YubikeySetupViewController: SignatureManagerDelegate {
    func didConnectionStop(with error: Error?) {
        
    }
    
    func didGenerateDigitalSignature(with error: Error?) {
        DispatchQueue.main.async {
            self.loadDatasource()
            self.tableView.reloadData()
        }
    }
    
    func retrieveCertificate(with error: Error?) {
        
    }
    
    func retrieveYubikeyInfo(with error: Error?) {
        
    }
    
    
}
