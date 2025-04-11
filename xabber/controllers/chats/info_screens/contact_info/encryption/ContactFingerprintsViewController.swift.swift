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
import RealmSwift
import TOInsetGroupedTableView
import CocoaLumberjack


class ContactFingerprintsViewController: SimpleBaseViewController {
    open var isFromOnboarding: Bool = true
    open var isModal: Bool = false
    
    class Datasource {
        enum Kind {
            case lbael
            case button(String)
        }
        
        
//        var fingerprint: String
//        var clientL: String
//
//
//        var title: String
//        var subtitle: String
        var kind: Kind
        
        init(kind: Kind) {
            self.kind = kind
        }
//        var isTimeField: Bool
//
//        init(fingerprint: String, client: String, device: String, description descr: String, ip: String, lastAuth: Date, current: Bool, editable: Bool, isOnline: Bool) {
//            self.title = title
//            self.subtitle = subtitle
//            self.kind = kind
//            self.isTimeField = isTimeField
//        }
    }
    
    internal var datasource: [[Datasource]] = []
    var timer: Timer? = nil
    
    private let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        
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

//        do {
//            let realm = try WRealm.safe()
//            
//            
//            
//        } catch {
//            DDLogDebug("ContactFingerprintsViewController: \(#function). \(error.localizedDescription)")
//        }
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
        self.timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateTsCell), userInfo: nil, repeats: true)
    }
    
    @objc
    internal func updateTsCell(_ sender: AnyObject) {
//        DispatchQueue.main.async {
//            let section = 1
//            if let row = self.datasource[section].firstIndex(where: { $0.isTimeField }) {
//                let path = IndexPath(row: row, section: section)
//                self.tableView.performBatchUpdates {
//                    self.tableView.reloadRows(at: [path], with: .none)
//                } completion: { result in
//                    self.tableView.beginUpdates()
//                    self.tableView.reloadRows(at: [path], with: .none)
//                    self.tableView.endUpdates()
//                }
//
//                
//            }
//        }
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

extension ContactFingerprintsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button(let value):
            switch value {
//            case "sign":
//                SignatureManager.shared.delegate = self
//                FeedbackManager.shared.tap()
//                if #available(iOS 13.0, *) {
//                    if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
//                        SignatureManager.shared.currentAction = .signature
//                        YubiKitExternalLocalization.nfcScanAlertMessage = "Generate digital signature"
//                        YubiKitManager.shared.startNFCConnection()
//                        YubiKitManager.shared.delegate = SignatureManager.shared
//                    }
//                }
//            case "delete":
//                YesNoPresenter().present(
//                    in: self,
//                    style: .actionSheet,
//                    title: "Forget registered Yubikey",
//                    message: "Some text about deleting yubikey",
//                    yesText: "Forget",
//                    dangerYes: true,
//                    noText: "Cancel",
//                    animated: true) { result in
//                        if result {
//                            DispatchQueue.main.async {
//                                SignatureManager.shared.clear()
//                                CredentialsManager.shared.clearSignature()
//                                self.navigationController?.popViewController(animated: true)
//                            }
//                        }
//                    }
//
                
            default:
                break
            }
        default: break
        }
    }
}

extension ContactFingerprintsViewController: UITableViewDataSource {
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
//        switch item.kind {
//        case .lbael:
//            cell.textLabel?.text = item.title
//            if item.isTimeField {
//                if let signatureTs = CredentialsManager.shared.getSignatureTimestamp() {
//                    let interval = signatureTs + Double(CommonConfigManager.shared.config.time_signature_for_messages_period) - Date().timeIntervalSince1970
//                    if interval < 0 {
//                        cell.detailTextLabel?.text = "Expired"
//                    } else {
//                        let formatter = DateComponentsFormatter()
//                        cell.detailTextLabel?.text = formatter.string(from: interval)
//                    }
//
//                }
//            } else {
//                cell.detailTextLabel?.text = item.subtitle
//            }
//        case .button(let value):
//            cell.textLabel?.text = item.title
//            if value == "delete" {
//                cell.textLabel?.textColor = .systemRed
//            } else {
//                cell.textLabel?.textColor = .systemBlue
//            }
//
//        }
        
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
