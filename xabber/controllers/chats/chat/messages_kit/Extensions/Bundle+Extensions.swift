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

extension Bundle {

    internal static func messageKitAssetBundle() -> Bundle {
        let podBundle = Bundle(for: MessagesViewController.self)
        
        guard let resourceBundleUrl = podBundle.url(forResource: "MessageKitAssets", withExtension: "bundle") else {
            fatalError(MessageKitError.couldNotCreateAssetsPath)
        }
        
        guard let resourceBundle = Bundle(url: resourceBundleUrl) else {
            fatalError(MessageKitError.couldNotLoadAssetsBundle)
        }
        
        return resourceBundle
    }

}
