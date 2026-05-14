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
import AVFoundation
import Photos
import MaterialComponents.MDCPalettes
import CocoaLumberjack

extension ChatViewController {
        
    internal func askPhotoPermision(callback: @escaping ((Bool) -> Void)) {
        if let value = self.isAccessToPhotoGranted {
            callback(value)
            return
        }
        switch PHPhotoLibrary.authorizationStatus() {
        
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { (status) in
                switch status {
                case .restricted, .notDetermined, .denied:
                    self.isAccessToPhotoGranted = false
                    callback(false)
                case .authorized, .limited:
                    self.isAccessToPhotoGranted = true
                    callback(true)
                @unknown default:
                    self.isAccessToPhotoGranted = false
                    callback(false)
                }
            }
        case .denied, .restricted:
            self.isAccessToPhotoGranted = false
            callback(false)
        case .authorized, .limited:
            self.isAccessToPhotoGranted = true
            callback(true)
        @unknown default:
            self.isAccessToPhotoGranted = false
            callback(false)
        }
        
    }
    
    @objc
    internal func showImagePicker() {
        self.view.endEditing(false)
        askPhotoPermision { (value) in
//            DispatchQueue.main.asyncAfter(deadline: .now() + (keyboardState ? 0.0 : 0.0)) {
            DispatchQueue.main.async {
                if value {
//                    if AccountManager.shared.find(for: self.owner)?.httpUploads.isAvailable() ?? false {
//                    if AccountManager.shared.find(for: self.owner)?.xUploads.isAvailable() ?? false {
                    if AccountManager.shared.find(for: self.owner)?.cloudStorage.isAvailable() ?? false {
                        let picker = ImagePickerViewController()
                        picker.jid = self.jid
                        picker.owner = self.owner
                        picker.delegate = self
                        picker.conversationType = self.conversationType
                        picker.forwardedMessages = self.attachedMessagesIds.value
                        picker.modalTransitionStyle = .coverVertical
                        picker.modalPresentationStyle = .overFullScreen
                        self.present(picker, animated: false, completion: nil)
//                        UIApplication.shared.windows.last?.rootViewController?.present(picker, animated: false, completion: nil)
                    } else {
                        ToastPresenter().presentError(message: "File transfer is unavailable for this account.".localizeString(id: "media_picker_error_upload_unavailable", arguments: []))
                    }
                } else {
                    ToastPresenter().presentError(message: "Photo Library access is required to select images.".localizeString(id: "media_picker_error_photo_permission", arguments: []))
                }
            }
        }
    }
    
    @objc
    func keyboardWillChangeFrameNotification(_ notification: Notification) {
        self.handleKeyboardFrameChange(notification)
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        self.handleKeyboardFrameChange(notification)
    }
    
    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
        self.handleKeyboardFrameChange(notification as Notification)
    }

    internal static func keyboardOverlapHeight(viewBounds: CGRect, keyboardFrameInView: CGRect) -> CGFloat {
        guard viewBounds.width > 0,
              viewBounds.height > 0,
              !keyboardFrameInView.isEmpty else {
            return 0
        }

        let intersection = viewBounds.intersection(keyboardFrameInView)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }

        return max(0, intersection.height)
    }

    internal func keyboardOverlapHeight(from keyboardFrameInScreenCoordinates: CGRect) -> CGFloat {
        let keyboardFrameInView = self.view.convert(keyboardFrameInScreenCoordinates, from: self.view.window)
        return Self.keyboardOverlapHeight(
            viewBounds: self.view.bounds,
            keyboardFrameInView: keyboardFrameInView
        )
    }

    private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let inputView = self.xabberInputView else {
            return
        }

        let keyboardVisibleHeight = self.keyboardOverlapHeight(from: frameValue.cgRectValue)
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curveValue = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
        let options = curveValue
            .map { UIView.AnimationOptions(rawValue: $0 << 16).union(.beginFromCurrentState) }
            ?? [.beginFromCurrentState, .curveEaseInOut]
        let wasNearBottom = self.isNearBottom()
        let visibleAnchor = wasNearBottom ? nil : self.capturePagingAnchorIfNeeded(direction: .older)

        let updates = {
            inputView.update(screenHeight: self.view.bounds.height, keyboardHeight: keyboardVisibleHeight)
            let inputHeight = inputView.bounds.height
            self.updateChatCollectionInsets(inputHeight: inputHeight)

            self.updateInitialMessageOverlayFrame()
            self.view.layoutIfNeeded()
            self.updateChatCollectionInsets(inputHeight: inputHeight)
            if wasNearBottom {
                self.scrollToBottom(animated: false)
            } else if let visibleAnchor {
                self.restorePagingAnchor(visibleAnchor)
            }
        }

        if duration > 0 {
            UIView.animate(
                withDuration: TimeInterval(duration),
                delay: 0,
                options: options,
                animations: updates,
                completion: nil
            )
        } else {
            updates()
        }
    }
}
