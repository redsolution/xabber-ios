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
import MaterialComponents
import CocoaLumberjack

enum ChatNavigationTitleTextPolicy {
    static func displayTitle(
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        groupName: String? = nil,
        rosterDisplayName: String? = nil
    ) -> String {
        if conversationType == .saved {
            return SavedMessagesChatListPresentationPolicy.title
        }
        if conversationType == .group,
           let groupName = normalizedTitle(groupName) {
            return groupName
        }
        if let rosterDisplayName = normalizedTitle(rosterDisplayName) {
            return rosterDisplayName
        }
        return jid
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        let title = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }
}

extension ChatViewController{
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        self.addObservers()
    }
}

extension ChatViewController {
    @objc
    internal func onTitleButtonTouchUp(_ sender: UIButton) {
        self.showInfo()
//        self.topPanelState.accept(.shouldRequestVerification)
        
    }
    
    internal final func updateTitle() -> NSAttributedString {
        let attributedTitle: NSMutableAttributedString = NSMutableAttributedString()
        func appendTitle(_ title: String, color: UIColor) {
            attributedTitle.append(NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
            ]))
        }

        do {
            let realm = try WRealm.safe()
            let indicatorAttach = NSTextAttachment()
            
            var color: UIColor = .label//self.accountPallete.tint500
            
            if self.conversationType.isEncrypted {
                
                    let collectionJid = realm
                        .objects(SignalDeviceStorageItem.self)
                        .filter("jid == %@ AND owner == %@", jid, owner)
                    if collectionJid.count == 0 {
                        color = .label
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.secondaryLabel)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.toArray().filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).count > 0 {
                        color = .systemRed
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.toArray().filter({ $0.state != .trusted }).count > 0 {
                        color = .systemOrange
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.toArray().filter({ $0.isTrustedByCertificate }).count > 0 {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    }
                
            }

            if self.conversationType == .saved {
                appendTitle(
                    ChatNavigationTitleTextPolicy.displayTitle(
                        jid: self.jid,
                        conversationType: self.conversationType
                    ),
                    color: color
                )
                return attributedTitle
            }

            if self.conversationType == .group {
                let projection = try GroupRepository(realm: realm).projection(
                    owner: self.owner,
                    groupJID: self.jid
                )
                if projection.state.isActive {
                    appendTitle(
                        ChatNavigationTitleTextPolicy.displayTitle(
                            jid: self.jid,
                            conversationType: self.conversationType,
                            groupName: projection.state.snapshot.info?.name
                        ),
                        color: color
                    )
                    return attributedTitle
                }
            } else {
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                    appendTitle(
                        ChatNavigationTitleTextPolicy.displayTitle(
                            jid: self.jid,
                            conversationType: self.conversationType,
                            rosterDisplayName: instance.displayName
                        ),
                        color: color
                    )
                    return attributedTitle
                }
            }
            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        appendTitle(
            ChatNavigationTitleTextPolicy.displayTitle(
                jid: self.jid,
                conversationType: self.conversationType
            ),
            color: .label
        )
        return attributedTitle
    }
}
