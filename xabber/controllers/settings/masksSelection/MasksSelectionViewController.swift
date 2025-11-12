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

class MasksSelectionViewController: BaseViewController {
    class Datasource {
        var title: String
        var maskName: String?
        var rawName: String?
        var isChosen: Bool
        var key: String
        var children: [Datasource]
        
        init(title: String, maskName: String?, rawName: String? = nil, isChosen: Bool = false, key: String, children: [Datasource] = []) {
            self.title = title
            self.maskName = maskName
            self.rawName = rawName
            self.isChosen = isChosen
            self.key = key
            self.children = children
        }
    }
    
    let masksSelectionTableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        
        return tableView
    }()
    
    var datasource: [Datasource] = []
    
    func configure() {
        title = "Available masks".localizeString(id: "account_settings_available_masks", arguments: [])
        
        prepareDatasource()
        
        view.addSubview(masksSelectionTableView)
        masksSelectionTableView.fillSuperview()
        
        masksSelectionTableView.delegate = self
        masksSelectionTableView.dataSource = self
    }
    
    private func prepareDatasource() {
        let availableMasks = AccountMasksManager.shared.masksList()
        
        datasource.append(Datasource(title: "Choose mask".localizeString(id: "account_settings_choose_mask", arguments: []), maskName: nil, key: "masks", children: []))
        availableMasks.forEach({
            var maskName: String = ""
            let mask = ($0.prefix(1).uppercased() + $0.lowercased().dropFirst())
                .replacingOccurrences(of: "_", with: " ")
            switch mask {
            case "Circle": maskName = mask.localizeString(id: "circle_mask_name", arguments: [])
            case "Rounded": maskName = mask.localizeString(id: "rounded_mask_name", arguments: [])
            case "Square": maskName = mask.localizeString(id: "square_mask_name", arguments: [])
            case "Rounded square": maskName = mask.localizeString(id: "rounded_square_mask_name", arguments: [])
            case "Star": maskName = mask.localizeString(id: "star_mask_name", arguments: [])
            case "Pentagon": maskName = mask.localizeString(id: "pentagon_mask_name", arguments: [])
            case "Octagon": maskName = mask.localizeString(id: "octagon_mask_name", arguments: [])
            default: maskName = mask
            }
            datasource.first?.children
                .append(Datasource(title: "", maskName: maskName, rawName: $0, key: ""))
        })
        let currentMask = AccountMasksManager.shared.load()
        datasource.first?.children.first(where: { $0.rawName == currentMask })?.isChosen = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }
}

extension Notification.Name {
    static let newMaskSelected = Notification.Name("NewMaskSelected")
}
