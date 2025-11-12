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
import Realm

class DevicesAndEncryptionListViewController: SimpleBaseViewController {
    
    class Datasource {
        enum Kind {
            case fingerprint
            case device
            case bundle
            case button(String)
        }
        
        var kind: Kind
        var title: String
        var subtitile: String
        var date: Date
        var state: SignalDeviceStorageItem.TrustState? = nil
        var achtung: Bool = false
        
        init(kind: Kind, title: String, subtitle: String, date: Date, state: SignalDeviceStorageItem.TrustState? = nil, achtung: Bool = false) {
            self.kind = kind
            self.title = title
            self.subtitile = subtitle
            self.date = date
            self.state = state
            self.achtung = achtung
        }
    }
    
    internal var datasource: [[Datasource]] = []
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        
        
        return view
    }()
    
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func loadDatasource() {
        super.loadDatasource()
    }
    
}

extension DevicesAndEncryptionListViewController: UITableViewDelegate {
    
}

extension DevicesAndEncryptionListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .fingerprint:
            fatalError()
        case .device:
            fatalError()
        case .bundle:
            fatalError()
        case .button(_):
            fatalError()
        }
    }
}
