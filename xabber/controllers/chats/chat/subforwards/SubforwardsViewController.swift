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
import RealmSwift
import RxRealm
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class SubforwardsViewController: MessagesViewController {
    
//    override var owner: String = "" {
//        didSet {
//
//        }
//    }
//    internal var jid: String = ""
    
    var opponentSender: Sender = Sender(id: "", displayName: "")
    var ownerSender: Sender = Sender(id: "", displayName: "")
    
    var accountPallete: MDCPalette = MDCPalette.red
    
    // audio messages
    var playingMessageIndexPath: ChatViewController.PlayingAudioCell? = nil
    var playingMessageUpdateTimer: Timer? = nil
    var lastRecordingNotificationRequestDate: Date? = nil
    
    internal var subforwards: [MessageForwardsInlineStorageItem.Model] = []
    
    var bag: DisposeBag = DisposeBag()
    
    let messageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "HH:mm"
        
        return formatter
    }()
    
    @objc
    internal func dissmissModal() {
        self.dismiss(animated: true) {
            
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            var parentIds: Set<String> = Set<String>()
            subforwards.compactMap { return $0.parentId }.forEach { parentIds.insert($0) }
            Observable
                .changeset(from: realm.objects(MessageForwardsInlineStorageItem.self)
                    .filter("parentId IN %@", Array(parentIds)))
                .debug()
                .subscribe(onNext: { results in
                    guard let changeset = results.1 else { return }
                    let collection = results.0
                    func updateDatasource() {
                        if changeset.inserted.isNotEmpty {
                            self.messagesCollectionView.reloadDataAndKeepOffset()
                        }
                        if changeset.deleted.isNotEmpty {
                            self.messagesCollectionView.reloadDataAndKeepOffset()
                        }
                        if changeset.updated.isNotEmpty {
                            let messageIndexes = changeset
                                .updated
                                .compactMap { collection[$0].messageId }
                                .compactMap { id in self.subforwards.firstIndex(where: { $0.messageId == id }) }
                            self.messagesCollectionView.reloadSections(IndexSet(messageIndexes))
                        }
                    }
                    if #available(iOS 11.0, *) {
                        self.messagesCollectionView.performBatchUpdates({
                            updateDatasource()
                        }, completion: nil)
                    } else {
                        updateDatasource()
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("SubforwardsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    override var inputAccessoryView: UIView? {
        return nil
    }
    
    open func configure(_ owner: String, jid: String, items subforwards: [MessageForwardsInlineStorageItem.Model]) {
        self.owner = owner
        self.jid = jid
        self.subforwards = subforwards
        messagesCollectionView.messagesDataSource = self
        messagesCollectionView.messageCellDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self
        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        messagesCollectionView.scrollsToTop = false
        scrollsToBottomOnKeybordBeginsEditing = false
        maintainPositionOnKeyboardFrameChanged = true
        
        messagesCollectionView.accountPalette = accountPallete
        
        let backgroundImage = UIImageView(frame: self.view.bounds)
        backgroundImage.image =  imageLiteral( "chatBackground320")?.withRenderingMode(.alwaysOriginal)
            .resizableImage(withCapInsets: UIEdgeInsets.zero,
                            resizingMode: .tile)
        backgroundImage.contentMode = .scaleAspectFill//.scaleAspectFit
        let coloredView: UIView = UIView(frame: view.bounds)
        coloredView.backgroundColor = AccountColorManager.shared.pairedPalette(jid: owner).tint100
        coloredView.alpha = 0.8
        backgroundImage.addSubview(coloredView)
        backgroundImage.bringSubviewToFront(coloredView)
        
        self.messagesCollectionView.backgroundView =  backgroundImage
        if subforwards.count == 1 {
            title = "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])
        } else {
            title = "\(subforwards.count) forwarded messages"
                .localizeString(id: "counted_forwarded_messages", arguments: ["\(subforwards.count)"])
        }
        navigationItem.setLeftBarButton(UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(self.dissmissModal)), animated: true)
//        self.xab.isHidden = true
//        self.additionalTopInset = -34
        self.accessoryViewCorrectionConstant = 38
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ownerSender = Sender(id: owner, displayName: AccountManager.shared.find(for: owner)?.username ?? owner)
        accountPallete = AccountColorManager.shared.palette(for: owner)
        let messageIds = subforwards.compactMap { return $0.messageId }
        AccountManager.shared.find(for: owner)?.action({ _,_ in
            messageIds.forEach {
                MessageReferenceStorageItem.prepareVoice(inline: $0 )}
//                MessageReferenceStorageItem
        })
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
//        OpusAudio.shared.resetPlayer()
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
