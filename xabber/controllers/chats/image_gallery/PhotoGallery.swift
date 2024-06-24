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
import Kingfisher
import Toast_Swift
import simd
import RealmSwift
import CocoaLumberjack


public class PhotoGallery: UIViewController {
    static func getSenderName(messageId: String) -> (senderName: String, date: String, time: String) {
        var senderName = ""
        var date = ""
        var time = ""
        
        do {
            let realm = try WRealm.safe()
            let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messageId)
            if message?.outgoing == true {
                senderName = extractSenderName(owner: message?.owner, jid: message?.opponent)
            }
            if message?.outgoing == false {
                senderName = extractSenderName(owner: message?.opponent, jid: message?.owner)
            }
            if let msgDate = message?.date {
                let dateAndTime = prepareDate(date: msgDate)
                date = dateAndTime.date
                time = dateAndTime.send_time
            }
        } catch {
            DDLogDebug("PhotoGallery: \(#function). \(error.localizedDescription)")
        }
        return (senderName, date, time)
    }
    
    static func extractSenderName(owner: String?, jid: String?) -> String {
        guard let ownr = owner,
              let jd = jid else { return "" }
        do {
            let realm = try WRealm.safe()
            let primary = RosterStorageItem.genPrimary(jid: ownr, owner: jd)
            let sender_roster = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: primary)
            
            if let displayName = sender_roster?.displayName {
                if displayName != "" {
                    return displayName
                }
            }

            let sender_vcard = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: ownr)
            
            if let nickname = sender_vcard?.nickname {
                if nickname != "" {
                    return nickname
                }
            }

            if let fullName = sender_vcard?.fn {
                if fullName != "" {
                    return fullName
                }
            }

            if let name = sender_vcard?.given,
               let surname = sender_vcard?.family {
                if name != "" && surname != "" {
                    return name + " " + surname
                }
            }
        } catch {
            DDLogDebug("XabberUplaodManager: \(#function). \(error.localizedDescription)")
        }
        return ownr
    }
    
    static func prepareDate(date: Date) -> (date: String, send_time: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.YYYY"
        let dateString = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "H:mm"
        let timeString = dateFormatter.string(from: date)
        return (date: dateString, send_time: timeString)
    }
    
    
    let backgroundNavBarView: UIView = {
        let view = UIView()
        view.backgroundColor = .black.withAlphaComponent(0.5)
        
        return view
    }()
    
    let bottomInfoView: UIView = {
        let view = UIView()
        view.backgroundColor = .black.withAlphaComponent(0.5)
        view.translatesAutoresizingMaskIntoConstraints = false
        
        view.isUserInteractionEnabled = true
        
        return view
    }()
    
    let senderNameButton: UIButton = {
        let button = UIButton()
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18)
        button.titleLabel?.textColor = .white
        button.contentHorizontalAlignment = .left
        button.translatesAutoresizingMaskIntoConstraints = false
        
        
        return button
    }()
    
    let messageInfoButton: UIButton = {
        let button = UIButton()
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18)
        button.titleLabel?.textColor = .white
        button.contentHorizontalAlignment = .left
        button.translatesAutoresizingMaskIntoConstraints = false
        
        
        return button
    }()

    internal var animateImageTransition = false
    internal var isViewFirstAppearing = true
    internal var deviceInRotation = false
    internal var navBarIsHidden = false

    public lazy var imageCollectionView: UICollectionView = self.setupCollectionView()

    open var imageUrls: [URL] = []
    open var senders: [String] = []
    open var dates: [String] = []
    open var times: [String] = []
    open var messageIds: [String] = []
    
    var tappedPhotoDelegate: TappedPhotoInMediaGallery?
    var chatVCDelegate: TappedPhotoInMediaGalleryDelegate?
    var calledFromChatViewController: Bool = false
    
    open var initialPage: Int = 0
    
    public var numberOfImages: Int {
        return imageUrls.count
    }

    public var backgroundColor: UIColor {
        get {
            return view.backgroundColor!
        }
        set(newBackgroundColor) {
            view.backgroundColor = newBackgroundColor
            navigationController?.navigationBar.barTintColor = newBackgroundColor
        }
    }

    
    func setPage(page: Int) {
        self.initialPage = page
    }
    
    public var currentPage: Int {
        get {
            if isViewFirstAppearing {
                imageCollectionView.contentOffset.x = imageCollectionView.frame.size.width * CGFloat(initialPage)
                return initialPage
            } else {
                return Int(imageCollectionView.contentOffset.x / imageCollectionView.frame.size.width)
            }
        }
    }


    public var isSwipeToDismissEnabled: Bool = true

    internal var flowLayout: UICollectionViewFlowLayout = UICollectionViewFlowLayout()
    internal var pageControlBottomConstraint: NSLayoutConstraint?
    internal var pageControlCenterXConstraint: NSLayoutConstraint?
    internal var needsLayout = true
    
    public init(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], calledFromChat: Bool = false) {
        super.init(nibName: nil, bundle: nil)
        self.imageUrls = urls
        self.senders = senders
        self.dates = dates
        self.times = times
        self.messageIds = messageIds
        self.calledFromChatViewController = calledFromChat
    }
    
    func setupDelegate(photoGalleryDelegate: InfoScreenFooterView) {
        self.tappedPhotoDelegate = photoGalleryDelegate
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.black

        senderNameButton.addTarget(self, action: #selector(didTapSenderInfoButton), for: .touchUpInside)
        messageInfoButton.addTarget(self, action: #selector(didTapSenderInfoButton), for: .touchUpInside)
        configureNavbar()
        setupGestureRecognizers()
        
        view.addSubview(bottomInfoView)
        bottomInfoView.addSubview(senderNameButton)
        bottomInfoView.addSubview(messageInfoButton)
        view.bringSubviewToFront(bottomInfoView)
        makeConstraints()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updateTitle()
        updateSenderInfoLabels()
    }
    
    public override func viewDidAppear(_ animated: Bool) {

        super.viewDidAppear(animated)
        isViewFirstAppearing = false
        
//        if var topController = UIApplication.shared.keyWindow?.rootViewController {
//            while let presentedViewController = topController.presentedViewController {
//                topController = presentedViewController
//            }
//            print(topController.debugDescription)
//        }
    }
    
    func makeConstraints() {
        NSLayoutConstraint.activate([
            bottomInfoView.leftAnchor.constraint(equalTo: view.leftAnchor),
            bottomInfoView.rightAnchor.constraint(equalTo: view.rightAnchor),
            bottomInfoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomInfoView.heightAnchor.constraint(equalToConstant: 90),
            
            senderNameButton.leftAnchor.constraint(equalTo: bottomInfoView.leftAnchor, constant: 15),
            senderNameButton.rightAnchor.constraint(equalTo: bottomInfoView.rightAnchor, constant: -15),
            senderNameButton.topAnchor.constraint(equalTo: bottomInfoView.topAnchor, constant: 5),
            
            messageInfoButton.leftAnchor.constraint(equalTo: senderNameButton.leftAnchor),
            messageInfoButton.rightAnchor.constraint(equalTo: senderNameButton.rightAnchor),
            messageInfoButton.topAnchor.constraint(equalTo: senderNameButton.bottomAnchor, constant: -5)
        ])
    }
    
    @objc
    func didTapSenderInfoButton() {
        self.dismissGallery()
//        if chatVCDelegate == nil {
//            guard let primary = messageIds[currentPage].split(separator: "_").first else { return }
//            let chatViewController = ChatViewController()
////            chatViewController. // определить messageId сообщения и потом по нему создать ChatViewController()
//        }
        if calledFromChatViewController {
            guard let primary = messageIds[currentPage].split(separator: "_").first else { return }
            chatVCDelegate?.didTapPhotoFromChat(primary: String(primary))
        } else {
            guard let primary = messageIds[currentPage].split(separator: "_").first else { return }
            tappedPhotoDelegate?.tappedPhoto(primary: String(primary))
        }
    }

    
    public func reload(imageIndexes: Int...) {

        if imageIndexes.isEmpty {
            imageCollectionView.reloadData()

        } else {
            let indexPaths: [IndexPath] = imageIndexes.map({IndexPath(item: $0, section: 0)})
            imageCollectionView.reloadItems(at: indexPaths)
        }
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        flowLayout.itemSize = view.bounds.size
    }

    internal func updateSenderInfoLabels() {
        if currentPage < senders.count {
            senderNameButton.setTitle("Sent by \(senders[currentPage])"
                                        .localizeString(id: "photo_sent_by",
                                                        arguments: ["\(senders[currentPage])"]),
                                      for: .normal)
            let attributedInfoString = NSMutableAttributedString(string: String(dates[currentPage] + ", " + times[currentPage]))
            let range = NSRange(location: 0, length: dates[currentPage].count)
            attributedInfoString.addAttribute(.underlineStyle,
                                              value: 1,
                                              range: range)
            messageInfoButton.setAttributedTitle(attributedInfoString, for: .normal)
        }
    }
    
    internal func updateTitle() {
        title = "\(currentPage + 1) of \(imageUrls.count)"
            .localizeString(id: "page_of_number_of_pictures", arguments: ["\(currentPage + 1)", "\(imageUrls.count)"])
    }
    
    internal func configureNavbar() {
        navigationController?
            .navigationBar
            .titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.white]
        
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.addSubview(backgroundNavBarView)
        navigationController?.navigationBar.backgroundColor = .black.withAlphaComponent(0.5)
        backgroundNavBarView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: -120)
        
        let dismissButton = UIBarButtonItem(title: "Close".localizeString(id: "close", arguments: []),
                                            style: .done,
                                            target: self,
                                            action: #selector(dismissGallery))
        let linkButton = UIBarButtonItem(image: #imageLiteral(resourceName: "link-variant").withRenderingMode(.alwaysTemplate),
                                         style: .plain,
                                         target: self,
                                         action: #selector(onCopyLinkButton))
        let shareButton = UIBarButtonItem(image: #imageLiteral(resourceName: "share").withRenderingMode(.alwaysTemplate),
                                          style: .plain,
                                          target: self,
                                          action: #selector(onShareButton))
        [dismissButton, linkButton, shareButton].forEach{
            $0.tintColor = .white
        }
        navigationItem.setLeftBarButton(dismissButton, animated: true)
        navigationItem.setRightBarButtonItems([shareButton, linkButton], animated: true)
    }

    

    // MARK: - Internal Methods
//    internal func updatePageControl() {
//        pageControl.currentPage = currentPage
//    }


    // MARK: Gesture Handlers

    internal func setupGestureRecognizers() {

        #if os(iOS)
            let panGesture = PanDirectionGestureRecognizer(direction: PanDirection.vertical, target: self, action: #selector(wasDragged(_:)))
            imageCollectionView.addGestureRecognizer(panGesture)
            imageCollectionView.isUserInteractionEnabled = true
        #endif


        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapAction(recognizer:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        imageCollectionView.addGestureRecognizer(singleTap)
    }

    #if os(iOS)
    @objc
    internal func wasDragged(_ gesture: PanDirectionGestureRecognizer) {

        guard let image = gesture.view, isSwipeToDismissEnabled else { return }

        let translation = gesture.translation(in: self.view)
        image.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY + translation.y)

        let yFromCenter = image.center.y - self.view.bounds.midY


        if gesture.state == UIGestureRecognizer.State.ended {

            var swipeDistance: CGFloat = 0
            let swipeBuffer: CGFloat = 50
            var animateImageAway = false

            if yFromCenter > -swipeBuffer && yFromCenter < swipeBuffer {
                // reset everything
                self.navigationController?.setNavigationBarHidden(false, animated: true)
                UIView.animate(withDuration: 0.25, animations: {
                    self.view.backgroundColor = self.backgroundColor.withAlphaComponent(1.0)
                    image.center = CGPoint(x: self.view.frame.midX, y: self.view.frame.midY - (((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) / 1.65))
                })
            } else if yFromCenter < -swipeBuffer {
                swipeDistance = 0
                animateImageAway = true
            } else {
                swipeDistance = self.view.bounds.height
                animateImageAway = true
            }

            if animateImageAway {
                self.navigationController?.setNavigationBarHidden(true, animated: true)
                
                if self.modalPresentationStyle == .custom {
                    dismissGallery()
                    return
                }

                UIView.animate(withDuration: 0.35, animations: {
                    self.view.alpha = 0
                    image.center = CGPoint(x: self.view.bounds.midX, y: swipeDistance)
                }, completion: { (complete) in
                    self.dismissGallery()
                })
            }

        }
    }
    #endif

    @objc
    public func singleTapAction(recognizer: UITapGestureRecognizer) {
        if navBarIsHidden {
            UIView.animate(withDuration: 0.11, animations: {
                self.navigationController?.navigationBar.alpha = 1
                self.bottomInfoView.alpha = 1
            })
        } else {
            UIView.animate(withDuration: 0.11, animations: {
                self.navigationController?.navigationBar.alpha = 0
                self.bottomInfoView.alpha = 0
            })
        }
        navBarIsHidden.toggle()
    }
    
    internal func setupCollectionView() -> UICollectionView {
        // Set up flow layout
        flowLayout.scrollDirection = UICollectionView.ScrollDirection.horizontal
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0

        // Set up collection view
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: flowLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(PhotoGalleryCell.self, forCellWithReuseIdentifier: "PhotoGalleryCell")
        collectionView.register(PhotoGalleryCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "PhotoGalleryCell")
        collectionView.register(PhotoGalleryCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "PhotoGalleryCell")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = UIColor.clear
        collectionView.showsHorizontalScrollIndicator = false
        #if os(iOS)
            collectionView.isPagingEnabled = true
        #endif

        // Set up collection view constraints
        var imageCollectionViewConstraints: [NSLayoutConstraint] = []
        imageCollectionViewConstraints.append(NSLayoutConstraint(item: collectionView,
                                                                 attribute: .leading,
                                                                 relatedBy: .equal,
                                                                 toItem: view,
                                                                 attribute: .leading,
                                                                 multiplier: 1,
                                                                 constant: 0))

        imageCollectionViewConstraints.append(NSLayoutConstraint(item: collectionView,
                                                                 attribute: .top,
                                                                 relatedBy: .equal,
                                                                 toItem: view,
                                                                 attribute: .top,
                                                                 multiplier: 1,
                                                                 constant: -((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) * 1.95)) //So when navbar is hidden, image doesn't jump up

        imageCollectionViewConstraints.append(NSLayoutConstraint(item: collectionView,
                                                                 attribute: .trailing,
                                                                 relatedBy: .equal,
                                                                 toItem: view,
                                                                 attribute: .trailing,
                                                                 multiplier: 1,
                                                                 constant: 0))

        imageCollectionViewConstraints.append(NSLayoutConstraint(item: collectionView,
                                                                 attribute: .bottom,
                                                                 relatedBy: .equal,
                                                                 toItem: view,
                                                                 attribute: .bottom,
                                                                 multiplier: 1,
                                                                 constant: (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0))
        
        view.addSubview(collectionView)
        view.addConstraints(imageCollectionViewConstraints)

        collectionView.contentSize = CGSize(width: 1000.0, height: 1.0)

        return collectionView
    }

    internal func getImageUrl(currentPage: Int) -> URL? {
        return imageUrls[currentPage]
    }
}

extension PhotoGallery: UICollectionViewDataSource {

    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }

    public func collectionView(_ imageCollectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return imageUrls.count
    }

    public func collectionView(_ imageCollectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = imageCollectionView
            .dequeueReusableCell(withReuseIdentifier: "PhotoGalleryCell",
                                 for: indexPath) as? PhotoGalleryCell else {
            fatalError()
        }
        cell.imageUrl = getImageUrl(currentPage: indexPath.item)
        
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        var cell = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "PhotoGalleryCell", for: indexPath) as! PhotoGalleryCell

        switch kind {
        case UICollectionView.elementKindSectionFooter:
            cell.imageUrl = getImageUrl(currentPage: currentPage)
        case UICollectionView.elementKindSectionHeader:
            cell = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "PhotoGalleryCell", for: indexPath) as! PhotoGalleryCell
            cell.imageUrl = getImageUrl(currentPage: currentPage)
        default:
            assertionFailure("Unexpected element kind")
        }

        return cell
    }
}

extension PhotoGallery: UICollectionViewDelegate {

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        animateImageTransition = true
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        animateImageTransition = false
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? PhotoGalleryCell {
            cell.configureForNewImageUrl(animated: animateImageTransition)
        }
        updateTitle()
        updateSenderInfoLabels()
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView, forElementKind elementKind: String, at indexPath: IndexPath) {
        if let cell = view as? PhotoGalleryCell {
            collectionView.layoutIfNeeded()
            cell.configureForNewImageUrl(animated: animateImageTransition)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        updateTitle()
        updateSenderInfoLabels()
    }
}

extension PhotoGallery: UIGestureRecognizerDelegate {
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        
        return otherGestureRecognizer is UITapGestureRecognizer &&
            gestureRecognizer is UITapGestureRecognizer &&
            otherGestureRecognizer.view is PhotoGalleryCell &&
            gestureRecognizer.view == imageCollectionView
    }
}
//MARK: - В делегат от чата
extension PhotoGallery {
    @objc
    internal func dismissGallery() {
        self.dismiss(animated: true, completion: nil)
        chatVCDelegate?.showInputBar()
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
    }
    
    @objc
    internal func onCopyLinkButton() {
        UIPasteboard.general.url = imageUrls[currentPage]
        self.view.makeToast("Image link in your pasteboard".localizeString(id: "image_link_in_pasteboard", arguments: []),
                            duration: 3.0, position: .bottom)
    }
    
    @objc
    internal func onShareButton() {

        guard let image = (imageCollectionView.cellForItem(at: IndexPath(item: currentPage, section: 0)) as? PhotoGalleryCell)?.imageView.image else { return } //row?
        let objectsToShare = [image, imageUrls[currentPage]] as [Any]
        let activityVC = UIActivityViewController(activityItems: objectsToShare, applicationActivities: nil)
        activityVC.excludedActivityTypes = []
        showModal(activityVC)
    }
}
