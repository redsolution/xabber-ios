//
//  ChatViewController+ContactSubscribtionsFlow.swift
//  xabber
//
//  Created by Игорь Болдин on 02.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

extension ChatViewController {
    @objc
    internal func onAddContact(_ sender: UIButton) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.subscribe(stream, jid: self.jid)
            user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
            user.roster.setContact(stream, jid: self.jid, nickname: nil, groups: [], callback: nil)
        })
        self.topPanelState.accept(.none)
    }
    
    @objc
    internal func onBlockContact(_ sender: UIButton) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.blocked.blockContact(stream, jid: self.jid)
            user.roster.removeContact(stream, jid: self.jid)
        })
        self.topPanelState.accept(.none)
    }
    
    @objc
    internal func onRequestSubscribtion(_ sender: UIButton) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.subscribe(stream, jid: self.jid)
        })
        self.topPanelState.accept(.none)
    }
    
    @objc
    internal func onAllowSubscribtion(_ sender: UIButton) {
        do {
            let realm = try WRealm.safe()
            if let item = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner
                )
            ), ![.undefined, .none].contains(item.subscribtion) {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
                })
            } else {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    user.presences.subscribe(stream, jid: self.jid)
                    user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
                    user.roster.setContact(stream, jid: self.jid, nickname: nil, groups: [], callback: nil)
                })
            }
        } catch {
            DDLogDebug("XhatViewController: \(#function). \(error.localizedDescription)")
        }
        
        self.topPanelState.accept(.none)
    }
}
