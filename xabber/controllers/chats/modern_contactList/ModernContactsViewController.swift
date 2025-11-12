//
//  ModernContactsViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 18.07.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack
import YubiKit
import MaterialComponents.MDCPalettes

class ModernContactsViewController: SimpleBaseViewController {
    
    class Datasource {
        var primary: String
        var owner: String
        var jid: String
        var avatarUrl: String?
        
        init(primary: String, owner: String, jid: String, avatarUrl: String? = nil) {
            self.primary = primary
            self.owner = owner
            self.jid = jid
            self.avatarUrl = avatarUrl
        }
    }
    
    var datasource: [Datasource] = []
    
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func configure() {
        super.configure()
    }
    
}


extension ModernContactsViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return UITableViewCell(frame: .zero)
    }
    
    
}

extension ModernContactsViewController: UITableViewDelegate {
    
}
