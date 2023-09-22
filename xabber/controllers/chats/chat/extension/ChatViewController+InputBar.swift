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
                    if let account = AccountManager.shared.find(for: self.owner), let _ = account.getDefaultUploader() {
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
                    }
                }
            }
        }
    }
    
    @objc
    func keyboardWillChangeFrameNotification(_ notification: Notification) {

    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let frame = frameValue.cgRectValue
                let keyboardVisibleHeight = frame.size.height
                print("keyboardVisibleHeight", keyboardVisibleHeight)
                switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                        let inputHeight: CGFloat = self.xabberInputView.barHeight + keyboardVisibleHeight
                    
                    let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    print("duration, options", duration, options)
                    UIView.animate(
                        withDuration: TimeInterval(duration.doubleValue),
                        delay: 0,
                        options: options,
                        animations: {
                            self.xabberInputView.update(screenHeight: self.view.bounds.height, keyboardHeight: keyboardVisibleHeight)
                            self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 100, right: 0)
                            
                            if self.messagesCollectionView.contentOffset.y < 100 {
                                self.messagesCollectionView.contentOffset.y = -inputHeight - 8
                                print("-inputHeight - 8", -inputHeight - 8)
                            }
                            return
                        }, completion: { finished in
                    })
                default:
                    
                    break
                }
            }
        }
        
    }
    
    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
//            keyboardVisibleHeight = 0
//            self.updateConstant()
        
        if let userInfo = notification.userInfo {
            
            switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
            case let (.some(duration), .some(curve)):
                let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                print("duration, options", duration, options)
                var inputHeight: CGFloat = self.xabberInputView.barHeight
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
                
                UIView.animate(
                    withDuration: TimeInterval(duration.doubleValue),
                    delay: 0,
                    options: options,
                    animations: {
                        self.xabberInputView.update(screenHeight: self.view.bounds.height, keyboardHeight: 0)
                        self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 100, right: 0)
                        return
                    }, completion: { finished in
                })
            default:
                break
            }
        }
    }
}
