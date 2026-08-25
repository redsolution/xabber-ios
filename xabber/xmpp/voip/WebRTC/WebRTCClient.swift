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
import WebRTC
import CocoaLumberjack

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didUpdateState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didUpdateCameraResolution resolution: VoIPManager.CameraResolution)
    func webRTCClient(_ client: WebRTCClient, didFail error: Error)
}

enum WebRTCClientError: Error {
    case failedToCreateOffer
    case failedToCreateAnswer
    case failedToAddRemoteCandidate
}

extension VoIPICEServerConfiguration {
    func rtcIceServer() -> RTCIceServer? {
        guard !urls.isEmpty else {
            return nil
        }
        if let username = username, !username.isEmpty,
           let credential = credential, !credential.isEmpty {
            return RTCIceServer(urlStrings: urls, username: username, credential: credential)
        }
        return RTCIceServer(urlStrings: urls)
    }
}

enum VoIPICEConfiguration {
    static func rtcIceServers(from configurations: [VoIPICEServerConfiguration]?) -> [RTCIceServer] {
        return (configurations ?? []).compactMap { $0.rtcIceServer() }
    }
}

class WebRTCClient: NSObject {
    private struct RemoteCandidateKey: Hashable {
        let sdp: String
        let sdpMLineIndex: Int32
        let sdpMid: String?
    }

    private let factory: RTCPeerConnectionFactory
    let peerConnection: RTCPeerConnection
    weak var delegate: WebRTCClientDelegate?
    var localCandidates = [RTCIceCandidate]()
    private let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]
    
    private var videoCapturer: RTCVideoCapturer?
    private var remoteStream: RTCMediaStream?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localVideoRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var remoteVideoRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidateKeys: Set<RemoteCandidateKey> = []
    private var appliedRemoteCandidateKeys: Set<RemoteCandidateKey> = []
    private var remoteDescriptionWasApplied: Bool = false
    private var didDisconnect: Bool = false
    
    private var isCaptureStart: Bool = false
        
    override init() {
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue]
        )
        let config = RTCConfiguration()
//        config.certificate
        config.iceServers = VoIPICEConfiguration.rtcIceServers(
            from: CommonConfigManager.shared.config.voip_ice_servers
        )
        if config.iceServers.isEmpty {
            DDLogWarn("VoIP WebRTC ICE servers are not configured; only host candidates will be gathered")
        }
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.enableDscp = true
        config.disableIPV6OnWiFi = false
        config.iceTransportPolicy = .all
        
        config.rtcpVideoReportIntervalMs = .min
        
        config.continualGatheringPolicy = .gatherContinually
        guard let connectiion = self.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError()
        }
        self.peerConnection = connectiion

        super.init()
        self.addAudioTrack()
        self.addVideoTrack(enabled: false)
        self.peerConnection.delegate = self
    }

    private func performOnMain(_ work: @escaping (WebRTCClient) -> Void) {
        if Thread.isMainThread {
            work(self)
            return
        }

        let retainedClient = self
        DispatchQueue.main.async {
            work(retainedClient)
        }
    }
    
    func offer(completion: @escaping (_ sdp: RTCSessionDescription?, _ error: Error?) -> Void) {
        guard Thread.isMainThread else {
            let retainedClient = self
            DispatchQueue.main.async {
                retainedClient.offer(completion: completion)
            }
            return
        }
        guard !didDisconnect else { return }

        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.offer(for: constrains) { [weak self] (sdp, error) in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didDisconnect else { return }
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    completion(nil, error)
                    return
                }
                guard let sdp = sdp else {
                    completion(nil, WebRTCClientError.failedToCreateOffer)
                    return
                }
                self.peerConnection.setLocalDescription(sdp, completionHandler: { [weak self] (error) in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.didDisconnect else { return }
                        if let error = error {
                            DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                            completion(nil, error)
                            return
                        }
                        completion(sdp, nil)
                    }
                })
            }
        }
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription?, _ error: Error?) -> Void)  {
        guard Thread.isMainThread else {
            let retainedClient = self
            DispatchQueue.main.async {
                retainedClient.answer(completion: completion)
            }
            return
        }
        guard !didDisconnect else { return }

        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { [weak self] (sdp, error) in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didDisconnect else { return }
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    completion(nil, error)
                    return
                }
                guard let sdp = sdp else {
                    completion(nil, WebRTCClientError.failedToCreateAnswer)
                    return
                }
                self.peerConnection.setLocalDescription(sdp, completionHandler: { [weak self] (error) in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.didDisconnect else { return }
                        if let error = error {
                            DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                            completion(nil, error)
                            return
                        }
                        completion(sdp, nil)
                    }
                })
            }
        }
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        guard Thread.isMainThread else {
            let retainedClient = self
            DispatchQueue.main.async {
                retainedClient.set(remoteSdp: remoteSdp, completion: completion)
            }
            return
        }
        guard !didDisconnect else { return }

        print("receive remote sdp")
        self.peerConnection.setRemoteDescription(remoteSdp) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didDisconnect else { return }
                if error == nil {
                    self.remoteDescriptionWasApplied = true
                    self.flushPendingRemoteCandidates()
                }
                completion(error)
            }
        }
    }
    
    func set(remoteCandidate: RTCIceCandidate) {
        guard Thread.isMainThread else {
            let retainedClient = self
            DispatchQueue.main.async {
                retainedClient.set(remoteCandidate: remoteCandidate)
            }
            return
        }
        guard !didDisconnect else { return }

        print(["receive", remoteCandidate.sdp].joined(separator: ": "))
        let key = RemoteCandidateKey(
            sdp: remoteCandidate.sdp,
            sdpMLineIndex: remoteCandidate.sdpMLineIndex,
            sdpMid: remoteCandidate.sdpMid
        )
        if !self.remoteDescriptionWasApplied {
            if self.pendingRemoteCandidateKeys.insert(key).inserted {
                self.pendingRemoteCandidates.append(remoteCandidate)
            }
            return
        }
        self.addRemoteCandidate(remoteCandidate, key: key)
    }
    
    func stopCaptureLocalVideo(_ completionHandler: (() -> Void)?) {
        if !isCaptureStart {
            localVideoRenderers.values.forEach { renderer in
                localVideoTrack?.remove(renderer)
            }
            localVideoRenderers.removeAll()
            completionHandler?()
            return
        }
        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
            localVideoRenderers.values.forEach { renderer in
                localVideoTrack?.remove(renderer)
            }
            localVideoRenderers.removeAll()
            completionHandler?()
            return
        }
        capturer.stopCapture { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didDisconnect else {
                    completionHandler?()
                    return
                }
                self.localVideoRenderers.values.forEach { renderer in
                    self.localVideoTrack?.remove(renderer)
                }
                self.localVideoRenderers.removeAll()
                completionHandler?()
            }
        }
        isCaptureStart = false
    }
    
    func startCaptureLocalVideo(renderer: RTCVideoRenderer, camera: AVCaptureDevice.Position) {
        let rendererId = ObjectIdentifier(renderer as AnyObject)
        localVideoRenderers[rendererId] = renderer
        if localVideoTrack == nil {
            addVideoTrack(enabled: true)
        }
        localVideoTrack?.add(renderer)

        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer,
              let frontCamera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == camera }),
              let format = Self.captureFormat(for: frontCamera) else {
            DDLogWarn("VoIP WebRTC local video capture cannot start: camera or format unavailable")
            return
        }
        
        let widht = CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
        let height = CMVideoFormatDescriptionGetDimensions(format.formatDescription).height
        let cameraResolution = VoIPManager.CameraResolution(height: Float(height), width: Float(widht))
        self.delegate?.webRTCClient(self, didUpdateCameraResolution: cameraResolution)
        
        capturer.startCapture(
            with: frontCamera,
            format: format,
            fps: 15
        )
        
        isCaptureStart = true
    }
    
    func addVideoTrack(enabled: Bool = true) {
        guard self.localVideoTrack == nil else {
            self.setVideoEnabled(enabled)
            return
        }
        let videoTrack = self.createVideoTrack()
        videoTrack.isEnabled = enabled
        self.peerConnection.add(videoTrack, streamIds: ["stream0"])
        self.localVideoTrack = videoTrack
    }
    
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        let rendererId = ObjectIdentifier(renderer as AnyObject)
        remoteVideoRenderers[rendererId] = renderer
        currentRemoteVideoTrack()?.add(renderer)
    }
    
    func stopRenderRemoteVideo(_ renderer: RTCVideoRenderer) {
        let rendererId = ObjectIdentifier(renderer as AnyObject)
        remoteVideoRenderers.removeValue(forKey: rendererId)
        currentRemoteVideoTrack()?.remove(renderer)
    }
    
    func muteAudio() {
        self.setAudioEnabled(false)
    }
    
    func unmuteAudio() {
        self.setAudioEnabled(true)
    }
    
    func enableVideo() {
        if self.localVideoTrack == nil {
            self.addVideoTrack(enabled: true)
        }
        self.setVideoEnabled(true)
    }
    
    func disableVideo() {
        self.setVideoEnabled(false)
    }
    
    func addAudioTrack() {
        let audioTrack = self.createAudioTrack()
        self.peerConnection.add(audioTrack, streamIds: ["stream0"])
    }
    
    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = self.factory.audioSource(with: audioConstrains)
        let audioTrack = self.factory.audioTrack(with: audioSource, trackId: "audio0")
        return audioTrack
    }
    
    private func createVideoTrack() -> RTCVideoTrack {
        let videoSource = self.factory.videoSource()
//        if TARGET_OS_SIMULATOR != 0 {
//            self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
//        }
//        else {
            self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
//        }
        let videoTrack = self.factory.videoTrack(with: videoSource, trackId: "video0")
        return videoTrack
    }

    private static func captureFormat(for camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: camera)
        return formats
            .sorted { first, second in
                let firstDimensions = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                let secondDimensions = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                return firstDimensions.width < secondDimensions.width
            }
            .last { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width <= 640
            } ?? formats.first
    }

    private func currentRemoteVideoTrack() -> RTCVideoTrack? {
        if let remoteVideoTrack {
            return remoteVideoTrack
        }
        if let streamTrack = remoteStream?.videoTracks.first {
            remoteVideoTrack = streamTrack
            return streamTrack
        }
        if let receiverTrack = peerConnection
            .receivers
            .compactMap({ $0.track as? RTCVideoTrack })
            .first {
            remoteVideoTrack = receiverTrack
            return receiverTrack
        }
        return nil
    }

    private func attachRemoteRenderers() {
        guard let remoteVideoTrack = currentRemoteVideoTrack() else { return }
        remoteVideoRenderers.values.forEach { renderer in
            remoteVideoTrack.add(renderer)
        }
    }
    
    private func setAudioEnabled(_ isEnabled: Bool) {
        self.peerConnection
            .senders
            .compactMap { return $0.track as? RTCAudioTrack }
            .forEach { $0.isEnabled = isEnabled }
    }
    
    private func setVideoEnabled(_ isEnabled: Bool) {
        self.peerConnection
            .senders
            .compactMap { return $0.track as? RTCVideoTrack }
            .forEach { $0.isEnabled = isEnabled }
    }
    
    open func disconnect() {
        guard Thread.isMainThread else {
            let retainedClient = self
            DispatchQueue.main.async {
                retainedClient.disconnect()
            }
            return
        }
        guard !didDisconnect else { return }
        didDisconnect = true
        peerConnection.delegate = nil
        pendingRemoteCandidates.removeAll()
        pendingRemoteCandidateKeys.removeAll()
        appliedRemoteCandidateKeys.removeAll()
        localVideoRenderers.removeAll()
        remoteVideoRenderers.removeAll()
        remoteDescriptionWasApplied = false
        peerConnection.close()
    }
    
    deinit {
        guard !Thread.isMainThread else { return }

        // A missed owner path must not make synthesized ivar destruction the
        // final release of native WebRTC resources on the signaling thread.
        // Transfer fallback retirement to main without re-entering close here.
        let retiredFactory = factory
        let retiredPeerConnection = peerConnection
        let retiredVideoCapturer = videoCapturer
        let retiredRemoteStream = remoteStream
        let retiredLocalVideoTrack = localVideoTrack
        let retiredRemoteVideoTrack = remoteVideoTrack
        let retiredLocalRenderers = localVideoRenderers
        let retiredRemoteRenderers = remoteVideoRenderers
        let retiredLocalCandidates = localCandidates
        let retiredPendingCandidates = pendingRemoteCandidates
        DispatchQueue.main.async {
            retiredPeerConnection.delegate = nil
            retiredPeerConnection.close()
            withExtendedLifetime(
                (
                    retiredFactory,
                    retiredVideoCapturer,
                    retiredRemoteStream,
                    retiredLocalVideoTrack,
                    retiredRemoteVideoTrack,
                    retiredLocalRenderers,
                    retiredRemoteRenderers,
                    retiredLocalCandidates,
                    retiredPendingCandidates
                )
            ) {}
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    private func key(for candidate: RTCIceCandidate) -> RemoteCandidateKey {
        return RemoteCandidateKey(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
    }

    private func addRemoteCandidate(_ candidate: RTCIceCandidate, key: RemoteCandidateKey) {
        guard self.appliedRemoteCandidateKeys.insert(key).inserted else {
            return
        }
        self.peerConnection.add(candidate) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didDisconnect else { return }
                self.delegate?.webRTCClient(self, didFail: WebRTCClientError.failedToAddRemoteCandidate)
            }
        }
    }

    private func flushPendingRemoteCandidates() {
        let candidates = self.pendingRemoteCandidates
        self.pendingRemoteCandidates.removeAll()
        self.pendingRemoteCandidateKeys.removeAll()
        candidates.forEach { candidate in
            self.addRemoteCandidate(candidate, key: self.key(for: candidate))
        }
    }
        
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        self.performOnMain { _ in
            // Keep the native callback's receiver alive until main owns its
            // final release, even though this state is not currently consumed.
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        self.performOnMain { client in
            guard !client.didDisconnect else { return }
            client.remoteStream = stream
            client.remoteVideoTrack = stream.videoTracks.first
            client.attachRemoteRenderers()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        self.performOnMain { client in
            guard !client.didDisconnect else { return }
            if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
                client.remoteVideoTrack = videoTrack
                client.attachRemoteRenderers()
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        self.performOnMain { _ in }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        self.performOnMain { _ in }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        self.performOnMain { client in
            guard !client.didDisconnect else { return }
            client.delegate?.webRTCClient(client, didUpdateState: newState)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        self.performOnMain { _ in }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        self.performOnMain { client in
            guard !client.didDisconnect,
                  candidate.sdpMLineIndex <= 0 else {
                return
            }
            client.localCandidates.append(candidate)
            client.delegate?.webRTCClient(client, didDiscoverLocalCandidate: candidate)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        self.performOnMain { _ in }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        self.performOnMain { _ in }
    }
}
