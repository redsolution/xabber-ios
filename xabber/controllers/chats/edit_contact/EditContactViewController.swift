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
import RealmSwift
import RxSwift
import RxCocoa
import CocoaLumberjack

class EditContactViewController: BaseViewController {
    
    class Datasource {
        enum Kind {
            case field
            case select
            case simple
            case danger
        }
        
        var kind: Kind
        var title: String
        var selectedValue: Bool?
        var fieldValue: String?
        var key: String
        
        init(kind: Kind, key: String, title: String, bool selectedValue: Bool? = nil, string fieldValue: String? = nil) {
            self.kind = kind
            self.key = key
            self.title = title
            self.selectedValue = selectedValue
            self.fieldValue = fieldValue
        }
    }
    
//    open var jid: String = ""
//    open var owner: String = ""
    
    open var isCircleSelectView: Bool = false
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.keyboardDismissMode = .onDrag
        
        view.register(TextEditBaseCell.self, forCellReuseIdentifier: TextEditBaseCell.cellName)
        view.register(SelectionCell.self, forCellReuseIdentifier: SelectionCell.cellName)
        view.register(SubscribtionCell.self, forCellReuseIdentifier: SubscribtionCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DangerCell")
                
        return view
    }()
    
    private var tableViewBottomInset: CGFloat = 8 {
        didSet {
            self.tableView.contentInset.bottom = self.tableViewBottomInset
            self.tableView.scrollIndicatorInsets.bottom = self.tableViewBottomInset
        }
    }
    private var automaticallyAddedBottomInset: CGFloat {
        if #available(iOS 11.0, *) {
            return tableView.adjustedContentInset.bottom - tableView.contentInset.bottom
        } else {
            return 0
        }
    }
    
    private var additionalBottomInset: CGFloat = 8 {
        didSet {
            let delta = additionalBottomInset - oldValue
            tableViewBottomInset += delta
        }
    }
    
    private var initialBottomInset: CGFloat {
        if #available(iOS 11, *) {
            return 0
        } else {
            return 8
        }
    }
    
    let topFrontView: UITabBar = {
        let view = UITabBar()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Save".localizeString(id: "save", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
        
    internal let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                     style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasource: [[Datasource]] = []
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var saveButtonActive: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
        
    
    internal var initialNickname: String? = nil
    internal var nickname: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var initialGroups: Set<String> = Set<String>()
    internal var selectedGroups: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    internal var initialAcceptSubscribtions: Bool = false
    internal var initialAskSubscribtions: Bool = false
    
    internal var acceptSubscribtions: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var askSubscribtions: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    
    internal var subscribtion: BehaviorRelay<RosterStorageItem.Subsccribtion> = BehaviorRelay(value: .undefined)
    internal var ask: BehaviorRelay<RosterStorageItem.Ask> = BehaviorRelay(value: .none)
    internal var approved: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var subscribtionSectionIndex: Int = 2
    internal var groupsSectionIndex: Int = 0
    
    internal var isGroupchat: Bool = false {
        willSet {
            if newValue {
                self.subscribtionSectionIndex = 5
                self.groupsSectionIndex = 0
            }
        }
    }
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            let vcardItem = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid)
            let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
            let groupchat = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, owner].prp())
            isGroupchat = groupchat != nil
            switch rosterItem?.subscribtion ?? .none {
            case .to:
                self.askSubscribtions.accept(true)
                self.acceptSubscribtions.accept(false)
            case .from:
                self.askSubscribtions.accept(false)
                self.acceptSubscribtions.accept(true)
            case .both:
                self.askSubscribtions.accept(true)
                self.acceptSubscribtions.accept(true)
            case .none, .undefined:
                self.askSubscribtions.accept(false)
                self.acceptSubscribtions.accept(false)
            }
            if rosterItem?.ask == .out {
                self.askSubscribtions.accept(true)
            }
            if let contactGroups = rosterItem?.groups.toArray() {
                initialGroups = Set(contactGroups)
                selectedGroups.accept(Set(contactGroups))
            }
            initialNickname = rosterItem?.customUsername
            nickname.accept(initialNickname)
            
            let preaprovedItem = realm.object(ofType: PreaprovedSubscribtionStorageItem.self, forPrimaryKey: [jid, owner].prp())
            if preaprovedItem != nil {
                self.acceptSubscribtions.accept(true)
            }
            let groups = realm
                .objects(RosterGroupStorageItem.self)
                .filter("owner == %@ AND isSystemGroup == false", owner)
                .sorted(byKeyPath: "name", ascending: true)

            if self.isCircleSelectView {
                
                let contactGroups = groups.toArray().compactMap {
                    Datasource(
                        kind: .select, key: "circle",
                        title: $0.name,
                        bool: initialGroups.contains($0.name)
                    )
                }
                
                datasource.append(contactGroups + [Datasource(kind: .field, key: "new_circle", title: "Create new circle")])
                
                contactGroups
                    .enumerated()
                    .compactMap({ return $1.selectedValue == true ? IndexPath(row: $0, section: groupsSectionIndex) : nil })
                    .forEach { self.tableView.selectRow(at: $0, animated: false, scrollPosition: .none) }
            } else {
                datasource = [
                    [Datasource(kind: .field, key: "nickname", title: groupchat?.name ?? vcardItem?.generatedNickname ?? jid, string: rosterItem?.customUsername)],
                    [Datasource(kind: .simple, key: "presence_receive", title: "Receiving presence updates".localizeString(id: "subscription_status_out_to", arguments: []), bool: nil, string: nil),
                     Datasource(kind: .simple, key: "presence_send", title: "Sending presence updates".localizeString(id: "subscription_status_in_from", arguments: []), bool: nil, string: nil)],
                    [Datasource(kind: .danger, key: "delete", title: "Delete".localizeString(id: "delete", arguments: []))]
                ]
            }
        } catch {
            DDLogDebug("EditContactViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        addObservers()
        saveButton.rx.tap.bind {
            self.onSave()
        }.disposed(by: bag)
        
        cancelButton.rx.tap.bind {
            self.cancel()
        }.disposed(by: bag)
        
        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm
                                .objects(RosterStorageItem.self)
                                .filter("jid == %@ AND owner == %@", self.jid, self.owner))
//                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let rosterItem = results.first {
                        self.subscribtion.accept(rosterItem.subscribtion)
                        self.ask.accept(rosterItem.ask)
                        self.approved.accept(rosterItem.approved)
                    }
                } onError: { error in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: bag)

        } catch {
            DDLogDebug(error.localizedDescription)
        }
        
        subscribtion
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .subscribe { value in
                if self.isCircleSelectView {
                    return
                }
                DispatchQueue.main.async {
                    self.tableView.reloadSections(IndexSet([1]), with: .none)
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)

        ask
            .asObservable()
            .debounce(.milliseconds(60), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .subscribe { value in
                if self.isCircleSelectView {
                    return
                }
                DispatchQueue.main.async {
                    self.tableView.reloadSections(IndexSet([1]), with: .none)
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)
        
        approved
            .asObservable()
            .debounce(.milliseconds(70), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .subscribe { value in
                if self.isCircleSelectView {
                    return
                }
                DispatchQueue.main.async {
                    self.tableView.reloadSections(IndexSet([1]), with: .none)
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)
        
        nickname
            .asObservable()
            .subscribe(onNext: { _ in
                self.saveButtonActive.accept(self.validate())
            })
            .disposed(by: bag)
        
        selectedGroups
            .asObservable()
            .subscribe(onNext: { _ in
                self.saveButtonActive.accept(self.validate())
            })
            .disposed(by: bag)
        
        acceptSubscribtions
            .asObservable()
            .subscribe(onNext: { _ in
                self.saveButtonActive.accept(self.validate())
            })
            .disposed(by: bag)
        
        askSubscribtions
            .asObservable()
            .subscribe(onNext: { _ in
                self.saveButtonActive.accept(self.validate())
            })
            .disposed(by: bag)
        
        saveButtonActive.asObservable().subscribe(onNext: { (value) in
            UIView.animate(withDuration: 0.33, animations: {
                self.saveButton.isEnabled = value
            })
        }).disposed(by: bag)
        
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
    
    internal func unsubscribe() {
        bag = DisposeBag()
        removeObservers()
    }
    
    func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleKeyboardDidChangeState(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    internal func requiredScrollViewBottomInset(forKeyboardFrame keyboardFrame: CGRect) -> CGFloat {
        let intersection = tableView.frame.intersection(keyboardFrame)
        if intersection.isNull || intersection.maxY < tableView.frame.maxY {
            return max(initialBottomInset, additionalBottomInset - automaticallyAddedBottomInset)
        } else {
            return max(initialBottomInset, intersection.height + additionalBottomInset - automaticallyAddedBottomInset)
        }
    }
    
    @objc
    internal func handleKeyboardDidChangeState(_ notification: Notification) {
        guard let keyboardStartFrameInScreenCoords = notification
            .userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect,
            !keyboardStartFrameInScreenCoords.isEmpty,
            let keyboardEndFrameInScreenCoords = notification
                .userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardEndFrame = view.convert(keyboardEndFrameInScreenCoords, from: view.window)
        let newBottomInset = requiredScrollViewBottomInset(forKeyboardFrame: keyboardEndFrame)
        tableViewBottomInset = newBottomInset
    }
    
    @objc
    internal func cancel() {
        if self.isCircleSelectView {
            self.dismissKeyboard()
            self.dismiss(animated: true, completion: nil)
        } else {
            self.dismissKeyboard()
            self.nickname.accept(initialNickname)
            self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
            
        }
    }
    
    internal func configure() {
        view.addSubview(tableView)
//        view.addSubview(topFrontView)
        makeConstraints()
        
        tableView.fillSuperview()
//        tableView.fillSuperviewWithOffset(top: -24, bottom: 0, left: 0, right: 0)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.tableHeaderView = UIView()
        tableView.tableFooterView = UIView()
        load()
        if self.isCircleSelectView {
            self.title = "Circles".localizeString(id: "contact_circle", arguments: [])
//            self.navigationItem.setLeftBarButton(self.cancelButton, animated: true)
        } else {
            self.title = "Edit".localizeString(id: "groupchat_member_edit", arguments: [])
        }
        self.navigationItem.setRightBarButton(saveButton, animated: true)
    }
    
    func makeConstraints() {
//        NSLayoutConstraint.activate([
//            topFrontView.leftAnchor.constraint(equalTo: view.leftAnchor),
//            topFrontView.topAnchor.constraint(equalTo: view.topAnchor),
//            topFrontView.rightAnchor.constraint(equalTo: view.rightAnchor),
//            topFrontView.heightAnchor.constraint(equalToConstant: 48)
//        ])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
