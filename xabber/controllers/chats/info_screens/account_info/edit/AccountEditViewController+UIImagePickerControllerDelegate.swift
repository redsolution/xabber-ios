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

extension AccountEditViewController: UIImagePickerControllerDelegate {
   
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        guard let newImage = info[UIImagePickerController.InfoKey.editedImage] as? UIImage ?? info[UIImagePickerController.InfoKey.originalImage] as? UIImage else {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
            return
        }
        var image = newImage
        if picker.sourceType == .camera {
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        }
//        if image.size.width > maxSize || image.size.height > maxSize {
//            image = image.resize(targetSize: CGSize(square: maxSize))
//        }
        image = image.fixOrientation()
        picker.dismiss(animated: true) {
            self.didReceiveNewAvatar(image)
        }
    }
}

