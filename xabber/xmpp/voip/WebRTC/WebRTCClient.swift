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
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidateKeys: Set<RemoteCandidateKey> = []
    private var appliedRemoteCandidateKeys: Set<RemoteCandidateKey> = []
    private var remoteDescriptionWasApplied: Bool = false
    
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
        // We use Google's public stun/turn server. For production apps you should deploy your own stun/turn servers.
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun01.pool-01.fckrkn202102.cyou:3478"]),
            RTCIceServer(urlStrings: ["turn:stun01.pool-01.fckrkn202102.cyou:3478"],
                         username: "xclient",
                         credential: "eix3Poh5eu")
        ]
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
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
        self.addVideoTrack()
        self.disableVideo()
        self.peerConnection.delegate = self
    }
    
    func offer(completion: @escaping (_ sdp: RTCSessionDescription?, _ error: Error?) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.offer(for: constrains) { (sdp, error) in
            if let error = error {
                DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                completion(nil, error)
                return
            }
            guard let sdp = sdp else {
                completion(nil, WebRTCClientError.failedToCreateOffer)
                return
            }
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    completion(nil, error)
                    return
                }
                completion(sdp, nil)
            })
        }
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription?, _ error: Error?) -> Void)  {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            if let error = error {
                DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                completion(nil, error)
                return
            }
            guard let sdp = sdp else {
                completion(nil, WebRTCClientError.failedToCreateAnswer)
                return
            }
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    completion(nil, error)
                    return
                }
                completion(sdp, nil)
            })
        }
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        print("receive remote sdp")
        self.peerConnection.setRemoteDescription(remoteSdp) { error in
            if error == nil {
                self.remoteDescriptionWasApplied = true
                self.flushPendingRemoteCandidates()
            }
            completion(error)
        }
    }
    
    func set(remoteCandidate: RTCIceCandidate) {
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
        if !isCaptureStart { return}
        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
            return
        }
        capturer.stopCapture(completionHandler: completionHandler)
        isCaptureStart = false
    }
    
    func startCaptureLocalVideo(renderer: RTCVideoRenderer, camera: AVCaptureDevice.Position) {
        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer,
              let frontCamera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == camera }),
              let format = (RTCCameraVideoCapturer.supportedFormats(for: frontCamera).sorted {
                    (f1, f2) -> Bool in
                    let width1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
                    let width2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
                    return width1 < width2
                })
                .reversed()
                .first(where: {
                    item in
                    let width = CMVideoFormatDescriptionGetDimensions(item.formatDescription).width
                    return width == 640
                }) else {
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
        
        self.localVideoTrack?.add(renderer)
    }
    
    func addVideoTrack() {
        let videoTrack = self.createVideoTrack()
        self.peerConnection.add(videoTrack, streamIds: ["stream0"])
        self.localVideoTrack = videoTrack
    }
    
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        self.remoteStream?.videoTracks.first?.add(renderer)
    }
    
    func stopRenderRemoteVideo(_ renderer: RTCVideoRenderer) {
        self.remoteStream?.videoTracks.first?.remove(renderer)
    }
    
    func muteAudio() {
        self.setAudioEnabled(false)
    }
    
    func unmuteAudio() {
        self.setAudioEnabled(true)
    }
    
    func enableVideo() {
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
        pendingRemoteCandidates.removeAll()
        pendingRemoteCandidateKeys.removeAll()
        appliedRemoteCandidateKeys.removeAll()
        remoteDescriptionWasApplied = false
        peerConnection.close()
    }
    
    deinit {
        peerConnection.close()
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
        self.peerConnection.add(candidate) { error in
            if error != nil {
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
        //print("peerConnection new signaling state: \(stateChanged)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        self.remoteStream = stream
        //print("peerConnection did add stream")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        //print("peerConnection did remote stream")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        //print("peerConnection should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        //print("peerConnection new connection state: \(newState)")
        delegate?.webRTCClient(self, didUpdateState: newState)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        //print(newState.description)
        //print("peerConnection new gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        //print(["generate", candidate.sdp].joined(separator: ": "))
        self.localCandidates.append(candidate)
        self.delegate?.webRTCClient(self, didDiscoverLocalCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        //print("peerConnection did remove candidate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        //print("peerConnection did open data channel")
    }
}
