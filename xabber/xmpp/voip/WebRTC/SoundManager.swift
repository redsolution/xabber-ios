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

struct SoundManager {
    
    enum AudioPort {
        case initial
        case speaker
    }
    
    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        do {
//            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setCategory(.playAndRecord, mode: .videoChat)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setPreferredSampleRate(4_410)
        } catch {
            DDLogDebug(error.localizedDescription)
        }
    }
    
    static func routeAudioToSpeaker() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth])
    }
    
    static func changeAudioPort(_ port: AudioPort) {
        let session = AVAudioSession.sharedInstance()
        switch port {
        case .initial:
            try? session.overrideOutputAudioPort(.none)
        case .speaker:
            try? session.overrideOutputAudioPort(.speaker)
        }
        
    }
    
}
