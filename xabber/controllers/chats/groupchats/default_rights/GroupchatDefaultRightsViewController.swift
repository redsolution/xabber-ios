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
import RxSwift
import RxCocoa

class GroupchatDefaultRightsViewController: BaseViewController {
    
    struct Value {
        let label: String
        let value: String
    }
    
    class Datasource {
        
        var itemId: String
        var title: String
        var value: String?
        var values: [Value]
        var enabled: Bool
        
        init(_ itemId: String, title: String, value: String?, values: [Value], enabled: Bool) {
            self.itemId = itemId
            self.title = title
            self.value = value
            self.values = values
            self.enabled = enabled
        }
    }
    
//    internal var jid: String = ""
//    internal var owner: String = ""
    
    internal var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var form: [[String: Any]] = []
    internal var modifiedForm: BehaviorRelay<[[String: Any]]> = BehaviorRelay(value: [])
    
    var formId: String? = nil
    var updateFormId: String? = nil
    
    internal var enableSaveButton: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: true)
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(ListItemEditCell.self, forCellReuseIdentifier: ListItemEditCell.cellName)
        
        return view
    }()
    
    
    internal func subscribe() {
        bag = DisposeBag()
        
        inSaveMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                    }
                }
            })
            .disposed(by: bag)
        
        enableSaveButton
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.33) {
                        if value {
                            if !self.saveButton.isEnabled {
                                self.saveButton.isEnabled = true
                            }
                        } else {
                            if self.saveButton.isEnabled {
                                self.saveButton.isEnabled = false
                            }
                        }
                    }
                }
            })
            .disposed(by: bag)
        
        modifiedForm
            .asObservable()
            .subscribe(onNext: { (value) in
                self.enableSaveButton.accept(value.isNotEmpty)
            })
            .disposed(by: bag)
        
        saveButton
            .rx
            .tap
            .asObservable()
            .subscribe(onNext: { (_) in
                self.onSave()
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
        if let formId = formId {
            AccountManager.shared.find(for: owner)?.groupchats.invalidateCallback(formId)
        }
        if let updateFormId = updateFormId {
            AccountManager.shared.find(for: owner)?.groupchats.invalidateCallback(updateFormId)
        }
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(_ owner: String, jid: String) {
        title = "Default restrictions".localizeString(id: "groupchat_default_restrictions", arguments: [])
        self.jid = jid
        self.owner = owner
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        self.navigationController?.setNavigationBarHidden(false, animated: false)
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
