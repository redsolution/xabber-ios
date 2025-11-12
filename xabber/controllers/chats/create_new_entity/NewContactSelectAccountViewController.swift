//
//  NewContactSelectAccountViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 05.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class NewContactSelectAccountViewController: BaseViewController {
    internal var callback: ((String) -> Void)? = nil
    internal var datasource: [String] = []
    internal var header: String? = nil
    internal var footer: String? = nil
    internal var current: String? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")
        
        return view
    }()
    
    @objc
    internal func done(_ force: Bool = false) {
        if let current = current {
            callback?(current)
            navigationController?.popViewController(animated: true)
        }
    }
        
    internal func activateConstraints() {
        
    }
    
    open func configure(_ values: [String], title: String, header: String?, footer: String?, current: String, callback: @escaping ((String) -> Void)) {
        self.title = title
        self.datasource = values
        self.callback = callback
        self.header = header
        self.footer = footer
        self.current = current
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}

extension NewContactSelectAccountViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return header
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return footer
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        
        let cell = tableView
            .dequeueReusableCell(withIdentifier: "UITableViewCell",
                                 for: indexPath)
        cell.textLabel?.text = item
        cell.accessoryType = item == current ? .checkmark : .none
        return cell
        
    }
}

extension NewContactSelectAccountViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        current = item
        done()
    }
}
