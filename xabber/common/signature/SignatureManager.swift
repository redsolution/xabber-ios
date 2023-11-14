//
//  SignatureManager.swift
//  clandestino
//
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
import XMPPFramework
import YubiKit
import RxSwift
import RealmSwift
import CryptoSwift

protocol SignatureManagerDelegate {
    func didConnectionStop(with error: Error?)
    func didGenerateDigitalSignature(with error: Error?)
    func retrieveCertificate(with error: Error?)
    func retrieveYubikeyInfo(with error: Error?)
}

class SignatureManager: NSObject {
    open class var shared: SignatureManager {
        struct SignatureManagerSingleton {
            static let instance = SignatureManager()
        }
        return SignatureManagerSingleton.instance
    }
    
    enum SignatureError: Error {
        case commonError
        case certNotForUser
    }
    
    enum ActionKind {
        case info
        case certificate
        case signature
    }
    
    
    struct BundleSignedInfo {
        let signedBy: String
        let signedAt: Double
    }
    
    class MessageError {
        var hasError: Bool = true
        var certValid: Bool = false
        var certConfirmed: Bool = false
        var signed: Bool = false
        var signDecrypted: Bool = false
        var signValid: Bool = false
        var certCommonName: String = ""
        var certSubject: String = ""
        
        init() {
            
        }
        
        init(from dict: [String: Any]) {
            self.certValid = dict["certValid"] as? Bool ?? false
            self.certConfirmed = dict["certConfirmed"] as? Bool ?? false
            self.signed = dict["signed"] as? Bool ?? false
            self.signDecrypted = dict["signDecrypted"] as? Bool ?? false
            self.signValid = dict["signValid"] as? Bool ?? false
            self.certCommonName = dict["certCommonName"] as? String ?? ""
            self.certSubject = dict["certSubject"] as? String ?? ""
        }
        
        func confirm() {
            self.hasError = false
            self.certValid = true
            self.certConfirmed = true
            self.signed = true
            self.signDecrypted = true
            self.signValid = true
        }
        
        var errorMetadata: [String: Any] {
            get {
                return [
                    "certValid": certValid,
                    "certConfirmed": certConfirmed,
                    "signed": signed,
                    "signDecrypted": signDecrypted,
                    "signValid": signValid,
                    "certCommonName": certCommonName,
                    "certSubject": certSubject
                ]
            }
        }
    }
    
    public var currentAction: ActionKind = .certificate
    
    public static let xmlns: String = "urn:xmpp:x509:0"
    
    public var certificate: SecCertificate? = nil
    public var rootCertificate: SecCertificate? = nil
    
    public var delegate: SignatureManagerDelegate? = nil
    fileprivate var checkSignatureTimestampTimer: Timer? = nil
    fileprivate var isCheckSignatureDialogShowed: Bool = false
    
    private var signature: String? {
        get {
            if let ts = CredentialsManager.shared.getSignatureTimestamp(),
               Date().timeIntervalSince1970 - ts < Double(CommonConfigManager.shared.config.time_signature_for_messages_period),
               let signature = CredentialsManager.shared.getSignature() {
                return signature
            }
            return nil
        }
    }
        
    public var signatureElement: DDXMLElement? {
        get {
            guard let signature = self.signature else {
                return nil
            }

            let element = DDXMLElement(name: "time-signature", xmlns: SignatureManager.xmlns)
            element.stringValue = signature
            if let stamp = CredentialsManager.shared.getSignatureTimestamp() {
                element.addAttribute(withName: "stamp", doubleValue: round(stamp))
            }
            
            return element
        }
    }
    
//    public var bundleSignatureElement: DDXMLElement? {
//        get {
//            guard let signature = self.signature else {
//                return nil
//            }
//
//            let element = DDXMLElement(name: "signature", xmlns: SignatureManager.xmlns)
//            element.stringValue = signature
//            
//            if let stamp = CredentialsManager.shared.getSignatureTimestamp() {
//                element.addAttribute(withName: "stamp", doubleValue: round(stamp))
//            }
//            
//            return element
//        }
//    }
    
    public var isSignatureSetted: Bool {
        get {
            return CredentialsManager.shared.getSignature() != nil
        }
    }
    
    override init() {
        super.init()
        guard let path = Bundle.main.path(forResource: "root", ofType: "crt"),
              let rootUrl = URL(string: path),
              let data = try? Data(contentsOf: rootUrl) as CFData,
              let crt = SecCertificateCreateWithData(nil, data) else {
                  return
              }
        self.rootCertificate = crt
    }
    
    public final func prepare() {
        if let data = CredentialsManager.shared.loadCertificate() {
            self.certificate = SecCertificateCreateWithData(nil, data)
        }
//        self.checkSignatureTimestampTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(self.checkStoredSignatureTimestamp), userInfo: nil, repeats: true)
//            
//        RunLoop.main.add(self.checkSignatureTimestampTimer!, forMode: .default)
    }
    
    public func isSignatureValid() -> Bool {
        return self.signature != nil
    }
    
    public final func clear() {
        self.certificate = nil
        guard let jid = AccountManager.shared.users.first?.jid else {
            return
        }
        XMPPUIActionManager.shared.performRequest(owner: jid) { stream, session in
            session.x509?.publicateCertificate(stream, remove: true)
        } fail: {
            AccountManager.shared.find(for: jid)?.action({ user, stream in
                user.x509Manager.publicateCertificate(stream, remove: true)
            })
        }

    }
    
    public func checkBundleSignature(owner: String, for jid: String, signature: DDXMLElement?) throws -> BundleSignedInfo? {
        
        guard let sign = signature?.stringValue,
            let en = Data(base64Encoded: sign) else {
            return nil
        }
        guard let tsRaw = signature?.attributeDoubleValue(forName: "stamp"),
              let ts = "\(tsRaw)".data(using: .utf8) else {
            return nil
        }
        
        let realm = try WRealm.safe()
        
        guard let certData = realm.object(ofType: X509StorageItem.self, forPrimaryKey: X509StorageItem.genRpimary(owner: owner, jid: jid))?.certData else {
            return nil
        }
        
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }
        
//        guard let certificate = self.certificate else {
//            return nil
//        }
        
        if let key = SecCertificateCopyKey(cert) {
            guard SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA512) else {
                return nil
            }
            var error: Unmanaged<CFError>?
            let verf = SecKeyVerifySignature(
                key,
                .rsaSignatureMessagePKCS1v15SHA512,
                ts as CFData,
                en as CFData,
                &error
            )
            if !verf { return nil }
        }
        
        var cfName: CFString?
        SecCertificateCopyCommonName(cert, &cfName)
        if let cn = cfName as String? {
            return BundleSignedInfo(signedBy: cn, signedAt: tsRaw)
        }
        return nil
    }
    
    public func checkSignature(owner: String, for jid: String, signature: DDXMLElement?, messageDate: Date) throws -> MessageError {
        let result = MessageError()
        
        guard let sign = signature?.stringValue,
            let en = Data(base64Encoded: sign) else {
            return result
        }
        guard let tsRaw = signature?.attributeDoubleValue(forName: "stamp"),
              let ts = "\(tsRaw)".data(using: .utf8) else {
            return result
        }
        result.signed = true
        result.signDecrypted = true
        result.signValid = true
        
        let realm = try WRealm.safe()
        
        guard let certData = realm.object(ofType: X509StorageItem.self, forPrimaryKey: X509StorageItem.genRpimary(owner: owner, jid: jid))?.certData else {
            return result
        }
        
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return result
        }
        result.certConfirmed = true
        
        if let subjectSummary = SecCertificateCopySubjectSummary(cert) as String? {
            result.certSubject = subjectSummary
        }
        var cfName: CFString?
        SecCertificateCopyCommonName(cert, &cfName)
        if let cn = cfName as String? {
            result.certValid = cn == jid
            result.certCommonName = cn
        }
        
        
//        guard let certificate = self.certificate else {
//            return result
//        }

        if let key = SecCertificateCopyKey(cert) {
            guard SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA512) else {
                return result
            }
            result.signDecrypted = true
            print(tsRaw, ts, ts.bytes)
            var error: Unmanaged<CFError>?
            let verf = SecKeyVerifySignature(
                key,
                .rsaSignatureMessagePKCS1v15SHA512,
                ts as CFData,
                en as CFData,
                &error
            )
            result.signValid = verf
        }
        
        return result
    }
    
    private func updateSignature(_ signature: String, for timestamp: TimeInterval, device deviceType: YUDeviceType) {
        CredentialsManager.shared.setSignature(signature, for: timestamp, deviceType: deviceType)
        guard let jid = AccountManager.shared.users.first?.jid else {
            return
        }
        
        AccountManager.shared.find(for: jid)?.action({ user, stream in
            try? user.omemo.sendOwnDeviceBundle(stream, createNode: false)
        })
    }
    
    private final func publicateCertificate() {
        guard let jid = AccountManager.shared.users.first?.jid else {
            return
        }
        if let certificate = certificate {
            let data = SecCertificateCopyData(certificate)
            CredentialsManager.shared.storeCertificate(data)
            
            XMPPUIActionManager.shared.performRequest(owner: jid) { stream, session in
                session.x509?.publicateCertificate(stream, remove: false)
            } fail: {
                AccountManager.shared.find(for: jid)?.action({ user, stream in
                    user.x509Manager.publicateCertificate(stream, remove: false)
                })
            }
        }
        
        
    }
    
    @objc
    internal func checkStoredSignatureTimestamp(_ sender: AnyObject) {
        if ApplicationStateManager.shared.state == .locked {
            return
        }
        if AccountManager.shared.users.isNotEmpty {
//            if let ts = CredentialsManager.shared.getSignatureTimestamp(),
//               (Date().timeIntervalSince1970 - ts) > 60000 {
//                if !self.isCheckSignatureDialogShowed {
//                    self.isCheckSignatureDialogShowed = true
//                    UpdateSignaturePresenter().present()
//                }
//            }
        }
    }
    
    fileprivate final func releaseUpdateSignatureDialog() {
        self.isCheckSignatureDialogShowed = false
    }
    
    public final func isCertificateStored(for jid: String, owner: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: X509StorageItem.self,
                forPrimaryKey: X509StorageItem.genRpimary(
                    owner: owner,
                    jid: jid
                )
            ) == nil
        } catch {
            DDLogDebug("SignatureManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
}

extension SignatureManager: YKFManagerDelegate {
    
    private final func stopConnection(_ connection: YKFConnectionProtocol, with message: String, error: Bool) {
        if let connection = connection as? YKFNFCConnection {
            if #available(iOS 13.0, *) {
                if error {
                    connection.stopWithErrorMessage(message)
                } else {
                    connection.stop(withMessage: message)
                }
            }
        } else if let connection = connection as? YKFAccessoryConnection {
            connection.stop()
        }
    }
    
    
    private final func requestSignature(from connection: YKFConnectionProtocol, deviceType: YUDeviceType, action: ActionKind) {
//        connection.managementSession { session, error in
//            session?.getDeviceInfo(completion: { info, error in
//                info.
//            })
//        }
        switch action {
        case .info:
            connection.managementSession { session, error in
                guard error == nil else {
                    self.delegate?.didConnectionStop(with: error)
                    self.delegate?.retrieveYubikeyInfo(with: error)
                    return
                }
                session?.getDeviceInfo(completion: { deviceInfo, error in
                    guard error == nil,
                        let deviceInfo = deviceInfo else {
                        self.delegate?.didConnectionStop(with: error)
                        self.delegate?.retrieveYubikeyInfo(with: error)
                        return
                    }
//                    YKFFormFactor
//                    deviceInfo.for
                })
            }
        case .certificate:
            connection.pivSession { session, error in
                guard error == nil else {
                    self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                    self.delegate?.didConnectionStop(with: error)
                    self.delegate?.retrieveCertificate(with: error)
                    return
                }
                session?.verifyPin("123456", completion: { retries, error in
                    guard error == nil else {
                        self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                        self.delegate?.didConnectionStop(with: error)
                        self.delegate?.retrieveCertificate(with: error)
                        return
                    }
                    session?.getCertificateIn(.signature, completion: { cert, error in
                        guard error == nil else {
                            self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                            self.delegate?.didConnectionStop(with: error)
                            self.releaseUpdateSignatureDialog()
                            return
                        }
                        if let cert = cert {
                            var cfName: CFString?
                            SecCertificateCopyCommonName(cert, &cfName)
                            if let cn = cfName as String? {
                                if let jid = AccountManager.shared.users.first?.jid,
                                   jid != cn {
                                    self.stopConnection(connection, with: "Invalid certificate", error: true)
                                    self.delegate?.retrieveCertificate(with: SignatureError.certNotForUser)
                                    return
                                }
                            }
                            
                            self.certificate = cert
                            
                            self.publicateCertificate()
                            self.stopConnection(connection, with: "", error: false)
                            self.delegate?.retrieveCertificate(with: nil)
                        } else {
                            
                            self.stopConnection(connection, with: "Unexpected error", error: true)
                            self.delegate?.retrieveCertificate(with: SignatureError.commonError)
                        }
                        
                    })

                })
            }
        case .signature:
            connection.pivSession { session, error in
                guard error == nil else {
                    self.delegate?.didConnectionStop(with: error)
                    self.delegate?.didGenerateDigitalSignature(with: SignatureError.commonError)
                    self.releaseUpdateSignatureDialog()
                    self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                    return
                }

                session?.verifyPin("123456", completion: { retries, error in
                    guard error == nil else {
                        self.delegate?.didConnectionStop(with: error)
                        self.delegate?.didGenerateDigitalSignature(with: SignatureError.commonError)
                        self.releaseUpdateSignatureDialog()
                        self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                        return
                    }
                    let stamp = Double(UInt32(Date().timeIntervalSince1970))
                    guard let ts = "\(stamp)".data(using: .utf8) else {
                        return
                    }
                    //rsaSignatureMessagePKCS1v15SHA256
                    session?.signWithKey(in: .signature, type: .RSA2048, algorithm: SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA512, message: ts, completion: { result, error in
                        guard error == nil else {
                            self.delegate?.didConnectionStop(with: error)
                            self.delegate?.didGenerateDigitalSignature(with: SignatureError.commonError)
                            self.releaseUpdateSignatureDialog()
                            self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                            return
                        }
                        var errorPointer: Unmanaged<CFError>?
                        print(stamp, ts, ts.bytes)
                        guard let cert = SignatureManager.shared.certificate,
                              let publicKey = SecCertificateCopyKey(cert),
                              let signature = result,
                              SecKeyVerifySignature(publicKey, SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA512, ts as CFData, signature as CFData, &errorPointer) else {
                            self.stopConnection(connection, with: "Incorrect Yubikey. Please apply key issued for \(AccountManager.shared.users.first?.jid ?? "your account" )", error: true)
                            DispatchQueue.main.async {
                                self.delegate?.didConnectionStop(with: SignatureError.commonError)
                                self.delegate?.didGenerateDigitalSignature(with: SignatureError.commonError)
                                self.releaseUpdateSignatureDialog()
                            }
                            return
                        }
                        if let result = result {
                            self.updateSignature(result.base64EncodedString(), for: stamp, device: deviceType)
                            self.stopConnection(connection, with: "Account successfully verified", error: false)
                            self.delegate?.didConnectionStop(with: nil)
                            self.delegate?.didGenerateDigitalSignature(with: nil)
                            self.releaseUpdateSignatureDialog()
                        } else {
                            self.stopConnection(connection, with: "Connection error. Please try again", error: true)
                            DispatchQueue.main.async {
                                self.delegate?.didConnectionStop(with: SignatureError.commonError)
                                self.delegate?.didGenerateDigitalSignature(with: SignatureError.commonError)
                                self.releaseUpdateSignatureDialog()
                            }
                        }
                    })
                })
            }
        }


    }
    
    func didConnectNFC(_ connection: YKFNFCConnection) {
        requestSignature(from: connection, deviceType: .nfc, action: currentAction)
    }
    
    func didDisconnectNFC(_ connection: YKFNFCConnection, error: Error?) {
        print(#function)
    }
    
    func didConnectAccessory(_ connection: YKFAccessoryConnection) {
        requestSignature(from: connection, deviceType: .dongle, action: currentAction)
    }
    
    func didDisconnectAccessory(_ connection: YKFAccessoryConnection, error: Error?) {
        print(#function)
    }
    
    
}
