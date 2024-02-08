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

extension SubforwardsViewController: AVAudioPlayerDelegate {
        
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let path = playingMessageIndexPath {
            playingMessageIndexPath = nil
            (messagesCollectionView.cellForItem(at: path.indexPath) as? CommonMessageCell)?
                .updateAudio(next: .stop, messageId: path.messageId)
        }
        playingMessageIndexPath = nil
        playingMessageUpdateTimer?.invalidate()
        playingMessageUpdateTimer = nil
//        OpusAudio.shared.resetPlayer()
    }
    
    @objc
    internal func playingMessageUpdateTimerCallback(timer: Timer) {
        if let path = playingMessageIndexPath,
            let cell = messagesCollectionView.cellForItem(at: path.indexPath) as? CommonMessageCell {
            cell.updateDurationLabel(with: audioMessageDurationString(at: path.indexPath,
                                                                      messageId: path.messageId,
                                                                      index: path.index),
                                     messageId: path.messageId)
        }
    }
    
}
