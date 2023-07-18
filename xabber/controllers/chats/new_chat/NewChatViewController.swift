////
////  NewChatViewController.swift
////  xabber_test_xmpp
////
////  Created by Igor Boldin on 11/07/2019.
////  Copyright © 2019 Igor Boldin. All rights reserved.
////
//
//import Foundation
//import UIKit
//
//class NewChatViewController: UIViewController {
//    
//    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
//        
//        return view
//    }()
//    
//    internal func subscribe() {
//        
//    }
//    
//    internal func unsubscribe() {
//        
//    }
//    
//    internal func activateConstraints() {
//        
//    }
//    
//    internal func configure() {
//        view.addSubview(tableView)
//        tableView.fillSuperview()
//    }
//    
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        configure()
//        activateConstraints()
//    }
//    
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//        subscribe()
//    }
//    
//    override func viewDidAppear(_ animated: Bool) {
//        super.viewDidAppear(animated)
//    }
//    
//    override func viewWillDisappear(_ animated: Bool) {
//        super.viewWillDisappear(animated)
//    }
//    
//    override func viewDidDisappear(_ animated: Bool) {
//        super.viewDidDisappear(animated)
//        unsubscribe()
//    }
//    
//    override func didReceiveMemoryWarning() {
//        super.didReceiveMemoryWarning()
//    }
//}
