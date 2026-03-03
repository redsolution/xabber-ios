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
import MaterialComponents.MDCPalettes
import XMPPFramework.XMPPJID

class SignInServerFeaturesViewController: UIViewController {
    
    class SignInTitleCell: UITableViewCell {
        public static let cellName: String = "titleCell"
        
        private let titleLabel: UILabel = {
            let label = UILabel()
                        
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
            label.numberOfLines = 0
            label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            
            return label
        }()
        
        public final func configure(_ title: String) {
            titleLabel.text = title
            selectionStyle = .none
        }
        
        private final func setup() {
            contentView.addSubview(titleLabel)
            titleLabel.fillSuperviewWithOffset(top: 2, bottom: 2, left: 20, right: 20)
            selectionStyle = .none
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override class func awakeFromNib() {
            super.awakeFromNib()
        }
        
    }
    
    class SignInFeatureCell: UITableViewCell {
        public static let cellName: String = "featureCell"
        
        var errorText: NSAttributedString = NSAttributedString()
        
        private let container: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 0
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        private let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 0
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        private let topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.spacing = 16
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        private let label: UILabel = {
            let label = UILabel()
            
            label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            
            return label
        }()
        
        private let errorLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 15, weight: .regular)
            label.numberOfLines = 0
            label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            
            return label
        }()
        
        private let indicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .gray)
            
            view.isHidden = false
            view.startAnimating()
            
            return view
        }()
        
        private let checkView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 24))
            
            view.image = imageLiteral( "xabber.checkmark")
            view.tintColor = .systemGreen
            view.isHidden = true
            
            return view
        }()
        
        private final func activateConstrtaints() {
            NSLayoutConstraint.activate([
                stack.widthAnchor.constraint(equalToConstant: 375),
                indicator.widthAnchor.constraint(equalToConstant:  24),
                indicator.heightAnchor.constraint(equalToConstant: 24),
                checkView.widthAnchor.constraint(equalToConstant:  24),
                checkView.heightAnchor.constraint(equalToConstant: 24),
                label.heightAnchor.constraint(equalToConstant: 24),
                topStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0),
                errorLabel.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
                errorLabel.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
                topStack.heightAnchor.constraint(equalToConstant: 24),
                errorHeightConstraint!
            ])
        }
        
        private final func setup() {
            contentView.addSubview(container)
            container.fillSuperviewWithOffset(top: 4, bottom: 12, left: 32, right: 32)
            container.addArrangedSubview(stack )
            stack.addArrangedSubview(topStack)
            stack.addArrangedSubview(errorLabel)
            topStack.addArrangedSubview(label)
            topStack.addArrangedSubview(indicator)
            topStack.addArrangedSubview(checkView)
            heightAnchorConstraint = heightAnchor.constraint(equalToConstant: 44)
            errorHeightConstraint = errorLabel.heightAnchor.constraint(equalToConstant: 0)
            activateConstrtaints()
            selectionStyle = .none
        }
        
        public final func configure(title: String) {
            label.text = title
            selectionStyle = .none
        }
        
        public final func reset() {
            self.isHidden = true
            self.checkView.isHidden = true
            self.errorLabel.text = nil
            self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        }
        
        public final func setChecked(_ checked: Bool) {
            if checked {
                self.checkView.tintColor = .systemGreen
                self.checkView.image = imageLiteral( "xabber.checkmark")
                self.indicator.isHidden = true
                self.indicator.alpha = 0.0
                self.checkView.isHidden = false
                if #available(iOS 13.0, *) {
                    self.label.textColor = .label
                } else {
                    self.label.textColor = .darkText
                }
            } else {
                self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                self.checkView.isHidden = true
            }
        }
        
        public final func setError(_ error: Bool, isDamger: Bool) {
                if error {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineHeightMultiple = 1.27
                    let attributedError = NSMutableAttributedString(attributedString: errorText)
                    attributedError.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(errorText.string.startIndex..<errorText.string.endIndex, in: errorText.string))
                    self.errorLabel.attributedText = attributedError
                    
                    let constraintBox = CGSize(width: UIDevice.current.userInterfaceIdiom == .pad ? 375 : (bounds.width - 84), height: .greatestFiniteMagnitude)
                    let rect = attributedError.boundingRect(with: constraintBox, options: [
                        .usesLineFragmentOrigin,
                        .usesFontLeading
                    ], context: nil)
                    
                    let size = rect.size
                    self.errorLabel.frame = CGRect(origin: .zero, size: size)
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        self.errorHeightConstraint?.constant = size.height + 44
                    } else {
                        self.errorHeightConstraint?.constant = size.height + 28
                    }
                    if isDamger {
                        self.checkView.tintColor = .systemRed
                        self.checkView.image = imageLiteral("exclamationmark.circle.fill")
                    } else {
                        self.checkView.tintColor = .systemYellow
                        self.checkView.image = imageLiteral("exclamationmark.triangle.fill")
                    }
                    self.indicator.isHidden = true
                    self.indicator.alpha = 0.0
                    self.checkView.isHidden = false
                    if #available(iOS 13.0, *) {
                        self.label.textColor = .label
                    } else {
                        self.label.textColor = .darkText
                    }
                } else {
                    self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                    self.errorLabel.text = nil
//                    self.indicator.isHidden = false
                    self.checkView.isHidden = true
                }
//            }
        }
        
        var errorHeightConstraint: NSLayoutConstraint? = nil
        var heightAnchorConstraint: NSLayoutConstraint? = nil
                
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override class func awakeFromNib() {
            super.awakeFromNib()
        }
    }
    
    class SignInSubtitleCell: UITableViewCell {
        public static let cellName: String = "subtitleCell"
        
        private let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            
            
            return label
        }()
        
        private let separartorView: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.22)
            
            return view
        }()
        
        public final func configure(_ subtitle: NSAttributedString) {
            subtitleLabel.attributedText = subtitle
            selectionStyle = .none
        }
        
        private final func setup() {
            contentView.addSubview(subtitleLabel)
            subtitleLabel.fillSuperviewWithOffset(top: 32, bottom: 24, left: 32, right: 32)
            NSLayoutConstraint.activate([
                subtitleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
            ])
            selectionStyle = .none
            
            contentView.addSubview(separartorView)
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            separartorView.frame = CGRect(
                x: 28,
                y: 12,
                width: contentView.bounds.width - 56,
                height: 0.5
            )
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override class func awakeFromNib() {
            super.awakeFromNib()
        }
    }
    
    class SignInButtonCell: UITableViewCell {
        public static let cellName: String = "buttonCell"
        
        public var onButtonTouchUpCallback: (() -> Void)? = nil
        
        private let button: UIButton = {
            let button = UIButton()
            
            button.layer.cornerRadius = 28
            button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
                        
            return button
        }()
        
        private let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            
            return stack
        }()
        
        public final func configure(_ title: String, active: Bool) {
            button.setTitle(title, for: .normal)
            button.setTitle(title, for: .disabled)
            if active {
                makeButtonEnabled(false)
            } else {
                makeButtonDisabled(false)
            }
            selectionStyle = .none
            button.addTarget(self, action: #selector(self.onButtonTouchUp), for: .touchUpInside)
        }
        
        private final func doAnimationsBlock(animated: Bool, block: @escaping (() -> Void)) {
            if animated {
                UIView.animate(
                    withDuration: 0.33,
                    delay: 0.0,
                    options: [.curveEaseIn],
                    animations: block,
                    completion: nil
                )
            } else {
                UIView.performWithoutAnimation(block)
            }
        }
        
        public final func makeButtonEnabled(_ animated: Bool) {
            doAnimationsBlock(animated: animated) {
                self.button.isEnabled = true
                self.button.backgroundColor = .systemBlue
                self.button.setTitleColor(.white, for: .normal)
            }
        }
        
        public final func makeButtonDisabled(_ animated: Bool) {
            doAnimationsBlock(animated: animated) {
                self.button.isEnabled = true
                self.button.backgroundColor = .clear
                self.button.setTitleColor(.systemBlue, for: .normal)
            }
        }
        
        private final func setup() {
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(UIStackView())
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 276),
                button.heightAnchor.constraint(equalToConstant: 56),
            ])
            selectionStyle = .none
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override class func awakeFromNib() {
            super.awakeFromNib()
        }
        
        @objc
        private final func onButtonTouchUp(_ sender: UIButton) {
            self.onButtonTouchUpCallback?()
        }
    }
    
    class Datasource {
        enum Kind {
            case title
            case feature
            case subtitle
            case button
        }
        
        var key: String
        var kind: Kind
        var title: String?
        var text: String?
        var value: Bool?
        var isHidden: Bool
        var attributedText: NSAttributedString?
        var isDanger: Bool
        
        init(key: String, kind: Kind, title: String? = nil, text: String? = nil, attributedText: NSAttributedString? = nil, value: Bool? = nil, isHidden: Bool = true, isDanger: Bool = false) {
            self.key = key
            self.kind = kind
            self.title = title
            self.text = text
            self.value = value
            self.isHidden = isHidden
            self.attributedText = attributedText
            self.isDanger = isDanger
        }
    }
    
    var datasource: [Datasource] = []
    
    public var isModal: Bool = false
    
    public var jid: String = ""
    public var host: String? = nil
    
    public var features: [String] = []
    
    private var isPushAvailable             : Bool? = nil
    private var isMamAvailable              : Bool? = nil
    private var isSyncAvailable             : Bool? = nil
    private var isRewriteAvailable          : Bool? = nil
    private var isDeviceManagementAvailable : Bool? = nil
    private var isPubsubAvailable           : Bool? = nil
    private var isHTTPUploadAvailable       : Bool? = nil
//    private var isXabberUploadAvailable     : Bool? = nil
    
    
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        view.separatorStyle = .none
        
        view.register(SignInTitleCell.self, forCellReuseIdentifier: SignInTitleCell.cellName)
        view.register(SignInFeatureCell.self, forCellReuseIdentifier: SignInFeatureCell.cellName)
        view.register(SignInSubtitleCell.self, forCellReuseIdentifier: SignInSubtitleCell.cellName)
        view.register(SignInButtonCell.self, forCellReuseIdentifier: SignInButtonCell.cellName)
        
        return view
    }()
    
    private final func setup() {
        view.addSubview(tableView)
//        tableView.fillSuperview()
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        tableView.fillSuperviewWithOffset(top: view.safeAreaInsets.top + 64, bottom: view.safeAreaInsets.bottom, left: 0, right: 0)
        tableView.tableFooterView = UIView()
        tableView.tableHeaderView = UIView()
    }
    
    private final func configure() {
        tableView.dataSource = self
        tableView.delegate = self
        if isModal {
            if #available(iOS 13.0, *) {
                isModalInPresentation = true
            } else {
                // Fallback on earlier versions
            }
        }
        navigationController?.isNavigationBarHidden = false
        self.navigationItem.largeTitleDisplayMode = .never
        self.navigationController?.navigationBar.prefersLargeTitles = false
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        title = "Server features".localizeString(id: "signin_server_features", arguments: [])
    }
    
    private final func loadDatasource() {
        
        isSyncAvailable = SettingManager.shared.getKey(for: jid, scope: .clientSynchronization, key: "version") != nil
        isPushAvailable = features.isEmpty ? false : features.contains("xpush")
        isMamAvailable = features.isEmpty ? false : features.contains("mam")
        isRewriteAvailable = features.isEmpty ? false : features.contains("rewrite")
        isDeviceManagementAvailable = AccountManager.shared.find(for: jid)?.devices.isAvailable ?? false
        isPubsubAvailable = features.isEmpty ? false : features.contains("pubsub")
//        isXabberUploadAvailable = features.isEmpty ? false : features.contains("xabber")
        
//        let syncText = NSMutableAttributedString(string: "Quick synchronization is not supported. This feature allows robust work on mobile devices and greatly improves user experience. It is not recommended to use Xabber on servers without quick synchronization.").localizeHTML(id: "signin_quick_synchronization_error", arguments: [])
//
//        let pushText = NSMutableAttributedString(string: "Push notifications are not supported. Your device won’t be able to receive incoming messages when Xabber is not active. It is not recommended to use Xabber on this server.").localizeHTML(id: "signin_push_notifications_error", arguments: [])
//
//        let mamText = NSMutableAttributedString(string: "Message Archive is not supported. Without Message Archive you can’t synchronize chat history between server and connected clients.  Xabber can not be used on servers that do not support message archive.").localizeHTML(id: "signin_message_archive_error", arguments: [])
//
//        let rewriteText = NSMutableAttributedString(string: "Message editing is not supported. You will not be able to edit or delete messages from this server’s Message Archive.").localizeHTML(id: "signin_message_editing_error", arguments: [])
//
//        let devicesText = NSMutableAttributedString(string: "Xabber tokens are not supported. Without Xabber tokens you can’t revoke access from compromised devices. Account password will be stored locally and can be potentially stolen. ").localizeHTML(id: "signin_tokens_error", arguments: [])
//
//        let pubsubText = NSMutableAttributedString(string: "PubSub is not supported. Without publish-subscribe, you can’t use modern encryption, set user avatar, etc. It is not recommended to use Xabber on this server.").localizeHTML(id: "signin_pubsub_error", arguments: [])
//
//        let httpText = NSMutableAttributedString(string: "File upload is not supported. Without file upload, you will not be able to send images, voice messages and other media to your contacts. It is not recommended to use Xabber on servers without file upload support.").localizeHTML(id: "signin_file_upload_error", arguments: [])
        
        let syncText = "Quick synchronization is not supported. This feature allows robust work on mobile devices and greatly improves user experience. It is not recommended to use Clandestino on servers without quick synchronization.".localizeHTML(id: "signin_quick_synchronization_error", arguments: [])
        
        let pushText = "Push notifications are not supported. Your device won’t be able to receive incoming messages when Clandestino is not active. It is not recommended to use Clandestino on this server.".localizeHTML(id: "signin_push_notifications_error", arguments: [])
        
        let mamText = "Message Archive is not supported. Without Message Archive you can’t synchronize chat history between server and connected clients.  Clandestino can not be used on servers that do not support message archive.".localizeHTML(id: "signin_message_archive_error", arguments: [])
        
        let rewriteText = "Message editing is not supported. You will not be able to edit or delete messages from this server’s Message Archive.".localizeHTML(id: "signin_message_editing_error", arguments: [])
        
        let devicesText = "Clandestino tokens are not supported. Without Clandestino tokens you can’t revoke access from compromised devices. Account password will be stored locally and can be potentially stolen. ".localizeHTML(id: "signin_tokens_error", arguments: [])
        
        let pubsubText = "PubSub is not supported. Without publish-subscribe, you can’t use modern encryption, set user avatar, etc. It is not recommended to use Clandestino on this server.".localizeHTML(id: "signin_pubsub_error", arguments: [])
        
        let httpText = "File upload is not supported. Without file upload, you will not be able to send images, voice messages and other media to your contacts. It is not recommended to use Clandestino on servers without file upload support.".localizeHTML(id: "signin_file_upload_error", arguments: [])
        
//        [syncText, pushText, mamText, rewriteText, devicesText, pubsubText, httpText].forEach({
//            item in
//            if let sentenceLength = item.string.firstIndex(of: ".") {
//                let range = NSRange(item.string.startIndex..<sentenceLength, in: item.string)
//                item.addAttribute(.font, value: UIFont.systemFont(ofSize: 15, weight: .medium), range: range)
//            }
//        })
        guard let host = XMPPJID(string: self.jid)?.domain else { return }
        
        datasource = [
            Datasource(key: "title",
                       kind: .title,
                       title: "Hang on there a second! Checking if \(host) supports all necessary features."
                        .localizeString(id: "signin_checking_features_message", arguments: ["\(host)"]),
                       isHidden: false),
            Datasource(key: "featureMam",
                       kind: .feature,
                       title: "Message archive".localizeString(id: "signin_message_archive", arguments: []),
                       attributedText: mamText, isHidden: false, isDanger: true),
            Datasource(key: "featureSync",
                       kind: .feature,
                       title: "Synchronization".localizeString(id: "signin_synchronization", arguments: []),
                       attributedText: syncText),
            Datasource(key: "featurePush",
                       kind: .feature,
                       title: "Push notifications".localizeString(id: "settings_account__label_push_notifications", arguments: []),
                       attributedText: pushText),
            Datasource(key: "featureRewrite",
                       kind: .feature,
                       title: "Message editing".localizeString(id: "signin_message_editing", arguments: []),
                       attributedText: rewriteText),
            Datasource(key: "featureDevices",
                       kind: .feature,
                       title: "Device management".localizeString(id: "signin_device_management", arguments: []),
                       attributedText: devicesText),
            Datasource(key: "featurePubsub",
                       kind: .feature,
                       title: "Publish-subscribe".localizeString(id: "signin_publish_subscribe", arguments: []),
                       attributedText: pubsubText),
//            Datasource(key: "featureXabberUpload",
//                       kind: .feature,
//                       title: "File upload",
//                       attributedText: httpText),
            Datasource(key: "featureHttpUpload",
                       kind: .feature,
                       title: "File upload".localizeString(id: "signin_file_upload", arguments: []),
                       attributedText: httpText),
            Datasource(key: "subtitle",
                       kind: .subtitle,
                       title: "Ask to register on clandestino.chat if his xmpp server is old.".localizeString(id: "signin_ask_to_register", arguments: [])),
            Datasource(key: "registerButton", kind: .button, title: "Create new account"
                        .localizeString(id: "xmpp_login__button_sign_up", arguments: [])),
            Datasource(key: "connectButton", kind: .button, title: "Let's rock!"
                        .localizeString(id: "signin_lets_rock", arguments: []), value: true),
        ]
    }
    
    private final func activateConstraints() {
        
    }
        
    override func viewDidLoad() {
        super.viewDidLoad()
        setup()
        configure()
        loadDatasource()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        tableView.reloadData()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        continuesFeatureAppearing()
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
    
    private final func closeViewController() {
//        let vc = UISplitViewController(style: .tripleColumn)
//        vc.navigationItem.largeTitleDisplayMode = .always
//        vc.navigationController?.navigationBar.prefersLargeTitles = true
//        vc.restorationIdentifier = "MainSplitViewController"
//        vc.restoresFocusAfterTransition = true
//        let chatsVc = LastChatsViewController()
//        let primaryVc = LeftMenuViewController()
//        let emptyChatVc = EmptyChatViewController()
//        primaryVc.chatsVc = chatsVc
//        chatsVc.splitDelegate = emptyChatVc
//        chatsVc.navigationController?.navigationBar.prefersLargeTitles = true
//        vc.minimumPrimaryColumnWidth = 320
//        vc.minimumSupplementaryColumnWidth = 320
//        vc.displayModeButtonVisibility = .always
//        vc.preferredDisplayMode = .oneBesideSecondary//.oneBesideSecondary//.allVisible
//        vc.preferredSplitBehavior = .displace//.tile
//        vc.primaryBackgroundStyle = .sidebar
//        
//        vc.delegate = (UIApplication.shared.delegate as! AppDelegate)
//        vc.viewControllers = [
//            primaryVc,
//            chatsVc,
//            UINavigationController(rootViewController: emptyChatVc)
//        ]
//        (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = vc
//        (UIApplication.shared.delegate as! AppDelegate).splitController = vc
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        AppDelegate.setupRootViewController(instance: appDelegate, window: appDelegate?.window, userInfo: nil)
    }
    
    private final func continuesFeatureAppearing() {
        var counter: Int = 0
        let repeatLimit: Int = 30
        let timer = Timer.scheduledTimer(withTimeInterval: 0.66, repeats: true) { timer in
            guard let index = self.datasource.firstIndex(where: { $0.kind == .feature && $0.value == nil }) else {
                timer.invalidate()
                return
            }
            counter += 1
            var allFeaturesInserted: Bool = false
            var isLastFeatureChecked: Bool = false
            switch self.datasource[index].key {
            case "featureSync":
                self.datasource[index].value = self.isSyncAvailable
            case "featurePush":
                self.datasource[index].value = self.isPushAvailable
            case "featureMam":
                self.datasource[index].value = self.isMamAvailable
            case "featureRewrite":
                self.datasource[index].value = self.isRewriteAvailable
            case "featureDevices":
                self.datasource[index].value = self.isDeviceManagementAvailable
            case "featurePubsub":
                self.datasource[index].value = self.isPubsubAvailable
            case "featureHttpUpload":
                isLastFeatureChecked = true
                if let value = self.isHTTPUploadAvailable {
                    self.datasource[index].value = value
                    allFeaturesInserted = true
                } else {
                    
                    self.isHTTPUploadAvailable = AccountManager.shared.find(for: self.jid)?.cloudStorage.isAvailable() ?? false
                }

            default: break
            }
            if allFeaturesInserted {
                self.tableView.performBatchUpdates {
                    self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                } completion: { _ in
                    
                }
                timer.invalidate()
                self.showControlsRows()
            } else if !isLastFeatureChecked {
                self.datasource[index + 1].isHidden = false
                self.tableView.performBatchUpdates {
                    self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                    self.tableView.insertRows(at: [IndexPath(row: index + 1, section: 0)], with: .top)
                } completion: { _ in
                    
                }
            }

        }
        RunLoop.main.add(timer, forMode: .default)
    }
    
    private final func showControlsRows() {
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.27
        paragraph.alignment = .center
        
        if (self.isPushAvailable ?? false)
            && (self.isMamAvailable ?? false)
            && (self.isSyncAvailable ?? false)
            && (self.isRewriteAvailable ?? false)
            && (self.isDeviceManagementAvailable ?? false)
            && (self.isPubsubAvailable ?? false)
//            && (self.isXabberUploadAvailable ?? false)
            && (self.isHTTPUploadAvailable ?? false) {
            self.datasource.first(where: { $0.key == "subtitle" })?.isHidden = false
            self.datasource.first(where: { $0.key == "connectButton" })?.isHidden = false
            guard let subtitleIndex = self.datasource
                    .filter({ !$0.isHidden })
                    .firstIndex(where: { $0.key == "subtitle" }),
                let connectButtonIndex = self.datasource
                  .filter({ !$0.isHidden })
                  .firstIndex(where: { $0.key == "connectButton" }) else {
                return
            }
            self.datasource[subtitleIndex].attributedText = NSAttributedString(string: "Shiny! Everything’s fine! Press the button below and start messaging r-r-right away!!"
                        .localizeString(id: "signin_start_messaging_message", arguments: []),
                        attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.green.tint800, .font: UIFont.systemFont(ofSize: 15)])
            self.datasource[connectButtonIndex].value = true
            self.tableView.performBatchUpdates {
                self.tableView.insertRows(
                    at: [IndexPath(row: subtitleIndex, section: 0),
                         IndexPath(row: connectButtonIndex, section: 0)],
                    with: .bottom)
            } completion: { _ in
                
            }
        } else {
            if (self.isMamAvailable ?? false) {
                self.datasource.first(where: { $0.key == "subtitle" })?.isHidden = false
                self.datasource.first(where: { $0.key == "connectButton" })?.isHidden = false
                self.datasource.first(where: { $0.key == "registerButton" })?.isHidden = false
                guard let subtitleIndex = self.datasource
                        .filter({ !$0.isHidden })
                        .firstIndex(where: { $0.key == "subtitle" }),
                      let connectButtonIndex = self.datasource
                        .filter({ !$0.isHidden })
                        .firstIndex(where: { $0.key == "connectButton" }),
                      let registerButtonIndex = self.datasource
                        .filter({ !$0.isHidden })
                        .firstIndex(where: { $0.key == "registerButton" }) else {
                    return
                }
                let attrSubtitle = NSMutableAttributedString(string: "Not all necessary features are supported. Proceed using this account at your own risk, and with low expectations. However, we suggest creating a new account on a fully-compatible Xabber server.".localizeString(id: "signin_not_all_features", arguments: []),
                        attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.yellow.tint800, .font: UIFont.systemFont(ofSize: 15)])
                let range = (attrSubtitle.string as NSString).range(of: "xabber.chat")
                attrSubtitle.addAttribute(.font, value: UIFont.systemFont(ofSize: 13, weight: .medium), range: range)
                self.datasource[subtitleIndex].attributedText = attrSubtitle
                self.datasource[connectButtonIndex].title = "Proceed anyway"
                    .localizeString(id: "signin_proceed_anyway", arguments: [])
                self.datasource[connectButtonIndex].value = false
                self.datasource[registerButtonIndex].value = true
                self.tableView.performBatchUpdates {
                    self.tableView.insertRows(
                        at: [IndexPath(row: subtitleIndex, section: 0),
                             IndexPath(row: connectButtonIndex, section: 0),
                             IndexPath(row: registerButtonIndex, section: 0)],
                        with: .bottom)
                } completion: { _ in
                    
                }
            } else {
                self.datasource.first(where: { $0.key == "subtitle" })?.isHidden = false
                self.datasource.first(where: { $0.key == "registerButton" })?.isHidden = false
                guard let subtitleIndex = self.datasource
                        .filter({ !$0.isHidden })
                        .firstIndex(where: { $0.key == "subtitle" }),
                      let registerButtonIndex = self.datasource
                        .filter({ !$0.isHidden })
                        .firstIndex(where: { $0.key == "registerButton" }) else {
                    return
                }
                self.datasource[subtitleIndex].attributedText = NSAttributedString(string: "This server does not support message archive. It is impossible for Clandestino to work without message archive, so we suggest creating a new account on a fully-compatible Clandestno server.".localizeString(id: "signin_no_message_archive", arguments: []),
                            attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.red.tint800, .font: UIFont.systemFont(ofSize: 15)])
                self.datasource[registerButtonIndex].value = true
                self.tableView.performBatchUpdates {
                    self.tableView.insertRows(
                        at: [IndexPath(row: subtitleIndex, section: 0),
                             IndexPath(row: registerButtonIndex, section: 0)],
                        with: .bottom)
                } completion: { _ in
                    
                }
            }
            
        }
    }
    
    private final func onRegisterButtonTouchUp() {
        AccountManager.shared.deleteAccount(by: self.jid)
        let rootVc = OnboardingViewController()
        rootVc.title = " "
        let vc = SignUpSelectNicknameViewController()
        if let host = self.host {
            vc.metadata = ["host": host]
        }
        self.navigationController?.setViewControllers([rootVc, vc], animated: true)
    }
    
    private final func onContinueButtonTouchUp() {
//        let vc = YubikeySetupViewController()
//        self.navigationController?.pushViewController(vc, animated: true)
        if isModal {
            self.dismiss(animated: true, completion: nil)
        } else {
            if CommonConfigManager.shared.config.required_touch_id_or_password {
                let vc = PasscodeViewController(isOnboarding: true)
                self.navigationController?.pushViewController(vc, animated: true)
            } else {
                let appDelegate = UIApplication.shared.delegate as? AppDelegate
                AppDelegate.setupRootViewController(instance: appDelegate, window: appDelegate?.window, userInfo: nil)
            }
        }
    }
}

extension SignInServerFeaturesViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.filter { !$0.isHidden }.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource.filter { !$0.isHidden } [indexPath.row]
        switch item.kind {
        case .title:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SignInTitleCell.cellName, for: indexPath) as? SignInTitleCell else {
                fatalError()
            }
            
            cell.configure(item.title ?? "")
            
            return cell
        case .feature:
            let cell =  SignInFeatureCell()
            
            cell.configure(title: item.title ?? "")
            cell.errorText = item.attributedText ?? NSAttributedString()
            if let value = item.value {
                if value {
                    cell.setChecked(true)
                } else {
                    cell.setError(true, isDamger: item.isDanger)
                }
            }
            return cell
        case .subtitle:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SignInSubtitleCell.cellName, for: indexPath) as? SignInSubtitleCell else {
                fatalError()
            }
            
            cell.configure(item.attributedText ?? NSAttributedString())
            
            return cell
        case .button:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SignInButtonCell.cellName, for: indexPath) as? SignInButtonCell else {
                fatalError()
            }
            
            cell.configure(item.title ?? "", active: item.value ?? false)
            
            if item.key == "registerButton" {
                cell.onButtonTouchUpCallback = self.onRegisterButtonTouchUp
            } else if item.key == "connectButton" {
                cell.onButtonTouchUpCallback = self.onContinueButtonTouchUp
            }
            return cell
        }
    }
}

extension SignInServerFeaturesViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource.filter { !$0.isHidden } [indexPath.row]
        switch item.kind {
        case .title:
            return 102
        case .feature:
            return tableView.estimatedRowHeight
        case .subtitle:
            return tableView.estimatedRowHeight
        case .button:
            return 64
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource.filter { !$0.isHidden }[indexPath.row]
        switch item.kind {
        case .feature:
            
            break
        default:
            break
        }
    }
    
}
