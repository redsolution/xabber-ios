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
}

class WebRTCClient: NSObject {
        
    private let factory: RTCPeerConnectionFactory
    let peerConnection: RTCPeerConnection
    weak var delegate: WebRTCClientDelegate?
    var localCandidates = [RTCIceCandidate]()
    private let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]
    
    private var videoCapturer: RTCVideoCapturer?
    private var remoteStream: RTCMediaStream?
    private var localVideoTrack: RTCVideoTrack?
    
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
        config.allowCodecSwitching = true
        config.disableIPV6 = false
        config.disableIPV6OnWiFi = false
        config.iceTransportPolicy = .all
        
        config.rtcpVideoReportIntervalMs = .min
        
        config.continualGatheringPolicy = .gatherContinually
        self.peerConnection = self.factory.peerConnection(with: config, constraints: constraints, delegate: nil)
                
        super.init()
        self.addAudioTrack()
        self.addVideoTrack()
        self.disableVideo()
        self.peerConnection.delegate = self
    }
    
    func offer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.offer(for: constrains) { (sdp, error) in
            if let error = error {
                DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                return
            }
            guard let sdp = sdp else {
                return
            }
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    return
                }
                completion(sdp)
            })
        }
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            if let error = error {
                DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                return
            }
            guard let sdp = sdp else {
                return
            }
            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    DDLogError([#function, error.localizedDescription].joined(separator: ". "))
                    return
                }
                completion(sdp)
            })
        }
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        print("receive remote sdp")
        self.peerConnection.setRemoteDescription(remoteSdp, completionHandler: completion)
    }
    
    func set(remoteCandidate: RTCIceCandidate) {
        print(["receive", remoteCandidate.sdp].joined(separator: ": "))
        self.peerConnection.add(remoteCandidate)
        
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
        if TARGET_OS_SIMULATOR != 0 {
            self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        }
        else {
            self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        }
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
        peerConnection.close()
    }
    
    deinit {
        peerConnection.close()
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
        
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
