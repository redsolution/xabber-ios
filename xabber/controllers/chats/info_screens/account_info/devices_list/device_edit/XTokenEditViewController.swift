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
import TOInsetGroupedTableView
import RealmSwift
import RxSwift
import RxCocoa
import CocoaLumberjack

class XTokenEditViewController: SimpleBaseViewController {
    internal var deviceDescr: String? = nil
    internal var newDeviceDescr: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var saveButtonActive: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .plain, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
        
    internal let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .cancel, target: nil, action: nil)
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    private let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(TextEditBaseCell.self, forCellReuseIdentifier: TextEditBaseCell.cellName)
        
        return view
    }()
    
    override func subscribe() {
        super.subscribe()
        saveButton.rx.tap.bind {
            self.onSave()
        }.disposed(by: bag)
        
        cancelButton.rx.tap.bind {
            self.cancel()
        }.disposed(by: bag)
        
        newDeviceDescr
            .asObservable()
            .subscribe(onNext: { _ in
                self.saveButtonActive.accept(self.validate())
            })
            .disposed(by: bag)
        
        saveButtonActive
            .asObservable()
            .subscribe(onNext: { (value) in
                UIView.animate(withDuration: 0.33, animations: {
                    self.saveButton.isEnabled = value
                })
                if value {
                    self.navigationItem.setLeftBarButton(self.cancelButton, animated: true)
                } else {
                    self.navigationItem.setLeftBarButton(nil, animated: true)
                }
            })
            .disposed(by: bag)
        
        inSaveMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    self.tableView.isUserInteractionEnabled = !value
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
                    }
                }
            })
            .disposed(by: bag)
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            guard let uid = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.xTokenUID else {
                return
            }
            self.deviceDescr = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp())?.descr
            self.newDeviceDescr.accept(self.deviceDescr)
        } catch {
            DDLogDebug("XTokenEditViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
    }
    
    override func configure() {
        super.configure()
        tableView.delegate = self
        tableView.dataSource = self
        self.title = "Edit device".localizeString(id: "account_edit_device", arguments: [])
    }
    
    override func onAppear() {
        super.onAppear()
        print(self.owner)
        XMPPUIActionManager.shared.open(owner: self.owner)
    }
    
    
}

extension XTokenEditViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
}

extension XTokenEditViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: TextEditBaseCell.cellName, for: indexPath) as? TextEditBaseCell else {
            fatalError()
        }
        
        cell.configure("description", value: newDeviceDescr.value, placeholder: UIDevice.current.name)
        cell.textFieldDidChangeValueCallback = self.onTextFieldDidChange
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "Device description".localizeString(id: "devices__dialog__device_description", arguments: [])
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Example \(UIDevice.current.name)".localizeString(id: "devices_dialog_device_example",
                                                                 arguments: ["\(UIDevice.current.name)"])
    }
    
}

extension XTokenEditViewController {
    internal final func onTextFieldDidChange(target field: String, value: String?) {
        switch field {
        case "description":
            self.newDeviceDescr.accept(value)
            break
        default:
            break
        }
    }
    
    internal final func validate() -> Bool {
        return newDeviceDescr.value != deviceDescr
    }
    
    internal final func onSave() {
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.devices?.update(stream, descr: self.newDeviceDescr.value)
            DispatchQueue.main.async {
                self.goBack()
            }
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.devices.update(stream, descr: self.newDeviceDescr.value)
                DispatchQueue.main.async {
                    self.goBack()
                }
            })
        }
    }
    
    internal final func cancel() {
        self.newDeviceDescr.accept(deviceDescr)
        self.inSaveMode.accept(false)
        self.saveButtonActive.accept(false)
    }
}
