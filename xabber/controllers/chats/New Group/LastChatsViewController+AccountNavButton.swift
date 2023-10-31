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
import Kingfisher
import CocoaLumberjack

class AccountNavButton: UIButton {
    
    internal let avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(x: 0, y: 4, width: 32, height: 32))
        if let image = UIImage(named: AccountMasksManager.shared.mask32pt), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.layer.masksToBounds = true
        
        return view
    }()
    
    internal let statusView: RoundedStatusView = {
        let view = RoundedStatusView(frame: CGRect(x: 23, y: 27, width: 9, height: 9))
        
        return view
    }()
    
    internal func setup() {
        addSubview(avatarView)
        addSubview(statusView)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(jid: String, status: ResourceStatus, avatarUrl: String?) {
        if let avatarUrl = avatarUrl {
            
        } else {
            var url: String? = nil
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                    url = instance.avatarMinUrl ?? instance.avatarMaxUrl ?? instance.oldschoolAvatarKey
                }
            } catch {
                DDLogDebug("AccountNavButton: \(#function). \(error.localizedDescription)")
            }
            DefaultAvatarManager.shared.getAvatar(url: url, jid: jid, owner: jid, size: 128) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.setDefaultAvatar(for: jid, owner: jid)
                }
            }
        }
        
        statusView.setStatus(status: status, entity: .contact)
        statusView.border(1)
        self.layoutIfNeeded()
    }
    
    @objc
    func reloadDatasource() {
        if let image = UIImage(named: AccountMasksManager.shared.mask32pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
}

extension LastChatsViewController {
    @objc
    internal func onAccountNavButtonPress(_ sender: UIButton) {
        let vc = SettingsViewController() //AccountInfoViewController()
        vc.jid = self.topAccountJid
        vc.isModal = false
        self.navigationController?.pushViewController(vc, animated: true)
//        let nvc = UINavigationController(rootViewController: vc)
//        nvc.modalPresentationStyle = .fullScreen
//        nvc.modalTransitionStyle = .coverVertical
//        self.definesPresentationContext = true
//        self.present(nvc, animated: true, completion: nil)
    }
}
