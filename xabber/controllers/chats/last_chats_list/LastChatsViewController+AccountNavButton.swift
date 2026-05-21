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
    private enum Metrics {
        static let hitTarget: CGFloat = 44
        static let avatarSize: CGFloat = 32
        static let statusSize: CGFloat = 9
        static let statusOffset: CGFloat = 3
    }
    
    internal let avatarView: UIImageView = {
        let view = UIImageView(frame: .zero)
        if let image = UIImage(named: AccountMasksManager.shared.mask32pt), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.masksToBounds = true
        
        return view
    }()
    
    internal let statusView: RoundedStatusView = {
        let view = RoundedStatusView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    internal func setup() {
        backgroundColor = nil
        layer.borderWidth = 0
        layer.shadowOpacity = 0
        addSubview(avatarView)
        addSubview(statusView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.hitTarget),
            heightAnchor.constraint(equalToConstant: Metrics.hitTarget),
            avatarView.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
            statusView.widthAnchor.constraint(equalToConstant: Metrics.statusSize),
            statusView.heightAnchor.constraint(equalToConstant: Metrics.statusSize),
            statusView.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Metrics.statusOffset),
            statusView.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: Metrics.statusOffset)
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Metrics.hitTarget, height: Metrics.hitTarget)
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
    
    var avatarUrl: String? = ""
    
    public func update(jid: String, status: ResourceStatus) {
        var url: String? = nil
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                url = instance.avatarMinUrl ?? instance.avatarMaxUrl ?? instance.oldschoolAvatarKey
            }
        } catch {
            DDLogDebug("AccountNavButton: \(#function). \(error.localizedDescription)")
        }
        if avatarUrl != url {
//            print(url)
            DefaultAvatarManager.shared.getAvatar(url: url, jid: jid, owner: jid, size: 128) { image in
                if let image = image {
                    self.avatarView.image = image
                    self.avatarUrl = url
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: jid, size: 128)
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
        let vc = AccountInfoViewController()
        vc.jid = self.topAccountJid
        vc.configureTokens(for: self.topAccountJid)
        self.navigationController?.pushViewController(vc, animated: true)
    }
}
