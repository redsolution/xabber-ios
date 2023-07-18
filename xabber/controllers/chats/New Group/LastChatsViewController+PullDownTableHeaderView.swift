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

extension LastChatsViewController {
    class PullDownTableHeaderView: UIView {
        
        enum State {
            case normal
            case disabled
        }
        
        public var state: State = .normal
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        internal let textButton: UIButton = {
            let button = UIButton()
            
            button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
            
            button.setTitle("", for: .disabled)
            if #available(iOS 13.0, *) {
                button.setTitle("↓ Pull down for archive ↓".localizeString(id: "pull_down_for_archive", arguments: []),
                                for: .normal)
                button.setTitle("✨ Ta da! ✨".localizeString(id: "ta_da", arguments: []),
                                for: .disabled)
                button.setTitleColor(.secondaryLabel, for: .normal)
                button.setTitleColor(.secondaryLabel, for: .disabled)
//                button.setImage(UIImage(systemName: "arrow.down",
//                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16,
//                                                                                       weight: .bold)),
//                                for: .normal)
                
//                button.setImage(nil, for: .disabled)
                button.tintColor = .secondaryLabel
            } else {
                button.setTitle("↓ Pull down to archive ↓".localizeString(id: "pull_down_for_archive", arguments: []),
                                for: .normal)
                button.setTitle("✨ Ta da! ✨".localizeString(id: "ta_da", arguments: []),
                                for: .disabled)
                button.setTitleColor(.darkText, for: .normal)
                button.setTitleColor(.darkText, for: .disabled)
            }
            
            return button
        }()
        
        internal func setup() {
            addSubview(textButton)
            textButton.centerInSuperview()
            textButton.sizeToFit()
        }
        
        public func changeState(to value: State) {
            if self.state != value {
                self.state = value
                switch value {
                case .normal:
                    textButton.isEnabled = true
                case .disabled:
                    textButton.isEnabled = false
                }
            }
        }
        
    }
    
    internal func configurePullToArchived() {
        refreshControl.addTarget(self, action: #selector(self.onPullToArchiveChanged), for: .valueChanged)
        tableView.addSubview(refreshControl)
        pullDownTableHeaderView.frame = CGRect(x: 0, y: -44, width: self.view.frame.width, height: 44)
        tableView.addSubview(pullDownTableHeaderView)
    }
    
    @objc
    internal func onPullToArchiveChanged(_ sender: UIRefreshControl) {
        sender.endRefreshing()
        if archivedChats?.isEmpty ?? true { return }
        if filter.value != .chats { return }
        showArchivedSection.accept(true)
    }
}
