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
import RxCocoa
import RxSwift

enum SignInCloudStorageFeaturePresentationPolicy {
    struct Presentation: Equatable {
        enum Status: Equatable {
            case checking
            case supported
            case retryableFailure
            case unsupported
        }

        let featureValue: Bool?
        let isCapabilitySupported: Bool
        let isPermanentFailure: Bool
        let status: Status

        /// A retryable failure is rendered as a transient warning instead of
        /// an endless activity indicator. `featureValue` remains the semantic
        /// capability value used by non-UI consumers.
        var displayFeatureValue: Bool? {
            featureValue
        }
    }

    static func resolve(_ state: CloudStorageAvailabilityState) -> Presentation {
        switch state {
        case .discovering:
            return Presentation(
                featureValue: nil,
                isCapabilitySupported: false,
                isPermanentFailure: false,
                status: .checking
            )
        case .authorizing, .ready:
            return Presentation(
                featureValue: true,
                isCapabilitySupported: true,
                isPermanentFailure: false,
                status: .supported
            )
        case .unsupported:
            return Presentation(
                featureValue: false,
                isCapabilitySupported: false,
                isPermanentFailure: true,
                status: .unsupported
            )
        case .retryableFailure(_, let endpoint):
            return Presentation(
                featureValue: endpoint.map { _ in true },
                isCapabilitySupported: endpoint != nil,
                isPermanentFailure: false,
                status: .retryableFailure
            )
        }
    }
}

enum SignInCloudStorageFeatureReducer {
    struct State: Equatable {
        let availabilityState: CloudStorageAvailabilityState
        let presentation: SignInCloudStorageFeaturePresentationPolicy.Presentation

        var shouldResolveControls: Bool {
            if case .discovering = availabilityState {
                return false
            }
            return true
        }
    }

    static let initialState = State(
        availabilityState: .discovering,
        presentation: SignInCloudStorageFeaturePresentationPolicy.resolve(.discovering)
    )

    static func reduce(
        _ state: State,
        availabilityState: CloudStorageAvailabilityState
    ) -> State {
        guard state.availabilityState != availabilityState else {
            return state
        }
        return State(
            availabilityState: availabilityState,
            presentation: SignInCloudStorageFeaturePresentationPolicy.resolve(availabilityState)
        )
    }
}

enum SignInServerFeaturesControlsMode: Equatable {
    case fullySupported
    case partiallySupported
    case messageArchiveUnsupported
    case temporarilyUnverified
}

enum SignInServerFeaturesControlsPolicy {
    static func resolve(
        serverCapabilitiesAreRetryable: Bool = false,
        isMessageArchiveAvailable: Bool,
        areOtherRequiredFeaturesAvailable: Bool,
        cloudStorageAvailabilityState: CloudStorageAvailabilityState
    ) -> SignInServerFeaturesControlsMode? {
        if serverCapabilitiesAreRetryable {
            return .temporarilyUnverified
        }
        guard case .discovering = cloudStorageAvailabilityState else {
            guard isMessageArchiveAvailable else {
                return .messageArchiveUnsupported
            }
            if case .unsupported = cloudStorageAvailabilityState {
                return .partiallySupported
            }
            return areOtherRequiredFeaturesAvailable
                ? .fullySupported
                : .partiallySupported
        }
        return nil
    }

    static func resolve(
        isMessageArchiveAvailable: Bool,
        areOtherRequiredFeaturesAvailable: Bool,
        cloudStorageFeatureValue: Bool?
    ) -> SignInServerFeaturesControlsMode? {
        guard let cloudStorageFeatureValue = cloudStorageFeatureValue else {
            return nil
        }
        guard isMessageArchiveAvailable else {
            return .messageArchiveUnsupported
        }
        return areOtherRequiredFeaturesAvailable && cloudStorageFeatureValue
            ? .fullySupported
            : .partiallySupported
    }
}

enum SignInServerFeaturesRevealPolicy {
    /// Keep the feature checklist legible without making capability discovery
    /// look slower than it is. The seventh (File upload) row is resolved in
    /// under one second after the server capabilities arrive.
    static let screenPresentationDelay: TimeInterval = 0.10
    static let featureCadence: TimeInterval = 0.12

    static func totalDelayUntilFeature(at zeroBasedIndex: Int) -> TimeInterval {
        screenPresentationDelay + featureCadence * Double(max(0, zeroBasedIndex) + 1)
    }
}

enum SignInServerFeaturesRenderGatePolicy {
    enum Action: Equatable {
        case deferFullReload
        case commitFullReload
    }

    static func action(
        isPresentationActive: Bool,
        isTableAttachedToWindow: Bool
    ) -> Action {
        guard isPresentationActive, isTableAttachedToWindow else {
            return .deferFullReload
        }
        return .commitFullReload
    }
}

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

    private var serverCapabilitiesAreRetryable: Bool {
        features.contains(ServerDiscoManager.retryableServerCapabilitiesMarker)
    }
    
    private var isPushAvailable             : Bool? = nil
    private var isMamAvailable              : Bool? = nil
    private var isSyncAvailable             : Bool? = nil
    private var isRewriteAvailable          : Bool? = nil
    private var isDeviceManagementAvailable : Bool? = nil
    private var isPubsubAvailable           : Bool? = nil
    private var isHTTPUploadAvailable       : Bool? = nil
//    private var isXabberUploadAvailable     : Bool? = nil
    private var cloudStorageFeatureState = SignInCloudStorageFeatureReducer.initialState
    private var cloudStorageUnsupportedText: NSAttributedString?
    private let disposeBag = DisposeBag()
    private var featureAppearanceTimer: Timer?
    private var isPresentationActive: Bool = false
    private var hasPendingFullTableRender: Bool = false
    var fullTableRenderDidCommitForTesting: (() -> Void)?

    private final func requestFullTableRender() {
        hasPendingFullTableRender = true
        commitPendingFullTableRenderIfPossible()
    }

    private final func commitPendingFullTableRenderIfPossible() {
        guard hasPendingFullTableRender else {
            return
        }
        guard SignInServerFeaturesRenderGatePolicy.action(
            isPresentationActive: isPresentationActive,
            isTableAttachedToWindow: tableView.window != nil
        ) == .commitFullReload else {
            return
        }
        hasPendingFullTableRender = false
        fullTableRenderDidCommitForTesting?()
        tableView.reloadData()
    }
    
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
        
        let syncText = "Quick synchronization is not supported. This feature allows robust work on mobile devices and greatly improves user experience. It is not recommended to use Xabber on servers without quick synchronization.".localizeHTML(id: "signin_quick_synchronization_error", arguments: [])
        
        let pushText = "Push notifications are not supported. Your device won’t be able to receive incoming messages when Xabber is not active. It is not recommended to use Xabber on this server.".localizeHTML(id: "signin_push_notifications_error", arguments: [])
        
        let mamText = "Message Archive is not supported. Without Message Archive you can’t synchronize chat history between server and connected clients.  Xabber can not be used on servers that do not support message archive.".localizeHTML(id: "signin_message_archive_error", arguments: [])
        
        let rewriteText = "Message editing is not supported. You will not be able to edit or delete messages from this server’s Message Archive.".localizeHTML(id: "signin_message_editing_error", arguments: [])
        
        let devicesText = "Xabber devices are not supported. Without Xabber devices you can’t revoke access from compromised devices. Account password will be stored locally and can be potentially stolen. ".localizeHTML(id: "signin_tokens_error", arguments: [])
        
        let pubsubText = "PubSub is not supported. Without publish-subscribe, you can’t use modern encryption, set user avatar, etc. It is not recommended to use Xabber on this server.".localizeHTML(id: "signin_pubsub_error", arguments: [])
        
        let httpText = "Cloud storage is not supported. Without cloud storage, you will not be able to send images, voice messages and other media to your contacts. It is not recommended to use Xabber on servers without cloud storage support.".localizeHTML(id: "signin_file_upload_error", arguments: [])
        cloudStorageUnsupportedText = httpText
        
//        [syncText, pushText, mamText, rewriteText, devicesText, pubsubText, httpText].forEach({
//            item in
//            if let sentenceLength = item.string.firstIndex(of: ".") {
//                let range = NSRange(item.string.startIndex..<sentenceLength, in: item.string)
//                item.addAttribute(.font, value: UIFont.systemFont(ofSize: 15, weight: .medium), range: range)
//            }
//        })
        guard let host = XMPPJID(string: self.jid)?.domain else { return }

        if serverCapabilitiesAreRetryable {
            let retryableCapabilitiesText = "The server capability check could not be completed. This is temporary and does not mean that the server lacks these features."
                .localizeHTML(id: "signin_server_capabilities_retryable_failure", arguments: [])
            let retryableCloudText = "Could not verify Cloud Storage right now. The app will retry automatically."
                .localizeHTML(id: "signin_cloud_storage_retryable_failure", arguments: [])
            datasource = [
                Datasource(
                    key: "title",
                    kind: .title,
                    title: "Could not verify all capabilities of \(host) right now. You can continue; the app will retry automatically."
                        .localizeString(id: "signin_server_capabilities_retryable_title", arguments: ["\(host)"]),
                    isHidden: false
                ),
                Datasource(
                    key: "featureServerCapabilities",
                    kind: .feature,
                    title: "Server capabilities".localizeString(id: "signin_server_capabilities", arguments: []),
                    attributedText: retryableCapabilitiesText,
                    value: false,
                    isHidden: false
                ),
                Datasource(
                    key: "featureHttpUpload",
                    kind: .feature,
                    title: "Cloud storage".localizeString(id: "signin_cloud_storage", arguments: []),
                    attributedText: retryableCloudText,
                    isHidden: false
                ),
                Datasource(
                    key: "subtitle",
                    kind: .subtitle,
                    title: "Server capabilities will be checked again automatically."
                        .localizeString(id: "signin_server_capabilities_retryable_subtitle", arguments: [])
                ),
                Datasource(
                    key: "registerButton",
                    kind: .button,
                    title: "Create new account".localizeString(id: "xmpp_login__button_sign_up", arguments: [])
                ),
                Datasource(
                    key: "connectButton",
                    kind: .button,
                    title: "Proceed anyway".localizeString(id: "signin_proceed_anyway", arguments: []),
                    value: false
                )
            ]
            return
        }
        
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
                       title: "Cloud storage".localizeString(id: "signin_cloud_storage", arguments: []),
                       attributedText: httpText),
            Datasource(key: "subtitle",
                       kind: .subtitle,
                       title: "Ask to register on xabber.com if his xmpp server is old.".localizeString(id: "signin_ask_to_register", arguments: [])),
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
        bindCloudStorageAvailability()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        requestFullTableRender()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationActive = true
        requestFullTableRender()
        continuesFeatureAppearing()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        commitPendingFullTableRenderIfPossible()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationActive = false
        featureAppearanceTimer?.invalidate()
        featureAppearanceTimer = nil
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        featureAppearanceTimer?.invalidate()
        featureAppearanceTimer = nil
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
        featureAppearanceTimer?.invalidate()
        guard isPresentationActive else {
            featureAppearanceTimer = nil
            return
        }
        let timer = Timer(
            timeInterval: SignInServerFeaturesRevealPolicy.featureCadence,
            repeats: true
        ) { [weak self] timer in
            guard let self, self.isPresentationActive else {
                timer.invalidate()
                return
            }
            guard let index = self.datasource.firstIndex(where: {
                $0.kind == .feature && $0.value == nil
            }) else {
                timer.invalidate()
                return
            }
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
                if let value = self.resolvedCloudStorageFeatureValue {
                    self.isHTTPUploadAvailable = value
                    self.datasource[index].value = value
                }

            default: break
            }
            if isLastFeatureChecked {
                guard self.datasource[index].value != nil else {
                    return
                }
                timer.invalidate()
                self.showControlsRows()
                return
            }

            let nextIndex = index + 1
            if self.datasource.indices.contains(nextIndex) {
                self.datasource[nextIndex].isHidden = false
            }
            self.requestFullTableRender()
        }
        featureAppearanceTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private var resolvedCloudStorageFeatureValue: Bool? {
        cloudStorageFeatureState.presentation.displayFeatureValue
    }

    private func bindCloudStorageAvailability() {
        guard let manager = AccountManager.shared.find(for: jid)?.cloudStorage else {
            applyCloudStorageAvailability(
                .retryableFailure(stage: .discovery, endpoint: nil)
            )
            return
        }
        manager.availabilityRelay
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                self?.applyCloudStorageAvailability(state)
            })
            .disposed(by: disposeBag)
    }

    private func applyCloudStorageAvailability(_ state: CloudStorageAvailabilityState) {
        cloudStorageFeatureState = SignInCloudStorageFeatureReducer.reduce(
            cloudStorageFeatureState,
            availabilityState: state
        )
        let presentation = cloudStorageFeatureState.presentation
        isHTTPUploadAvailable = presentation.featureValue
        guard let index = datasource.firstIndex(where: { $0.key == "featureHttpUpload" }) else {
            return
        }

        var presentationChanged = false
        switch presentation.status {
        case .retryableFailure:
            let retryableText = "Could not verify Cloud Storage right now. The app will retry automatically."
                .localizeHTML(id: "signin_cloud_storage_retryable_failure", arguments: [])
            presentationChanged = datasource[index].attributedText != retryableText
                || datasource[index].isDanger
            datasource[index].attributedText = retryableText
            datasource[index].isDanger = false
        case .unsupported, .checking, .supported:
            if let unsupportedText = cloudStorageUnsupportedText {
                presentationChanged = datasource[index].attributedText != unsupportedText
                datasource[index].attributedText = unsupportedText
            }
        }

        guard datasource[index].isHidden == false else { return }

        let displayFeatureValue = presentation.displayFeatureValue
        let valueChanged = datasource[index].value != displayFeatureValue
        datasource[index].value = displayFeatureValue
        if valueChanged || presentationChanged {
            requestFullTableRender()
        }
        guard cloudStorageFeatureState.shouldResolveControls else { return }
        featureAppearanceTimer?.invalidate()
        featureAppearanceTimer = nil
        showControlsRows()
    }
    
    private final func showControlsRows() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.27
        paragraph.alignment = .center

        guard let subtitle = datasource.first(where: { $0.key == "subtitle" }),
              let connectButton = datasource.first(where: { $0.key == "connectButton" }),
              let registerButton = datasource.first(where: { $0.key == "registerButton" }) else {
            return
        }
        subtitle.isHidden = true
        connectButton.isHidden = true
        registerButton.isHidden = true
        connectButton.title = "Let's rock!"
            .localizeString(id: "signin_lets_rock", arguments: [])
        connectButton.value = true
        registerButton.value = true

        let areOtherRequiredFeaturesAvailable = (self.isPushAvailable ?? false)
            && (self.isSyncAvailable ?? false)
            && (self.isRewriteAvailable ?? false)
            && (self.isDeviceManagementAvailable ?? false)
            && (self.isPubsubAvailable ?? false)
        guard let controlsMode = SignInServerFeaturesControlsPolicy.resolve(
            serverCapabilitiesAreRetryable: serverCapabilitiesAreRetryable,
            isMessageArchiveAvailable: self.isMamAvailable ?? false,
            areOtherRequiredFeaturesAvailable: areOtherRequiredFeaturesAvailable,
            cloudStorageAvailabilityState: cloudStorageFeatureState.availabilityState
        ) else {
            return
        }

        switch controlsMode {
        case .fullySupported:
            subtitle.isHidden = false
            connectButton.isHidden = false
            subtitle.attributedText = NSAttributedString(string: "Shiny! Everything’s fine! Press the button below and start messaging r-r-right away!!"
                        .localizeString(id: "signin_start_messaging_message", arguments: []),
                        attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.green.tint800, .font: UIFont.systemFont(ofSize: 15)])
        case .partiallySupported:
            subtitle.isHidden = false
            connectButton.isHidden = false
            registerButton.isHidden = false
            let attrSubtitle = NSMutableAttributedString(string: "Not all necessary features are supported. Proceed using this account at your own risk, and with low expectations. However, we suggest creating a new account on a fully-compatible Xabber server.".localizeString(id: "signin_not_all_features", arguments: []),
                    attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.yellow.tint800, .font: UIFont.systemFont(ofSize: 15)])
            let range = (attrSubtitle.string as NSString).range(of: "xabber.chat")
            attrSubtitle.addAttribute(.font, value: UIFont.systemFont(ofSize: 13, weight: .medium), range: range)
            subtitle.attributedText = attrSubtitle
            connectButton.title = "Proceed anyway"
                .localizeString(id: "signin_proceed_anyway", arguments: [])
            connectButton.value = false
        case .messageArchiveUnsupported:
            subtitle.isHidden = false
            registerButton.isHidden = false
            subtitle.attributedText = NSAttributedString(string: "This server does not support message archive. It is impossible for Xabber to work without message archive, so we suggest creating a new account on a fully-compatible Xabber server.".localizeString(id: "signin_no_message_archive", arguments: []),
                        attributes: [.paragraphStyle: paragraph, .foregroundColor: MDCPalette.red.tint800, .font: UIFont.systemFont(ofSize: 15)])
        case .temporarilyUnverified:
            subtitle.isHidden = false
            connectButton.isHidden = false
            subtitle.attributedText = NSAttributedString(
                string: "Some server capabilities could not be verified right now. You can continue safely; the app will retry automatically."
                    .localizeString(id: "signin_server_capabilities_retryable_subtitle", arguments: []),
                attributes: [
                    .paragraphStyle: paragraph,
                    .foregroundColor: MDCPalette.yellow.tint800,
                    .font: UIFont.systemFont(ofSize: 15)
                ]
            )
            connectButton.title = "Proceed anyway"
                .localizeString(id: "signin_proceed_anyway", arguments: [])
            connectButton.value = false
        }
        requestFullTableRender()
    }
    
    private final func onRegisterButtonTouchUp() {
        EULANavigationGate.continueAfterAcceptance(from: self) { [weak self] in
            self?.continueToRegistration()
        }
    }

    private final func continueToRegistration() {
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
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
            AppDelegate.setupRootViewController(instance: appDelegate, window: appDelegate?.window, userInfo: nil)
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
