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
import CallKit
import UIKit
import CryptoSwift
import RealmSwift
import RxSwift
import RxCocoa
import XMPPFramework
import CocoaLumberjack
import WebRTC

class VoIPManager: NSObject {
   
    open class var shared: VoIPManager {
        struct VoIPManagerSingleton {
            static let instance = VoIPManager()
        }
        return VoIPManagerSingleton.instance
    }
   
    class CameraResolution {
        var height: Float
        var width: Float
       
        var horizontalAspectRatio: Float {
            return width / height
        }
        var verticalAspectRatio: Float {
            return height / width
        }
       
        init(height: Float, width: Float) {
            self.height = height
            self.width = width
        }
    }
   
    internal var provider: CXProvider
    internal var controller: CXCallController
    internal var update: CXCallUpdate? = nil
    internal var webRTC: WebRTCClient? = nil
   
    internal var callOwner: String?
    internal var callOpponent: String?
   
    internal var hasActiveCall: Bool = false
   
    internal var inCallingProcess: Bool = false
    internal var isCallAccepted: Bool = false
   
    internal var isCallEnded: Bool = false
   
    internal var currentCall: VoIPCall? = nil
    internal var callsQueue: [VoIPCall] = []
   
    internal var callScreenDelegate: VoIPCallManagerDelegate? = nil
   
    public var cameraPosition: AVCaptureDevice.Position = .front
       
    internal final var isVideoEnabled: Bool = false
    internal final var shouldChangeVideoModeAfterConnecting: Bool = false
   
    public var cameraResolution: BehaviorRelay<CameraResolution> = BehaviorRelay(value: CameraResolution(height: 640, width: 480))
   
    static func providerConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.emailAddress]
        configuration.includesCallsInRecents = false
        configuration.iconTemplateImageData = UIImage(named: "xabber_icon_call_kit")?.pngData()
        return configuration
    }
   
    override init() {
        let configuration = VoIPManager.providerConfiguration()
        self.provider = CXProvider(configuration: configuration)
        self.controller = CXCallController(queue: DispatchQueue.main)
       
        super.init()
        provider.setDelegate(self, queue: DispatchQueue.main)
        addObservers()
    }
   
    private func addObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: UIApplication.shared)
    }
   
    @objc private func willEnterForeground() {
        if let callState = self.currentCall?.state {
            self.callScreenDelegate?.didChangeState(to: callState)
        } else if self.currentCall == nil && self.callScreenDelegate != nil {
            self.callScreenDelegate?.shouldDismiss()
            self.endCall()
        }
    }
   
    @objc private func willEnterBackground() {}
   
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }
   
    public final func reset() {
        self.callScreenDelegate = nil
        self.hasActiveCall = false
        self.callOwner = nil
        self.callOpponent = nil
        self.update = nil
        self.webRTC = nil
        self.inCallingProcess = false
        self.isCallAccepted = false
        self.currentCall = nil
        self.isVideoEnabled = false
        self.shouldChangeVideoModeAfterConnecting = false
        self.callsQueue.removeAll()
       
        AccountManager.shared.users.forEach {
            if !$0.xmppStream.isAuthenticated { return }
            $0.action { (user, stream) in
                user.csi.active(stream, by: .voip)
            }
        }
        AccountManager.shared.load(true)
    }
   
    internal func performEndCallActions() {
        guard let call = self.currentCall else { return }
       
        var reason: MessageStorageItem.VoIPCallState = .none
        if !call.isMade {
            reason = call.outgoing ? .noanswer : .missed
        }
       
        if !isCallEnded {
            call.rejectCall(reason: reason)
        }
       
        var duration: TimeInterval = 0.0
        if let end = call.end, let start = call.start {
            duration = TimeInterval(Int(end.timeIntervalSince1970 - start.timeIntervalSince1970))
        }
       
        self.updateMessage(
            call.callId,
            jid: call.jid,
            owner: call.owner,
            callStqte: call.isMade ? .made : (call.outgoing ? .noanswer : .missed),
            duration: duration > 1 ? duration : nil
        )
       
        self.webRTC?.delegate = nil
        self.webRTC = nil
        self.reset()
    }
   
    private final func internalStartCall(owner: String, jid: String) {
        SoundManager.configureAudioSession()
       
        AccountManager.shared.users.forEach {
            if !$0.xmppStream.isAuthenticated { return }
            $0.action { (user, stream) in
                user.csi.inactive(stream, by: .voip)
            }
        }
       
        let callUUID = UUID()
        let handle = CXHandle(type: .emailAddress, value: jid)
        let action = CXStartCallAction(call: callUUID, handle: handle)
        let transaction = CXTransaction(action: action)
       
        self.callScreenDelegate?.shouldDismiss()
       
        let callScreenPresenter = CallScreenPresenter(jid: jid, owner: owner, hideAppTabBar: true)
        if callScreenPresenter.asyncGetPresenter() != nil {
            self.callScreenDelegate = callScreenPresenter.present(animated: true) {}
        }
       
        self.currentCall = VoIPCall(owner: owner, fullJid: jid, callId: callUUID.uuidString, callUUID: callUUID, outgoing: true)
       
        self.controller.request(transaction) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                self.callScreenDelegate?.shouldDismiss()
                return
            }
           
            self.inCallingProcess = true
            self.update = CXCallUpdate()
           
            do {
                let realm = try WRealm.safe()
                if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())?.displayName {
                    self.update?.localizedCallerName = name
                }
            } catch {
                DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
            }
           
            self.provider.reportCall(with: callUUID, updated: self.update!)
           
            self.webRTC = WebRTCClient()
            self.webRTC?.delegate = self
            self.currentCall?.delegate = self
            self.currentCall?.proposeCall()
           
            let messageItem = MessageStorageItem()
            messageItem.configureVoIPCallMessage(
                opponent: jid,
                owner: owner,
                date: Date(),
                isRead: true,
                callId: callUUID.uuidString,
                archivedId: nil,
                outgoing: true,
                duration: 0,
                callState: .none
            )
           
            if !messageItem.isInStorage() {
                _ = messageItem.save(commitTransaction: true, silentNotifications: true)
            }
        }
    }
   
    public final func startCall(owner: String, jid: String) {
        self.internalStartCall(owner: owner, jid: jid)
    }
   
    public final func receiveAnotherCall(payload: [AnyHashable: Any]) {
        let callUUID = UUID()
       
        provider.reportNewIncomingCall(with: callUUID, update: update!) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                return
            }
           
            self.callScreenDelegate?.shouldDismiss()
           
            guard let body = payload["body"] as? String else { return }
           
            let data = EncryptedPushDate(body)
           
            guard let target = payload["target"] as? String,
                  let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
                  let credentials = defaults.dictionary(forKey: target),
                  let secret = credentials["secret"] as? String, !secret.isEmpty,
                  let username = credentials["username"] as? String,
                  let host = credentials["host"] as? String else {
                return
            }
           
            let owner = [username, host].joined(separator: "@")
           
            guard let decrypted = data.payloadStanza(key: secret),
                  let from = decrypted.attributeStringValue(forName: "from"),
                  let propose = decrypted.element(forName: "propose", xmlns: VoIPCall.namespace),
                  let callId = propose.attributeStringValue(forName: "id") else {
                return
            }
           
            let bareJid = XMPPJID(string: from)?.bare ?? from
           
            do {
                let realm = try WRealm.safe()
                if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [bareJid, owner].prp())?.displayName {
                    self.update?.localizedCallerName = name
                } else {
                    self.update?.localizedCallerName = bareJid
                }
            } catch {
                DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
            }
           
            self.update?.remoteHandle = CXHandle(type: .emailAddress, value: bareJid)
            self.provider.reportCall(with: callUUID, updated: self.update!)
            self.provider.reportCall(with: callUUID, endedAt: nil, reason: .failed)
           
            let anotherCall = VoIPCall(owner: owner, fullJid: from, callId: callId, callUUID: callUUID, outgoing: false)
            anotherCall.rejectCall(reason: .busy)
           
            self.updateMessage(
                anotherCall.callId,
                jid: anotherCall.jid,
                owner: anotherCall.owner,
                callStqte: .missed,
                duration: nil
            )
           
            self.callsQueue.append(anotherCall)
        }
    }
   
    public final func receiveCall(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
       
        if self.currentCall != nil {
            self.receiveAnotherCall(payload: payload)
            return
        }
       
        self.inCallingProcess = false
       
        let callUUID = UUID()
        self.update = CXCallUpdate()
       
        func processIncomingCall() {
            guard let body = payload["body"] as? String else {
                completion()
                return
            }
           
            let data = EncryptedPushDate(body)
           
            guard let target = payload["target"] as? String,
                  let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
                  let credentials = defaults.dictionary(forKey: target),
                  let secret = credentials["secret"] as? String, !secret.isEmpty,
                  let username = credentials["username"] as? String,
                  let host = credentials["host"] as? String else {
                completion()
                return
            }
           
            let owner = [username, host].joined(separator: "@")
           
            guard let decrypted = data.payloadStanza(key: secret),
                  let from = decrypted.attributeStringValue(forName: "from"),
                  let fromJid = XMPPJID(string: from),
                  fromJid.isFull,
                  let propose = decrypted.element(forName: "propose", xmlns: VoIPCall.namespace),
                  let callId = propose.attributeStringValue(forName: "id") else {
                completion()
                return
            }
           
            let bareJid = fromJid.bare
           
            do {
                let realm = try WRealm.safe()
                if let name = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [bareJid, owner].prp())?.displayName {
                    self.update?.localizedCallerName = name
                } else {
                    self.update?.localizedCallerName = bareJid
                }
            } catch {
                self.update?.localizedCallerName = bareJid
            }
           
            self.update?.remoteHandle = CXHandle(type: .emailAddress, value: bareJid)
           
            self.currentCall = VoIPCall(
                owner: owner,
                fullJid: fromJid.full,
                callId: callId,
                callUUID: callUUID,
                outgoing: false
            )
           
            self.currentCall?.delegate = self
           
            let stanzaIdRaw = decrypted
                .elements(forName: "stanza-id")
                .first(where: { $0.attributeStringValue(forName: "by") == owner })?
                .attributeStringValue(forName: "id")
           
            let messageItem = MessageStorageItem()
            messageItem.configureVoIPCallMessage(
                opponent: bareJid,
                owner: owner,
                date: Date(),
                isRead: true,
                callId: callId,
                archivedId: stanzaIdRaw ?? "",
                outgoing: false,
                duration: 0,
                callState: .none
            )
           
            if !messageItem.isInStorage() {
                do {
                    let realm = try WRealm.safe()
                    if realm.isInWriteTransaction { return }
                    if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messageItem.primary) == nil {
                        try realm.write {
                            _ = messageItem.save(commitTransaction: false, silentNotifications: true)
                        }
                    }
                } catch {
                    DDLogDebug(error.localizedDescription)
                }
            }
           
            completion()
        }
       
        self.update?.localizedCallerName = "Xabber voice call".localizeString(id: "voice_call_message", arguments: [])
       
        provider.reportNewIncomingCall(with: callUUID, update: update!) { error in
            if let error = error {
                DDLogDebug(error.localizedDescription)
                completion()
                return
            }
            processIncomingCall()
        }
    }
   
    public final func cancelCall(uuid: String) {
        self.endCall()
    }
   
    public final func endCall() {
        performEndCallActions()
    }
   
    public final func enableVideo() {
        self.isVideoEnabled = true
        self.webRTC?.enableVideo()
        if (self.currentCall?.changeVideoState(to: .enabled) ?? false) {
            self.shouldChangeVideoModeAfterConnecting = false
        } else {
            self.shouldChangeVideoModeAfterConnecting = true
        }
    }
   
    public final func disableVideo() {
        self.isVideoEnabled = false
        self.webRTC?.disableVideo()
        if (self.currentCall?.changeVideoState(to: .disabled) ?? false) {
            self.shouldChangeVideoModeAfterConnecting = false
        } else {
            self.shouldChangeVideoModeAfterConnecting = true
        }
    }
   
    public final func enableAudio() {
        self.webRTC?.unmuteAudio()
    }
   
    public final func disableAudio() {
        self.webRTC?.muteAudio()
    }
   
    public final func enableRemoteVideo(_ renderer: RTCVideoRenderer) {
        self.webRTC?.renderRemoteVideo(to: renderer)
    }
   
    public final func disableRemoteVideo(_ renderer: RTCVideoRenderer, completionHandler: (() -> Void)?) {
        self.webRTC?.stopRenderRemoteVideo(renderer)
        completionHandler?()
    }
   
    open func enableLocalVideo(_ renderer: RTCVideoRenderer) {
        self.webRTC?.enableVideo()
        self.webRTC?.startCaptureLocalVideo(renderer: renderer, camera: self.cameraPosition)
    }
   
    open func disableLocalVideo(_ completionHandler: (() -> Void)?) {
        self.webRTC?.disableVideo()
        self.webRTC?.stopCaptureLocalVideo(completionHandler)
    }
   
    open func switchCamera(local: RTCVideoRenderer) {
        self.webRTC?.stopCaptureLocalVideo {
            self.cameraPosition = self.cameraPosition == .front ? .back : .front
            self.webRTC?.startCaptureLocalVideo(renderer: local, camera: self.cameraPosition)
        }
    }
   
    public final func onReceiveMessage(_ message: DDXMLElement, owner: String, archivedDate: Date?, commitTransaction: Bool = true, runtime: Bool = false, outgoing: Bool = false) -> Bool {
        do {
            let realm = try WRealm.safe()
           
            if message.element(forName: "propose", xmlns: VoIPCall.namespace) != nil {
                guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                      let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                      let toJidUnwr = message.attributeStringValue(forName: "to"),
                      let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                    return false
                }
               
                if runtime { return true }
               
                let instance = MessageStorageItem()
                let isOutgoing = owner == fromJid
               
                guard let callId = message.element(forName: "propose", xmlns: VoIPCall.namespace)?
                        .attributeStringValue(forName: "id") else {
                    return true
                }
               
                instance.configureVoIPCallMessage(
                    opponent: isOutgoing ? toJid : fromJid,
                    owner: owner,
                    date: archivedDate ?? Date(),
                    isRead: true,
                    callId: callId,
                    archivedId: getStanzaId(XMPPMessage(from: message), owner: owner),
                    outgoing: isOutgoing,
                    duration: 0,
                    callState: .received
                )
                instance.archivedId = getUniqueMessageId(XMPPMessage(from: message), owner: owner)
               
                if instance.isInStorage() { return true }
               
                _ = instance.save(commitTransaction: commitTransaction, silentNotifications: true)
                return true
            } else if let accept = message.element(forName: "accept", xmlns: VoIPCall.namespace),
                      let callId = accept.attributeStringValue(forName: "id") {
                if let deviceId = AccountManager.shared.find(for: owner)?.devices.deviceId,
                let fromDeviceId = message.element(forName: "device")?.attributeStringValue(forName: "id"),
                deviceId != fromDeviceId,
                runtime == true {
                    self.currentCall?.shouldSendReject = false
                    self.currentCall?.isMade = true
                    let transaction = CXTransaction(action: CXEndCallAction(call: self.currentCall?.callUUID ?? UUID()))
                    self.controller.request(transaction) { (error) in
                        if let error = error {
                            DDLogDebug(error)
                            self.provider.invalidate()
                        }
                        print(#function)
                        self.reset()
                    }
                }

                guard let fullJid = self.currentCall?.jid,
                      let jid = XMPPJID(string: fullJid)?.bare else {
                    return true
                }

                if callId != self.currentCall?.callId {
                    return true
                }

                if (self.currentCall?.outgoing ?? false) {
                    return true
                }

                if isCallAccepted {
                    return true
                }

                if let referencePrimary = realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?.references.first?.primary,
                   let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                    if commitTransaction {
                        try realm.write {
                            if instance.isInvalidated { return }
                            instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.made.rawValue
                            realm.object(
                                ofType: MessageStorageItem.self,
                                forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId)
                            )?.isRead = true
                        }
                    } else {
                        instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.made.rawValue
                        realm.object(
                            ofType: MessageStorageItem.self,
                            forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId)
                        )?.isRead = true
                    }
                }
                self.currentCall?.shouldSendReject = false

                let transaction = CXTransaction(action: CXEndCallAction(call: self.currentCall?.callUUID ?? UUID()))

                self.controller.request(transaction) { (error) in
                    if let error = error {
                        //print(error.localizedDescription)
                        DDLogDebug(error)
                        print("INVALIDATE IN \(#function)")
                        self.provider.invalidate()
                    }
                    self.reset()
                }
                return true
            } else if let reject = message.element(forName: "reject", xmlns: VoIPCall.namespace) {
                //print("********* MESSAGE: ", message.prettyXMLString!)
                if self.currentCall?.onReject(XMPPMessage(from: message)) ?? false {
                    return true
                }
                guard let callId = message.element(forName: "reject",
                     xmlns: VoIPCall.namespace)?.attributeStringValue(forName: "id") else {
                    return true
                }

                if runtime,
                   let currentCallId = self.currentCall?.callId,
                   currentCallId == callId {


                    let transaction = CXTransaction(action: CXEndCallAction(call: self.controller.callObserver.calls.first?.uuid ?? self.currentCall?.callUUID ?? UUID())) //self.currentCall?.callUUID ?? UUID()))
                    self.currentCall?.shouldSendReject = false
                    //print("EXECUTE END TRANSACTION")

                    DispatchQueue.main.async {
                        self.callScreenDelegate?.didChangeState(to: .ended)
                        self.controller.request(transaction) { (error) in
                            if let error = error {
                                //print(error.localizedDescription)
                                print("INVALIDATE IN \(#function)")
                                self.provider.invalidate()
                            }
                            self.reset()
                        }
                    }
                }
                if let date = archivedDate {
                    guard let fromJidUnwr = message.attributeStringValue(forName: "from"),
                        let fromJid = XMPPJID(string: fromJidUnwr)?.bare,
                        let toJidUnwr = message.attributeStringValue(forName: "to"),
                        let toJid = XMPPJID(string: toJidUnwr)?.bare else {
                        return false
                    }

                    let call = reject.element(forName: "call")

                    let duration = call?.attributeDoubleValue(forName: "duration") ?? 0
                    let endReason = call?.attributeStringValue(forName: "end-reason") ?? "made"

                    let instance = MessageStorageItem()

                    let outgoing: Bool = owner == fromJid

                    guard let callId = reject.attributeStringValue(forName: "id") else { return true }

                    instance.configureVoIPCallMessage(
                        opponent: outgoing ? toJid : fromJid,
                        owner: owner,
                        date: date,
                        isRead: true,
                        callId: callId,
                        archivedId: getStanzaId(XMPPMessage(from: message), owner: owner),
                        outgoing: outgoing,
                        duration: duration,
                        callState: MessageStorageItem.VoIPCallState(rawValue: endReason) ?? .made
                    )
                    if instance.isInStorage() {
                        return true
                    }
                    _ = instance.save(commitTransaction: commitTransaction, silentNotifications: true)

                    return true
                }
                guard let callId = reject.attributeStringValue(forName: "id") else { return true }
                guard let fullJid = self.currentCall?.jid,
                    let jid = XMPPJID(string: fullJid)?.bare else {
                    return true
                }
                if callId != self.currentCall?.callId {
                    return true
                }
                self.callScreenDelegate?.didChangeState(to: .ended)
                if let call = reject.element(forName: "call") {
                    let duration = call.attributeDoubleValue(forName: "duration")
                    let endReason = call.attributeStringValue(forName: "end-reason")
                    let dateString = call.attributeStringValue(forName: "start") ?? ""
                    let startDate = Date.parseXMPPFormattedString(dateString) ?? archivedDate ?? Date()
                    if let referencePrimary = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?.references.first?.primary,
                        let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                        if commitTransaction {
                            try realm.write {
                                if instance.isInvalidated { return }
                                instance.metadata?["duration"] = TimeInterval(Int(duration))
                                instance.metadata?["date"] = startDate.timeIntervalSince1970
                                instance.metadata?["callState"] = MessageStorageItem.VoIPCallState(rawValue: endReason ?? "none")?.rawValue
                                switch endReason {
                                    case "noanswer":
                                        instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.noanswer.rawValue
                                    case "missed":
                                        instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.missed.rawValue
                                    default:
                                        instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.made.rawValue
                                }
                            }
                        } else {
                            instance.metadata?["duration"] = TimeInterval(Int(duration))
                            switch endReason {
                                case "noanswer":
                                    instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.noanswer.rawValue
                                case "missed":
                                    instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.missed.rawValue
                                default:
                                    instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.made.rawValue
                            }
                        }
                    }
                }
                return true
            }
              
        } catch {
            return false
        }
       
        return false
    }
   
    public final func onReceivePushUpdate(_ payload: [AnyHashable: Any]) -> Bool {
        guard let callUUID = self.currentCall?.callUUID else {
            return false
        }
        do {
            guard let body = payload["body"] as? String else {
                print("FAIL 0")
                return false
            }
            let data = EncryptedPushDate(body)
    //            let data = try JSONDecoder().decode(EncryptedPushDate.self, from: encodedBody)
            guard let target = payload["target"] as? String,
                let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
                print("FAIL 1")
                return false
            }
            guard let creditionals = defaults.dictionary(forKey: target) else {
                print("FAIL 2")
                return false
            }
            
            guard let secret = creditionals["secret"] as? String,
                  secret.isNotEmpty else {
                print("FAIL 3")
                return false
            }
            
            guard let username = creditionals["username"] as? String,
                  let host = creditionals["host"] as? String else {
                print("FAIL 4")
                return false
            }
            
            let owner = [username, host].joined(separator: "@")
        
            guard let decrypted = data.payloadStanza(key: secret) else {
                print("FAIL 4.5")
                return false
            }
            
            guard let callId = decrypted.attributeStringValue(forName: "id") else {
                print("FAIL 5")
                return false
            }
            
            if callId != self.currentCall?.callId {
                return false
            }
            guard let fullJid = self.currentCall?.jid,
                  let jid = XMPPJID(string: fullJid)?.bare else {
                return false
            }
            print("VOIP PUSH DECRYPTED", decrypted)
            let realm = try  WRealm.safe()
            switch decrypted.name {
            case "reject":
                
                self.currentCall?.shouldSendReject = false
                let transaction = CXTransaction(action: CXEndCallAction(call: callUUID))
                self.controller.request(transaction) { (error) in
                    if let error = error {
                        //print(error.localizedDescription)
                        print("INVALIDATE IN \(#function). \(error.localizedDescription)")
                        self.provider.invalidate()
                    }
                    self.reset()
                }
                self.callScreenDelegate?.didChangeState(to: .ended)
                if let call = decrypted.element(forName: "call") {
                    let duration = call.attributeDoubleValue(forName: "duration")
                    let endReason = call.attributeStringValue(forName: "end-reason")
                    if let referencePrimary = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?.references.first?.primary,
                       let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                        try realm.write {
                            if instance.isInvalidated { return }
                            instance.metadata?["duration"] = TimeInterval(Int(duration))
                            switch endReason {
                            case "noanswer":
                                instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.noanswer.rawValue
                            case "missed":
                                instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.missed.rawValue
                            default:
                                instance.metadata?["callState"] = MessageStorageItem.VoIPCallState.made.rawValue
                            }
                        }
                    }
                }
            default:
                return false
            }
            
        } catch {
            return false
        }
        return true
    }
   
    internal final func updateMessage(_ callId: String, jid: String, owner: String, callStqte: MessageStorageItem.VoIPCallState? = nil, duration: TimeInterval? = nil) {
        guard let jid = XMPPJID(string: jid)?.bare else { return }
        do {
            let realm = try WRealm.safe()
            if let referencePrimary = realm
                .object(ofType: MessageStorageItem.self,
                        forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?
                .references.first?.primary,
               let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                try realm.write {
                    if instance.isInvalidated { return }
                    if let callState = callStqte {
                        instance.metadata?["callState"] = callState.rawValue
                    }
                    if let duration = duration {
                        instance.metadata?["duration"] = duration
                    }
                    realm.object(ofType: MessageStorageItem.self,
                                 forPrimaryKey: MessageStorageItem.messageIdForVoIPCall(owner: owner, jid: jid, callId: callId))?.isRead = true
                }
            }
        } catch {
            DDLogDebug("VoIPManager: \(#function). \(error.localizedDescription)")
        }
    }
   
    public static func isVoIPMessage(_ message: DDXMLElement) -> Bool {
        return message.element(forName: "reject", xmlns: VoIPCall.namespace) != nil ||
               message.element(forName: "accept", xmlns: VoIPCall.namespace) != nil ||
               message.element(forName: "propose", xmlns: VoIPCall.namespace) != nil
    }
}
