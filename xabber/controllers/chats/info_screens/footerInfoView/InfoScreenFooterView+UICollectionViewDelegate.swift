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
import AVKit
import CocoaLumberjack
import RealmSwift


extension InfoScreenFooterView: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if datasource.isNotEmpty {
            switch selectedKind {
            case .images, .videos:
                let width = frame.width / InfoScreenFooterView.numberOfCells - InfoScreenFooterView.cellSpacing * (InfoScreenFooterView.numberOfCells + 1) / InfoScreenFooterView.numberOfCells
                return CGSize(square: width)
            case .files, .voice:
                return CGSize(width: (frame.width - InfoScreenFooterView.cellSpacing * 2), height: 60)
            }
        } else {
            switch selectedKind {
            case .files, .voice:
                return CGSize(width: frame.width - InfoScreenFooterView.cellSpacing * 2, height: 50 + InfoScreenFooterView.cellSpacing * 2)
            default:
                return CGSize(width: frame.width - InfoScreenFooterView.cellSpacing * 2, height: 50)
            }
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if datasource.isNotEmpty {
            switch selectedKind {
            case .images:
                let imageUrls: [URL] = datasource.compactMap({ URL(string: $0.uri) })
                let senders: [String] = datasource.compactMap({ $0.senderName })
                let dates: [String] = datasource.compactMap({ $0.date })
                let times: [String] = datasource.compactMap({ $0.send_time })
                let messageIds: [String] = datasource.compactMap({ $0.messageId })
                
                self.infoVCDelegate?.presentPhotoGallery(urls: imageUrls,
                                                         senders: senders,
                                                         dates: dates,
                                                         times: times,
                                                         messageIds: messageIds,
                                                         page: indexPath.item)
            case .videos:
                if let url = URL(string: datasource[indexPath.item].uri) {
                    let player = AVPlayer(url: url)
                    let controller = AVPlayerViewController()
                    controller.player = player
                    
                    infoVCDelegate?.presentVC(vc: controller)
                    player.play()
                }
            case .files:
                guard let url = URL(string: datasource[indexPath.item].uri),
                      UIApplication.shared.canOpenURL(url) else { return }
                infoVCDelegate?.presentYesNoPresenter(with: url)
            case .voice:
                let cell = collectionView.cellForItem(at: indexPath) as! VoiceMediaCollectionCell
                if previousSelectedCellIndex != nil {
                    let previousCell = collectionView.cellForItem(at: previousSelectedCellIndex!) as! VoiceMediaCollectionCell
                    if previousCell != cell {
                        previousCell.reset()
                    }
                }
                
                selectedCell = cell
                switch cell.state {
                case .play:
                    cell.setupOpusAudio()
                    OpusAudio.shared.player?.delegate = self
                    setupTimer()
                    cell.update(state: .play)
                case .pause:
                    cell.update(state: .pause)
                default:
                    break
                }
            }
        }
        previousSelectedCellIndex = indexPath
    }
}

extension InfoScreenFooterView: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let cell = selectedCell else { return }
        cell.update(state: .stop)
        cell.deactivateDurationLabel()
        resetTimer()
    }
}
