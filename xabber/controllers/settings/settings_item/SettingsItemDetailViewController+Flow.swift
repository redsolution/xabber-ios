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

extension SettingsItemDetailViewController {
    internal func onBoolItemDidChange(_ key: String, value: Bool) {
        SettingManager.shared.saveItem(key: key, bool: value)
    }
    
    internal func shareLogFiles() {
        guard let filesPaths = (UIApplication.shared.delegate as? AppDelegate)?
            .logFileManager?
            .sortedLogFilePaths
            .compactMap({ return URL(fileURLWithPath: $0) }) else {
            if SettingManager.logEnabled {
                self.view.makeToast("Please restart application to enable logs.")
            } else {
                self.view.makeToast("There are no log files on your phone".localizeString(id: "debug_no_log_files", arguments: []))
            }
            return
        }
        let shareVC = UIActivityViewController(activityItems: filesPaths,
                                               applicationActivities: [])
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = shareVC.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        self.present(shareVC, animated: true, completion: nil)
    }
}
