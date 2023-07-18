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
import AVKit

enum Orientations: String {
    case unknown = "unknown"
    case portrait = "portrait"
    case portraitUpsideDown = "portraitUpsideDown"
    case landscapeRight = "landscapeRight"
    case landscapeLeft = "landscapeLeft"
    
    static func getOrientationFromRawValue(rawOrientation: String) -> Orientations {
        switch rawOrientation {
        case Orientations.portrait.rawValue: return Orientations.portrait
        case Orientations.portraitUpsideDown.rawValue: return Orientations.portraitUpsideDown
        case Orientations.landscapeLeft.rawValue: return Orientations.landscapeLeft
        case Orientations.landscapeRight.rawValue: return Orientations.landscapeRight
        default: return Orientations.unknown
        }
    }
}

extension AVAsset {
    func videoOrientation() -> (orientation: Orientations, device: AVCaptureDevice.Position) { //orientation: UIInterfaceorientation
        var orientation: Orientations = .unknown
        var device: AVCaptureDevice.Position = .unspecified

        let tracks :[AVAssetTrack] = self.tracks(withMediaType: AVMediaType.video)
        if let videoTrack = tracks.first {
            
            let t = videoTrack.preferredTransform
            
            if (t.a == 0 && t.b == 1.0 && t.d == 0) {
                orientation = .portrait
                
                if t.c == 1.0 {
                    device = .front
                } else if t.c == -1.0 {
                    device = .back
                }
            }
            else if (t.a == 0 && t.b == -1.0 && t.d == 0) {
                orientation = .portraitUpsideDown
                
                if t.c == -1.0 {
                    device = .front
                } else if t.c == 1.0 {
                    device = .back
                }
            }
            else if (t.a == 1.0 && t.b == 0 && t.c == 0) {
                orientation = .landscapeRight
                
                if t.d == -1.0 {
                    device = .front
                } else if t.d == 1.0 {
                    device = .back
                }
            }
            else if (t.a == -1.0 && t.b == 0 && t.c == 0) {
                orientation = .landscapeLeft
                
                if t.d == 1.0 {
                    device = .front
                } else if t.d == -1.0 {
                    device = .back
                }
            }
        }
        
        return (orientation, device)
    }
}
