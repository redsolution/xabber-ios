//
//  NewCallSearchViewController+UITableViewDataSource.swift
//  xabber
//
//  Created by Игорь Болдин on 05.02.2021.
//  Copyright © 2021 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension NewCallSearchViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: NewCallViewController.ItemCell.cellName, for: indexPath) as? NewCallViewController.ItemCell else {
            fatalError()
        }
        let item = datasource[indexPath.row]
        
        cell.configure(
            owner: item.owner,
            jid: item.jid,
            title: item.username
        )
        cell.setMask()
        
        return cell
    }
}
