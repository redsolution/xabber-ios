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

    private struct RenderRequest {
        let jid: String
        let status: ResourceStatus
    }

    private var latestRenderRequest: RenderRequest?
    private var avatarRequestGeneration = UUID()
    private var resolvedAvatarRequestKey: String?
    private var shouldReloadMaskWhenUnfrozen = false
    internal private(set) var isRenderingFrozen = false
    
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
    
    var avatarUrl: String?

    internal func setRenderingFrozen(_ frozen: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setRenderingFrozen(frozen)
            }
            return
        }
        guard isRenderingFrozen != frozen else {
            return
        }

        isRenderingFrozen = frozen
        avatarRequestGeneration = UUID()
        guard !frozen else {
            return
        }

        if shouldReloadMaskWhenUnfrozen {
            shouldReloadMaskWhenUnfrozen = false
            applyCurrentMask()
        }
        if let latestRenderRequest {
            render(latestRenderRequest)
        }
    }

    public func update(jid: String, status: ResourceStatus) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(jid: jid, status: status)
            }
            return
        }

        let request = RenderRequest(jid: jid, status: status)
        latestRenderRequest = request
        guard !isRenderingFrozen else {
            return
        }
        render(request)
    }

    private func render(_ request: RenderRequest) {
        var url: String?
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: AccountStorageItem.self,
                forPrimaryKey: request.jid
            ) {
                url = instance.avatarMinUrl ?? instance.avatarMaxUrl ?? instance.oldschoolAvatarKey
            }
        } catch {
            DDLogDebug("AccountNavButton: \(#function). \(error.localizedDescription)")
        }

        statusView.setStatus(status: request.status, entity: .contact)
        statusView.border(1)

        let requestKey = [request.jid, url ?? ""].joined(separator: "|")
        avatarUrl = url
        guard resolvedAvatarRequestKey != requestKey else {
            layoutIfNeeded()
            return
        }

        avatarView.image = UIImageView.getDefaultAvatar(
            for: request.jid,
            owner: request.jid,
            size: 128
        ) ?? UIImage(systemName: "person.crop.circle.fill")

        guard url != nil else {
            resolvedAvatarRequestKey = requestKey
            layoutIfNeeded()
            return
        }

        let generation = UUID()
        avatarRequestGeneration = generation
        DefaultAvatarManager.shared.getAvatar(
            url: url,
            jid: request.jid,
            owner: request.jid,
            size: 128
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self,
                      !self.isRenderingFrozen,
                      self.avatarRequestGeneration == generation,
                      self.latestRenderRequest?.jid == request.jid else {
                    return
                }
                guard let image else {
                    return
                }
                self.avatarView.image = image
                self.resolvedAvatarRequestKey = requestKey
            }
        }

        layoutIfNeeded()
    }

    @objc
    func reloadDatasource() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadDatasource()
            }
            return
        }
        guard !isRenderingFrozen else {
            shouldReloadMaskWhenUnfrozen = true
            return
        }
        applyCurrentMask()
    }

    private func applyCurrentMask() {
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
