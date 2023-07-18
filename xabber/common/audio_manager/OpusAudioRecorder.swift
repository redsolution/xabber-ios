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
import CocoaLumberjack

enum AudioErrorType: Error {
    case alreadyRecording
    case alreadyPlaying
    case notCurrentlyPlaying
    case audioFileWrongPath
    case recordFailed
    case playFailed
    case recordPermissionNotGranted
    case internalError
}

extension AudioErrorType: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "The application is currently recording sounds".localizeString(id: "audio_error_already_recording", arguments: [])
        case .alreadyPlaying:
            return "The application is already playing a sound".localizeString(id: "audio_error_already_playing", arguments: [])
        case .notCurrentlyPlaying:
            return "The application is not currently playing".localizeString(id: "audio_error_not_currently_playing", arguments: [])
        case .audioFileWrongPath:
            return "Invalid path for audio file".localizeString(id: "audio_error_wrong_path", arguments: [])
        case .recordFailed:
            return "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: [])
        case .playFailed:
            return "Unable to play sound at the moment, please try again".localizeString(id: "audio_error_play_failed", arguments: [])
        case .recordPermissionNotGranted:
            return "Unable to record sound because the permission has not been granted. This can be changed in your settings.".localizeString(id: "audio_error_no_permission", arguments: [])
        case .internalError:
            return "An error occured while trying to process audio command, please try again".localizeString(id: "audio_error_internal", arguments: [])
        }
    }
}

class AudioRecorder: NSObject {
    static let audioPercentageUserInfoKey = "com.xabber.audio.percentage"
    
    let audioFileNamePrefix = "com.xabber.voice_messages"
    let numberOfChannels: Int = 1
    let sampleRate: Double = 48000.0
    let depthInBits: Int = 16
    
    open class var shared: AudioRecorder {
        struct AudioRecorderSingleton {
            static let instance = AudioRecorder()
        }
        return AudioRecorderSingleton.instance
    }
    
    var isPermissionGranted = false
    var isRunning: Bool {
        guard let recorder = self.recorder, recorder.isRecording else {
            return false
        }
        return true
    }
    
    var currentRecordPath: URL?
    
    private var recorder: AVAudioRecorder?
    private var audioMeteringLevelTimer: Timer?
    
    func askPermission(completion: ((Bool, Bool) -> Void)? = nil) {// -> Bool {
        
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                self?.isPermissionGranted = granted
                completion?(granted, true)
            }
        case .denied:
            isPermissionGranted = false
            completion?(false, false)
        case .granted:
            isPermissionGranted = true
            completion?(true, false)
//            return true
        @unknown default:
            isPermissionGranted = false
            completion?(false, false)
        }
//        return false
    }
    
    func startRecording(visualNotificationFreq timeInterval: TimeInterval = 0.05, completion: @escaping (URL?, Error?) -> Void, failure: @escaping(() -> Void)) {
        func startRecordingReturn() {
            do {
                let result = try internalStartRecording(with: timeInterval)
                DispatchQueue.main.async {
                    completion(result, nil)
                }
            } catch {
                print(error.localizedDescription)
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
        
        if !self.isPermissionGranted {
            self.askPermission { _, _ in
                failure()
            }
        } else {
            startRecordingReturn()
        }
    }
    
    private final func internalStartRecording(with timeInterval: TimeInterval) throws -> URL {
        if self.isRunning {
            throw AudioErrorType.alreadyRecording
        }
        
        let recordSettings = [
            AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVLinearPCMBitDepthKey: self.depthInBits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: self.numberOfChannels,
            AVSampleRateKey : self.sampleRate
        ] as [String : Any]
//
        guard let path = URL.documentsPath(forFileName: self.audioFileNamePrefix + NSUUID().uuidString) else {
            DDLogDebug("Incorrect path for new audio file")
            throw AudioErrorType.audioFileWrongPath
        }
        
        try AVAudioSession.sharedInstance().setActive(true)
        
        self.recorder = try AVAudioRecorder(url: path, settings: recordSettings)
        self.recorder?.delegate = self
        self.recorder?.isMeteringEnabled = true
        
        guard let prepared = self.recorder?.prepareToRecord(),
            prepared != false,
            let started = self.recorder?.record(atTime: self.recorder!.deviceCurrentTime + 0.4),
            started != false else {
            throw AudioErrorType.recordFailed
        }
        
//        self.audioMeteringLevelTimer = Timer.scheduledTimer(
//            timeInterval: audioVisualizationTimeInterval,
//            target: self,
//            selector: #selector(AudioRecorder.timerDidUpdateMeter),
//            userInfo: nil,
//            repeats: true
//        )
        
        DispatchQueue.main.async {
            self.audioMeteringLevelTimer = Timer.scheduledTimer(
                withTimeInterval: timeInterval,
                repeats: true,
                block: { timer in
                    if !self.isRunning { return }
                    self.recorder?.updateMeters()
                    let averagePower = self.recorder?.averagePower(forChannel: 0) ?? 0
                    let percentage: Float = pow(10, (0.05 * averagePower))
                    NotificationCenter
                        .default
                        .post(
                            name: .recorderDidUpdateMeteringLevelNotification,
                            object: self,
                            userInfo: [AudioRecorder.audioPercentageUserInfoKey: percentage])
                })
            RunLoop.main.add(self.audioMeteringLevelTimer!, forMode: .default)
        }
        
        DDLogDebug("Audio Recorder did start - creating file at index: \(path.absoluteString)")
        
        self.currentRecordPath = path
        return path
    }
    
    func stopRecording() throws {
        self.audioMeteringLevelTimer?.invalidate()
        self.audioMeteringLevelTimer = nil
        
        if !self.isRunning {
            DDLogDebug("Audio Recorder did fail to stop")
            throw AudioErrorType.notCurrentlyPlaying
        }
        self.recorder?.stop()
        try AVAudioSession.sharedInstance().setActive(false)
        self.recorder = nil
        DDLogDebug("Audio Recorder did stop successfully")
    }
    
    func reset() throws {
        if self.isRunning {
            DDLogDebug("Audio Recorder tried to remove recording before stopping it")
            throw AudioErrorType.alreadyRecording
        }
        
        self.recorder?.deleteRecording()
        self.recorder = nil
        self.currentRecordPath = nil
        DDLogDebug("Audio Recorder did remove current record successfully")
    }
    
    @objc func timerDidUpdateMeter() {
        if self.isRunning {
            self.recorder!.updateMeters()
            let averagePower = recorder!.averagePower(forChannel: 0)
            let percentage: Float = pow(10, (0.05 * averagePower))
            NotificationCenter.default.post(name: .recorderDidUpdateMeteringLevelNotification, object: self, userInfo: [AudioRecorder.audioPercentageUserInfoKey: percentage])
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        NotificationCenter.default.post(name: .audioRecorderManagerMeteringLevelDidFinishNotification, object: self)
        DDLogDebug("Audio Recorder finished successfully")
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        NotificationCenter.default.post(name: .audioRecorderManagerMeteringLevelDidFailNotification, object: self)
        DDLogDebug("Audio Recorder error")
    }
}

extension Notification.Name {
    static let recorderDidUpdateMeteringLevelNotification = Notification.Name("AudioRecorderManagerMeteringLevelDidUpdateNotification")
    static let audioRecorderManagerMeteringLevelDidFinishNotification = Notification.Name("AudioRecorderManagerMeteringLevelDidFinishNotification")
    static let audioRecorderManagerMeteringLevelDidFailNotification = Notification.Name("AudioRecorderManagerMeteringLevelDidFailNotification")
}

extension URL {
    static func checkPath(_ path: String) -> Bool {
        let isFileExist = FileManager.default.fileExists(atPath: path)
        return isFileExist
    }
    
    static func documentsPath(forFileName fileName: String) -> URL? {
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let writePath = URL(string: documents)!.appendingPathComponent(fileName)
        
        var directory: ObjCBool = ObjCBool(false)
        if FileManager.default.fileExists(atPath: documents, isDirectory: &directory) {
            return directory.boolValue ? writePath : nil
        }
        return nil
    }
}
